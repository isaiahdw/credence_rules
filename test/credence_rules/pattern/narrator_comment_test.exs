defmodule CredenceRules.Pattern.NarratorCommentTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.NarratorComment

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    NarratorComment.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test ~s(flags `# Here we …`) do
      assert [issue] = analyze("# Here we fetch the user\nuser = nil")
      assert issue.rule == :narrator_comment
      assert issue.meta.line == 1
      assert issue.message =~ "Narrator comment"
    end

    test ~s(flags `# Now we …`) do
      assert [_] = analyze("# Now we validate the input\n:ok")
    end

    test ~s(flags `# Let's …`) do
      assert [_] = analyze("# Let's create a new changeset\n:ok")
    end

    test ~s(flags `# Lets …` without apostrophe) do
      assert [_] = analyze("# Lets build a list\n:ok")
    end

    test ~s(flags `# Next we …` / `# Next, we …`) do
      assert [_] = analyze("# Next we transform the data\n:ok")
      assert [_] = analyze("# Next, we transform the data\n:ok")
    end

    test ~s(flags `# Finally we …`) do
      assert [_] = analyze("# Finally we save it\n:ok")
    end

    test ~s(flags `# First we …`) do
      assert [_] = analyze("# First we sort the list\n:ok")
    end

    test "flags multiple narrator lines and reports line numbers" do
      source = """
      # Here we fetch the user
      user = nil
      # Now we update them
      :ok
      """

      assert [a, b] = analyze(source)
      assert a.meta.line == 1
      assert b.meta.line == 3
    end

    test "flags indented narrator comment" do
      assert [_] = analyze("def foo do\n  # Here we do stuff\n  :ok\nend")
    end
  end

  describe "check/2 — not flagged" do
    test "ignores TODO / FIXME / HACK keepers" do
      assert [] = analyze("# TODO: Here we fetch the user\n:ok")
      assert [] = analyze("# FIXME: Now we validate\n:ok")
      assert [] = analyze("# HACK: Let's bypass the check\n:ok")
      assert [] = analyze("# NOTE: Here we ignore errors on purpose\n:ok")
    end

    test "ignores tool pragmas" do
      assert [] = analyze("# credo:disable-for-next-line\n:ok")
      assert [] = analyze("# dialyzer: Here we suppress\n:ok")
    end

    test "ignores comments that explain WHY (because / since / avoid / …)" do
      assert [] = analyze("# Here we skip validation because admin imports are pre-validated\n:ok")
      assert [] = analyze("# Now we retry since the upstream service is flaky\n:ok")
      assert [] = analyze("# Let's pin the version to avoid the 0.6 regression\n:ok")
      assert [] = analyze("# Here we copy the buffer so that the caller can free its source\n:ok")
    end

    test "ignores plain code, plain comments, doc-style comments" do
      assert [] = analyze("user = Repo.get(User, id)")
      assert [] = analyze("# Unparseable line should still be safe")
      assert [] = analyze("# We need this because of the rate limit (not first-person narrator)")
    end

    test "ignores comments above the length limit" do
      long = String.duplicate("x", 100)
      assert [] = analyze("# Here we #{long}\n:ok")
    end
  end
end
