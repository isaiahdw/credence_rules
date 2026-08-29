defmodule CredenceRules.Pattern.StringLengthForEmptiness do
  @moduledoc """
  Performance rule: `String.length(s) == 0` (or any comparison against
  literal `0`) walks the entire string to compute a value that
  `byte_size(s) == 0` answers in constant time.

  `String.length/1` is O(n) — it counts Unicode graphemes by walking the
  binary. For "is this empty?" comparisons specifically, this is wasted
  work; an empty binary is the only one with `byte_size 0`.

  This rule fires *only* on comparison-with-zero — `String.length(s) == 11`
  is genuinely asking for character count, not emptiness, and is fine.

  ## Bad

      if String.length(name) == 0, do: :error
      if String.length(name) > 0, do: :ok
      String.length(input) <= 0

  ## Good

      if name == "", do: :error
      if byte_size(name) > 0, do: :ok
      input != ""
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
          :flag -> {node, [build_issue(node) | acc]}
          :ok -> {node, acc}
        end
      end)

    Enum.reverse(issues)
  end

  # Match {op, _, [lhs, rhs]} where one side is `String.length(_)` and
  # the other is integer literal 0.
  defp classify({op, _meta, [lhs, rhs]}) when op in @comparison_ops do
    cond do
      string_length_call?(lhs) and rhs == 0 -> :flag
      string_length_call?(rhs) and lhs == 0 -> :flag
      true -> :ok
    end
  end

  defp classify(_), do: :ok

  defp string_length_call?({{:., _, [{:__aliases__, _, [:String]}, :length]}, _, [_arg]}), do: true
  defp string_length_call?(_), do: false

  defp build_issue({op, meta, _args}) do
    %Issue{
      rule: :string_length_for_emptiness,
      message:
        "`String.length(s) #{op} 0` walks the whole string to answer an " <>
          "O(1) question. Use `s == \"\"` (or `byte_size(s) #{op} 0`) for " <>
          "emptiness checks; reserve `String.length/1` for actual character " <>
          "counts.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
