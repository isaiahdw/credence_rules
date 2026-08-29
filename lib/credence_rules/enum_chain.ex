defmodule CredenceRules.EnumChain do
  @moduledoc """
  Shared detector for the "`Enum` producer feeding a wasteful consumer"
  rules (`sort_then_take_first`, `filter_then_count`,
  `filter_then_first`). Each is the same shape — a producing `Enum.*`
  call whose whole result is then collapsed by a consumer that a
  single-pass `Enum` function does directly.

  Handles both spellings:

  - piped — `enum |> Enum.filter(f) |> Enum.count()`
  - nested — `Enum.count(Enum.filter(enum, f))`, `length(Enum.filter(…))`
  """

  @doc """
  If `node` is `<Enum producer> |> <taker>` or `<taker>(<Enum
  producer>, …)`, returns `{:ok, line_meta}`; otherwise `:no`.

  `producer_funs` is the set of `Enum` function names that count as the
  producer (e.g. `[:filter]`, `[:sort, :sort_by]`). `taker_pred` is a
  predicate on the consumer call node (matched by function identity,
  ignoring arity — the piped form has one fewer argument).
  """
  @spec match(Macro.t(), [atom()], (Macro.t() -> boolean())) :: {:ok, keyword()} | :no
  def match({:|>, meta, [left, taker]}, producer_funs, taker_pred) do
    if taker_pred.(taker) and producer?(producing_value(left), producer_funs),
      do: {:ok, meta},
      else: :no
  end

  def match(node, producer_funs, taker_pred) do
    with true <- taker_pred.(node),
         {:ok, arg} <- first_arg(node),
         true <- producer?(arg, producer_funs) do
      {:ok, node_meta(node)}
    else
      _ -> :no
    end
  end

  @doc "True if `node` is `Enum.<fun>(…)` with `fun` in `funs`."
  @spec producer?(Macro.t(), [atom()]) :: boolean()
  def producer?({{:., _, [{:__aliases__, _, [:Enum]}, fun]}, _, args}, funs)
      when is_atom(fun) and is_list(args),
      do: fun in funs

  def producer?(_, _), do: false

  # The value flowing into the taker: for a piped left, that's its final
  # stage; otherwise the expression itself.
  defp producing_value({:|>, _, [_, right]}), do: right
  defp producing_value(node), do: node

  defp first_arg({{:., _, _}, _, [a | _]}), do: {:ok, a}
  defp first_arg({name, _, [a | _]}) when is_atom(name), do: {:ok, a}
  defp first_arg(_), do: :none

  defp node_meta({{:., _, _}, meta, _}), do: meta
  defp node_meta({_, meta, _}), do: meta
end
