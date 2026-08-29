defmodule CredenceRules.Pattern.EnumEachAssigned do
  @moduledoc """
  Shape rule: `Enum.each/2` always returns `:ok`. Assigning its return
  value to a binding is a sign of confusion — the author thought `each`
  built a collection. They wanted `Enum.map/2`, `Enum.reduce/3`, or to
  drop the binding entirely.

  ## Bad

      result = Enum.each(users, &deliver/1)
      processed = users |> Enum.each(&deliver/1)
      _ignored = Enum.each(users, &deliver/1)

  ## Good — drop the binding entirely

      Enum.each(users, &deliver/1)

  ## Good — `Enum.map` if you want the results

      results = Enum.map(users, &deliver/1)

  Detecting the `_var = ...` form too because LLMs sometimes write that
  when they want to "discard the result" — but the discard is the
  default, and the named-underscore is misleading: it implies a value
  worth ignoring, when in fact `:ok` is the only thing being ignored.
  """

  use CredenceRules.Rule

  @impl true
  def priority, do: 400

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn node, acc ->
        case match_each_assigned(node) do
          {:ok, meta} -> {node, [build_issue(meta) | acc]}
          :error -> {node, acc}
        end
      end)

    Enum.reverse(issues)
  end

  # _var = Enum.each(...)
  defp match_each_assigned({:=, _, [_lhs, rhs]}) do
    case extract_each_call(rhs) do
      {:ok, meta} -> {:ok, meta}
      :error -> :error
    end
  end

  defp match_each_assigned(_), do: :error

  # Enum.each(list, fun) — direct two-arg call.
  defp extract_each_call({{:., meta, [{:__aliases__, _, [:Enum]}, :each]}, _, [_, _]}),
    do: {:ok, meta}

  # list |> Enum.each(fun) — the assignment captures the pipe's value.
  defp extract_each_call({:|>, _, [_, rhs]}), do: extract_each_call(rhs)

  # Enum.each(fun) at the tail of a pipe — the LHS becomes the first
  # arg after macro expansion, so in the unexpanded AST the inner call
  # carries only one literal argument.
  defp extract_each_call({{:., meta, [{:__aliases__, _, [:Enum]}, :each]}, _, [_]}),
    do: {:ok, meta}

  defp extract_each_call(_), do: :error

  defp build_issue(meta) do
    %Issue{
      rule: :enum_each_assigned,
      message:
        "`Enum.each/2` always returns `:ok` — assigning its result is a sign you wanted " <>
          "`Enum.map/2` (collect the results), `Enum.reduce/3` (fold), or to drop the " <>
          "binding entirely.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
