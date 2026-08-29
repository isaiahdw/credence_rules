# credence-file:repeated_subtree_in_function — this module is an AST pattern
#   matcher whose check/2 + Macro.prewalk + build_issue shape is the Rule
#   contract itself, so the structural duplication is inherent to the form
#   rather than a smell
defmodule CredenceRules.Pattern.LengthListForEmptiness do
  @moduledoc """
  Performance rule: `length(list) == 0` (or any comparison against literal
  `0`) walks the entire list to compute a value that pattern matching
  answers in constant time.

  `length/1` is O(n) — Erlang lists are linked lists, not arrays. For
  "is this empty?" or "is this non-empty?" checks specifically:

  - `list == []` — O(1) emptiness check
  - `match?([_ | _], list)` — O(1) non-empty check (also a guard-safe form)
  - `[head | _] = list` — O(1) pattern match with binding

  This rule fires *only* on comparison-with-zero — `length(events) == 3`
  is genuinely asking for a cardinality and is fine.

  ## Bad

      if length(items) == 0, do: :empty
      if length(items) > 0, do: :has_items
      Enum.count(items) == 0     # same antipattern

  ## Good

      if items == [], do: :empty
      case items do
        [] -> :empty
        [_ | _] -> :has_items
      end
  """

  use CredenceRules.Rule

  @comparison_ops [:==, :!=, :>, :<, :>=, :<=]

  @impl true
  def priority, do: 320

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn node, acc ->
        case classify(node) do
          {:flag, fun_label} -> {node, [build_issue(node, fun_label) | acc]}
          :ok -> {node, acc}
        end
      end)

    Enum.reverse(issues)
  end

  defp classify({op, _meta, [lhs, rhs]}) when op in @comparison_ops do
    cond do
      counting_call?(lhs) and rhs == 0 -> {:flag, label(lhs)}
      counting_call?(rhs) and lhs == 0 -> {:flag, label(rhs)}
      true -> :ok
    end
  end

  defp classify(_), do: :ok

  # Kernel.length/1 — local call, no module prefix.
  defp counting_call?({:length, _, [_arg]}), do: true
  # Enum.count/1 — same antipattern, same fix.
  defp counting_call?({{:., _, [{:__aliases__, _, [:Enum]}, :count]}, _, [_arg]}), do: true
  defp counting_call?(_), do: false

  defp label({:length, _, _}), do: "length/1"
  defp label({{:., _, [{:__aliases__, _, [:Enum]}, :count]}, _, _}), do: "Enum.count/1"

  defp build_issue({op, meta, _args}, fun_label) do
    %Issue{
      rule: :length_list_for_emptiness,
      message:
        "`#{fun_label}(list) #{op} 0` walks the whole list to answer an " <>
          "O(1) question. Use `list == []` (or pattern-match on `[]` vs " <>
          "`[_ | _]`) for emptiness checks; reserve `#{fun_label}` for " <>
          "actual counts.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
