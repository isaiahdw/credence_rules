defmodule CredenceRules.Pattern.ListAppendInReduceTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.ListAppendInReduce

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    ListAppendInReduce.check(ast, source: source)
  end

  defp analyze_sourceror(source) do
    {:ok, ast} = Sourceror.parse_string(source)
    ListAppendInReduce.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "acc ++ [x] inside Enum.reduce" do
      assert [issue] = analyze("Enum.reduce(items, [], fn i, acc -> acc ++ [f(i)] end)")
      assert issue.rule == :list_append_in_reduce
    end

    test "acc ++ [x] inside Enum.reduce_while" do
      assert [_] = analyze("Enum.reduce_while(items, [], fn i, acc -> {:cont, acc ++ [i]} end)")
    end

    test "flags under Sourceror parse" do
      source = ~S"""
      defmodule M do
        def go(items), do: Enum.reduce(items, [], fn i, acc -> acc ++ [f(i)] end)
      end
      """

      assert [_] = analyze_sourceror(source)
    end
  end

  describe "check/2 — not flagged" do
    test "prepend then reverse (the fix)" do
      assert [] = analyze("Enum.reduce(items, [], fn i, acc -> [f(i) | acc] end)")
    end

    test "accumulator on the right of ++ (copies the small literal, not acc)" do
      assert [] = analyze("Enum.reduce(items, [], fn i, acc -> [f(i)] ++ acc end)")
    end

    test "++ outside a reduce is not flagged" do
      assert [] = analyze("a ++ [x]")
    end

    test "reduce without ++" do
      assert [] = analyze("Enum.reduce(items, 0, fn i, acc -> acc + i end)")
    end
  end
end
