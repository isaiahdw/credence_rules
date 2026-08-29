# credence-file:repeated_subtree_in_module — this module is an AST pattern
#   matcher whose check/2 + Macro.prewalk + build_issue shape is the Rule
#   contract itself, so the structural duplication is inherent to the form
#   rather than a smell
defmodule CredenceRules.Pattern.NilPredicateLambda do
  @moduledoc """
  Refactor rule: `Enum.filter` / `Enum.reject` whose lambda just checks
  `x == nil` / `x != nil` / `is_nil(x)` should use the `is_nil/1` guard
  capture directly.

  ## Bad

      Enum.filter(list, fn x -> x != nil end)
      Enum.reject(list, fn x -> x == nil end)
      Enum.filter(list, fn x -> not is_nil(x) end)

  ## Good

      Enum.reject(list, &is_nil/1)

  (Or `Enum.filter(list, &(not is_nil(&1)))` if you need the keep-non-nil
  framing — but `Enum.reject(&is_nil/1)` reads more naturally and is
  the idiomatic shape.)

  Merges ex_slop's separate `FilterNil` and `RejectNil` checks; the fix
  is the same in both cases.

  Ported from
  [`ExSlop.Check.Refactor.FilterNil`](https://hex.pm/packages/ex_slop)
  and `ExSlop.Check.Refactor.RejectNil`.
  """

  use CredenceRules.Rule

  @impl true
  def priority, do: 400

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn node, acc ->
        case match_nil_predicate(node) do
          {:ok, meta, op} -> {node, [build_issue(meta, op) | acc]}
          :error -> {node, acc}
        end
      end)

    Enum.reverse(issues)
  end

  # Enum.filter(list, fn x -> <nil-keep predicate> end)
  defp match_nil_predicate(
         {{:., meta, [{:__aliases__, _, [:Enum]}, op]}, _,
          [_enumerable, {:fn, _, [{:->, _, [[{var, _, _}], body]}]}]}
       )
       when op in [:filter, :reject] and is_atom(var) do
    if predicate_matches?(body, var, op), do: {:ok, meta, op}, else: :error
  end

  # list |> Enum.filter(fn x -> ... end)
  defp match_nil_predicate(
         {:|>, meta,
          [
            _,
            {{:., _, [{:__aliases__, _, [:Enum]}, op]}, _, [{:fn, _, [{:->, _, [[{var, _, _}], body]}]}]}
          ]}
       )
       when op in [:filter, :reject] and is_atom(var) do
    if predicate_matches?(body, var, op), do: {:ok, meta, op}, else: :error
  end

  defp match_nil_predicate(_), do: :error

  # For Enum.filter, the keep-condition has to mean "not nil"
  defp predicate_matches?(body, var, :filter), do: keep_non_nil?(body, var)
  # For Enum.reject, the reject-condition has to mean "is nil"
  defp predicate_matches?(body, var, :reject), do: nil_check?(body, var)

  # x != nil, x !== nil
  defp keep_non_nil?({op, _, [{var, _, _}, nil]}, var) when op in [:!=, :!==], do: true
  # nil != x
  defp keep_non_nil?({op, _, [nil, {var, _, _}]}, var) when op in [:!=, :!==], do: true
  # not is_nil(x), !is_nil(x)
  defp keep_non_nil?({:not, _, [{:is_nil, _, [{var, _, _}]}]}, var), do: true
  defp keep_non_nil?({:!, _, [{:is_nil, _, [{var, _, _}]}]}, var), do: true
  defp keep_non_nil?(_, _), do: false

  # x == nil, x === nil
  defp nil_check?({op, _, [{var, _, _}, nil]}, var) when op in [:==, :===], do: true
  # nil == x
  defp nil_check?({op, _, [nil, {var, _, _}]}, var) when op in [:==, :===], do: true
  # is_nil(x)
  defp nil_check?({:is_nil, _, [{var, _, _}]}, var), do: true
  defp nil_check?(_, _), do: false

  defp build_issue(meta, :filter) do
    %Issue{
      rule: :nil_predicate_lambda,
      message:
        "`Enum.filter(list, fn x -> x != nil end)` reinvents `Enum.reject(&is_nil/1)`. " <>
          "Use the capture directly.",
      meta: %{line: Keyword.get(meta, :line), op: :filter}
    }
  end

  defp build_issue(meta, :reject) do
    %Issue{
      rule: :nil_predicate_lambda,
      message:
        "`Enum.reject(list, fn x -> x == nil end)` reinvents `Enum.reject(&is_nil/1)`. " <>
          "Use the capture directly.",
      meta: %{line: Keyword.get(meta, :line), op: :reject}
    }
  end
end
