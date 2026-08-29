defmodule CredenceRules.Pattern.NonAssertiveMapAccessTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.NonAssertiveMapAccess

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    NonAssertiveMapAccess.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags m[:email]" do
      assert [issue] = analyze(~S"m[:email]")
      assert issue.rule == :non_assertive_map_access
      assert issue.message =~ "m.email"
    end

    test "flags inside a function body" do
      source = ~S"""
      def email(user) do
        user[:email]
      end
      """

      assert [_] = analyze(source)
    end

    test "flags nested map[:k][:k2]" do
      # Two bracket accesses → two findings.
      issues = analyze(~S"m[:outer][:inner]")
      assert length(issues) == 2
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag m.atom_key (dot access)" do
      assert analyze(~S"m.email") == []
    end

    test "does NOT flag m[var] (variable key)" do
      assert analyze(~S"m[key]") == []
    end

    test "does NOT flag m[\"string\"]" do
      assert analyze(~S|m["email"]|) == []
    end

    test "does NOT flag explicit Access.get(m, :k)" do
      assert analyze(~S"Access.get(m, :email)") == []
    end

    test "does NOT flag Map.get/get_lazy" do
      assert analyze(~S"Map.get(m, :email)") == []
    end
  end
end
