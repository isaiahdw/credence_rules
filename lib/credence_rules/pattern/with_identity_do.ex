defmodule CredenceRules.Pattern.WithIdentityDo do
  @moduledoc """
  Shape rule: a `with` whose `do` block just returns the value the
  final `<-` matched is ceremony around a function call.

  ## Bad

      with {:ok, result} <- do_something() do
        {:ok, result}
      end

  ## Good

      do_something()

  This rule fires only when there's a single `<-` clause and no `else`
  block. The else-block case is handled by
  `CredenceRules.Pattern.WithIdentityElse`.

  Ported from
  [`ExSlop.Check.Refactor.WithIdentityDo`](https://hex.pm/packages/ex_slop).
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
          if identity_with_do?(args),
            do: {node, [build_issue(meta) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp identity_with_do?(args) do
    arrows = Enum.filter(args, &match?({:<-, _, _}, &1))

    with [{:<-, _, [pattern, _expr]}] <- arrows,
         kw when is_list(kw) <- last_arg(args),
         false <- AstKeyword.has_key?(kw, :else),
         do_body when not is_nil(do_body) <- AstKeyword.get(kw, :do) do
      strip(pattern) == strip(do_body)
    else
      _ -> false
    end
  end

  defp last_arg([arg]), do: arg
  defp last_arg([_ | rest]), do: last_arg(rest)
  defp last_arg([]), do: nil

  defp strip(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp build_issue(meta) do
    %Issue{
      rule: :with_identity_do,
      message:
        "Identity `with` — the `do` block returns exactly what the `<-` matched. " <>
          "Drop the `with` and use the expression directly.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
