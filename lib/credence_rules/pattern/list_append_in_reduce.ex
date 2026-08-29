defmodule CredenceRules.Pattern.ListAppendInReduce do
  @moduledoc """
  Performance rule: `acc ++ [x]` inside `Enum.reduce` is quadratic.

  `a ++ b` copies the **left** list. So appending to a growing
  accumulator — `acc ++ [x]` — copies the whole accumulator every
  iteration, making the reduce `O(n²)` in the list length. The list
  analog of `string_concat_in_reduce`, and a classic imperative tell
  (`list.append(x)`).

  ## Bad

      Enum.reduce(items, [], fn item, acc -> acc ++ [transform(item)] end)
      # Each iteration copies `acc`; O(n²) total.

  ## Good — prepend, then reverse once

      items
      |> Enum.reduce([], fn item, acc -> [transform(item) | acc] end)
      |> Enum.reverse()

  Prepending (`[x | acc]`) is `O(1)`; the single `Enum.reverse/1` at
  the end is `O(n)`. Often the reduce is itself unnecessary — a plain
  `Enum.map/2` (see `reduce_as_map`) is clearer still.

  ## Detection

  Flags `Enum.reduce(_, _, fn _, acc -> body end)` (and
  `Enum.reduce_while`) where the body uses `acc ++ _` with the
  accumulator on the **left** of `++`. Only the left position is
  flagged: `[x] ++ acc` copies the small literal, not the accumulator,
  so it isn't quadratic.

  Recursion that builds a list with `acc ++ [x]` has the same problem
  but isn't detected here — this rule scopes to the `Enum.reduce`
  shape for precision.
  """

  use CredenceRules.Rule

  @reduce_funs MapSet.new([:reduce, :reduce_while])

  @impl true
  def priority, do: 350

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:Enum]}, fun]}, meta, args} = node, acc
        when is_atom(fun) and is_list(args) ->
          if MapSet.member?(@reduce_funs, fun) and reduce_fn_appends?(args),
            do: {node, [build_issue(meta) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    issues
    |> Enum.uniq_by(& &1.meta.line)
    |> Enum.sort_by(& &1.meta.line)
  end

  defp reduce_fn_appends?(args) do
    Enum.any?(args, &lambda_appends_accumulator?/1)
  end

  defp lambda_appends_accumulator?({:fn, _, [{:->, _, [[_item, {acc_name, _, ctx}], body]}]})
       when is_atom(acc_name) and is_atom(ctx) do
    body_appends_to?(body, acc_name)
  end

  defp lambda_appends_accumulator?(_), do: false

  # `acc ++ _` with the accumulator on the LEFT — the quadratic case.
  defp body_appends_to?(body, acc_name) do
    {_ast, found?} =
      Macro.prewalk(body, false, fn
        _node, true -> {[], true}
        {:++, _, [lhs, _rhs]} = node, _ -> {node, var_matches?(lhs, acc_name)}
        node, acc -> {node, acc}
      end)

    found?
  end

  defp var_matches?({name, _, ctx}, name) when is_atom(name) and is_atom(ctx), do: true
  defp var_matches?(_, _), do: false

  defp build_issue(meta) do
    %Issue{
      rule: :list_append_in_reduce,
      message:
        "`acc ++ _` inside `Enum.reduce` is O(n²) — `++` copies its left " <>
          "operand, so appending to the growing accumulator copies it every " <>
          "iteration. Prepend instead and reverse once: " <>
          "`Enum.reduce(enum, [], fn x, acc -> [x | acc] end) |> Enum.reverse()` " <>
          "(or use `Enum.map/2` if the reduce is only building a list).",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
