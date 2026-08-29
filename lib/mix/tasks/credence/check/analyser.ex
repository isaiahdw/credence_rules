defmodule Mix.Tasks.Credence.Check.Analyser do
  @moduledoc """
  In-process per-file analyser.

  Runs Credence's **Syntax** + **Pattern** phases plus the custom
  [`CredenceRules.Pattern.*`](`CredenceRules`) rules on
  the source AST. The **Semantic** phase is intentionally skipped —
  it's the only phase that calls `Code.compile_string/2`, which loads
  modules into the BEAM's global code table and can't be fully
  reclaimed (`:code.purge/1` + `:code.delete/1` leaves persistent
  traces in atoms / `:elixir_module` ETS entries / attribute storage).
  Skipping it means we can run hundreds of files in one BEAM with
  bounded memory — matching how Credo, Sobelow, and `mix format`
  handle the same problem.

  Trade-off: we lose Credence's compiler-warning diagnostics (unused
  vars, dead clauses, shadowing). Those are already surfaced by
  `mix compile --warnings-as-errors`; this project's value-add is the
  AST-only Pattern rules targeting LLM failure modes.

  ## Per-rule configuration

  Every rule in this project's catalog accepts options. To tune a
  rule's threshold project-wide, set `:rule_opts` in your
  Application env:

      config :credence_rules,
        rule_opts: %{
          large_defstruct: [min_clusters: 3, scan_min_fields: 15],
          genserver_handle_call_explosion: [
            max_handle_call: 12,
            max_handle_call_per_instance: 20,
            max_handle_call_read_bypass: 24
          ],
          forbidden_module_dependency: [graph_source: :beam],
          iosp_predicate_side_effects: [
            side_effect_modules: ~w(Repo Req Phoenix.PubSub MyApp.Mailer)
          ]
        }

  The analyser merges each rule's per-rule opts on top of the
  global opts (`:source`, `:allowed_modules`) before calling the
  rule's `check/2`. Built-in Credence rules receive only the global
  opts — they aren't keyed by atom in our `:rule_opts` map.

  Pure function of input — no shared state, safe to call concurrently
  from `Task.async_stream`.
  """

  alias CredenceRules.Finding
  alias Credence.Issue

  @type issue :: %{
          rule: atom(),
          line: pos_integer() | nil,
          message: String.t(),
          severity: Finding.level(),
          confidence: Finding.level(),
          fingerprint: String.t() | nil
        }

  @doc """
  Analyse one file. Returns `{path, [issue], line_count}` so the
  caller can stay agnostic about ordering when running
  concurrently. `line_count` is the number of non-empty source
  lines, used by `CredenceRules.Score` to compute the
  lines-clean ratio.

  `cli_opts` is a keyword list of options the CLI explicitly
  passed (currently `:graph_source`). Threaded through with
  **CLI last-wins** precedence — overrides per-rule `:rule_opts`,
  which override Application env, which overrides the rule's
  built-in defaults.
  """
  @spec analyse(Path.t(), keyword()) :: {Path.t(), [issue], non_neg_integer()}
  def analyse(path, cli_opts \\ []) do
    source = File.read!(path)
    opts_with_path = Keyword.put_new(cli_opts, :source_path, path)
    {path, analyse_source(source, opts_with_path), count_non_empty_lines(source)}
  end

  @doc """
  Count non-empty source lines. Skips lines that are pure
  whitespace; counts comments and code alike. Used as the
  denominator for the lines-clean score.
  """
  @spec count_non_empty_lines(String.t()) :: non_neg_integer()
  def count_non_empty_lines(source) do
    source
    |> String.split("\n")
    |> Enum.count(&(String.trim(&1) != ""))
  end

  @doc """
  Like `analyse/2` but takes the source string directly. Exposed
  for tests that want to drive the pipeline without touching disk.
  """
  @spec analyse_source(String.t(), keyword()) :: [issue]
  def analyse_source(source, cli_opts \\ []) do
    global_opts = [
      source: source,
      source_path: Keyword.get(cli_opts, :source_path),
      allowed_modules: Application.get_env(:credence_rules, :allowed_modules, [])
    ]

    issues =
      case Credence.Syntax.analyze(source, global_opts) do
        [] ->
          # Built-in Credence rules — all share the same global opts.
          # `Credence.Pattern.analyze/2` doesn't expose per-rule opts,
          # and tuning upstream rules isn't this project's concern.
          builtin = Credence.Pattern.analyze(source, global_opts)

          # Our custom rules: parse once, then call each rule with its
          # own merged opts. Lets project authors tune any rule via
          # `:rule_opts` in Application env.
          custom = analyse_custom_rules(source, global_opts, cli_opts)

          builtin ++ custom

        syntax_issues ->
          syntax_issues
      end

    issues
    |> Enum.map(&to_issue_map/1)
    |> suppress(source)
  end

  # Apply inline `# credence:<rule>` suppressions. Findings covered by a
  # directive are dropped; each reasonless directive becomes a
  # `credence_suppression_without_reason` finding (exceptions must be
  # justified). See `CredenceRules.Suppression`.
  defp suppress(maps, source) do
    {kept, reasonless} = CredenceRules.Suppression.filter(maps, source)
    kept ++ Enum.map(reasonless, &reasonless_suppression_issue/1)
  end

  defp reasonless_suppression_issue(%{line: line, rules: rules, scope: scope}) do
    rendered = CredenceRules.Suppression.render_rules(rules)
    token = if scope == :file, do: "credence-file", else: "credence"

    %{
      rule: :credence_suppression_without_reason,
      line: line,
      message:
        "`# #{token}:#{rendered}` suppresses a finding with no reason. Every " <>
          "exception must document why it's acceptable — add a justification: " <>
          "`# #{token}:#{rendered} — <reason>`.",
      severity: :high,
      confidence: :high,
      meta: %{line: line},
      fingerprint: nil
    }
  end

  defp analyse_custom_rules(source, global_opts, cli_opts) do
    case Sourceror.parse_string(source) do
      {:ok, ast} ->
        Enum.flat_map(CredenceRules.rules(), fn rule ->
          # Precedence (last-wins): global → rule_opts → cli_opts.
          # CLI flag always wins, so `mix credence.check
          # --graph-source beam` reaches every rule even if its
          # `:rule_opts` says otherwise.
          opts =
            global_opts
            |> Keyword.merge(CredenceRules.rule_opts(rule))
            |> Keyword.merge(cli_opts)

          # Universal `:exclude_paths` carve-out — every rule honours
          # it without needing to opt in. Configured via `:rule_opts`:
          #
          #     rule_opts: %{some_rule: [exclude_paths: ["lib/gen/"]]}
          if CredenceRules.PathExclusion.excluded?(opts),
            do: [],
            else: rule.check(ast, opts)
        end)

      {:error, _reason} ->
        # Syntax phase would have caught a parse error; if Sourceror
        # disagrees we silently drop the file (same shape as
        # parse_files_for_cross_file). Built-in Credence already
        # reported anything actionable.
        []
    end
  end

  defp to_issue_map(%Issue{rule: rule, message: message, meta: meta}) do
    # Collapse multi-line messages so single-line output formats
    # (github workflow commands, terminal-friendly text lists) don't
    # need to re-escape.
    normalized = message |> String.replace(~r/\s+/, " ") |> String.trim()
    meta = meta || %{}

    %{
      rule: rule,
      line: Map.get(meta, :line),
      message: normalized,
      severity: severity_for(rule),
      confidence: confidence_for(rule),
      # Preserve :meta so the fingerprint can include distinguishing
      # structured fields (cycle members, target module, cluster id)
      # that may be more stable than the prose message.
      meta: meta,
      # `:path` isn't set yet (the caller adds it after the per-file
      # phase). Fingerprint is computed later in the Mix task once
      # the path is known.
      fingerprint: nil
    }
  end

  # Resolve a rule's severity: per-rule module attribute first, then
  # category-derived default. The Credence built-in rules don't have
  # a severity/0 function — they fall through to the category default.
  defp severity_for(rule_atom) do
    case rule_module(rule_atom) do
      nil ->
        Finding.severity_for(rule_atom)

      module ->
        case maybe_call(module, :severity) do
          nil -> Finding.severity_for(rule_atom)
          level -> level
        end
    end
  end

  defp confidence_for(rule_atom) do
    case rule_module(rule_atom) do
      nil ->
        Finding.confidence_for(rule_atom)

      module ->
        case maybe_call(module, :confidence) do
          nil -> Finding.confidence_for(rule_atom)
          level -> level
        end
    end
  end

  defp rule_module(rule_atom) do
    Enum.find(CredenceRules.rules(), fn mod ->
      CredenceRules.rule_atom(mod) == rule_atom
    end)
  end

  defp maybe_call(module, fun) do
    if function_exported?(module, fun, 0), do: apply(module, fun, []), else: nil
  end
end
