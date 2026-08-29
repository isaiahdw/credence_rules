defmodule CredenceRules.Pattern.StepCommentTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.StepComment

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    StepComment.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test ~s(flags `# Step 1: …`) do
      assert [issue] = analyze("# Step 1: Validate input\n:ok")
      assert issue.rule == :step_comment
      assert issue.meta.line == 1
      assert issue.message =~ "Step N"
    end

    test ~s|flags `# STEP 2: …` (uppercase)| do
      assert [_] = analyze("# STEP 2: Transform\n:ok")
    end

    test ~s|flags `# step 3 …` (lowercase, no colon)| do
      assert [_] = analyze("# step 3 save it\n:ok")
    end

    test "flags multiple step comments and reports each line" do
      source = """
      def process(data) do
        # Step 1: Validate
        :ok
        # Step 2: Transform
        :ok
        # Step 3: Save
        :ok
      end
      """

      assert [a, b, c] = analyze(source)
      assert a.meta.line == 2
      assert b.meta.line == 4
      assert c.meta.line == 6
    end

    test "flags step comment after leading whitespace inside a function" do
      assert [issue] = analyze("def f do\n    # Step 1: do the thing\n    :ok\n  end")
      assert issue.meta.line == 2
    end
  end

  describe "check/2 — not flagged" do
    test "ignores `# Stepwise` and similar word-overlap" do
      assert [] = analyze("# Stepwise refinement note\n:ok")
    end

    test "ignores `# steps to follow` (plural, different word)" do
      assert [] = analyze("# steps to follow are documented elsewhere\n:ok")
    end

    test "ignores plain comments and code" do
      assert [] = analyze("# Normal comment\n:ok")
      assert [] = analyze("step = 1")
    end

    test "ignores comments with `Step` in the middle of the line" do
      assert [] = analyze("# Reviewing Step 1 here\n:ok")
    end

    test "ignores indented but non-step comments" do
      assert [] = analyze("  # not a step marker\n:ok")
    end
  end
end
