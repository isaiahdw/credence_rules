defmodule CredenceRules.Pattern.FlatMapFilter do
  @moduledoc """
  Shape rule: `Enum.flat_map(fn x -> if cond, do: [x], else: [] end)` is
  `Enum.filter/2` wearing a costume.

  ## Bad

      list |> Enum.flat_map(fn x -> if active?(x), do: [x], else: [] end)

  ## Good

      list |> Enum.filter(&active?/1)

  ## Not flagged — filter-then-map (transformation in the kept branch)

  Only the *identity* singleton fires. If the kept branch transforms the
  input — even when wrapped as a one-elem_astent list — the canonical
  refactor is `Enum.filter/2 |> Enum.map/2` or a `for` comprehension,
  not bare `Enum.filter/2`. Those shapes are out of scope for this rule.

      Enum.flat_map(list, fn x -> if keep?(x), do: [transform(x)], else: [] end)
      Enum.flat_map(state.services, fn {instance, svc} ->
        if match?(svc), do: [build(instance)], else: []
      end)

  Ported from
  [`ExSlop.Check.Refactor.FlatMapFilter`](https://hex.pm/packages/ex_slop).
  """

  use CredenceRules.Rule

  @impl true
  def priority, do: 450

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn node, acc ->
        case extract_flat_map(node) do
          {:ok, meta, fun} ->
            if filter_via_flat_map?(fun),
              do: {node, [build_issue(meta) | acc]},
              else: {node, acc}

          :error ->
            {node, acc}
        end
      end)

    Enum.reverse(issues)
  end

  # Enum.flat_map(list, fn x -> ... end)
  defp extract_flat_map({{:., meta, [{:__aliases__, _, [:Enum]}, :flat_map]}, _, [_list, fun]}),
    do: {:ok, meta, fun}

  # list |> Enum.flat_map(fn x -> ... end)
  defp extract_flat_map({:|>, meta, [_, {{:., _, [{:__aliases__, _, [:Enum]}, :flat_map]}, _, [fun]}]}),
    do: {:ok, meta, fun}

  defp extract_flat_map(_), do: :error

  defp filter_via_flat_map?({:fn, _, [{:->, _, [[arg], body]}]}),
    do: singleton_list_pattern?(body, arg)

  defp filter_via_flat_map?(_), do: false

  # `if cond, do: [elem_ast], else: []` is filter-only iff `elem_ast` is the lambda's
  # input pattern verbatim. If `elem_ast` transforms the input — even when wrapped
  # as a singleton — the call is filter+map, not filter.
  defp singleton_list_pattern?({:if, _, [_, [do: [elem_ast], else: []]]}, arg),
    do: same_pattern?(elem_ast, arg)

  defp singleton_list_pattern?({:if, _, [_, [do: [], else: [elem_ast]]]}, arg),
    do: same_pattern?(elem_ast, arg)

  # Block form: `if cond do [elem_ast] else [] end`.
  defp singleton_list_pattern?(
         {:if, _, [_, [do: {:__block__, _, [[elem_ast]]}, else: {:__block__, _, [[]]}]]},
         arg
       ),
       do: same_pattern?(elem_ast, arg)

  defp singleton_list_pattern?(
         {:if, _, [_, [do: {:__block__, _, [[]]}, else: {:__block__, _, [[elem_ast]]}]]},
         arg
       ),
       do: same_pattern?(elem_ast, arg)

  defp singleton_list_pattern?(_, _), do: false

  # Structural equality ignoring metadata — same approach as IdentityPassthrough.
  defp same_pattern?(a, b), do: strip(a) == strip(b)

  defp strip(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp build_issue(meta) do
    %Issue{
      rule: :flat_map_filter,
      message:
        "`Enum.flat_map(fn x -> if cond, do: [x], else: [] end)` is `Enum.filter/2`. " <>
          "Use `Enum.filter(list, &predicate/1)` directly.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
