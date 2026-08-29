defmodule CredenceRules.Pattern.IdentityPassthrough do
  @moduledoc """
  Shape rule: a `case` whose every clause returns exactly what it
  matched is a no-op — just return the expression directly.

  LLMs ship these in two flavours: as nervous "preserve the tagged-tuple
  shape" boilerplate, or as half-finished branches where every arm was
  going to do something different and then ended up identical.

  ## Bad

      case do_something() do
        {:ok, value} -> {:ok, value}
        {:error, reason} -> {:error, reason}
      end

  ## Good

      do_something()

  Companion rules: `CredenceRules.Pattern.WithIdentityDo` and
  `CredenceRules.Pattern.WithIdentityElse` cover the equivalent
  `with` shapes.

  Ported from
  [`ExSlop.Check.Refactor.IdentityPassthrough`](https://hex.pm/packages/ex_slop).
  """

  use CredenceRules.Rule

  @impl true
  def priority, do: 450

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:case, meta, [_expr, [do: clauses]]} = node, acc when is_list(clauses) ->
          if match?([_, _ | _], clauses) and Enum.all?(clauses, &identity_clause?/1),
            do: {node, [build_issue(meta) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp identity_clause?({:->, _, [[pattern], body]}), do: strip(pattern) == strip(body)
  defp identity_clause?(_), do: false

  defp strip(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp build_issue(meta) do
    %Issue{
      rule: :identity_passthrough,
      message:
        "Identity `case` — every clause returns exactly what it matched. Drop the " <>
          "`case` and use the expression directly.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
