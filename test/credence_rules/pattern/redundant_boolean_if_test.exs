defmodule CredenceRules.Pattern.RedundantBooleanIfTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.RedundantBooleanIf

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    RedundantBooleanIf.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags `if cond, do: true, else: false`" do
      assert [issue] = analyze("if status == :active, do: true, else: false")
      assert issue.rule == :redundant_boolean_if
    end

    test "flags negated `if cond, do: false, else: true`" do
      assert [_] = analyze("if is_nil(x), do: false, else: true")
    end

    test "flags block form `if cond do true else false end`" do
      source = ~S"""
      if status == :active do
        true
      else
        false
      end
      """

      assert [_] = analyze(source)
    end

    test "flags negated block form" do
      source = ~S"""
      if is_nil(x) do
        false
      else
        true
      end
      """

      assert [_] = analyze(source)
    end

    test "reports the line of the if" do
      source = ~S"""
      def active?(status) do
        result = if status == :active, do: true, else: false
        result
      end
      """

      assert [issue] = analyze(source)
      assert issue.meta.line == 2
    end

    test "flags each redundant if separately" do
      source = ~S"""
      def go(a, b) do
        x = if a, do: true, else: false
        y = if b, do: true, else: false
        {x, y}
      end
      """

      assert [first, second] = analyze(source)
      assert first.meta.line == 2
      assert second.meta.line == 3
    end
  end

  describe "check/2 — not flagged" do
    test "ignores ifs returning non-boolean atoms" do
      assert [] = analyze("if status == :active, do: :on, else: :off")
    end

    test "ignores ifs returning boolean expressions (not literals)" do
      assert [] = analyze("if x, do: y, else: z")
    end

    test "ignores `if x, do: true, else: nil` (asymmetric — not this rule's job)" do
      assert [] = analyze("if x, do: true, else: nil")
    end

    test "ignores ifs with three-arm (not possible — if only has 2 arms)" do
      # Sanity check that other ifs don't accidentally match.
      assert [] = analyze("if x, do: x")
    end

    test "ignores plain expressions" do
      assert [] = analyze("x = 1")
    end

    test "ignores `unless` macros" do
      assert [] = analyze("unless x, do: true, else: false")
    end
  end
end
