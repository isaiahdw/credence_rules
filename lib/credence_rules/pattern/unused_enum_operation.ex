defmodule CredenceRules.Pattern.UnusedEnumOperation do
  @moduledoc """
  Correctness rule: an `Enum.map`/`Enum.filter`/`Enum.reduce`/etc. call
  whose return value is discarded is almost always a bug.

  Elixir collections are immutable. `Enum.map(list, fun)` does not
  modify `list` — it returns a *new* list, leaving the original
  untouched. So a statement like:

      def process(items) do
        Enum.map(items, &transform/1)    # result discarded
        :ok                              # return :ok
      end

  …does **nothing observable** unless `transform/1` itself has side
  effects, in which case `Enum.each/2` is the correct function.

  This pattern is one of the strongest signatures of an LLM trained
  primarily on mutable-language code: in Python `list.map(...)` or
  Ruby `list.map!`, the call mutates in place; in Elixir, the result
  is the point.

  ## Detection

  Within `:__block__` expressions (`def f do; expr1; expr2; …; last end`),
  every expression except the last has its value discarded. If any
  such "discarded" expression is a call to one of:

  `Enum.{map, filter, reject, reduce, flat_map, map_join, into,
  with_index, chunk_every, dedup, uniq, uniq_by, sort, sort_by,
  drop, take, drop_while, take_while, partition, group_by, zip,
  concat, count}` (or the `Map.{new, map, filter, reject, update}`
  / `Stream.{map, filter, …}` equivalents), the call is flagged.

  `Enum.each/2`, `Enum.reduce_while/3` returning `:halt`, and similar
  side-effect-oriented functions are NOT flagged.

  ## Bad

      def update_all(users) do
        Enum.map(users, fn user ->
          Repo.update!(user)          # this is a side effect, but…
        end)                          # …Enum.map's result is discarded
        :ok                           # …and we just return :ok regardless
      end

  ## Good

      def update_all(users) do
        Enum.each(users, &Repo.update!/1)   # explicit side-effect iteration
        :ok
      end

      # Or, return the mapped list:
      def update_all(users) do
        Enum.map(users, &Repo.update!/1)
      end
  """

  use CredenceRules.Rule

  @flagged_remotes %{
    Enum: ~w(map filter reject reduce flat_map map_join into with_index
             chunk_every dedup dedup_by uniq uniq_by sort sort_by drop
             take drop_while take_while partition group_by zip concat
             count split min max min_by max_by sum)a,
    Map: ~w(new map filter reject update)a,
    Stream: ~w(map filter reject flat_map with_index chunk_every dedup
               uniq drop take drop_while take_while zip concat)a,
    MapSet: ~w(new put delete union difference intersection filter)a,
    Keyword: ~w(new put delete merge update)a,
    List: ~w(flatten insert_at replace_at delete_at update_at zip)a
  }

  @impl true
  def priority, do: 460

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:__block__, _, [_, _ | _] = stmts} = node, acc ->
          # All but the last are statement-context; their values are discarded.
          to_check = stmts |> Enum.reverse() |> tl() |> Enum.reverse()
          {node, Enum.flat_map(to_check, &maybe_flag/1) ++ acc}

        node, acc ->
          {node, acc}
      end)

    issues
    |> Enum.uniq_by(& &1.meta.line)
    |> Enum.sort_by(& &1.meta.line)
  end

  defp maybe_flag({{:., _, [{:__aliases__, _, [mod]}, fun]}, meta, _args} = _node)
       when is_atom(mod) and is_atom(fun) do
    case Map.get(@flagged_remotes, mod) do
      nil -> []
      funs -> if fun in funs, do: [build_issue(meta, mod, fun)], else: []
    end
  end

  defp maybe_flag(_), do: []

  defp build_issue(meta, mod, fun) do
    suggestion =
      cond do
        mod == :Enum and fun == :map ->
          "`Enum.each/2` if you only want side effects, or use the returned list"

        mod in [:Enum, :Stream] ->
          "`Enum.each/2` if you only want side effects"

        true ->
          "use the returned value, or replace with a side-effect-only call"
      end

    %Issue{
      rule: :unused_enum_operation,
      message:
        "`#{mod}.#{fun}/_` is being called but its result is discarded — " <>
          "Elixir collections are immutable, so this call does nothing " <>
          "unless the inner function has side effects. #{suggestion}.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
