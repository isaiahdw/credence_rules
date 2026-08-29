defmodule CredenceRules.Score do
  @moduledoc """
  Quality Score for `mix credence.check` — a severity-weighted
  penalty per finding.

  ## The formula

      quality_score = max(0, 100 × (1 − weighted_findings / SCALE))

  where:

      weighted_findings = Σ severity_weight(finding)
      severity_weight(:high)   = 5
      severity_weight(:medium) = 2
      severity_weight(:low)    = 1

  SCALE is a project-tunable constant (default `1000`). Each
  unit of severity weight subtracts `100 / SCALE` points from
  the score — with the default, one severity:low finding costs
  0.1 points, one severity:medium costs 0.2, one severity:high
  costs 0.5.

  ## Heuristic rules cap at :low severity

  Rules whose detection is heuristic (clustering, threshold-
  based, name-based — see `CredenceRules.Finding`'s
  internal heuristic table) cap at `:low` severity regardless
  of category. A `rescue_catch_all` finding really IS a bug; a
  `repeated_subtree_in_module` is "you might want to extract a
  helper." They shouldn't contribute equally to the score, and
  the heuristic cap encodes that.

  ## Why a penalty model, not a coverage ratio

  Lines-clean and files-clean models share a flaw: adding code
  expands the denominator, so a project can ADD findings and the
  score can still go UP. The penalty model is immune — score
  drops by exactly `severity_weight × 100 / SCALE` per new
  finding, and rises by the same amount per fix, independent of
  codebase size.

  Trade-off: the "% of code that's clean" interpretation is gone.
  The Quality Score is now a **quality budget** — 100 is perfect,
  0 is "you have so many findings the formula bottoms out."

  ## Per-category Quality Score

  Same formula, filtered to findings whose rule is in that
  category. `Documentation: 92.0%` means "documentation findings
  cost 16 points (32 weighted) against this category's budget."

  All categories share the same SCALE so the headline overall
  score is the unfiltered version of the per-category formula.

  ## Severity falls back through category default

  Findings without explicit `:severity` (older test fixtures,
  some synthetic findings) get their rule's category-derived
  severity via `Finding.severity_for/1`. Crash-synthetic findings
  (`:analyse_crashed`, `:cross_file_rule_crashed`) carry explicit
  `severity: :high` so the fallback doesn't run for them.

  ## Configuration

      config :credence_rules,
        score_scale: 500,
        severity_weights: %{high: 10, medium: 3, low: 1}

  Higher SCALE → more forgiving (each finding costs less).
  Lower SCALE → stricter. Custom severity weights override the
  defaults; missing keys fall back to the defaults.

  ## Returned struct

  - `:overall` — quality score (`0.0`–`100.0`)
  - `:by_category` — `%{category => score}`. Always includes
    every category from `CredenceRules.Category.all/0`.
  - `:totals` — `%{files: n, lines: n, issues: n,
    boundary: n, advisory: n, weighted_findings: n}`. Line and
    file totals are informational only — not in the score
    formula. `weighted_findings` exposes the formula's input.

  When there are no scanned files (or zero weighted findings)
  the score is `100.0`.
  """

  alias CredenceRules.{Category, Finding}

  @type issue :: %{
          required(:rule) => atom(),
          optional(:severity) => atom() | nil,
          optional(:path) => String.t() | nil
        }

  @type t :: %__MODULE__{
          overall: float(),
          by_category: %{atom() => float()},
          totals: %{
            files: non_neg_integer(),
            lines: non_neg_integer(),
            issues: non_neg_integer(),
            boundary: non_neg_integer(),
            advisory: non_neg_integer(),
            weighted_findings: non_neg_integer()
          }
        }

  defstruct overall: 100.0,
            by_category: %{},
            totals: %{
              files: 0,
              lines: 0,
              issues: 0,
              boundary: 0,
              advisory: 0,
              weighted_findings: 0
            }

  @default_score_scale 1000
  @default_severity_weights %{high: 5, medium: 2, low: 1}

  @doc """
  Compute the Quality Score from a list of finding maps.

  `line_counts` is a `%{path => non_empty_line_count}` map. Lines
  are NOT in the score formula — they're informational context
  shown in the summary header. The map is used to populate the
  `:totals` `files` and `lines` counters.
  """
  @spec compute([issue], %{String.t() => non_neg_integer()}) :: t()
  def compute(issues, line_counts \\ %{}) do
    scale = score_scale()
    weights = severity_weights()

    weighted_overall = weighted_sum(issues, weights)
    overall = penalty_score(weighted_overall, scale)

    by_category =
      Map.new(Category.all(), fn category ->
        cat_weighted =
          issues
          |> Enum.filter(fn %{rule: rule} -> Category.for_rule(rule) == category end)
          |> weighted_sum(weights)

        {category, penalty_score(cat_weighted, scale)}
      end)

    {boundary, advisory} =
      Enum.split_with(issues, fn %{rule: rule} -> not CredenceRules.advisory?(rule) end)

    %__MODULE__{
      overall: overall,
      by_category: by_category,
      totals: %{
        files: map_size(line_counts),
        lines: Enum.reduce(line_counts, 0, fn {_p, n}, acc -> acc + n end),
        issues: length(issues),
        boundary: length(boundary),
        advisory: length(advisory),
        weighted_findings: weighted_overall
      }
    }
  end

  @doc """
  Returns the severity weight for a finding's severity level.
  Falls back to the rule's category-derived default when the
  finding doesn't carry an explicit severity.
  """
  @spec finding_weight(map(), %{atom() => number()}) :: number()
  def finding_weight(finding, weights) do
    severity = Map.get(finding, :severity) || Finding.severity_for(Map.get(finding, :rule))
    Map.get(weights, severity, 1)
  end

  defp weighted_sum(issues, weights) do
    Enum.reduce(issues, 0, fn finding, acc -> acc + finding_weight(finding, weights) end)
  end

  defp penalty_score(weighted, scale) when scale > 0 do
    raw = 100.0 * (1.0 - weighted / scale)
    Float.round(max(0.0, raw), 1)
  end

  defp penalty_score(_, _), do: 100.0

  defp score_scale do
    Application.get_env(:credence_rules, :score_scale, @default_score_scale)
  end

  defp severity_weights do
    overrides = Application.get_env(:credence_rules, :severity_weights, %{})
    Map.merge(@default_severity_weights, Map.new(overrides))
  end
end
