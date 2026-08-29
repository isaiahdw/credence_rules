defmodule CredenceRules.Pattern.UnusedEnumOperationTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.UnusedEnumOperation

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    UnusedEnumOperation.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags Enum.map as a discarded statement" do
      source = ~S"""
      def f(xs) do
        Enum.map(xs, &transform/1)
        :ok
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :unused_enum_operation
      assert issue.message =~ "Enum.map"
      assert issue.message =~ "Enum.each"
    end

    test "flags Map.new as discarded" do
      source = ~S"""
      def f(xs) do
        Map.new(xs, fn x -> {x, true} end)
        :done
      end
      """

      assert [_] = analyze(source)
    end

    test "flags multiple discards in one block" do
      source = ~S"""
      def f(xs) do
        Enum.map(xs, &transform/1)
        Enum.filter(xs, &valid?/1)
        :ok
      end
      """

      assert length(analyze(source)) == 2
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag Enum.map as the last expression" do
      source = ~S"""
      def f(xs) do
        Enum.map(xs, &transform/1)
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag Enum.each (side-effect-by-design)" do
      source = ~S"""
      def f(xs) do
        Enum.each(xs, &IO.puts/1)
        :ok
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag the assignment form `x = Enum.map(...)`" do
      source = ~S"""
      def f(xs) do
        mapped = Enum.map(xs, &transform/1)
        process(mapped)
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag piped form ending the block" do
      source = ~S"""
      def f(xs) do
        xs |> Enum.map(&transform/1) |> Enum.sum()
      end
      """

      assert analyze(source) == []
    end
  end
end
