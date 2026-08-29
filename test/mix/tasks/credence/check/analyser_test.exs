defmodule Mix.Tasks.Credence.Check.AnalyserTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Credence.Check.Analyser

  describe "analyse_source/1" do
    test "returns an empty list for clean source" do
      source = """
      defmodule Clean do
        @moduledoc "I do nothing of consequence."
        def noop, do: :ok
      end
      """

      assert [] = Analyser.analyse_source(source)
    end

    test "surfaces an CredenceRules.Pattern.* finding with line metadata" do
      # `obvious_comment` is one of our advisory rules; it fires on
      # the `# Fetch the user` comment.
      source = """
      defmodule Smoke do
        def get_user(id) do
          # Fetch the user
          %{id: id}
        end
      end
      """

      issues = Analyser.analyse_source(source)
      obvious = Enum.find(issues, &(&1.rule == :obvious_comment))
      assert obvious, "expected an obvious_comment finding, got: #{inspect(issues)}"
      assert obvious.line == 3
      assert obvious.message =~ "# Fetch the user"
    end

    test "collapses multi-line messages to one line" do
      # Use a rule whose default message wraps. `string_to_atom_unsafe`
      # has a long advisory blurb — we expect single-line output.
      source = """
      defmodule Atomy do
        def f(s), do: String.to_atom(s)
      end
      """

      assert [%{rule: :string_to_atom_unsafe, message: message}] =
               Analyser.analyse_source(source) |> Enum.filter(&(&1.rule == :string_to_atom_unsafe))

      refute String.contains?(message, "\n")
    end

    test "returns syntax issues short-circuit (no pattern pass on broken source)" do
      # Unclosed `do` block — Sourceror reports a parse error and
      # `Credence.Syntax.analyze/2` surfaces it. Pattern phase is
      # skipped: every pattern rule assumes a parseable AST.
      source = "defmodule Broken do\n"

      issues = Analyser.analyse_source(source)
      assert Enum.any?(issues), "expected at least one syntax issue"
      refute Enum.any?(issues, &(&1.rule == :obvious_comment))
    end
  end

  describe "analyse_source/1 — inline # credence:<rule> suppression" do
    @nested "defmodule M do\n  def f(s), do: String.to_atom(String.trim(s))\nend\n"

    test "a reasoned trailing directive drops the finding" do
      source = """
      defmodule M do
        def f(s), do: String.to_atom(s) # credence:string_to_atom_unsafe — input is from a fixed allowlist
      end
      """

      refute Enum.any?(Analyser.analyse_source(source), &(&1.rule == :string_to_atom_unsafe))
    end

    test "a reasoned directive on the line above drops the finding" do
      source = """
      defmodule M do
        # credence:string_to_atom_unsafe — input is from a fixed allowlist
        def f(s), do: String.to_atom(s)
      end
      """

      refute Enum.any?(Analyser.analyse_source(source), &(&1.rule == :string_to_atom_unsafe))
    end

    test "a reasonless directive still suppresses but is itself reported as a boundary finding" do
      source = """
      defmodule M do
        def f(s), do: String.to_atom(s) # credence:string_to_atom_unsafe
      end
      """

      issues = Analyser.analyse_source(source)
      refute Enum.any?(issues, &(&1.rule == :string_to_atom_unsafe))

      assert nag = Enum.find(issues, &(&1.rule == :credence_suppression_without_reason))
      assert nag.line == 2
      # Must clear the default --strict gate (severity:high AND confidence:high).
      assert nag.severity == :high
      assert nag.confidence == :high
    end

    test "a directive for a different rule leaves the finding in place" do
      source = """
      defmodule M do
        def f(s), do: String.to_atom(s) # credence:nested_calls_should_pipe — wrong rule
      end
      """

      assert Enum.any?(Analyser.analyse_source(source), &(&1.rule == :string_to_atom_unsafe))
    end

    test "leaves an unannotated finding untouched" do
      assert Enum.any?(Analyser.analyse_source(@nested), &(&1.rule == :string_to_atom_unsafe))
    end
  end

  describe "analyse/1" do
    @tag :tmp_dir
    test "reads the file from disk and returns {path, issues, line_count}",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "sample.ex")

      File.write!(path, """
      defmodule Smoke do
        def f(s), do: String.to_atom(s)
      end
      """)

      assert {^path, issues, line_count} = Analyser.analyse(path)
      assert Enum.any?(issues, &(&1.rule == :string_to_atom_unsafe))
      # 3 non-empty lines in the fixture
      assert line_count == 3
    end
  end
end
