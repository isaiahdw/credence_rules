defmodule CredenceRules.Pattern.NilPredicateLambdaTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.NilPredicateLambda

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    NilPredicateLambda.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags `Enum.filter(list, fn x -> x != nil end)`" do
      assert [issue] = analyze("Enum.filter(list, fn x -> x != nil end)")
      assert issue.rule == :nil_predicate_lambda
      assert issue.meta.op == :filter
    end

    test "flags piped Enum.filter form" do
      assert [_] = analyze("list |> Enum.filter(fn x -> x != nil end)")
    end

    test "flags `Enum.filter(list, fn x -> not is_nil(x) end)`" do
      assert [_] = analyze("Enum.filter(list, fn x -> not is_nil(x) end)")
    end

    test "flags `Enum.filter(list, fn x -> !is_nil(x) end)`" do
      assert [_] = analyze("Enum.filter(list, fn x -> !is_nil(x) end)")
    end

    test "flags `Enum.reject(list, fn x -> x == nil end)`" do
      assert [issue] = analyze("Enum.reject(list, fn x -> x == nil end)")
      assert issue.meta.op == :reject
    end

    test "flags `Enum.reject(list, fn x -> is_nil(x) end)`" do
      assert [_] = analyze("Enum.reject(list, fn x -> is_nil(x) end)")
    end

    test "flags `Enum.filter(list, fn x -> x !== nil end)` (strict-equality variant)" do
      assert [_] = analyze("Enum.filter(list, fn x -> x !== nil end)")
    end

    test "flags `Enum.reject(list, fn x -> x === nil end)` (strict-equality)" do
      assert [_] = analyze("Enum.reject(list, fn x -> x === nil end)")
    end

    test "flags `nil != x` variant (swapped order)" do
      assert [_] = analyze("Enum.filter(list, fn x -> nil != x end)")
    end

    test "reports the line of the Enum call" do
      source = ~S"""
      def actives(list) do
        Enum.filter(list, fn x -> x != nil end)
      end
      """

      assert [issue] = analyze(source)
      assert issue.meta.line == 2
    end

    test "flags each occurrence in a single function" do
      source = ~S"""
      def go(a, b) do
        x = Enum.filter(a, fn x -> x != nil end)
        y = Enum.reject(b, fn x -> is_nil(x) end)
        {x, y}
      end
      """

      assert [first, second] = analyze(source)
      assert first.meta.op == :filter
      assert second.meta.op == :reject
    end
  end

  describe "check/2 — not flagged" do
    test "ignores `Enum.reject(&is_nil/1)` (the recommended form)" do
      assert [] = analyze("Enum.reject(list, &is_nil/1)")
    end

    test "ignores `Enum.filter(&(not is_nil(&1)))` (capture syntax)" do
      assert [] = analyze("Enum.filter(list, &(not is_nil(&1)))")
    end

    test "ignores non-nil predicates" do
      assert [] = analyze("Enum.filter(list, fn x -> x.active end)")
      assert [] = analyze("Enum.reject(list, fn x -> x == 0 end)")
    end

    test "ignores Enum.filter for keeping nils (reversed semantics)" do
      assert [] = analyze("Enum.filter(list, fn x -> x == nil end)")
    end

    test "ignores Enum.reject for rejecting non-nils (reversed semantics)" do
      assert [] = analyze("Enum.reject(list, fn x -> x != nil end)")
    end

    test "ignores lambdas with pattern-match args (we only match simple var)" do
      assert [] = analyze("Enum.filter(list, fn {:ok, x} -> x != nil end)")
    end

    test "ignores Stream.filter (different module)" do
      assert [] = analyze("Stream.filter(list, fn x -> x != nil end)")
    end
  end
end
