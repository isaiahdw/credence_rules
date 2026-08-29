defmodule CredenceRules.Pattern.TryRescueWithSafeAlternativeTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.TryRescueWithSafeAlternative

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    TryRescueWithSafeAlternative.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags try/rescue around String.to_integer/1" do
      source = ~S"""
      try do
        String.to_integer(value)
      rescue
        _ -> nil
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :try_rescue_with_safe_alternative
      assert issue.message =~ "Integer.parse/1"
    end

    test "flags try/rescue around Jason.decode!/1" do
      source = ~S"""
      try do
        Jason.decode!(body)
      rescue
        _ -> {:error, :bad_json}
      end
      """

      assert [issue] = analyze(source)
      assert issue.message =~ "Jason.decode/1"
    end

    test "flags try/rescue around Map.fetch!/2" do
      source = ~S"""
      try do
        Map.fetch!(m, :key)
      rescue
        _ -> nil
      end
      """

      assert [_] = analyze(source)
    end

    test "flags try/rescue around File.read!/1" do
      source = ~S"""
      try do
        File.read!(path)
      rescue
        _ -> ""
      end
      """

      assert [_] = analyze(source)
    end

    test "flags try whose body assigns the call to a binding" do
      source = ~S"""
      try do
        n = String.to_integer(value)
        n
      rescue
        _ -> nil
      end
      """

      # Body's last expression is `n` (a variable, not a raising call) —
      # we only flag when the LAST expression is the raising call. So
      # this should NOT fire. Encoding the spec as a test.
      assert [] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "ignores try around an unknown call" do
      source = ~S"""
      try do
        do_something_dangerous(value)
      rescue
        _ -> nil
      end
      """

      assert [] = analyze(source)
    end

    test "ignores plain function calls" do
      assert [] = analyze("String.to_integer(value)")
    end

    test "ignores try without rescue" do
      source = ~S"""
      try do
        String.to_integer(value)
      after
        :ok
      end
      """

      assert [] = analyze(source)
    end
  end
end
