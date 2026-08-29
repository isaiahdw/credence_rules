defmodule CredenceRules.Pattern.AssertMatchQuestionTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.AssertMatchQuestion

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    AssertMatchQuestion.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags `assert match?({:ok, _}, expr)`" do
      assert [issue] = analyze(~S"assert match?({:ok, _}, result)")
      assert issue.rule == :assert_match_question
      assert issue.message =~ "assert pattern = expr"
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag `assert match?(a, x) or match?(b, x)`" do
      source = ~S"""
      assert match?({:ok, _}, result) or match?({:error, :timeout}, result)
      """

      assert analyze(source) == []
    end

    test "does NOT flag `assert match?(a, x) and other`" do
      assert analyze(~S"assert match?({:ok, _}, r) and r.value > 0") == []
    end

    test "does NOT flag `assert {:ok, _} = result`" do
      assert analyze(~S"assert {:ok, _} = result") == []
    end

    test "does NOT flag `refute match?(…)`" do
      assert analyze(~S"refute match?({:error, _}, result)") == []
    end
  end
end
