defmodule CredenceRules.Suppression do
  @moduledoc """
  Inline finding suppression via `# credence:` comments.

  An exception to a rule is documented **at the code**, not hidden in
  config. There are two scopes, each with its own token:

  ## Line scope — `# credence:<rule>`

  Suppresses matching findings on the comment's own line (trailing) and
  the line directly below it (comment on the line above). Use it to
  exempt a single occurrence:

      def child_spec(opts), do: adapter().child_spec(opts) # credence:nested_calls_should_pipe — facade delegation reads clearer flat

      # credence:filter_then_first — bounded 3-element list, clarity over the micro-opt
      first_admin = users |> Enum.filter(& &1.admin?) |> List.first()

  ## File scope — `# credence-file:<rule>`

  Suppresses **every** matching finding in the whole file — both
  line-bearing findings and line-less cross-file findings
  (`hub_module`, `cross_file_duplicate_block`, …). Place it at the top
  of the file, above the `defmodule`. Use it when the rule's premise
  doesn't hold for the file as a whole (e.g. a module that is, by
  contract, a uniform pattern matcher). This replaces config-level
  `exclude_paths` / `exclude_modules` carve-outs.

      # credence-file:repeated_subtree_in_function — every Pattern rule shares the
      #   check/2 + Macro.prewalk + build_issue shape by contract
      defmodule CredenceRules.Pattern.TaggedTupleElemAccess do

  ## Syntax

      # credence:<rule>[,<rule>…] <reason>
      # credence-file:<rule>[,<rule>…] <reason>

  - `<rule>` is a rule atom name (`nested_calls_should_pipe`). Comma-
    separate several. `*` or `all` covers every finding in scope.
  - A **reason is required**. A directive with no reason still
    suppresses (honouring intent) but is itself reported as
    `credence_suppression_without_reason` — exceptions must be
    justified, or they rot.

  Comments are read with `CredenceRules.CommentScan`, so a
  `# credence:` sequence inside a string or docstring is correctly
  ignored — only real source comments count. A line-less cross-file
  finding can only be suppressed by the file-scope token (it has no
  line for the line-scope token to match).
  """

  alias CredenceRules.CommentScan

  @type scope :: :line | :file
  @type directive :: %{
          scope: scope(),
          line: pos_integer(),
          rules: :all | [String.t()],
          reason: String.t() | nil
        }

  # `credence-file:` is checked first; `credence:` is not a prefix of it
  # ("credence-" ≠ "credence:"), but ordering keeps intent obvious.
  @file_prefix "credence-file:"
  @line_prefix "credence:"

  @doc """
  Parse `# credence:` / `# credence-file:` directives from a source string.
  """
  @spec directives(String.t()) :: [directive()]
  def directives(source) when is_binary(source) do
    source
    |> CommentScan.extract()
    |> Enum.flat_map(&parse/1)
  end

  @doc """
  Drop line-bearing findings covered by a directive.

  A finding is dropped when a line-scope directive sits on its line
  (or the line above), or when a file-scope directive anywhere in the
  file names its rule. Returns `{kept_findings, reasonless_directives}`
  — the caller turns each reasonless directive into a
  `credence_suppression_without_reason` finding.
  """
  @spec filter([map()], String.t()) :: {[map()], [directive()]}
  def filter(findings, source) when is_list(findings) and is_binary(source) do
    dirs = directives(source)
    kept = Enum.reject(findings, fn finding -> Enum.any?(dirs, &suppresses?(&1, finding)) end)
    reasonless = Enum.filter(dirs, &is_nil(&1.reason))
    {kept, reasonless}
  end

  @doc """
  Drop cross-file (line-less) findings suppressed at file scope.

  `sources` is a `%{path => source}` map. A finding whose `:path` has a
  **file-scope** (`# credence-file:`) directive naming its rule (or
  `*`) is dropped. Reasonless directives are reported by the per-file
  phase (which scans every file), so they aren't re-reported here — but
  they still suppress, honouring intent.
  """
  @spec filter_cross_file([map()], %{optional(String.t()) => String.t()}) :: [map()]
  def filter_cross_file(findings, sources) when is_list(findings) and is_map(sources) do
    Enum.reject(findings, &cross_file_suppressed?(&1, sources))
  end

  defp cross_file_suppressed?(%{rule: rule, path: path}, sources) when is_binary(path) do
    case Map.fetch(sources, path) do
      {:ok, source} -> Enum.any?(directives(source), &file_covers?(&1, rule))
      :error -> false
    end
  end

  defp cross_file_suppressed?(_finding, _sources), do: false

  defp parse(%{line: line, body: @file_prefix <> rest}), do: build(:file, line, rest)
  defp parse(%{line: line, body: @line_prefix <> rest}), do: build(:line, line, rest)
  defp parse(_), do: []

  defp build(scope, line, rest) do
    case Regex.run(~r/^([a-z0-9_*,]+)(.*)$/, rest) do
      [_, rules, reason] ->
        [%{scope: scope, line: line, rules: parse_rules(rules), reason: normalize_reason(reason)}]

      # A bare token with no rule — treat as "everything", reasonless
      # (so it's reported until documented).
      _ ->
        [%{scope: scope, line: line, rules: :all, reason: nil}]
    end
  end

  defp parse_rules(tokens) do
    list = String.split(tokens, ",", trim: true)
    if Enum.any?(list, &(&1 in ["*", "all"])), do: :all, else: list
  end

  defp normalize_reason(rest) do
    case rest |> String.trim() |> String.replace(~r/^[-—–:]+\s*/, "") |> String.trim() do
      "" -> nil
      reason -> reason
    end
  end

  # File-scope directive: covers a matching rule anywhere in the file.
  defp suppresses?(%{scope: :file, rules: rules}, %{rule: rule}), do: rule_covered?(rules, rule)

  # Line-scope directive: covers the finding's own line and the line below.
  defp suppresses?(%{scope: :line, line: dline, rules: rules}, %{line: fline, rule: rule}),
    do: line_covered?(dline, fline) and rule_covered?(rules, rule)

  defp suppresses?(_directive, _finding), do: false

  defp file_covers?(%{scope: :file, rules: rules}, rule), do: rule_covered?(rules, rule)
  defp file_covers?(_directive, _rule), do: false

  # A line directive covers the line it's on (trailing comment) and the
  # line directly below it (comment on the line above the finding).
  defp line_covered?(dir_line, finding_line) when is_integer(finding_line),
    do: dir_line == finding_line or dir_line == finding_line - 1

  defp line_covered?(_dir_line, _finding_line), do: false

  defp rule_covered?(:all, _rule), do: true
  defp rule_covered?(rules, rule) when is_list(rules), do: Atom.to_string(rule) in rules

  @doc "Render a directive's rule set for messages."
  @spec render_rules(:all | [String.t()]) :: String.t()
  def render_rules(:all), do: "*"
  def render_rules(rules) when is_list(rules), do: Enum.join(rules, ",")
end
