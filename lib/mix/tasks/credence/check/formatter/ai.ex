defmodule Mix.Tasks.Credence.Check.Formatter.Ai do
  @moduledoc """
  Compact single-line JSON envelope tuned for LLM agent consumption.

  Shape (expanded here for readability — the actual output is one
  line, no whitespace):

      {
        "version": "0.1.0",
        "files": 42,
        "lines": 8420,
        "findings": 3,
        "weighted_findings": 7,
        "score": 96.5,
        "scores_by_category": {
          "concurrency": 100.0,
          "safety": 97.5,
          "test_quality": 100.0,
          "documentation": 99.0,
          "naming": 100.0,
          "idioms": 100.0
        },
        "findings_by_file": {
          "lib/foo.ex": [
            {
              "category": "architecture",
              "rule": "iosp_predicate_side_effects",
              "advisory": true,
              "line": 12,
              "detail": "`active?` looks like a predicate but ...",
              "severity": "medium",
              "confidence": "high",
              "fingerprint": "AB12CD34",
              "hint": "Lift the Repo call into `list_users_with_active_status/0` ...",
              "carve_outs": [
                "Liveness predicates (Process.alive?/info/whereis) — TOCTOU",
                "Inside Mix.Tasks.* modules — orchestration is the point"
              ],
              "docs_url": "https://github.com/isaiahdw/credence_rules/blob/main/lib/credence_rules/pattern/iosp_predicate_side_effects.ex",
              "docs_fetch_command": "gh api repos/isaiahdw/credence_rules/contents/lib/credence_rules/pattern/iosp_predicate_side_effects.ex -H \"Accept: application/vnd.github.raw\""
            }
          ]
        }
      }

  The `score` is a **severity-weighted penalty**: `max(0, 100 ×
  (1 − weighted_findings / SCALE))`. Each finding subtracts
  points by severity (high=5, medium=2, low=1) × `100 / SCALE`
  (default SCALE=200, so each weight unit = 0.5 points). See
  `CredenceRules.Score` for the full formula and tunables.

  Per-category scores apply the same formula filtered to that
  category's findings — `"safety": 97.5` means "safety findings
  cost this category 2.5 points (5 weighted units) against its
  budget."

  Grouping by file matches rustqual's `ai-json` shape — agents
  typically operate file-by-file, so colocating findings minimises
  re-reads. Categories use the stable atoms from
  `CredenceRules.Category`. `advisory` is included as a
  boolean alongside the rule so an agent can tell at a glance which
  findings are gates vs hints.

  ## Agent-targeted fields

  - `hint` — short, structured fix recommendation pulled from the
    rule's `@hint` module attribute. An LLM can read this and act
    without re-parsing the prose `detail`. May be `null` for
    rules that haven't defined a hint yet.
  - `carve_outs` — list of conditions where the rule would be
    wrong. Pulled from the rule's `@carve_outs` attribute.
    Agents should self-check each carve-out before applying the
    fix; the human moduledoc has the long form. Empty list if
    none defined.
  - `docs_url` — URL pointing at the rule module's source on
    GitHub (or the project's configured `:docs_url_base`).
    Agents can `WebFetch` (or curl, or paste into a browser) for
    the full moduledoc when context matters. `null` for rules
    that don't resolve to a known module (built-in Credence
    rules, user-defined rules outside the catalog).
  - `docs_fetch_command` — pre-baked shell command that returns
    the rule's source as raw text. Default uses `gh api` with
    the raw Accept header. For agents in shell-only environments
    (no `WebFetch`): paste the command, get the file content
    back. Customise via `:docs_fetch_command_template`
    Application env if you prefer curl or another tool.

  Encoding is via `Jason.encode!/1` — no hand-rolled escaping.
  """

  alias CredenceRules.{Category, Finding}

  @spec render(map()) :: String.t()
  def render(%{issues: issues, score: score} = report) do
    %{overall: overall, by_category: by_category, totals: totals} = score

    new_issues = Map.get(report, :new_issues, issues)
    baselined_issues = Map.get(report, :baselined_issues, [])
    baseline_status = Map.get(report, :baseline_status, :no_baseline)

    payload = %{
      version: version(),
      files: totals.files,
      lines: totals.lines,
      findings: totals.issues,
      weighted_findings: totals.weighted_findings,
      score: overall,
      scores_by_category: scores_by_category(by_category),
      baseline: baseline_payload(baseline_status, new_issues, baselined_issues),
      findings_by_file: findings_by_file(issues, new_issues)
    }

    Jason.encode!(payload) <> "\n"
  end

  defp baseline_payload(:no_baseline, _new, _baselined), do: nil

  defp baseline_payload({:missing, path}, _new, _baselined),
    do: %{status: "missing", path: path}

  defp baseline_payload({:loaded, path}, new, baselined),
    do: %{status: "loaded", path: path, new: length(new), baselined: length(baselined)}

  defp scores_by_category(by_category) do
    Map.new(Category.all(), fn cat ->
      {cat, Map.get(by_category, cat, 100.0)}
    end)
  end

  defp findings_by_file(issues, new_issues) do
    new_keys = MapSet.new(new_issues, &issue_key/1)

    issues
    |> Enum.group_by(& &1.path)
    |> Map.new(fn {path, entries} ->
      {Path.relative_to_cwd(path), Enum.map(entries, &finding_entry(&1, new_keys))}
    end)
  end

  # Baselined-display key: stable fingerprint, computed on the fly
  # if absent. Matches Baseline.diff/2 — the "baselined" boolean
  # in the JSON output can't disagree with the baseline gate.
  defp issue_key(%{fingerprint: fp}) when is_binary(fp), do: fp
  defp issue_key(issue), do: CredenceRules.Finding.fingerprint(issue)

  defp finding_entry(%{rule: rule, message: message, line: line} = issue, new_keys) do
    %{
      category: Category.for_rule(rule),
      rule: rule,
      advisory: CredenceRules.advisory?(rule),
      baselined: not MapSet.member?(new_keys, issue_key(issue)),
      line: line || 0,
      detail: message,
      severity: Map.get(issue, :severity),
      confidence: Map.get(issue, :confidence),
      fingerprint: Map.get(issue, :fingerprint),
      # Agent-targeted fields: structured fix recommendation,
      # list of carve-outs the LLM should self-check before
      # applying the fix, plus two retrieval primitives for the
      # rule's full moduledoc — a URL (for WebFetch / browser /
      # curl) and a ready-to-paste shell command (for agents in
      # shell-only environments).
      hint: Finding.hint_for(rule),
      carve_outs: Finding.carve_outs_for(rule),
      docs_url: Finding.docs_url(rule),
      docs_fetch_command: Finding.docs_fetch_command(rule)
    }
  end

  defp version do
    case Application.spec(:credence_rules, :vsn) do
      nil -> "0.0.0"
      vsn -> List.to_string(vsn)
    end
  end
end
