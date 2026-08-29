defmodule CredenceRules.Pattern.AnonymousFnCaptureWrap do
  @moduledoc """
  Style rule: a single-arg anonymous function that does nothing but pass
  its argument through to another function should use capture syntax.

  ## Bad

      Enum.map(list, fn x -> String.trim(x) end)
      Enum.filter(list, fn x -> active?(x) end)
      Enum.each(list, fn x -> handle(x) end)

  ## Good

      Enum.map(list, &String.trim/1)
      Enum.filter(list, &active?/1)
      Enum.each(list, &handle/1)

  ## Detection

  Fires when the lambda has the shape:

      fn arg -> call(arg) end

  where `arg` is a single bound variable and `call(arg)` is a function
  call (local `foo(x)` or remote `Mod.foo(x)`) whose only argument is
  that same variable. Multi-arg lambdas, lambdas whose body has extra
  args (`fn x -> foo(x, y) end`) or extra expressions, and lambdas that
  capture-wrap operators / kernel macros are not flagged.

  Capture syntax is `&Mod.foo/1` or `&foo/1` — readable, shows the
  arity, and avoids constructing a new closure at runtime.
  """

  use CredenceRules.Rule

  # Names a single-arg lambda whose body is `target(arg)` should NOT
  # be rewritten as `&target/1` — Kernel ops / macros mostly. (Most
  # would not parse as a call shape anyway, but `not` / `apply` do.)
  @disallowed_targets MapSet.new([:apply, :not, :unquote, :unquote_splicing])

  @impl true
  def priority, do: 350

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn node, acc ->
        case match_passthrough_lambda(node) do
          {:ok, meta, name} -> {node, [build_issue(meta, name) | acc]}
          :error -> {node, acc}
        end
      end)

    Enum.reverse(issues)
  end

  # fn arg -> local_fun(arg) end
  defp match_passthrough_lambda({:fn, _, [{:->, meta, [[{arg, _, ctx}], {fun, _, [{arg, _, ctx2}]}]}]})
       when is_atom(arg) and is_atom(ctx) and is_atom(ctx2) and is_atom(fun) do
    if fun in @disallowed_targets,
      do: :error,
      else: {:ok, meta, Atom.to_string(fun) <> "/1"}
  end

  # fn arg -> Mod.fun(arg) end
  defp match_passthrough_lambda({:fn, _, [{:->, meta, [[{arg, _, ctx}], call]}]})
       when is_atom(arg) and is_atom(ctx) do
    case call do
      {{:., _, [{:__aliases__, _, mod_parts}, fun]}, _, [{^arg, _, _}]}
      when is_atom(fun) ->
        {:ok, meta, "#{Enum.map_join(mod_parts, ".", &Atom.to_string/1)}.#{fun}/1"}

      _ ->
        :error
    end
  end

  defp match_passthrough_lambda(_), do: :error

  defp build_issue(meta, name) do
    %Issue{
      rule: :anonymous_fn_capture_wrap,
      message:
        "Single-arg lambda just forwards its argument — use capture syntax `&#{name}` " <>
          "instead. Shorter, shows the arity, no new closure at runtime.",
      meta: %{line: Keyword.get(meta, :line), target: name}
    }
  end
end
