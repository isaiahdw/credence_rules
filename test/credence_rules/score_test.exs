defmodule CredenceRules.ScoreTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Score

  defp finding(rule, severity, opts \\ []) do
    %{
      rule: rule,
      severity: severity,
      path: Keyword.get(opts, :path, "lib/a.ex"),
      line: Keyword.get(opts, :line, 1)
    }
  end

  describe "compute/2 — empty / vacuous" do
    test "100% when no findings" do
      score = Score.compute([])
      assert score.overall == 100.0
      assert score.totals.issues == 0
      assert score.totals.weighted_findings == 0
    end

    test "every category is 100% with no findings" do
      score = Score.compute([])
      for {_cat, s} <- score.by_category, do: assert(s == 100.0)
    end
  end

  describe "compute/2 — penalty per finding (default SCALE=1000)" do
    test "1 severity:low finding costs 0.1 points (weight 1 / 1000 * 100)" do
      score = Score.compute([finding(:obvious_comment, :low)])
      assert score.overall == 99.9
    end

    test "1 severity:medium finding costs 0.2 points (weight 2)" do
      score = Score.compute([finding(:large_defstruct, :medium)])
      assert score.overall == 99.8
    end

    test "1 severity:high finding costs 0.5 points (weight 5)" do
      score = Score.compute([finding(:rescue_catch_all, :high)])
      assert score.overall == 99.5
    end

    test "penalties accumulate linearly" do
      issues = [
        finding(:rescue_catch_all, :high),
        finding(:rescue_catch_all, :high),
        finding(:large_defstruct, :medium),
        finding(:obvious_comment, :low)
      ]

      # weighted = 5 + 5 + 2 + 1 = 13 → 13/1000 * 100 = 1.3 penalty → 98.7
      score = Score.compute(issues)
      assert score.overall == 98.7
      assert score.totals.weighted_findings == 13
    end

    test "score clamps to 0 when weighted_findings >= SCALE" do
      # 250 high-severity findings = 1250 weight = 125 penalty → clamped 0
      issues = for _ <- 1..250, do: finding(:rescue_catch_all, :high)
      score = Score.compute(issues)
      assert score.overall == 0.0
    end
  end

  describe "compute/2 — immunity to codebase growth (the whole point)" do
    test "score depends only on findings, not on line_counts" do
      issues = [finding(:obvious_comment, :low), finding(:obvious_comment, :low)]

      tiny = Score.compute(issues, %{"a.ex" => 10})
      huge = Score.compute(issues, %{"a.ex" => 100_000})

      assert tiny.overall == huge.overall
      # Both 99.8 (2 × 0.1 penalty)
      assert tiny.overall == 99.8
    end

    test "adding 'clean lines' does NOT change the score" do
      issues = [finding(:obvious_comment, :low)]

      small = Score.compute(issues, %{"a.ex" => 100})
      big = Score.compute(issues, %{"a.ex" => 100, "b.ex" => 10_000})

      assert small.overall == big.overall
    end
  end

  describe "compute/2 — severity falls back to category default" do
    test "finding without :severity uses Finding.severity_for(rule)" do
      # rescue_catch_all is :safety category → severity :high (weight 5)
      no_severity = %{rule: :rescue_catch_all}
      explicit_high = finding(:rescue_catch_all, :high)

      assert Score.compute([no_severity]).overall ==
               Score.compute([explicit_high]).overall
    end

    test "advisory rule with :high severity in the finding still uses that severity" do
      # advisory + heuristic rules cap at :low via Finding.severity_for,
      # but an explicit severity on the finding wins (e.g. crash-
      # synthetic findings carry explicit :high).
      explicit = %{rule: :obvious_comment, severity: :high}
      score = Score.compute([explicit])
      # weight 5 → 0.5 penalty → 99.5
      assert score.overall == 99.5
    end
  end

  describe "compute/2 — per-category breakdown" do
    test "each category gets its own penalty score" do
      issues = [
        # safety: weight 5 → 0.5 penalty → 99.5
        finding(:rescue_catch_all, :high),
        # documentation: weight 1 → 0.1 penalty → 99.9
        finding(:obvious_comment, :low),
        finding(:obvious_comment, :low)
      ]

      score = Score.compute(issues)

      # Safety has 5 weighted → 0.5 penalty → 99.5
      assert score.by_category.safety == 99.5
      # Documentation has 2 weighted → 0.2 penalty → 99.8
      assert score.by_category.documentation == 99.8
      # Concurrency has 0 weighted → 100.0
      assert score.by_category.concurrency == 100.0
    end

    test "overall is the cumulative penalty across all categories" do
      issues = [
        finding(:rescue_catch_all, :high),
        finding(:obvious_comment, :low),
        finding(:obvious_comment, :low)
      ]

      # Total weighted = 5 + 1 + 1 = 7 → 0.7 penalty → 99.3
      assert Score.compute(issues).overall == 99.3
    end

    test "every category from Category.all/0 is present" do
      score = Score.compute([])
      categories = score.by_category |> Map.keys() |> MapSet.new()
      assert MapSet.equal?(categories, MapSet.new(CredenceRules.Category.all()))
    end
  end

  describe "compute/2 — totals (back-compat for formatters)" do
    test "splits issues into boundary and advisory" do
      issues = [
        finding(:rescue_catch_all, :high),
        finding(:obvious_comment, :low)
      ]

      score = Score.compute(issues)
      assert score.totals.issues == 2
      # rescue_catch_all is safety, not advisory → boundary
      assert score.totals.boundary == 1
      # obvious_comment is advisory
      assert score.totals.advisory == 1
    end

    test "exposes weighted_findings for transparency" do
      issues = [
        finding(:rescue_catch_all, :high),
        finding(:large_defstruct, :medium)
      ]

      score = Score.compute(issues)
      # weight 5 + 2 = 7
      assert score.totals.weighted_findings == 7
    end

    test "files and lines come from line_counts (informational only)" do
      score = Score.compute([], %{"a.ex" => 100, "b.ex" => 50})
      assert score.totals.files == 2
      assert score.totals.lines == 150
    end
  end

  describe "compute/2 — configuration" do
    test "honours :score_scale Application env" do
      original = Application.get_env(:credence_rules, :score_scale)
      Application.put_env(:credence_rules, :score_scale, 100)

      try do
        # weight 5 / 100 * 100 = 5 penalty → 95.0
        score = Score.compute([finding(:rescue_catch_all, :high)])
        assert score.overall == 95.0
      after
        case original do
          nil -> Application.delete_env(:credence_rules, :score_scale)
          v -> Application.put_env(:credence_rules, :score_scale, v)
        end
      end
    end

    test "honours :severity_weights Application env (partial override)" do
      original = Application.get_env(:credence_rules, :severity_weights)
      Application.put_env(:credence_rules, :severity_weights, %{high: 10})

      try do
        # high overridden to 10; medium + low fall back to defaults
        score =
          Score.compute([
            finding(:rescue_catch_all, :high),
            finding(:large_defstruct, :medium)
          ])

        # weight 10 + 2 = 12 → 12/1000 * 100 = 1.2 penalty → 98.8
        assert score.overall == 98.8
      after
        case original do
          nil -> Application.delete_env(:credence_rules, :severity_weights)
          v -> Application.put_env(:credence_rules, :severity_weights, v)
        end
      end
    end
  end
end
