defmodule CredenceRules.Pattern.LengthListForEmptinessTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.LengthListForEmptiness

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    LengthListForEmptiness.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags length(list) == 0" do
      assert [issue] = analyze(~S"length(items) == 0")
      assert issue.rule == :length_list_for_emptiness
      assert issue.message =~ "length/1"
    end

    test "flags length(list) > 0" do
      assert [_] = analyze(~S"length(items) > 0")
    end

    test "flags Enum.count(list) == 0" do
      assert [issue] = analyze(~S"Enum.count(items) == 0")
      assert issue.message =~ "Enum.count/1"
    end

    test "flags 0 == length(list) (reversed)" do
      assert [_] = analyze(~S"0 == length(items)")
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag length(list) == 3" do
      assert analyze(~S"length(events) == 3") == []
    end

    test "does NOT flag length used as a value" do
      assert analyze(~S"len = length(items)") == []
    end

    test "does NOT flag Enum.count/2 (with predicate — different shape)" do
      assert analyze(~S"Enum.count(items, & &1.active?) == 0") == []
    end

    test "does NOT flag String.length or byte_size" do
      assert analyze(~S"String.length(name) == 0") == []
      assert analyze(~S"byte_size(name) == 0") == []
    end
  end
end
