defmodule CredenceRules.Pattern.EnumEachAssignedTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.EnumEachAssigned

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    EnumEachAssigned.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags `result = Enum.each(...)`" do
      assert [issue] = analyze("result = Enum.each(users, &deliver/1)")
      assert issue.rule == :enum_each_assigned
    end

    test "flags `processed = list |> Enum.each(...)`" do
      assert [_] = analyze("processed = users |> Enum.each(&deliver/1)")
    end

    test "flags `_var = Enum.each(...)` (named underscore)" do
      assert [_] = analyze("_results = Enum.each(users, &deliver/1)")
    end

    test "flags `_ = Enum.each(...)` (bare underscore)" do
      assert [_] = analyze("_ = Enum.each(users, &deliver/1)")
    end

    test "reports the line of the Enum.each call" do
      source = ~S"""
      def deliver_all(users) do
        x = 1
        result = Enum.each(users, &deliver/1)
        result
      end
      """

      assert [issue] = analyze(source)
      assert issue.meta.line == 3
    end

    test "flags each occurrence inside a single function" do
      source = ~S"""
      def go(a, b) do
        r1 = Enum.each(a, &deliver/1)
        r2 = Enum.each(b, &deliver/1)
        {r1, r2}
      end
      """

      assert [first, second] = analyze(source)
      assert first.meta.line < second.meta.line
    end

    test "flags chained pipe ending in Enum.each" do
      source = "result = users |> filter() |> Enum.each(&deliver/1)"
      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "ignores bare `Enum.each(...)`" do
      assert [] = analyze("Enum.each(users, &deliver/1)")
    end

    test "ignores Enum.each as the last (returned) expression of a function" do
      source = ~S"""
      def go(users) do
        Enum.each(users, &deliver/1)
      end
      """

      assert [] = analyze(source)
    end

    test "ignores `Enum.map(...)` assignment" do
      assert [] = analyze("result = Enum.map(users, &deliver/1)")
    end

    test "ignores `Enum.reduce(...)` assignment" do
      assert [] = analyze("acc = Enum.reduce(users, 0, fn _, a -> a + 1 end)")
    end

    test "ignores tap (returns its input — assignment is legitimate)" do
      assert [] = analyze("result = tap(users, &deliver/1)")
    end

    test "ignores Stream.run (different module)" do
      assert [] = analyze("result = Stream.run(stream)")
    end
  end

  describe "edge: destructuring pattern LHS" do
    test "flags `{:ok, _} = Enum.each(...)` (would crash at runtime — useful catch)" do
      # Enum.each returns :ok, so this match would always raise. Flagging
      # it surfaces the bug rather than letting it ship.
      assert [_] = analyze("{:ok, result} = Enum.each(users, &deliver/1)")
    end
  end
end
