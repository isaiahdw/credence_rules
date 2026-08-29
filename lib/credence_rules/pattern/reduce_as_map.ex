defmodule CredenceRules.Pattern.ReduceAsMap do
  @moduledoc """
  Refactor rule: `Enum.reduce(enum, [], fn x, acc -> [f(x) | acc] end)`
  reinvents `Enum.map/2` — and `Enum.reduce(enum, [], fn x, acc -> acc ++ [f(x)] end)`
  reinvents it badly (O(n²) list concatenation).

  ## Bad — manually building a reversed list

      Enum.reduce(items, [], fn item, acc ->
        [transform(item) | acc]
      end)

  ## Bad — O(n²) appending

      Enum.reduce(items, [], fn item, acc ->
        acc ++ [transform(item)]
      end)

  ## Good

      Enum.map(items, &transform/1)

  ## Detection

  Fires when `Enum.reduce/3` (or piped form) is called with:
  - An empty-list seed (`[]`).
  - A 2-arg lambda whose body is exactly `[expr | acc]` or `acc ++ [expr]`.

  Ported from
  [`ExSlop.Check.Refactor.ReduceAsMap`](https://hex.pm/packages/ex_slop).
  """

  use CredenceRules.Rule

  @impl true
  def priority, do: 400

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn node, acc ->
        case match_reduce_as_map(node) do
          {:ok, meta, variant} -> {node, [build_issue(meta, variant) | acc]}
          :error -> {node, acc}
        end
      end)

    Enum.reverse(issues)
  end

  # Enum.reduce(enum, [], fn x, acc -> [f(x) | acc] end)
  defp match_reduce_as_map({{:., meta, [{:__aliases__, _, [:Enum]}, :reduce]}, _, [_enum, seed, fun]}) do
    if empty_list_seed?(seed) do
      classify_body(fun, meta)
    else
      :error
    end
  end

  # |> Enum.reduce([], fn x, acc -> [f(x) | acc] end)
  defp match_reduce_as_map({:|>, meta, [_, {{:., _, [{:__aliases__, _, [:Enum]}, :reduce]}, _, [seed, fun]}]}) do
    if empty_list_seed?(seed) do
      classify_body(fun, meta)
    else
      :error
    end
  end

  defp match_reduce_as_map(_), do: :error

  defp empty_list_seed?([]), do: true
  defp empty_list_seed?({:__block__, _, [[]]}), do: true
  defp empty_list_seed?(_), do: false

  defp classify_body({:fn, _, [{:->, _, [[_item, {acc_name, _, _}], body]}]}, meta)
       when is_atom(acc_name) do
    cond do
      cons_to_acc?(body, acc_name) -> {:ok, meta, :cons}
      append_to_acc?(body, acc_name) -> {:ok, meta, :append}
      true -> :error
    end
  end

  defp classify_body(_, _), do: :error

  # [expr | acc] — single element prepended to the accumulator
  defp cons_to_acc?({:__block__, _, [inner]}, acc), do: cons_to_acc?(inner, acc)

  defp cons_to_acc?([{:|, _, [_elem, {acc, _, _}]}], acc) when is_atom(acc), do: true

  defp cons_to_acc?(_, _), do: false

  # acc ++ [expr]
  defp append_to_acc?({:__block__, _, [inner]}, acc), do: append_to_acc?(inner, acc)

  defp append_to_acc?({:++, _, [{acc, _, _}, [_elem]]}, acc) when is_atom(acc), do: true

  defp append_to_acc?(_, _), do: false

  defp build_issue(meta, :cons) do
    %Issue{
      rule: :reduce_as_map,
      message:
        "`Enum.reduce(enum, [], fn x, acc -> [f(x) | acc] end)` builds a reversed list one " <>
          "element at a time — use `Enum.map(enum, &f/1)` instead (same complexity, correct " <>
          "order, no manual `Enum.reverse` step later).",
      meta: %{line: Keyword.get(meta, :line), variant: :cons}
    }
  end

  defp build_issue(meta, :append) do
    %Issue{
      rule: :reduce_as_map,
      message:
        "`Enum.reduce(enum, [], fn x, acc -> acc ++ [f(x)] end)` is O(n²) — every append " <>
          "walks the entire accumulator. Use `Enum.map(enum, &f/1)` (O(n)) instead.",
      meta: %{line: Keyword.get(meta, :line), variant: :append}
    }
  end
end
