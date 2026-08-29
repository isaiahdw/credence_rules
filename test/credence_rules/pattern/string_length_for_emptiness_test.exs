defmodule CredenceRules.Pattern.StringLengthForEmptinessTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.StringLengthForEmptiness

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    StringLengthForEmptiness.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags String.length(s) == 0" do
      assert [issue] = analyze(~S"String.length(name) == 0")
      assert issue.rule == :string_length_for_emptiness
      assert issue.message =~ "== 0"
    end

    test "flags String.length(s) > 0" do
      assert [_] = analyze(~S"String.length(name) > 0")
    end

    test "flags String.length(s) <= 0" do
      assert [_] = analyze(~S"String.length(name) <= 0")
    end

    test "flags 0 == String.length(s) (reversed)" do
      assert [_] = analyze(~S"0 == String.length(name)")
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag String.length(s) == 11" do
      # Legitimate length check, not emptiness.
      assert analyze(~S"String.length(digits) == 11") == []
    end

    test "does NOT flag String.length used as a value" do
      assert analyze(~S"len = String.length(name)") == []
    end

    test "does NOT flag byte_size or length" do
      assert analyze(~S"byte_size(name) == 0") == []
      assert analyze(~S"length(list) == 0") == []
    end
  end
end
