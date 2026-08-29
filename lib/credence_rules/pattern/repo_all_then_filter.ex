defmodule CredenceRules.Pattern.RepoAllThenFilter do
  @moduledoc """
  Performance / boundary rule: `Repo.all(query) |> Enum.filter(...)`
  loads every row from the database into the BEAM heap and then
  filters in-process. The predicate belongs in the query.

  Ecto's query builder is the predicate-pushdown boundary. Filtering
  in `Enum.filter` after `Repo.all` means:

  - **Wire transfer is unbounded** — even rows you'll immediately
    discard travel from PostgreSQL/MySQL to BEAM.
  - **No index usage** — Postgres can't use a btree on the
    predicate the filter encodes because it never sees that
    predicate.
  - **Memory grows with table size** — the in-memory list is
    proportional to the *unfiltered* row count.

  The Ecto API is built around this: `from p in Post, where: ...`
  composes with `Repo.all/1` so the WHERE goes to the DB.

  ## Bad

      users = Repo.all(User)
      active_users = Enum.filter(users, & &1.active)

      # Pipe form is the same:
      User |> Repo.all() |> Enum.filter(&Map.get(&1, :active))

  ## Good

      import Ecto.Query

      active_users =
        from(u in User, where: u.active == true)
        |> Repo.all()

  ## Detection

  Flags `|>` pipes whose LHS is `Repo.all(_)` and whose RHS is one of
  `Enum.filter`, `Enum.reject`, `Enum.find`, `Enum.any?`, `Enum.all?`,
  `Enum.count` (with predicate), or `Enum.partition`. These are all
  predicate-pushdown candidates.

  Currently misses the multi-statement form
  `xs = Repo.all(Q); Enum.filter(xs, ...)` — that would require
  dataflow analysis. Inline the pipe to surface the smell.
  """

  use CredenceRules.Rule

  @flagged_enum_funs MapSet.new(~w(filter reject find any? all? count partition)a)

  @impl true
  def priority, do: 460

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:|>, meta, [lhs, rhs]} = node, acc ->
          if repo_all?(lhs) and pushdownable_enum?(rhs),
            do: {node, [build_issue(meta) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp repo_all?({{:., _, [{:__aliases__, _, [:Repo]}, :all]}, _, _}), do: true
  defp repo_all?({{:., _, [{:__aliases__, _, [_, :Repo]}, :all]}, _, _}), do: true
  defp repo_all?({{:., _, [{:__aliases__, _, [_, _, :Repo]}, :all]}, _, _}), do: true
  defp repo_all?(_), do: false

  defp pushdownable_enum?({{:., _, [{:__aliases__, _, [:Enum]}, fun]}, _, _})
       when is_atom(fun) do
    MapSet.member?(@flagged_enum_funs, fun)
  end

  defp pushdownable_enum?(_), do: false

  defp build_issue(meta) do
    %Issue{
      rule: :repo_all_then_filter,
      message:
        "`Repo.all/1 |> Enum.filter/reject/find/...` pulls every row into " <>
          "the BEAM heap before filtering. Push the predicate into the " <>
          "query via `from r in Q, where: ...` so the DB does the work and " <>
          "indexes apply.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
