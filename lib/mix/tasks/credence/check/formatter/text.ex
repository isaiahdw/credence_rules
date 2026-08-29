defmodule Mix.Tasks.Credence.Check.Formatter.Text do
  @moduledoc """
  Text formatter — the default. Coloured per-file finding lists +
  a rustqual-style score summary at the end. Suitable for terminal
  use; lossy on machine parsing (advisory tag interpolated into the
  human line).
  """

  alias CredenceRules.Category

  @spec render(map()) :: String.t()
  def render(%{issues: issues, files: files, score: score, strict?: strict?} = report) do
    baseline_status = Map.get(report, :baseline_status, :no_baseline)
    new_issues = Map.get(report, :new_issues, issues)
    baselined_issues = Map.get(report, :baselined_issues, [])

    IO.iodata_to_binary([
      header(length(files), strict?),
      "\n",
      issues_section(issues, new_issues),
      "\n",
      summary_section(score, baseline_status, new_issues, baselined_issues)
    ])
  end

  defp header(file_count, strict?) do
    mode = if strict?, do: " (strict)", else: " (report-only)"
    "[credence.check] Analysing #{file_count} file(s)#{mode}\n"
  end

  defp issues_section([], _new_issues), do: ""

  defp issues_section(issues, new_issues) do
    new_keys = MapSet.new(new_issues, &issue_key/1)

    issues
    |> Enum.group_by(& &1.path)
    |> Enum.sort_by(fn {path, _} -> path end)
    |> Enum.map(fn {path, entries} ->
      header = "\n#{Path.relative_to_cwd(path)} — #{length(entries)} issue(s):\n"

      lines =
        Enum.map(entries, fn %{rule: rule, message: message, line: line} = entry ->
          advisory_tag = if CredenceRules.advisory?(rule), do: " (advisory)", else: ""

          baseline_tag =
            if MapSet.member?(new_keys, issue_key(entry)), do: "", else: " (baselined)"

          # severity + confidence — show the dimensions inline so
          # reviewers can tell whether a finding is "definitely
          # broken" (S:high C:high) vs "heuristic guess" (S:low C:low).
          # Only shown when present (older flow paths still emit
          # plain issue maps).
          tier_tag = tier_tag(entry)

          line_str = if line, do: ":#{line}", else: ""
          "  • [#{rule}#{line_str}]#{tier_tag}#{advisory_tag}#{baseline_tag} #{message}\n"
        end)

      [header | lines]
    end)
  end

  # Baselined-display key: use the stable fingerprint when present
  # (the analyser attaches it), otherwise compute it on the fly.
  # Matches Baseline.diff/2's matching shape — formatter labels
  # can't disagree with the baseline gate's verdict.
  defp issue_key(%{fingerprint: fp}) when is_binary(fp), do: fp
  defp issue_key(issue), do: CredenceRules.Finding.fingerprint(issue)

  # `S:high C:medium` style tag, or empty if either dimension is
  # missing (resilient for hand-built issue maps in older tests).
  defp tier_tag(%{severity: sev, confidence: conf})
       when sev in [:high, :medium, :low] and conf in [:high, :medium, :low] do
    " (S:#{sev} C:#{conf})"
  end

  defp tier_tag(_), do: ""

  defp summary_section(score, baseline_status, new_issues, baselined_issues) do
    %{overall: overall, by_category: by_category, totals: totals} = score

    header = """

    ═══ Summary ═══
      Files: #{totals.files}    Lines: #{totals.lines}    Quality Score: #{format_pct(overall)}
      Findings: #{totals.issues} (#{totals.boundary} boundary, #{totals.advisory} advisory) — #{totals.weighted_findings} weighted

    """

    rows =
      Category.all()
      |> Enum.map(fn category ->
        pct = Map.get(by_category, category, 100.0)
        "  #{String.pad_trailing(Category.label(category) <> ":", 14)} #{format_pct(pct)}\n"
      end)

    baseline_line = baseline_summary(baseline_status, new_issues, baselined_issues)

    footer =
      case {totals.issues, totals.boundary, totals.advisory} do
        {0, _, _} ->
          "\n[credence.check] Scanned #{totals.files} file(s) — no issues found.\n"

        {n, b, a} ->
          "\n[credence.check] Scanned #{totals.files} file(s) — #{n} issue(s) (#{b} boundary, #{a} advisory).#{baseline_line}\n"
      end

    [header | rows] ++ [footer]
  end

  defp baseline_summary(:no_baseline, _new, _baselined), do: ""

  defp baseline_summary({:missing, path}, _new, _baselined),
    do: " Baseline #{path} not found — treating all as new."

  defp baseline_summary({:loaded, _path}, new, baselined),
    do: " vs baseline: #{length(new)} new, #{length(baselined)} baselined."

  defp format_pct(value) when is_float(value) do
    :io_lib.format("~5.1f%", [value]) |> IO.iodata_to_binary() |> String.trim_leading()
  end
end
