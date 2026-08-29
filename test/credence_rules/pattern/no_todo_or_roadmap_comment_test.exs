defmodule CredenceRules.Pattern.NoTodoOrRoadmapCommentTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.NoTodoOrRoadmapComment

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    NoTodoOrRoadmapComment.check(ast, source: source)
  end

  describe "TODO / FIXME / HACK / XXX" do
    test "flags `# TODO`" do
      assert [issue] = analyze("# TODO: do the thing\n:ok")
      assert issue.rule == :no_todo_or_roadmap_comment
      assert issue.message =~ "TODO"
      assert issue.meta.line == 1
    end

    test "flags `# FIXME`" do
      assert [issue] = analyze("# FIXME: broken on Tuesdays\n:ok")
      assert issue.message =~ "FIXME"
    end

    test "flags `# HACK`" do
      assert [_] = analyze("# HACK: works for now\n:ok")
    end

    test "flags `# XXX`" do
      assert [_] = analyze("# XXX revisit this\n:ok")
    end

    test "case-insensitive" do
      assert [_] = analyze("# todo: lowercase\n:ok")
      assert [_] = analyze("# ToDo mixed case\n:ok")
    end
  end

  describe "roadmap markers" do
    test "flags `# Phase 2`" do
      assert [issue] = analyze("# Phase 2: rate limiting\n:ok")
      assert issue.message =~ "Phase N"
    end

    test "flags `# (Phase 3)`" do
      assert [_] = analyze("# (Phase 3) cleanup\n:ok")
    end

    test "flags `# follow-up`" do
      assert [issue] = analyze("# follow-up: open issue\n:ok")
      assert issue.message =~ "follow-up"
    end

    test "flags `# followup` (no hyphen)" do
      assert [_] = analyze("# followup later\n:ok")
    end

    test "flags `# we'll add retries later`" do
      assert [issue] =
               analyze("# we'll add retry logic later when we have metrics\n:ok")

      assert issue.message =~ "future-work narration"
    end
  end

  describe "out of scope (handled by other rules)" do
    test ~s(does NOT flag `# tracked as #123` — owned by stale_reference_comment) do
      assert [] = analyze("# tracked as #123\n:ok")
    end
  end

  describe "negative cases" do
    test "ignores a regular comment" do
      assert analyze("# A normal docstring line\n:ok") == []
    end

    test "ignores `# TODO` inside a string literal" do
      # The regex requires `^\s*#` so it only matches actual comments.
      # A `"# TODO"` inside a string just contains `#` mid-line.
      assert analyze(~S|s = "# TODO not a comment"|) == []
    end

    test "ignores a function named todo" do
      assert analyze("def todo, do: :pending") == []
    end

    test "ignores `# follow` (not `follow-up`)" do
      assert analyze("# follow the spec\n:ok") == []
    end
  end

  describe "multiple findings" do
    test "flags every line in a multi-marker source" do
      source =
        """
        # TODO one
        :ok

        # FIXME two
        :ok

        # Phase 4 three
        :ok
        """

      issues = analyze(source)
      assert length(issues) == 3
      lines = Enum.map(issues, & &1.meta.line)
      assert lines == [1, 4, 7]
    end

    test "one finding per line even if multiple markers match" do
      assert [issue] = analyze("# TODO Phase 2 follow-up\n:ok")
      assert issue.message =~ "TODO"
    end
  end
end
