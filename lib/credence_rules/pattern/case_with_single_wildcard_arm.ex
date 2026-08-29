defmodule CredenceRules.Pattern.CaseWithSingleWildcardArm do
  @moduledoc """
  Idiomatic rule: a `case` with a single `_ -> body` arm is unconditional
  and should be `body` (with the subject expression evaluated for side
  effects if needed).

      case do_thing() do
        _ -> :ok
      end

  …does nothing except hide the fact that the author meant `do_thing(); :ok`.
  Usually this is dead code from a half-finished refactor — the author
  started writing patterns and only finished the wildcard. Either:

  - **Delete the case.** If `do_thing()` is meant to be a side effect,
    write `do_thing(); body`. If it isn't, delete the call.
  - **Add real arms.** Match on the actual return value.

  ## Detection

  Fires when `case e do _ -> body end` has exactly one arm whose pattern
  is the wildcard `_` (with no guard).

  Cases with one arm pinned to a value (`case e do :ok -> body end`) are
  NOT flagged — those at least encode an expectation, and the compiler
  / runtime will surface a `CaseClauseError` on mismatch.

  ## Bad

      case Repo.delete(record) do
        _ -> :ok
      end

  ## Good

      Repo.delete(record)
      :ok

      # Or, if you genuinely want to match:
      case Repo.delete(record) do
        {:ok, _} -> :ok
        {:error, changeset} -> handle_error(changeset)
      end
  """

  use CredenceRules.Rule

  @impl true
  def priority, do: 270

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:case, meta, [_subject, [{:do, arms}]]} = node, acc when is_list(arms) ->
          if single_wildcard_arm?(arms),
            do: {node, [build_issue(meta) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp single_wildcard_arm?([{:->, _, [[{:_, _, ctx}], _body]}]) when is_atom(ctx), do: true
  defp single_wildcard_arm?(_), do: false

  defp build_issue(meta) do
    %Issue{
      rule: :case_with_single_wildcard_arm,
      message:
        "`case expr do _ -> body end` is unconditional — the `case` is " <>
          "structurally dead. Replace with `expr; body` (or delete `expr` " <>
          "if it has no side effect), or add real arms that match on the " <>
          "actual return value.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
