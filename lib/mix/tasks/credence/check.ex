# credence-file:option_branched_function,repeated_case_arm_body,repeated_subtree_in_module — this
#   Mix task is CLI glue; flag parsing, value-fallback resolution and message
#   builders repeat across small helpers by nature, so extracting further only
#   relocates code without aiding readers
defmodule Mix.Tasks.Credence.Check do
  @shortdoc "Run Credence + CredenceRules over lib/ and test/ and report issues"
  @moduledoc """
  Walks `lib/**/*.{ex,exs}` and `test/**/*.{ex,exs}` and pipes each
  source file through Credence (https://github.com/Cinderella-Man/credence)
  plus the [`CredenceRules`](`CredenceRules`) Pattern catalog.
  Reports issues per file and a totals line at the end.

  Report-only by design — Credence itself ships a `fix/2` API but this
  task intentionally does NOT call it. CI surfaces findings for
  triage; nothing rewrites the tree automatically.

  ## In-process analysis

  Files are analysed in-process with `Task.async_stream` —
  one task per file, `max_concurrency` defaults to
  `System.schedulers_online()`. The pipeline runs Credence's
  **Syntax** + **Pattern** phases plus this project's custom Pattern
  catalog. The **Semantic** phase is skipped: it's the only phase
  that calls `Code.compile_string/2`, and that's what historically
  forced us to shell out to a fresh `mix run` per file. Sourceror /
  AST work has no global state to leak, so a single BEAM can scan
  hundreds of files in seconds — same model Credo and Sobelow use.

  Trade-off: we lose Credence's compiler-warning diagnostics
  (unused vars, dead clauses, shadowing). `mix compile
  --warnings-as-errors` already catches those, and the LLM-failure-
  mode Pattern rules are the value-add of this project.

  ## Usage

      mix credence.check                            # walks lib/ + test/, exits 0
      mix credence.check --strict                   # exits 1 ONLY on boundary findings
      mix credence.check --paths lib                # restrict to a subset of roots
      mix credence.check --paths lib/foo,test/foo   # comma-separated
      mix credence.check --format github            # GitHub Actions annotations
      mix credence.check --format ai                # compact JSON envelope for LLMs
      mix credence.check --jobs 4                   # cap parallelism (default: schedulers)
      mix credence.check --baseline                 # gate on NEW findings vs baseline
      mix credence.check --baseline PATH            # baseline at custom path
      mix credence.check --update-baseline          # write current findings to baseline
      mix credence.check --summary-json PATH        # dump score + counts JSON alongside --format

  ## Baseline gating

  Run `mix credence.check --update-baseline` once to snapshot current
  findings (default path: `credence-baseline.json`), commit the file,
  then run `mix credence.check --baseline --strict` in CI. The gate
  fails only on boundary findings NOT in the baseline — existing
  accepted code stays accepted, new drift is blocked. Tighten by
  deleting baseline entries as the code improves.

  See `CredenceRules.Baseline` for the file format.

  ## Output formats

  `--format` controls how findings are serialised:

  - `text` (default) — coloured per-file lists plus a rustqual-style
    score summary at the end. For terminal use.
  - `github` — `::error file=…,line=…::message` workflow commands so
    findings annotate the PR diff. Pair with `--strict` to gate CI.
  - `ai` (alias: `json`) — single-line JSON envelope grouped by file.
    Compact and stable; designed for piping into a coding agent.

  The default can be set in config:

      config :credence_rules, default_format: :github

  The `--format` flag always wins over the config setting.

  ## Boundary vs advisory

  `--strict` exits 1 on **boundary** findings only. Advisory findings
  (style / hygiene / test-quality — see `CredenceRules.advisory_rules/0`)
  print with an `(advisory)` tag in the output but do NOT fail the run.
  Boundary rules are CI gates; advisory rules are reviewer hints.

  ## Configuration

  Project-specific paths and grandfathered modules are read from
  `Application` env:

      config :credence_rules,
        # Default scan roots when no `--paths` flag is passed. Accepts
        # the same comma-separated format as the CLI flag. Defaults to
        # `"lib,test"`. Projects that vendor large external trees
        # under `test/` (sparse clones, fixture corpora) typically set
        # this to `"lib"` to skip the test root entirely.
        roots: "lib",
        # Default output format. Same atom as the `--format` flag
        # accepts; defaults to `:text` if unset.
        default_format: :github,
        # Files excluded from the scan (typically codegen output).
        generated_paths: ["lib/my_app/generated.ex"],
        # Pre-existing modules whose names end in OOP-style suffixes
        # but are kept as-is rather than renamed.
        allowed_modules: [MyApp.Legacy.Manager]

  ## Default roots

  Scans `lib/**/*.{ex,exs}` AND `test/**/*.{ex,exs}` unless overridden
  by the `:roots` config (above) or `--paths`. Some advisory rules
  (e.g. `assert_enum_all`, `no_test_without_assertion`) only fire on
  test code, so dropping the test root makes them effectively
  unreachable — accept that trade if you take it.
  """

  use Mix.Task

  alias CredenceRules.{Baseline, Score}
  alias Mix.Tasks.Credence.Check.{Analyser, Formatter}

  # Per-file analysis timeout. AST work is millisecond-scale; anything
  # past 30s means a pathological file (giant generated module) or a
  # rule with quadratic behaviour. Better to drop and keep going than
  # hang the whole run.
  @analyse_timeout_ms 30_000

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [
          strict: :boolean,
          paths: :string,
          format: :string,
          jobs: :integer,
          baseline: :string,
          update_baseline: :string,
          graph_source: :string,
          strict_min_severity: :string,
          strict_min_confidence: :string,
          summary_json: :string
        ],
        allow_nonexistent_atoms: false
      )

    # `--baseline` / `--update-baseline` are documented as accepting both
    # bare and `--flag PATH` forms. OptionParser only natively supports
    # one form per type, so detect the bare form by scanning argv and
    # inject an empty-string value — the resolvers below treat "" as
    # "use the default path."
    opts =
      opts
      |> maybe_inject_bare_flag(:baseline, argv)
      |> maybe_inject_bare_flag(:update_baseline, argv)

    strict? = Keyword.get(opts, :strict, false)
    format = resolve_format(opts)
    jobs = resolve_jobs(opts)
    baseline_path = resolve_baseline_path(opts)
    update_baseline? = Keyword.has_key?(opts, :update_baseline)
    strict_min_severity = resolve_level(opts, :strict_min_severity, :high)
    strict_min_confidence = resolve_level(opts, :strict_min_confidence, :high)

    default_roots = Application.get_env(:credence_rules, :roots, "lib,test")

    roots =
      opts
      |> Keyword.get(:paths, default_roots)
      |> String.split(",", trim: true)

    files = roots |> Enum.flat_map(&collect_files/1) |> Enum.sort()

    # CLI flag → explicit opts threaded through both phases.
    # `cross_file_opts` is a keyword list (e.g. `[graph_source:
    # :beam]`); reuse it as `cli_opts` for the per-file phase so
    # the CLI flag flows uniformly to every rule. Last-wins
    # precedence inside the analyser means CLI overrides per-rule
    # `:rule_opts` overrides Application env overrides the rule's
    # default — and there's no global put_env leaking across runs.
    cross_file_opts = resolve_cross_file_opts(opts)

    progress(
      "[credence.check] Analysing #{length(files)} file(s) under #{Enum.join(roots, ", ")}" <>
        if(strict?, do: " (strict)", else: " (report-only)") <>
        if(baseline_path && not update_baseline?, do: " — baseline #{baseline_path}", else: "") <>
        " — #{jobs} parallel job(s)"
    )

    results = analyse_files(files, jobs, cross_file_opts)

    per_file_issues =
      Enum.flat_map(results, fn {path, file_issues, _line_count} ->
        Enum.map(file_issues, &Map.put(&1, :path, path))
      end)

    # `%{path => line_count}` map drives the lines-clean
    # denominator. Files that crashed analysis still have a
    # line_count (read before the rules ran), so they contribute
    # to the total — their `:analyse_crashed` synthetic finding
    # marks a few of their lines as dirty.
    line_counts =
      Map.new(results, fn {path, _issues, line_count} -> {path, line_count} end)

    cross_file_issues =
      files
      |> run_cross_file_phase(cross_file_opts)
      |> suppress_cross_file()

    # Fingerprint can only be computed once the path is attached.
    # Per-file issues get their path in the flat_map above; cross-file
    # issues already include `:path` from their build_issue/* helpers.
    issues =
      (per_file_issues ++ cross_file_issues)
      |> Enum.map(&attach_fingerprint/1)

    score = Score.compute(issues, line_counts)

    if update_baseline? do
      path = update_baseline_path(opts)
      write_baseline(issues, path)
      # Exit 0 after writing; the user explicitly asked to capture.
    else
      {new_issues, baselined_issues, baseline_status} =
        apply_baseline(issues, baseline_path)

      report = %{
        issues: issues,
        new_issues: new_issues,
        baselined_issues: baselined_issues,
        baseline_status: baseline_status,
        score: score,
        files: files,
        strict?: strict?,
        strict_min_severity: strict_min_severity,
        strict_min_confidence: strict_min_confidence
      }

      maybe_write_summary_json(opts, report)

      IO.write(Formatter.render(format, report))

      # Strict mode keys on severity + confidence (defaults both
      # `:high`). Backwards-compatible with the old "boundary fails"
      # semantics — every previous boundary rule maps to
      # severity:high + confidence:high.
      maybe_exit_strict(
        strict?,
        baseline_path,
        new_issues,
        issues,
        strict_min_severity,
        strict_min_confidence
      )
    end
  end

  defp maybe_exit_strict(false, _, _, _, _, _), do: :ok

  defp maybe_exit_strict(true, baseline_path, new_issues, issues, min_sev, min_conf) do
    {scope_issues, scope_label} =
      if baseline_path,
        do: {new_issues, " new issue(s) ≥ severity:#{min_sev} & confidence:#{min_conf} vs baseline"},
        else: {issues, " issue(s) ≥ severity:#{min_sev} & confidence:#{min_conf}"}

    count = Enum.count(scope_issues, &strict_fail?(&1, min_sev, min_conf))

    if count > 0 do
      progress("[credence.check] #{count}#{scope_label} — exiting 1 (strict mode).")
      exit({:shutdown, 1})
    else
      :ok
    end
  end

  # `--baseline` with no value uses the default path; `--baseline PATH`
  # uses the explicit path. Returns `nil` when the flag was not given.
  defp resolve_baseline_path(opts) do
    case Keyword.fetch(opts, :baseline) do
      :error -> nil
      {:ok, ""} -> Baseline.default_path()
      {:ok, path} -> path
    end
  end

  # When the user passes a bare `--baseline` / `--update-baseline`
  # (without a value), OptionParser doesn't include it in opts because
  # the flag is typed as `:string`. Scan argv for the bare form and
  # inject an empty-string value, which the resolvers treat as "default
  # path."
  defp maybe_inject_bare_flag(opts, key, argv) do
    flag = "--" <> (key |> Atom.to_string() |> String.replace("_", "-"))

    if flag in argv and not Keyword.has_key?(opts, key) do
      Keyword.put(opts, key, "")
    else
      opts
    end
  end

  defp update_baseline_path(opts) do
    case Keyword.fetch(opts, :update_baseline) do
      :error -> Baseline.default_path()
      {:ok, path} when path in ["", nil] -> Baseline.default_path()
      {:ok, path} -> path
    end
  end

  defp apply_baseline(issues, nil), do: {issues, [], :no_baseline}

  defp apply_baseline(issues, baseline_path) do
    case Baseline.load(baseline_path) do
      {:ok, baseline} ->
        {baselined, new_issues} = Baseline.diff(issues, baseline)

        progress("[credence.check] #{length(new_issues)} new vs baseline (#{length(baselined)} baselined)")

        {new_issues, baselined, {:loaded, baseline_path}}

      {:error, :enoent} ->
        progress("[credence.check] baseline #{baseline_path} not found — treating all as new")
        {issues, [], {:missing, baseline_path}}

      {:error, reason} ->
        Mix.raise("invalid --baseline #{baseline_path}: #{inspect(reason)}")
    end
  end

  defp write_baseline(issues, path) do
    baseline = Baseline.from_findings(issues)

    case Baseline.save(baseline, path) do
      :ok ->
        progress("[credence.check] wrote #{length(issues)} finding(s) to baseline #{path}")

      {:error, reason} ->
        Mix.raise("failed to write baseline #{path}: #{inspect(reason)}")
    end
  end

  # `--summary-json <path>` writes a compact score + counts snapshot
  # to disk alongside whatever the chosen `--format` prints. The
  # CI use case is `--format github` (annotations on the PR diff)
  # plus this summary, which the workflow's report job reads to
  # render the per-category breakdown in a sticky PR comment.
  #
  # Per-file findings are deliberately omitted — they're already
  # surfaced as PR annotations and would bloat the artifact at no
  # added value to the reviewer. Consumers that want everything
  # should use `--format ai` instead.
  defp maybe_write_summary_json(opts, report) do
    case Keyword.get(opts, :summary_json) do
      nil ->
        :ok

      path ->
        %{
          issues: issues,
          new_issues: new_issues,
          baselined_issues: baselined_issues,
          baseline_status: baseline_status,
          score: %{overall: overall, by_category: by_category, totals: totals}
        } = report

        payload = %{
          score: overall,
          scores_by_category: by_category,
          totals: totals,
          baseline: baseline_summary(baseline_status, new_issues, baselined_issues),
          findings: length(issues)
        }

        File.mkdir_p!(Path.dirname(path))
        File.write!(path, Jason.encode!(payload))
        progress("[credence.check] wrote summary JSON to #{path}")
    end
  end

  defp baseline_summary(:no_baseline, _new, _baselined), do: nil

  defp baseline_summary({:missing, path}, _new, _baselined),
    do: %{status: "missing", path: path}

  defp baseline_summary({:loaded, path}, new, baselined),
    do: %{status: "loaded", path: path, new: length(new), baselined: length(baselined)}

  defp resolve_format(opts) do
    raw = Keyword.get(opts, :format) || Application.get_env(:credence_rules, :default_format)

    case Formatter.parse(raw) do
      {:ok, format} ->
        format

      {:error, reason} ->
        Mix.raise("invalid --format: #{reason}")
    end
  end

  # `--strict-min-severity` / `--strict-min-confidence` — accept
  # "high" / "medium" / "low" as strings, default to :high.
  defp resolve_level(opts, key, default) do
    case Keyword.get(opts, key) do
      nil ->
        default

      raw ->
        case CredenceRules.Finding.parse_level(raw) do
          {:ok, level} -> level
          :error -> Mix.raise("invalid --#{String.replace(to_string(key), "_", "-")}: #{inspect(raw)}")
        end
    end
  end

  # Attach a stable fingerprint to a finding. Used as the baseline
  # key — the fingerprint hashes {rule, path, normalized_message}
  # so small line moves don't churn the baseline.
  defp attach_fingerprint(%{fingerprint: fp} = issue) when is_binary(fp), do: issue

  defp attach_fingerprint(issue) do
    Map.put(issue, :fingerprint, CredenceRules.Finding.fingerprint(issue))
  end

  # Delegate to the public `Finding.strict_fail?/3` so the Mix
  # task and the GitHub formatter share a single source of truth
  # — preventing the case where the CI run exits 1 while the
  # summary annotation says ::notice (or vice versa). The public
  # predicate defaults missing severity/confidence to :high so
  # crash-synthetic findings still trip the gate.
  defp strict_fail?(finding, min_severity, min_confidence) do
    CredenceRules.Finding.strict_fail?(finding, min_severity, min_confidence)
  end

  # CLI flag wins; otherwise default to scheduler count. We don't
  # halve like rustqual's `--jobs` suggestion does because we're now
  # in-process — there's no second layer of parallel compile workers
  # to compound with.
  defp resolve_jobs(opts) do
    case Keyword.get(opts, :jobs) do
      nil -> System.schedulers_online()
      jobs when is_integer(jobs) and jobs > 0 -> jobs
      jobs -> Mix.raise("invalid --jobs: #{inspect(jobs)} — expected a positive integer")
    end
  end

  defp collect_files(root) do
    generated_paths = Application.get_env(:credence_rules, :generated_paths, [])

    # Scan both `.ex` (production code) and `.exs` (test files, mix
    # scripts, config). Some advisory rules — `assert_enum_all`,
    # `no_test_without_assertion`, `no_trivially_truthy_assertion`,
    # `assert_match_question` — only fire on test code, so excluding
    # `.exs` would mean those rules never run.
    (Path.wildcard(Path.join(root, "**/*.ex")) ++
       Path.wildcard(Path.join(root, "**/*.exs")))
    |> Enum.reject(&(Path.relative_to_cwd(&1) in generated_paths))
    |> Enum.sort()
  end

  # Fan files out across `jobs` workers, log progress per file as
  # results land, and surface analyser crashes as synthetic issues so
  # one wedged file doesn't poison the rest of the report.
  # `cli_opts` carries CLI flags (currently `:graph_source`) that
  # should override per-rule `:rule_opts` — last-wins precedence
  # in the analyser.
  defp analyse_files(files, jobs, cli_opts) do
    files
    |> Task.async_stream(
      fn path -> Analyser.analyse(path, cli_opts) end,
      max_concurrency: jobs,
      ordered: false,
      timeout: @analyse_timeout_ms,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Enum.map(fn
      {:ok, {path, file_issues, line_count}} ->
        progress("[credence.check] #{Path.relative_to_cwd(path)}: #{length(file_issues)} issue(s)")

        {path, file_issues, line_count}

      {:exit, {path, reason}} ->
        progress("[credence.check] #{Path.relative_to_cwd(path)}: analyser exited — #{inspect(reason)}")

        # Synthetic finding with severity:high + confidence:high so
        # `--strict` actually fails on it. Without these fields the
        # strict-mode predicate would silently pass crashed files.
        # Line count: try to read the file separately so the crash
        # path still contributes to the lines-clean denominator. If
        # the read also fails (truly inaccessible), default to 0 —
        # the cross-file-span attribution still marks lines as
        # dirty, so the synthetic finding registers regardless.
        line_count = safe_line_count(path)

        {path,
         [
           %{
             rule: :analyse_crashed,
             line: nil,
             message: "analyser exited: #{inspect(reason)}",
             severity: :high,
             confidence: :high,
             fingerprint: nil
           }
         ], line_count}
    end)
  end

  defp safe_line_count(path) do
    case File.read(path) do
      {:ok, source} -> Analyser.count_non_empty_lines(source)
      _ -> 0
    end
  end

  # Translate the CLI `--graph-source` flag (string) into the rule-
  # opt shape (atom). Absent flag → empty keyword list, so rules
  # use their default / Application env. `:beam` and `:union`
  # both require the project to be compiled; ensure that here.
  @doc false
  # Exposed @doc false for unit testing the CLI → opts → env flow.
  # Not part of the public API; callers should invoke the Mix task.
  def resolve_cross_file_opts(opts) do
    case Keyword.get(opts, :graph_source) do
      nil ->
        []

      str when str in ["beam", "ast", "union"] ->
        source = String.to_existing_atom(str)
        if source in [:beam, :union], do: ensure_compiled()
        [graph_source: source]

      other ->
        # Fail fast — same pattern as the other CLI flag validators
        # (--format, --jobs, --strict-min-*). Earlier this logged a
        # "falling back to :ast" warning then returned `[]`, which
        # let project env / rule_opts resolve the source instead —
        # making the warning a lie when env was `:beam`.
        Mix.raise("invalid --graph-source: #{inspect(other)} — must be one of \"beam\", \"ast\", \"union\"")
    end
  end

  defp graph_source_progress_suffix(opts) do
    case Keyword.get(opts, :graph_source) do
      :beam -> " (graph source: beam)"
      :ast -> " (graph source: ast)"
      :union -> " (graph source: union — ast ∪ beam)"
      _ -> ""
    end
  end

  # `:beam` graph source needs compiled artifacts. The user typically
  # runs `mix credence.check` after `mix compile` (or it's the
  # entrypoint that triggers compile via deps), but make it explicit.
  defp ensure_compiled do
    Mix.Task.run("compile", [])
  end

  # Cross-file analysis phase. Parses every file's AST once via
  # Sourceror (same parser the per-file phase uses), then hands the
  # `[{path, ast}]` list to each cross-file rule. Each rule decides
  # which file path each finding attaches to.
  defp run_cross_file_phase(files, cli_opts) do
    case CredenceRules.cross_file_rules() do
      [] ->
        []

      rules ->
        parsed = parse_files_for_cross_file(files)

        progress(
          "[credence.check] Cross-file phase — #{length(rules)} rule(s) over " <>
            "#{length(parsed)} file(s)" <>
            graph_source_progress_suffix(cli_opts)
        )

        Enum.flat_map(rules, fn rule ->
          # Match the per-file analyser's last-wins precedence:
          # per-rule `:rule_opts` first, CLI flag last. Earlier code
          # had the args swapped so a `:rule_opts` entry could
          # silently override `mix credence.check --graph-source beam`.
          merged_opts =
            CredenceRules.rule_opts(rule)
            |> Keyword.merge(cli_opts)

          try do
            rule.check(parsed, merged_opts) |> Enum.map(&cross_file_issue_to_map/1)
          rescue
            # Catch the specific exception classes a buggy rule could raise
            # — KeyError on a missing meta field, FunctionClauseError on a
            # malformed AST, etc. Anything else (system errors, signals)
            # propagates.
            e in [
              RuntimeError,
              FunctionClauseError,
              ArgumentError,
              MatchError,
              KeyError,
              BadMapError
            ] ->
              progress(
                "[credence.check] cross-file rule #{inspect(rule)} crashed — " <>
                  inspect(e)
              )

              # Synthetic finding so `--strict` actually fails on a
              # crashed rule rather than silently dropping its
              # output. Attached to the rule module's own source
              # file so the github annotation points at the buggy
              # rule for triage.
              [cross_file_crash_issue(rule, e)]
          end
        end)
    end
  end

  # File-scope suppression for cross-file (line-less) findings. A
  # `# credence:<rule>` directive anywhere in the finding's source file
  # drops it — the module-level analogue of the per-file line directive.
  # Reasonless directives are already reported by the per-file phase.
  defp suppress_cross_file(cross_file_issues) do
    sources =
      cross_file_issues
      |> Enum.map(& &1[:path])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.flat_map(fn path ->
        case File.read(path) do
          {:ok, source} -> [{path, source}]
          _ -> []
        end
      end)
      |> Map.new()

    CredenceRules.Suppression.filter_cross_file(cross_file_issues, sources)
  end

  defp cross_file_crash_issue(rule_module, exception) do
    rule_atom = CredenceRules.rule_atom(rule_module)

    %{
      rule: :cross_file_rule_crashed,
      line: nil,
      path: rule_module_source_path(rule_module),
      message:
        "Cross-file rule #{inspect(rule_module)} (#{rule_atom}) crashed during the " <>
          "cross-file phase: #{inspect(exception)}. Other findings from this rule were " <>
          "dropped. Fix the rule or disable it via `:disabled_rules`.",
      severity: :high,
      confidence: :high,
      # Fingerprint gets attached by attach_fingerprint/1 below;
      # leaving nil here means the {rule, path, message} key will
      # produce a stable fingerprint that includes the exception
      # type (so the same crash gets baselined together).
      fingerprint: nil
    }
  end

  defp rule_module_source_path(module) do
    segments =
      module
      |> Module.split()
      |> Enum.map(&Macro.underscore/1)

    "lib/" <> Enum.join(segments, "/") <> ".ex"
  end

  # Cross-file rules return %Credence.Issue{} structs; flatten to the
  # plain map shape the rest of the pipeline uses, lifting :path out
  # of :meta so the formatters can find it. Severity / confidence
  # come from the rule's @severity / @confidence module attributes
  # (or category default). Fingerprint is left nil — gets filled in
  # by attach_fingerprint/1 once the issue list is merged.
  defp cross_file_issue_to_map(%{rule: rule, message: message, meta: meta}) do
    meta = meta || %{}
    normalized = message |> String.replace(~r/\s+/, " ") |> String.trim()

    %{
      rule: rule,
      line: Map.get(meta, :line),
      message: normalized,
      path: Map.get(meta, :path),
      severity: cross_file_severity_for(rule),
      confidence: cross_file_confidence_for(rule),
      # Preserve :meta — cross-file findings carry distinguishing
      # data (cycle members, source/target modules, cluster id)
      # that the fingerprint can fold in for stable identity.
      meta: meta,
      fingerprint: nil
    }
  end

  defp cross_file_severity_for(rule_atom) do
    case Enum.find(CredenceRules.cross_file_rules(), fn mod ->
           CredenceRules.rule_atom(mod) == rule_atom
         end) do
      nil ->
        CredenceRules.Finding.severity_for(rule_atom)

      module ->
        case (function_exported?(module, :severity, 0) && module.severity()) || nil do
          nil -> CredenceRules.Finding.severity_for(rule_atom)
          level -> level
        end
    end
  end

  defp cross_file_confidence_for(rule_atom) do
    case Enum.find(CredenceRules.cross_file_rules(), fn mod ->
           CredenceRules.rule_atom(mod) == rule_atom
         end) do
      nil ->
        CredenceRules.Finding.confidence_for(rule_atom)

      module ->
        case (function_exported?(module, :confidence, 0) && module.confidence()) || nil do
          nil -> CredenceRules.Finding.confidence_for(rule_atom)
          level -> level
        end
    end
  end

  # Parse each file's AST for the cross-file phase. Sourceror is used
  # for parity with the per-file phase (Credence.Pattern.analyze also
  # uses Sourceror). Files we can't read or parse are dropped from the
  # corpus the cross-file rules see — log a warning per drop so a
  # reviewer notices that cross-file analysis ran on an incomplete
  # corpus rather than getting silent zero findings.
  # Parse each file's AST for the cross-file phase. Sourceror is used
  # for parity with the per-file phase (Credence.Pattern.analyze also
  # uses Sourceror). Files we can't read or parse are dropped from the
  # corpus the cross-file rules see — log a warning per drop so a
  # reviewer notices that cross-file analysis ran on an incomplete
  # corpus rather than getting silent zero findings.
  defp parse_files_for_cross_file(files) do
    Enum.flat_map(files, fn path ->
      with {:ok, source} <- File.read(path),
           {:ok, ast} <- Sourceror.parse_string(source) do
        [{path, ast}]
      else
        other ->
          progress(
            "[credence.check] cross-file phase: skipping " <>
              "#{Path.relative_to_cwd(path)} — #{inspect(other)}"
          )

          []
      end
    end)
  end

  # Progress chatter goes to stderr so machine formats can be piped
  # cleanly. `Mix.shell().info/1` writes to stdout, which would mix
  # progress and findings together.
  defp progress(line), do: IO.puts(:stderr, line)
end
