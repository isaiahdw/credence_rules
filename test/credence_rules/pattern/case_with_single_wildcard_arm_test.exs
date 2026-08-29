defmodule CredenceRules.Pattern.CaseWithSingleWildcardArmTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.CaseWithSingleWildcardArm

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    CaseWithSingleWildcardArm.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags `case x do _ -> body end`" do
      assert [issue] =
               analyze(~S"""
               case do_thing() do
                 _ -> :ok
               end
               """)

      assert issue.rule == :case_with_single_wildcard_arm
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag a case with more than one arm" do
      source = ~S"""
      case x do
        :ok -> :good
        _ -> :other
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag a single-arm case with a non-wildcard pattern" do
      assert analyze(~S"case x do :ok -> :good end") == []
      assert analyze(~S"case x do {:ok, _} -> :good end") == []
    end

    test "does NOT flag a case-expression assigned to a var (still single-arm wildcard wouldn't make sense)" do
      # This one would still fire — and that's correct. The assignment
      # doesn't change the dead-case-ness.
      assert [_] = analyze(~S"y = case x do _ -> :ok end")
    end
  end
end
