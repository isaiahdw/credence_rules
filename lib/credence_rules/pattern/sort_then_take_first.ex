defmodule CredenceRules.Pattern.SortThenTakeFirst do
  @moduledoc """
  Performance rule: sorting a collection just to grab one end of it is
  `O(n log n)` to answer an `O(n)` question.

  `Enum.sort(x) |> hd()` (or `List.first/last`) sorts the whole
  collection, then throws all but one element away. `Enum.min/max` (and
  `min_by/max_by`) find that element in a single linear pass.

  ## Bad

      Enum.sort(scores) |> hd()                 # smallest
      List.last(Enum.sort(scores))              # largest
      players |> Enum.sort_by(& &1.age) |> hd() # youngest

  ## Good

      Enum.min(scores)
      Enum.max(scores)
      Enum.min_by(players, & &1.age)

  ## Detection

  Flags `hd`, `List.first`, or `List.last` applied (piped or nested) to
  an `Enum.sort` / `Enum.sort_by` call. Use `min`/`max` for `sort`,
  `min_by`/`max_by` for `sort_by`; the direction (`min` vs `max`)
  depends on the sort order and which end you take.

  ## Why advisory

  For tiny collections the difference is negligible, and if you need
  the element *plus* the sorted remainder you do want the sort.
  Reviewer call.
  """

  use CredenceRules.Rule

  alias CredenceRules.EnumChain

  @severity :low
  @confidence :medium

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn node, acc ->
        case EnumChain.match(node, [:sort, :sort_by], &take_one?/1) do
          {:ok, meta} -> {node, [build_issue(meta) | acc]}
          :no -> {node, acc}
        end
      end)

    Enum.sort_by(issues, & &1.meta.line)
  end

  defp take_one?({:hd, _, _}), do: true
  defp take_one?({{:., _, [{:__aliases__, _, [:List]}, fun]}, _, _}) when fun in [:first, :last], do: true
  defp take_one?(_), do: false

  defp build_issue(meta) do
    %Issue{
      rule: :sort_then_take_first,
      message:
        "Sorting just to take one element is O(n log n) for an O(n) answer. " <>
          "Use `Enum.min/max` (or `Enum.min_by/max_by` for the `sort_by` form) " <>
          "to find the extreme in a single pass instead of `Enum.sort(...) |> " <>
          "hd()` / `List.first`/`List.last`.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
