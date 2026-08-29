defmodule CredenceRules.Pattern.DualKeyAccessTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.DualKeyAccess

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    DualKeyAccess.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags `m[:email] || m[\"email\"]`" do
      source = ~S"""
      m[:email] || m["email"]
      """

      assert [issue] = analyze(source)
      assert issue.rule == :dual_key_access
      assert issue.message =~ "boundary"
    end

    test "flags reversed `m[\"email\"] || m[:email]`" do
      source = ~S"""
      m["email"] || m[:email]
      """

      assert [_] = analyze(source)
    end

    test "flags `or` form" do
      source = ~S"""
      m[:email] or m["email"]
      """

      assert [_] = analyze(source)
    end

    test "flags with same dotted-path container" do
      source = ~S"""
      user.profile[:email] || user.profile["email"]
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag single bracket-access OR default value" do
      source = ~S"""
      m[:email] || "unknown@example.com"
      """

      assert analyze(source) == []
    end

    test "does NOT flag both-atom keys (matching shape)" do
      source = ~S"""
      m[:email] || m[:fallback_email]
      """

      assert analyze(source) == []
    end

    test "does NOT flag both-string keys" do
      source = ~S"""
      m["email"] || m["fallback_email"]
      """

      assert analyze(source) == []
    end

    test "does NOT flag access on different containers" do
      source = ~S"""
      user[:email] || account["email"]
      """

      assert analyze(source) == []
    end

    test "does NOT flag a single bracket-access alone" do
      assert analyze(~S"m[:email]") == []
    end

    test "does NOT flag explicit Access.get" do
      source = ~S"""
      Access.get(m, :email) || Access.get(m, "email")
      """

      assert analyze(source) == []
    end
  end
end
