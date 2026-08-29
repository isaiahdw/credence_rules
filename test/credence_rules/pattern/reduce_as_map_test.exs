defmodule CredenceRules.Pattern.ReduceAsMapTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.ReduceAsMap

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    ReduceAsMap.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags `Enum.reduce(_, [], fn x, acc -> [f(x) | acc] end)`" do
      source = "Enum.reduce(items, [], fn item, acc -> [transform(item) | acc] end)"
      assert [issue] = analyze(source)
      assert issue.rule == :reduce_as_map
      assert issue.meta.variant == :cons
    end

    test "flags `Enum.reduce(_, [], fn x, acc -> acc ++ [f(x)] end)`" do
      source = "Enum.reduce(items, [], fn item, acc -> acc ++ [transform(item)] end)"
      assert [issue] = analyze(source)
      assert issue.meta.variant == :append
      assert issue.message =~ "O(n²)"
    end

    test "flags piped form" do
      assert [_] = analyze("items |> Enum.reduce([], fn item, acc -> [item | acc] end)")
    end

    test "flags multi-line lambda body that is still just cons" do
      source = ~S"""
      Enum.reduce(items, [], fn item, acc ->
        [transform(item) | acc]
      end)
      """

      assert [_] = analyze(source)
    end

    test "reports the line of the Enum.reduce" do
      source = ~S"""
      def transform_all(items) do
        Enum.reduce(items, [], fn item, acc -> [transform(item) | acc] end)
      end
      """

      assert [issue] = analyze(source)
      assert issue.meta.line == 2
    end
  end

  describe "check/2 — not flagged" do
    test "ignores non-empty seed" do
      source = "Enum.reduce(items, seed, fn item, acc -> [transform(item) | acc] end)"
      assert [] = analyze(source)
    end

    test "ignores reduce whose body does more than cons" do
      source = ~S"""
      Enum.reduce(items, [], fn item, acc ->
        if active?(item), do: [item | acc], else: acc
      end)
      """

      assert [] = analyze(source)
    end

    test "ignores reduce where the accumulator is on the wrong side of `|`" do
      source = "Enum.reduce(items, [], fn item, acc -> [acc | item] end)"
      assert [] = analyze(source)
    end

    test "ignores reduce that appends a multi-element list" do
      # acc ++ [a, b] isn't a single-element transform; not Enum.map.
      source = "Enum.reduce(items, [], fn item, acc -> acc ++ [item, item] end)"
      assert [] = analyze(source)
    end

    test "ignores reduce that conses a multi-element list" do
      # [a, b | acc] is also not Enum.map-shaped.
      source = "Enum.reduce(items, [], fn item, acc -> [item, item | acc] end)"
      assert [] = analyze(source)
    end

    test "ignores Enum.map" do
      assert [] = analyze("Enum.map(items, &transform/1)")
    end

    test "ignores reduce with %{} seed (that's reduce_map_put's job)" do
      source = "Enum.reduce(items, %{}, fn x, acc -> Map.put(acc, x, true) end)"
      assert [] = analyze(source)
    end
  end
end
