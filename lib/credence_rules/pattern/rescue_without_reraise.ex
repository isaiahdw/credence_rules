defmodule CredenceRules.Pattern.RescueWithoutReraise do
  @moduledoc """
  Safety rule: a `rescue` clause that calls `Logger.<level>` (or similar)
  but neither re-raises nor returns the exception is swallowing the
  failure. Callers see a generic atom and have no way to know the
  process tripped.

  The Java / Python instinct ("log it and continue") fits poorly in
  Elixir, where the supervisor would have restarted the process and
  recorded the crash with a full stacktrace for free.

  ## Bad

      try do
        do_work(input)
      rescue
        e ->
          Logger.error("Failed: \#{inspect(e)}")
          :error
      end

  ## Good — re-raise with the original stack

      try do
        do_work(input)
      rescue
        e ->
          Logger.error("Failed: \#{Exception.message(e)}")
          reraise e, __STACKTRACE__
      end

  ## Good — return the exception info

      try do
        do_work(input)
      rescue
        e in RuntimeError -> {:error, Exception.message(e)}
      end

  ## Detection

  Fires when **all** of these are true for a single `rescue` clause:

  - The clause binds the exception (`e ->` or `e in RuntimeError ->`,
    not `_ ->` — `rescue_catch_all` owns that).
  - The body calls `Logger.<anything>`.
  - The body never calls `reraise/2,3`.
  - The body's last expression is a "generic" return that doesn't
    reference the binding: `:error`, `nil`, or `{:error, literal}`.

  Companion: `CredenceRules.Pattern.RescueCatchAll` catches the
  unbound `rescue _ -> _` shape.

  Ported from
  [`ExSlop.Check.Warning.RescueWithoutReraise`](https://hex.pm/packages/ex_slop).
  """

  use CredenceRules.Rule

  alias CredenceRules.AstKeyword

  @impl true
  def priority, do: 700

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:try, _, [blocks]} = node, acc when is_list(blocks) ->
          rescue_clauses = AstKeyword.get(blocks, :rescue, [])
          {node, Enum.reduce(rescue_clauses, acc, &check_clause/2)}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp check_clause({:->, meta, [[pattern], body]}, acc) do
    case extract_binding(pattern) do
      {:ok, name} ->
        if has_logger_call?(body) and not has_reraise?(body) and returns_generic?(body, name),
          do: [build_issue(meta) | acc],
          else: acc

      :skip ->
        acc
    end
  end

  defp check_clause(_, acc), do: acc

  # `e in [SomeError]` or `e in SomeError` — bind to `name`.
  defp extract_binding({:in, _, [{name, _, ctx}, _]}) when is_atom(name) and is_atom(ctx) do
    if String.starts_with?(Atom.to_string(name), "_"), do: :skip, else: {:ok, name}
  end

  # Plain `e` binding.
  defp extract_binding({name, _, ctx}) when is_atom(name) and is_atom(ctx) do
    if String.starts_with?(Atom.to_string(name), "_"), do: :skip, else: {:ok, name}
  end

  defp extract_binding(_), do: :skip

  defp has_logger_call?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {{:., _, [{:__aliases__, _, [:Logger]}, _]}, _, _} = node, _ -> {node, true}
        node, found -> {node, found}
      end)

    found?
  end

  defp has_reraise?(ast) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {:reraise, _, _} = node, _ -> {node, true}
        node, found -> {node, found}
      end)

    found?
  end

  defp returns_generic?({:__block__, _, exprs}, name), do: generic_return?(List.last(exprs), name)
  defp returns_generic?(expr, name), do: generic_return?(expr, name)

  defp generic_return?(:error, _name), do: true
  defp generic_return?(nil, _name), do: true
  defp generic_return?({:__block__, _, [:error]}, _name), do: true
  defp generic_return?({:__block__, _, [nil]}, _name), do: true
  defp generic_return?({:error, expr} = node, name), do: not uses_binding?(node, name) and literal?(expr)
  defp generic_return?({:{}, _, [:error | _]} = node, name), do: not uses_binding?(node, name)
  defp generic_return?(_, _), do: false

  defp literal?(expr) when is_atom(expr) or is_binary(expr) or is_number(expr), do: true
  defp literal?(_), do: false

  defp uses_binding?(ast, name) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {^name, _, ctx} = node, _ when is_atom(ctx) -> {node, true}
        node, found -> {node, found}
      end)

    found?
  end

  defp build_issue(meta) do
    %Issue{
      rule: :rescue_without_reraise,
      message:
        "`rescue` logs the exception but returns a generic value that drops the failure " <>
          "information. Either `reraise e, __STACKTRACE__` (preserves the stack) or return " <>
          "`{:error, Exception.message(e)}` (preserves the reason).",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
