defmodule Mix.Tasks.Credence.Check.FormatterTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Score
  alias Mix.Tasks.Credence.Check.Formatter

  describe "parse/1" do
    test "accepts known atoms" do
      assert {:ok, :text} == Formatter.parse(:text)
      assert {:ok, :github} == Formatter.parse(:github)
      assert {:ok, :ai} == Formatter.parse(:ai)
    end

    test "accepts strings (CLI input form)" do
      assert {:ok, :github} == Formatter.parse("github")
      assert {:ok, :ai} == Formatter.parse("ai")
    end

    test "defaults to :text on nil" do
      assert {:ok, :text} == Formatter.parse(nil)
    end

    test "errors on unknown formats" do
      assert {:error, _} = Formatter.parse("xml")
      assert {:error, _} = Formatter.parse(:html)
    end

    test "resolves :json alias to :ai" do
      assert {:ok, :ai} = Formatter.parse("json")
      assert {:ok, :ai} = Formatter.parse(:json)
    end

    test "error message mentions both canonical formats and aliases" do
      assert {:error, reason} = Formatter.parse("xml")
      assert reason =~ "ai"
      assert reason =~ "json"
      assert reason =~ "github"
    end
  end

  describe "render/2 — :text" do
    test "renders score summary even when there are no issues" do
      output = Formatter.render(:text, build_report([], 3))

      assert output =~ "═══ Summary ═══"
      assert output =~ "Quality Score: 100.0%"
      assert output =~ "no issues found"
    end

    test "groups issues per file with advisory tags" do
      issues = [
        finding("lib/a.ex", :obvious_comment, 10, "obvious comment found"),
        finding("lib/a.ex", :rescue_catch_all, 20, "naked rescue")
      ]

      output = Formatter.render(:text, build_report(issues, 1))

      assert output =~ "lib/a.ex — 2 issue(s):"
      assert output =~ "[obvious_comment:10] (advisory)"
      assert output =~ "[rescue_catch_all:20]"
      refute output =~ "[rescue_catch_all:20] (advisory)"
    end

    test "shows strict mode in the header" do
      report = build_report([], 1) |> Map.put(:strict?, true)
      assert Formatter.render(:text, report) =~ "(strict)"
    end
  end

  describe "render/2 — :github" do
    test "emits notice annotation on clean run" do
      output = Formatter.render(:github, build_report([], 5))
      assert output =~ "::notice::Quality score: 100.0% (no findings)"
    end

    test "emits ::error for boundary findings and ::warning for advisory" do
      issues = [
        finding("lib/a.ex", :rescue_catch_all, 12, "naked rescue"),
        finding("lib/a.ex", :obvious_comment, 30, "obvious comment")
      ]

      output = Formatter.render(:github, build_report(issues, 1))

      assert output =~
               "::error file=lib/a.ex,line=12,title=rescue_catch_all::naked rescue"

      assert output =~
               "::warning file=lib/a.ex,line=30,title=obvious_comment::obvious comment"
    end

    test "summary annotation reflects strict mode + strict-failing findings" do
      issues = [finding("lib/a.ex", :rescue_catch_all, 12, "naked rescue")]
      report = build_report(issues, 1) |> Map.put(:strict?, true)

      output = Formatter.render(:github, report)
      # New shape: count of findings >= severity:high & confidence:high.
      # rescue_catch_all is a safety rule → severity:high → trips the gate.
      assert output =~ "::error::Quality analysis: 1 finding(s) (1 >= severity:high & confidence:high)"
    end

    test "summary is ::notice when strict gate would not fire" do
      issues = [finding("lib/a.ex", :obvious_comment, 12, "obvious comment")]
      report = build_report(issues, 1) |> Map.put(:strict?, true)

      output = Formatter.render(:github, report)
      # obvious_comment is documentation → severity:low → doesn't trip
      # the default :high gate. Summary stays ::notice.
      assert output =~ "::notice::Quality analysis: 1 finding(s) (0 boundary, 1 advisory)"
    end

    test "synthetic :analyse_crashed finding trips the strict gate" do
      # Crash-synthetic findings carry explicit severity:high +
      # confidence:high. Without that, a broken analyser could
      # exit 0 — silent CI regression. This test exists to make
      # sure the synthetic shape stays gate-tripping.
      crash = %{
        path: "lib/buggy.ex",
        rule: :analyse_crashed,
        line: nil,
        message: "analyser exited: {:badmatch, nil}",
        severity: :high,
        confidence: :high
      }

      report = build_report([crash], 1) |> Map.put(:strict?, true)
      output = Formatter.render(:github, report)
      assert output =~ "::error::Quality analysis: 1 finding(s) (1 >= severity:high"
    end

    test "synthetic :cross_file_rule_crashed finding trips the strict gate" do
      crash = %{
        path: "lib/credence_rules/cross_file/buggy.ex",
        rule: :cross_file_rule_crashed,
        line: nil,
        message: "Cross-file rule X crashed: %KeyError{}",
        severity: :high,
        confidence: :high
      }

      report = build_report([crash], 1) |> Map.put(:strict?, true)
      output = Formatter.render(:github, report)
      assert output =~ "::error::Quality analysis: 1 finding(s) (1 >= severity:high"
    end

    test "summary respects --strict-min-severity threshold from report" do
      # Use an issue with explicit severity/confidence so the
      # test is independent of any rule's defaults — we're
      # testing threshold dispatch, not category routing.
      issue =
        finding("lib/a.ex", :large_defstruct, 12, "wide struct")
        |> Map.put(:severity, :medium)
        |> Map.put(:confidence, :medium)

      report_default =
        build_report([issue], 1)
        |> Map.put(:strict?, true)
        |> Map.put(:strict_min_severity, :high)
        |> Map.put(:strict_min_confidence, :high)

      output_default = Formatter.render(:github, report_default)
      assert output_default =~ "::notice::Quality analysis"

      report_medium_high =
        build_report([issue], 1)
        |> Map.put(:strict?, true)
        |> Map.put(:strict_min_severity, :medium)
        |> Map.put(:strict_min_confidence, :high)

      # severity meets :medium gate but confidence doesn't — no fire.
      output_medium_high = Formatter.render(:github, report_medium_high)
      assert output_medium_high =~ "::notice::Quality analysis"

      report_both_medium =
        build_report([issue], 1)
        |> Map.put(:strict?, true)
        |> Map.put(:strict_min_severity, :medium)
        |> Map.put(:strict_min_confidence, :medium)

      output_both = Formatter.render(:github, report_both_medium)
      assert output_both =~ "::error::Quality analysis: 1 finding(s) (1 >= severity:medium"
    end

    test "escapes newlines and percent signs in messages" do
      issues = [
        finding("lib/a.ex", :rescue_catch_all, 1, "first line\nsecond line 100% safe")
      ]

      output = Formatter.render(:github, build_report(issues, 1))
      assert output =~ "first line%0Asecond line 100%25 safe"
      refute output =~ "\nsecond line"
    end

    test "defaults missing line to 1 (GitHub workflow commands require an integer)" do
      issues = [%{path: "lib/a.ex", rule: :rescue_catch_all, line: nil, message: "no line"}]
      output = Formatter.render(:github, build_report(issues, 1))
      assert output =~ "line=1"
    end

    test "escapes `:` and `,` in property values (they're field delimiters)" do
      # A path with a colon or comma in it would otherwise break the
      # `key=value,key=value::message` shape GitHub parses.
      issues = [
        finding("lib/weird:path,name.ex", :rescue_catch_all, 1, "msg")
      ]

      output = Formatter.render(:github, build_report(issues, 1))
      assert output =~ "file=lib/weird%3Apath%2Cname.ex"
      refute output =~ "file=lib/weird:path,name.ex"
    end
  end

  describe "render/2 — :ai" do
    test "emits single-line JSON envelope" do
      output = Formatter.render(:ai, build_report([], 4))
      [json | _] = String.split(output, "\n", trim: true)
      assert json =~ ~s("findings":0)
      assert json =~ ~s("files":4)
      assert json =~ ~s("score":100.0)
      # Single line.
      refute String.contains?(json, "\n")
    end

    test "groups findings by file with category + advisory flag" do
      issues = [
        finding("lib/a.ex", :obvious_comment, 5, "obvious"),
        finding("lib/a.ex", :rescue_catch_all, 9, "rescue"),
        finding("lib/b.ex", :unsupervised_spawn, 1, "spawn")
      ]

      output = Formatter.render(:ai, build_report(issues, 5))

      assert output =~ ~s("lib/a.ex":[)
      assert output =~ ~s("lib/b.ex":[)
      assert output =~ ~s("category":"documentation")
      assert output =~ ~s("category":"safety")
      assert output =~ ~s("category":"concurrency")
      assert output =~ ~s("advisory":true)
      assert output =~ ~s("advisory":false)
      assert output =~ ~s("rule":"obvious_comment")
    end

    test "always lists every category in scores_by_category" do
      output = Formatter.render(:ai, build_report([], 1))

      for category <- CredenceRules.Category.all() do
        assert output =~ ~s("#{category}":100.0)
      end
    end

    test "escapes double quotes and backslashes in messages" do
      issues = [
        finding("lib/a.ex", :rescue_catch_all, 1, ~s(line with "quote" and \\ backslash))
      ]

      output = Formatter.render(:ai, build_report(issues, 1))
      assert output =~ ~s(line with \\"quote\\" and \\\\ backslash)
    end
  end

  defp build_report(issues, file_count) do
    files = issues |> Enum.map(& &1.path) |> Enum.uniq()

    files =
      if file_count > length(files),
        do: files ++ Enum.map(1..(file_count - length(files)), &"lib/synthetic_#{&1}.ex"),
        else: files

    # Synthesize a `%{path => line_count}` map for the lines-clean
    # score. Hand-built test fixtures don't have real files; give
    # each one a nominal 100 lines so the score has a stable
    # denominator. Tests that care about specific line-clean
    # percentages should build their own report inline.
    line_counts = Map.new(files, fn p -> {p, 100} end)

    %{
      issues: issues,
      score: Score.compute(issues, line_counts),
      files: files,
      strict?: false
    }
  end

  defp finding(path, rule, line, message) do
    %{path: path, rule: rule, line: line, message: message}
  end
end
