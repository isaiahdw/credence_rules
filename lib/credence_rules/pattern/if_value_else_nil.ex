# credence-file:repeated_subtree_in_module — this module is an AST pattern
#   matcher whose check/2 + Macro.prewalk + build_issue shape is the Rule
#   contract itself, so the structural duplication is inherent to the form
#   rather than a smell
defmodule CredenceRules.Pattern.IfValueElseNil do
  @moduledoc """
  Shape rule: `if value, do: value, else: nil` (or `if value, do: value`,
  which is equivalent at the AST level after macro expansion) is almost
  always redundant. The bare expression already evaluates to the truthy
  value, or to `false` / `nil` — and if you specifically want `false` to
  become `nil`, `value || nil` is shorter.

  ## Bad

      result = if user, do: user, else: nil

      def maybe_name(user) do
        if user.name, do: user.name, else: nil
      end

  ## Good — drop the if

      result = user

      def maybe_name(user), do: user.name

  ## Good — be explicit about falsy → nil if you really need that

      result = user || nil
      result = if(user, do: user)

  ## Detection

  Fires when the condition expression and the `do`-clause expression
  are AST-equal (modulo metadata), and the `else` branch is `nil` or
  the `else` is omitted (which Elixir treats as implicit `nil`).

  Identity equality is conservative: side-effecting calls like
  `if foo(), do: foo()` would be flagged here even though the
  two invocations could differ. The intent of the LLM-flavoured
  pattern is the same — the reviewer can decide.
  """

  use CredenceRules.Rule

  @impl true
  def priority, do: 400

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn node, acc ->
        case match_if_value_else_nil(node) do
          {:ok, meta} -> {node, [build_issue(meta) | acc]}
          :error -> {node, acc}
        end
      end)

    Enum.reverse(issues)
  end

  # if cond, do: cond, else: nil
  defp match_if_value_else_nil({:if, meta, [cond_ast, [do: do_ast, else: nil]]}) do
    if strip(cond_ast) == strip(do_ast), do: {:ok, meta}, else: :error
  end

  # if cond, do: cond  (implicit else: nil)
  defp match_if_value_else_nil({:if, meta, [cond_ast, [do: do_ast]]}) do
    if strip(cond_ast) == strip(do_ast), do: {:ok, meta}, else: :error
  end

  # Block form: if cond do cond else nil end
  defp match_if_value_else_nil(
         {:if, meta,
          [
            cond_ast,
            [do: {:__block__, _, [do_body]}, else: {:__block__, _, [nil]}]
          ]}
       ) do
    if strip(cond_ast) == strip(do_body), do: {:ok, meta}, else: :error
  end

  # Block form, no else: if cond do cond end
  defp match_if_value_else_nil({:if, meta, [cond_ast, [do: {:__block__, _, [do_body]}]]}) do
    if strip(cond_ast) == strip(do_body), do: {:ok, meta}, else: :error
  end

  defp match_if_value_else_nil(_), do: :error

  defp strip(ast) do
    Macro.prewalk(ast, fn
      {form, _meta, args} -> {form, [], args}
      other -> other
    end)
  end

  defp build_issue(meta) do
    %Issue{
      rule: :if_value_else_nil,
      message:
        "`if value, do: value, else: nil` is redundant — the bare expression already " <>
          "evaluates to the value (or to `false`/`nil` if falsy). Drop the `if`, or use " <>
          "`value || nil` if you specifically want `false` to normalize to `nil`.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
