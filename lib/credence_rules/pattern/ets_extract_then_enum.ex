defmodule CredenceRules.Pattern.EtsExtractThenEnum do
  @moduledoc """
  Boundary rule: `:ets.tab2list/1 |> Enum.{filter,map,sort,...}` pulls
  the entire table into the calling process's heap and then filters
  there. ETS can do the work in-place.

  ETS is a separate-heap, queryable mutable store. Its native
  query API (`:ets.select/2`, `:ets.match/2`, `:ets.match_object/2`,
  `:ets.foldl/3`) walks the table without copying every row into the
  caller's heap. When you `tab2list` first, you:

  - allocate O(n) in the caller's heap for the snapshot list,
  - then walk that list a second time in `Enum.filter`,
  - then GC the list,

  …versus `:ets.select/2`, which streams matched rows directly and
  copies only the survivors. On a 100k-row table the difference is
  often 10-100x, and the `tab2list` snapshot also breaks the
  read-while-written semantics of ETS (you get a frozen point-in-time
  view that diverges from concurrent writes).

  Book reference: Elixir Patterns, ch.4 — ETS filtering should
  happen inside ETS, not after.

  ## Detection

  `|>` pipes whose LHS is `:ets.tab2list/1` and whose RHS is an `Enum`
  function that touches every element (`map`, `filter`, `reject`,
  `sort`, `sort_by`, `find`, `any?`, `all?`, `group_by`, `reduce`,
  `flat_map`, `take`, `take_while`, `drop`, `drop_while`, `partition`,
  `count` with predicate).

  Multi-step forms (`data = :ets.tab2list(t); Enum.filter(data, fun)`)
  are NOT detected today — they require dataflow analysis. The pipe
  form is the LLM-canonical shape.

  ## Bad

      :ets.tab2list(:users)
      |> Enum.filter(fn {_id, %{active: a}} -> a end)
      |> Enum.map(&elem(&1, 1))

  ## Good

      # Match spec: extract only active users, return their record map.
      :ets.select(:users, [
        {{:"$1", %{active: true} = :"$2"}, [], [:"$2"]}
      ])
  """

  use CredenceRules.Rule

  @flagged_enum_funs MapSet.new(~w(map filter reject sort sort_by find any? all?
                          group_by reduce flat_map take take_while drop
                          drop_while partition count flat_map_each min_by
                          max_by sum)a)

  @impl true
  def priority, do: 440

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:|>, meta, [lhs, rhs]} = node, acc ->
          if tab2list?(lhs) and enum_op?(rhs),
            do: {node, [build_issue(meta) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  # `:ets.tab2list(_)` parses with the `:ets` module as a bare atom.
  defp tab2list?({{:., _, [:ets, :tab2list]}, _, [_]}), do: true
  defp tab2list?(_), do: false

  # An Enum.X(...) call in pipe form has one fewer arg than the eager form
  # (the piped-in value becomes the first arg), so match any arity ≥ 1.
  defp enum_op?({{:., _, [{:__aliases__, _, [:Enum]}, fun]}, _, args})
       when is_atom(fun) and is_list(args) do
    MapSet.member?(@flagged_enum_funs, fun)
  end

  defp enum_op?(_), do: false

  defp build_issue(meta) do
    %Issue{
      rule: :ets_extract_then_enum,
      message:
        "`:ets.tab2list/1 |> Enum.*` snapshots the whole table into the " <>
          "caller's heap and walks it again to filter/map. ETS can do that " <>
          "in-place: use `:ets.select/2` (match-spec), `:ets.match/2`, or " <>
          "`:ets.foldl/3` to avoid the snapshot copy and stay consistent " <>
          "with concurrent writes.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
