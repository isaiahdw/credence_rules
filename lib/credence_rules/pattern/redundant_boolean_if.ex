defmodule CredenceRules.Pattern.RedundantBooleanIf do
  @moduledoc """
  Shape rule: `if cond, do: true, else: false` (or the negated
  `do: false, else: true`) is wrapping a condition that already is a
  boolean. Use the condition directly.

  ## Bad

      is_active = if status == :active, do: true, else: false

      negated = if !is_nil(x), do: false, else: true

  ## Good

      is_active = status == :active

      negated = is_nil(x)

  Ported from
  [`ExSlop.Check.Refactor.RedundantBooleanIf`](https://hex.pm/packages/ex_slop).
  """

  use CredenceRules.Rule

  @impl true
  def priority, do: 500

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn node, acc ->
        case match_redundant_boolean_if(node) do
          {:ok, meta} -> {node, [build_issue(meta) | acc]}
          :error -> {node, acc}
        end
      end)

    Enum.reverse(issues)
  end

  # `if cond, do: true, else: false` (keyword form)
  defp match_redundant_boolean_if({:if, meta, [_cond, [do: true, else: false]]}), do: {:ok, meta}
  defp match_redundant_boolean_if({:if, meta, [_cond, [do: false, else: true]]}), do: {:ok, meta}

  # `if cond do true else false end` (block form)
  defp match_redundant_boolean_if(
         {:if, meta, [_cond, [do: {:__block__, _, [true]}, else: {:__block__, _, [false]}]]}
       ),
       do: {:ok, meta}

  defp match_redundant_boolean_if(
         {:if, meta, [_cond, [do: {:__block__, _, [false]}, else: {:__block__, _, [true]}]]}
       ),
       do: {:ok, meta}

  defp match_redundant_boolean_if(_), do: :error

  defp build_issue(meta) do
    %Issue{
      rule: :redundant_boolean_if,
      message:
        "`if cond, do: true, else: false` is redundant — the condition already evaluates " <>
          "to a boolean. Use the expression directly (or negate it with `not` / `!`).",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
