defmodule CredenceRules.Pattern.FlatMapFilterTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.FlatMapFilter

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    FlatMapFilter.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags `Enum.flat_map(list, fn x -> if cond, do: [x], else: [] end)`" do
      source = "Enum.flat_map(list, fn x -> if active?(x), do: [x], else: [] end)"

      assert [issue] = analyze(source)
      assert issue.rule == :flat_map_filter
    end

    test "flags piped form" do
      source = "list |> Enum.flat_map(fn x -> if active?(x), do: [x], else: [] end)"
      assert [_] = analyze(source)
    end

    test "flags negated pattern (do: [], else: [x])" do
      source = "Enum.flat_map(list, fn x -> if hidden?(x), do: [], else: [x] end)"
      assert [_] = analyze(source)
    end

    test "flags block form" do
      source = ~S"""
      Enum.flat_map(list, fn x ->
        if active?(x) do
          [x]
        else
          []
        end
      end)
      """

      assert [_] = analyze(source)
    end

    test "reports the line of the flat_map call" do
      source = ~S"""
      def actives(list) do
        Enum.flat_map(list, fn x -> if active?(x), do: [x], else: [] end)
      end
      """

      assert [issue] = analyze(source)
      assert issue.meta.line == 2
    end
  end

  describe "check/2 — not flagged" do
    test "ignores flat_map with non-list-shaped branches" do
      assert [] = analyze("Enum.flat_map(list, fn x -> children_of(x) end)")
    end

    test "ignores flat_map whose if returns multi-element lists" do
      assert [] = analyze("Enum.flat_map(list, fn x -> if pair?(x), do: [x, x], else: [] end)")
    end

    test "ignores flat_map where both branches return multi-element lists" do
      assert [] = analyze("Enum.flat_map(list, fn x -> if c?(x), do: [x, x], else: [x] end)")
    end

    test "ignores flat_map with case (not if) body" do
      source = ~S"""
      Enum.flat_map(list, fn x ->
        case x do
          {:ok, v} -> [v]
          _ -> []
        end
      end)
      """

      assert [] = analyze(source)
    end

    test "ignores plain Enum.filter" do
      assert [] = analyze("Enum.filter(list, &active?/1)")
    end

    test "ignores flat_map with a capture (no if)" do
      assert [] = analyze("Enum.flat_map(list, &children_of/1)")
    end

    test "ignores flat_map whose kept branch transforms the input (filter+map, not filter)" do
      assert [] =
               analyze("Enum.flat_map(list, fn x -> if keep?(x), do: [transform(x)], else: [] end)")
    end

    test "ignores flat_map with tuple-destructure and transforming body" do
      source = ~S"""
      Enum.flat_map(state.services, fn {instance, svc} ->
        if match?(svc), do: [build_rr(instance)], else: []
      end)
      """

      assert [] = analyze(source)
    end

    test "ignores flat_map with tuple-destructure that keeps a different element" do
      # `{a, b}` in; `[a]` out. The body extracts `a` — that's filter+map.
      assert [] =
               analyze("Enum.flat_map(list, fn {a, _b} -> if k?(a), do: [a], else: [] end)")
    end

    test "flags flat_map whose tuple-destructure body keeps the whole tuple" do
      # `{a, b}` in; `[{a, b}]` out. Identity — this is filter.
      assert [_] =
               analyze("Enum.flat_map(list, fn {a, b} -> if k?(a), do: [{a, b}], else: [] end)")
    end
  end
end
