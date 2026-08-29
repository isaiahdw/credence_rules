defmodule Mix.Tasks.Credence.Check.Formatter.Github do
  @moduledoc """
  GitHub Actions workflow-command formatter. Emits one annotation
  per finding so they render inline on the PR diff, plus a trailing
  summary annotation with the overall score.

  Per-finding line shape:

      ::error file=<path>,line=<n>,title=<rule>::<message>
      ::warning file=<path>,line=<n>,title=<rule>::<message>

  Annotation level is derived from severity:

  - `:high` → `::error`
  - `:medium` → `::warning`
  - `:low` → `::notice`

  Findings without a known line number default to `line=1` (GitHub
  workflow commands require an integer; omitting `line=` would
  surface the annotation at the top of the file silently, with no
  indication that the line was unknown).

  When a baseline is loaded, baselined findings are demoted from
  `::error`/`::warning` to `::notice` so they show on the PR diff as
  context without contributing to the failing-check verdict. New
  findings keep their normal level.

  The trailing summary is `::error::…` when strict mode is on and
  there are boundary findings, otherwise `::notice::…`. This mirrors
  the run's exit-code semantics so reviewers see the gate verdict at
  the top of the Actions log.

  Messages are sanitised per GitHub's escape rules (newline → `%0A`,
  carriage return → `%0D`).
  """

  @spec render(map()) :: String.t()
  def render(%{issues: issues, score: score, strict?: strict?} = report) do
    new_issues = Map.get(report, :new_issues, issues)
    baseline_status = Map.get(report, :baseline_status, :no_baseline)
    new_keys = MapSet.new(new_issues, &issue_key/1)

    # Strict-mode thresholds — same defaults as the Mix task so
    # the summary annotation matches the exit-code verdict.
    min_severity = Map.get(report, :strict_min_severity, :high)
    min_confidence = Map.get(report, :strict_min_confidence, :high)

    finding_lines = Enum.map(issues, &annotation_line(&1, new_keys, baseline_status))

    summary_line =
      summary_line(
        score,
        strict?,
        new_issues,
        issues,
        baseline_status,
        min_severity,
        min_confidence
      )

    IO.iodata_to_binary([finding_lines, summary_line, "\n"])
  end

  # Baselined-display key: stable fingerprint, computed on the fly
  # if absent. Matches Baseline.diff/2 so the "new vs baselined"
  # demotion can never disagree with the baseline gate's verdict
  # on the same finding.
  defp issue_key(%{fingerprint: fp}) when is_binary(fp), do: fp
  defp issue_key(issue), do: CredenceRules.Finding.fingerprint(issue)

  defp annotation_line(
         %{path: path, rule: rule, message: message, line: line} = issue,
         new_keys,
         baseline_status
       ) do
    level = annotation_level(rule, issue, new_keys, baseline_status)

    [
      "::",
      level,
      " file=",
      escape_prop(Path.relative_to_cwd(path)),
      ",line=",
      to_string(line || 1),
      ",title=",
      escape_prop(Atom.to_string(rule)),
      "::",
      escape_message(message),
      "\n"
    ]
  end

  # When a baseline is loaded, demote baselined findings to `::notice`
  # so they appear on the diff as context but don't fail the check.
  # New findings keep their severity-derived level.
  defp annotation_level(_rule, issue, _new_keys, :no_baseline),
    do: severity_level(issue)

  defp annotation_level(_rule, issue, _new_keys, {:missing, _path}),
    do: severity_level(issue)

  defp annotation_level(_rule, issue, new_keys, {:loaded, _path}) do
    if MapSet.member?(new_keys, issue_key(issue)),
      do: severity_level(issue),
      else: "notice"
  end

  # Severity → GitHub annotation level.
  defp severity_level(%{severity: :high}), do: "error"
  defp severity_level(%{severity: :medium}), do: "warning"
  defp severity_level(%{severity: :low}), do: "notice"
  # Backwards-compat for issue maps that haven't been enriched
  # (older tests, code paths that bypass the analyser).
  defp severity_level(%{rule: rule}) do
    if CredenceRules.advisory?(rule), do: "warning", else: "error"
  end

  defp summary_line(
         score,
         strict?,
         new_issues,
         all_issues,
         baseline_status,
         min_severity,
         min_confidence
       ) do
    %{overall: overall, totals: totals} = score

    # Same predicate the Mix task uses for its exit code — never
    # disagree. With baseline, only new findings count toward the
    # gate; without baseline, every strict-failing finding does.
    failures =
      case baseline_status do
        {:loaded, _} -> new_issues
        _ -> all_issues
      end
      |> Enum.count(&CredenceRules.Finding.strict_fail?(&1, min_severity, min_confidence))

    baseline_suffix = baseline_suffix(baseline_status, new_issues)

    cond do
      totals.issues == 0 ->
        ["::notice::Quality score: ", format_pct(overall), " (no findings).\n"]

      strict? and failures > 0 ->
        [
          "::error::Quality analysis: ",
          Integer.to_string(totals.issues),
          " finding(s) (",
          Integer.to_string(failures),
          " >= severity:",
          Atom.to_string(min_severity),
          " & confidence:",
          Atom.to_string(min_confidence),
          "). Score: ",
          format_pct(overall),
          ".",
          baseline_suffix,
          "\n"
        ]

      true ->
        [
          "::notice::Quality analysis: ",
          Integer.to_string(totals.issues),
          " finding(s) (",
          Integer.to_string(totals.boundary),
          " boundary, ",
          Integer.to_string(totals.advisory),
          " advisory). Score: ",
          format_pct(overall),
          ".",
          baseline_suffix,
          "\n"
        ]
    end
  end

  defp baseline_suffix(:no_baseline, _new), do: ""
  defp baseline_suffix({:missing, path}, _new), do: " Baseline #{path} not found."

  defp baseline_suffix({:loaded, _path}, new),
    do: " " <> Integer.to_string(length(new)) <> " new vs baseline."

  # GitHub workflow commands percent-encode CR/LF in messages so the
  # whole annotation stays on one line. Property values (file, title)
  # additionally escape `:` and `,` since those are the field
  # delimiters.
  defp escape_message(value) do
    value
    |> String.replace("%", "%25")
    |> String.replace("\r", "%0D")
    |> String.replace("\n", "%0A")
  end

  defp escape_prop(value) do
    value
    |> escape_message()
    |> String.replace(":", "%3A")
    |> String.replace(",", "%2C")
  end

  defp format_pct(value) when is_float(value) do
    :io_lib.format("~.1f%", [value]) |> IO.iodata_to_binary()
  end
end
