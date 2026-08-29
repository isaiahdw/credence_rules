defmodule CredenceRules.Pattern.QueryInEnumMap do
  @moduledoc """
  Performance / boundary rule: a `Repo.<fun>` call inside an
  `Enum.map`/`Enum.each`/`Enum.flat_map`/etc. lambda is the
  canonical N+1 query pattern.

  Issuing one query per list element scales linearly with N: 100
  users → 100 round trips → 100× the latency, ~10× the DB load,
  potential connection-pool exhaustion under concurrency.

  The Ecto idioms that avoid this:

  - **`Repo.preload/3`** — preload an association in one query
    instead of one-per-parent.
  - **`Repo.all(query)` with `where: x.id in ^ids`** — batch the
    lookups into a single IN query.
  - **`Repo.insert_all/3` / `Repo.update_all/3`** — bulk writes in
    one round trip.

  ## Bad

      Enum.map(user_ids, fn id -> Repo.get(User, id) end)
      # → N queries

      Enum.each(orders, fn o ->
        Repo.update(o |> Order.changeset(%{status: :paid}))
      end)
      # → N writes

  ## Good

      Repo.all(from u in User, where: u.id in ^user_ids)
      # → 1 query

      Repo.update_all(from o in Order, where: o.id in ^ids,
                      update: [set: [status: :paid]])
      # → 1 write

  ## Detection

  Flags `Enum.{map, each, flat_map, filter, reject, find, count,
  reduce, partition, group_by}` calls whose lambda body contains any
  `Repo.<fun>(_)` call (or `MyApp.Repo.<fun>` — any module ending
  in `.Repo`).

  Captured-form lambdas (`Enum.map(ids, &Repo.get(User, &1))`) are
  also flagged.

  This rule is a tripwire on Ecto-less projects. Worth keeping for
  cross-project portability: if the codebase ever adopts Ecto, the
  rule will catch the first N+1 introduced.
  """

  use CredenceRules.Rule

  @flagged_enum_funs MapSet.new(~w(map each flat_map filter reject find count reduce
                          partition group_by any? all? count_by min_by max_by)a)

  @impl true
  def priority, do: 480

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        # Eager form: Enum.map(enum, fn -> ... end) / Enum.map(enum, &captured)
        {{:., _, [{:__aliases__, _, [:Enum]}, fun]}, meta, args} = node, acc
        when is_atom(fun) and is_list(args) ->
          if MapSet.member?(@flagged_enum_funs, fun) and any_arg_contains_repo_call?(args),
            do: {node, [build_issue(meta, fun) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    issues
    |> Enum.uniq_by(& &1.meta.line)
    |> Enum.sort_by(& &1.meta.line)
  end

  defp any_arg_contains_repo_call?(args) when is_list(args) do
    Enum.any?(args, &contains_repo_call?/1)
  end

  defp contains_repo_call?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        _node, true ->
          {[], true}

        # `Repo.fun(...)` or `MyApp.Repo.fun(...)` — match any alias path
        # whose last segment is `:Repo`.
        {{:., _, [{:__aliases__, _, parts}, _fun]}, _, _} = node, _
        when is_list(parts) ->
          if List.last(parts) == :Repo,
            do: {node, true},
            else: {node, false}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp build_issue(meta, fun) do
    %Issue{
      rule: :query_in_enum_map,
      message:
        "`Enum.#{fun}` lambda calls `Repo.<fun>` — N+1 query pattern. One " <>
          "DB round trip per element. Batch via `Repo.all(from x in Q, " <>
          "where: x.id in ^ids)` for reads, `Repo.preload/3` for " <>
          "associations, or `Repo.{insert,update,delete}_all/3` for writes.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
