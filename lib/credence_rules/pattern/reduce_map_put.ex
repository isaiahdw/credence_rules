# credence-file:repeated_subtree_in_module — this module is an AST pattern
#   matcher whose check/2 + Macro.prewalk + build_issue shape is the Rule
#   contract itself, so the structural duplication is inherent to the form
#   rather than a smell
defmodule CredenceRules.Pattern.ReduceMapPut do
  @moduledoc """
  Refactor rule: `Enum.reduce(list, %{}, fn x, acc -> Map.put(acc, k, v) end)`
  is `Map.new/2` with the threading done by hand. `Map.new/2` takes the
  same mapper (returning `{k, v}` tuples) and skips the explicit
  accumulator.

  ## Bad

      Enum.reduce(users, %{}, fn u, acc -> Map.put(acc, u.id, u.name) end)

  ## Good

      Map.new(users, fn u -> {u.id, u.name} end)

  Alternatively a `for ... into: %{}` comprehension reads even more
  cleanly when there's filtering or pattern-matching involved.

  Ported from
  [`ExSlop.Check.Refactor.ReduceMapPut`](https://hex.pm/packages/ex_slop).
  """

  use CredenceRules.Rule

  @impl true
  def priority, do: 400

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn node, acc ->
        case match_reduce_map_put(node) do
          {:ok, meta} -> {node, [build_issue(meta) | acc]}
          :error -> {node, acc}
        end
      end)

    Enum.reverse(issues)
  end

  # Enum.reduce(list, %{}, fn x, acc -> Map.put(acc, ...) end)
  defp match_reduce_map_put(
         {{:., meta, [{:__aliases__, _, [:Enum]}, :reduce]}, _, [_list, {:%{}, _, []}, fun]}
       ) do
    if body_only_map_put?(fun), do: {:ok, meta}, else: :error
  end

  # |> Enum.reduce(%{}, fn x, acc -> Map.put(acc, ...) end)
  defp match_reduce_map_put(
         {:|>, meta, [_, {{:., _, [{:__aliases__, _, [:Enum]}, :reduce]}, _, [{:%{}, _, []}, fun]}]}
       ) do
    if body_only_map_put?(fun), do: {:ok, meta}, else: :error
  end

  defp match_reduce_map_put(_), do: :error

  defp body_only_map_put?({:fn, _, [{:->, _, [[_arg, {acc_name, _, _}], body]}]})
       when is_atom(acc_name) do
    body_uses_acc_for_map_put?(body, acc_name)
  end

  defp body_only_map_put?(_), do: false

  # Map.put(acc, _, _)
  defp body_uses_acc_for_map_put?(
         {{:., _, [{:__aliases__, _, [:Map]}, :put]}, _, [{acc_name, _, _} | _]},
         acc_name
       ),
       do: true

  # A wrapping block with a single expression — recurse.
  defp body_uses_acc_for_map_put?({:__block__, _, [single]}, acc_name),
    do: body_uses_acc_for_map_put?(single, acc_name)

  defp body_uses_acc_for_map_put?(_, _), do: false

  defp build_issue(meta) do
    %Issue{
      rule: :reduce_map_put,
      message:
        "`Enum.reduce(list, %{}, fn x, acc -> Map.put(acc, k, v) end)` reinvents " <>
          "`Map.new/2`. Use `Map.new(list, fn x -> {k, v} end)` (or a `for ... into: %{}` " <>
          "comprehension) instead.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
