# credence-file:cross_file_duplicate_block — this module is an AST pattern
#   matcher whose check/2 + Macro.prewalk + build_issue shape is the Rule
#   contract itself, so the structural duplication is inherent to the form
#   rather than a smell
defmodule CredenceRules.Pattern.FilterThenCount do
  @moduledoc """
  Performance rule: `Enum.filter/2` only to count the results builds an
  intermediate list you immediately discard. `Enum.count/2` counts the
  matches in a single pass with no allocation.

  ## Bad

      Enum.filter(users, & &1.active) |> Enum.count()
      length(Enum.filter(users, & &1.active))

  ## Good

      Enum.count(users, & &1.active)

  ## Detection

  Flags `Enum.count/1` or `length/1` (piped or nested) applied to an
  `Enum.filter/2` call. Use `Enum.count(enum, fun)`.
  """

  use CredenceRules.Rule

  alias CredenceRules.EnumChain

  @severity :low
  @confidence :medium

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn node, acc ->
        case EnumChain.match(node, [:filter], &counts?/1) do
          {:ok, meta} -> {node, [build_issue(meta) | acc]}
          :no -> {node, acc}
        end
      end)

    Enum.sort_by(issues, & &1.meta.line)
  end

  defp counts?({{:., _, [{:__aliases__, _, [:Enum]}, :count]}, _, _}), do: true
  defp counts?({:length, _, _}), do: true
  defp counts?(_), do: false

  defp build_issue(meta) do
    %Issue{
      rule: :filter_then_count,
      message:
        "Filtering just to count the results builds an intermediate list " <>
          "you throw away. Count the matches in one pass: " <>
          "`Enum.count(enum, fun)` instead of `Enum.filter(enum, fun) |> " <>
          "Enum.count()` / `length(Enum.filter(...))`.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
