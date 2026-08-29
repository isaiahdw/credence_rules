defmodule CredenceRules.Pattern.AssertEnumAllTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.AssertEnumAll

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    AssertEnumAll.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags `assert Enum.all?(enum, fun)`" do
      assert [issue] = analyze(~S"assert Enum.all?(users, & &1.active)")
      assert issue.rule == :assert_enum_all
      assert issue.message =~ "comprehension"
    end

    test "flags `assert Enum.all?(enum)` (1-arg form)" do
      assert [_] = analyze(~S"assert Enum.all?(bools)")
    end

    test "flags inside a describe/test block" do
      source = ~S"""
      test "all users active" do
        assert Enum.all?(users, & &1.active)
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag `assert Enum.all?(...) or other`" do
      # Boolean composition — per-element message wouldn't add anything
      # over the original `assert` failure here.
      source = ~S"""
      assert Enum.all?(users, & &1.active) or admin_override?
      """

      assert analyze(source) == []
    end

    test "does NOT flag `refute Enum.any?` (different mental model)" do
      assert analyze(~S"refute Enum.any?(users, & &1.banned?)") == []
    end

    test "does NOT flag `Enum.all?` not under `assert`" do
      assert analyze(~S"valid? = Enum.all?(users, & &1.active)") == []
    end

    test "does NOT flag `assert Enum.empty?`" do
      assert analyze(~S"assert Enum.empty?(errors)") == []
    end
  end
end
