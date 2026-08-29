defmodule CredenceRules.Pattern.NoTriviallyTruthyAssertionTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.NoTriviallyTruthyAssertion

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    NoTriviallyTruthyAssertion.check(ast, [])
  end

  describe "check/2 — assert" do
    test "flags `assert true`" do
      assert [issue] = analyze("assert true")
      assert issue.rule == :no_trivially_truthy_assertion
      assert issue.message =~ "literal `true`"
    end

    test "flags `assert :ok`" do
      assert [issue] = analyze("assert :ok")
      assert issue.message =~ "atom literal"
    end

    test "flags `assert :error`" do
      assert [_] = analyze("assert :error")
    end

    test "flags `assert _ = expr`" do
      assert [issue] = analyze("assert _ = some_call(arg)")
      assert issue.message =~ "matches anything"
    end

    test "flags `assert _result = expr`" do
      assert [_] = analyze("assert _result = some_call(arg)")
    end

    test "does NOT flag `assert result = expr` (binding without leading _)" do
      # Plain variable bindings often precede later field-level asserts;
      # too noisy to flag without examining the rest of the test body.
      assert analyze("assert result = some_call(arg)") == []
    end

    test "flags `assert 1` (non-zero integer)" do
      assert [_] = analyze("assert 1")
    end

    test "does NOT flag `assert 0` (zero is falsy under truthiness)" do
      # `assert 0` would actually fail, so it's not a "trivially truthy"
      # placeholder — leave it alone (the test will catch the real bug).
      assert analyze("assert 0") == []
    end

    test "flags `assert \"x\"`" do
      assert [_] = analyze(~S|assert "x"|)
    end

    test "does NOT flag `assert \"\"` (empty string is falsy in Erlang sense — actually truthy in Elixir)" do
      # Empty string in Elixir is truthy (it's a non-nil non-false value),
      # but it's such a corner case that flagging it would surprise more
      # than it'd help. Leave alone.
      assert analyze(~S|assert ""|) == []
    end

    test "does NOT flag a real assert" do
      assert analyze("assert {:ok, _} = create_user(params)") == []
    end

    test "does NOT flag `assert foo == bar`" do
      assert analyze("assert foo == bar") == []
    end

    test "does NOT flag `assert function_call()`" do
      assert analyze("assert MyMod.something()") == []
    end
  end

  describe "check/2 — refute" do
    test "flags `refute false`" do
      assert [issue] = analyze("refute false")
      assert issue.message =~ "literal `false`"
    end

    test "flags `refute nil`" do
      assert [issue] = analyze("refute nil")
      assert issue.message =~ "literal `nil`"
    end

    test "does NOT flag a real refute" do
      assert analyze("refute User.admin?(user)") == []
    end
  end
end
