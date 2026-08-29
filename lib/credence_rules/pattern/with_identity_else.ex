defmodule CredenceRules.Pattern.WithIdentityElse do
  @moduledoc """
  Shape rule: a `with` whose `else` clauses all return exactly what they
  matched is doing nothing — drop the `else`.

  When every `else` arm has the form `pattern -> pattern`, the block is
  preserving the failure shape that `with` already preserves for free.

  ## Bad

      with {:ok, result} <- do_something() do
        format(result)
      else
        {:error, reason} -> {:error, reason}
      end

  ## Good

      with {:ok, result} <- do_something() do
        format(result)
      end

  Companion: `CredenceRules.Pattern.WithIdentityDo` catches the
  no-else identity case.

  Ported from
  [`ExSlop.Check.Refactor.WithIdentityElse`](https://hex.pm/packages/ex_slop).
  """

  use CredenceRules.Rule

  alias CredenceRules.AstKeyword

  @impl true
  def priority, do: 450

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:with, meta, args} = node, acc when is_list(args) ->
          if identity_else?(args),
            do: {node, [build_issue(meta) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp identity_else?(args) do
    case last_arg(args) do
      kw when is_list(kw) ->
        case AstKeyword.get(kw, :else) do
          clauses when is_list(clauses) and clauses != [] ->
            Enum.all?(clauses, &identity_clause?/1)

          _ ->
            false
        end

      _ ->
        false
    end
  end

  defp last_arg([arg]), do: arg
  defp last_arg([_ | rest]), do: last_arg(rest)
  defp last_arg([]), do: nil

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
      rule: :with_identity_else,
      message:
        "Identity `else` in `with` — every clause returns exactly what it matched. " <>
          "Drop the `else` block; `with` already passes failure shapes through.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
