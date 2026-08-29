defmodule CredenceRules.Pattern.FilterThenFirst do
  @moduledoc """
  Performance rule: `Enum.filter/2` only to take the first match scans
  the **whole** collection and builds the full result list, then keeps
  one element. `Enum.find/2` stops at the first match.

  ## Bad

      Enum.filter(users, & &1.admin?) |> List.first()
      hd(Enum.filter(users, & &1.admin?))

  ## Good

      Enum.find(users, & &1.admin?)

  ## Detection

  Flags `List.first/1` or `hd/1` (piped or nested) applied to an
  `Enum.filter/2` call. Use `Enum.find(enum, fun)`.

  ## Note on semantics

  `Enum.find/2` and `List.first(Enum.filter(...))` both return `nil`
  when nothing matches. `hd(Enum.filter(...))` instead **raises** on no
  match — if you were relying on that, `Enum.find/2` won't reproduce
  it (use a pattern match or `Enum.find/3` with a raising default).
  """

  use CredenceRules.Rule

  alias CredenceRules.EnumChain

  @severity :low
  @confidence :medium

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn node, acc ->
        case EnumChain.match(node, [:filter], &takes_first?/1) do
          {:ok, meta} -> {node, [build_issue(meta) | acc]}
          :no -> {node, acc}
        end
      end)

    Enum.sort_by(issues, & &1.meta.line)
  end

  defp takes_first?({:hd, _, _}), do: true
  defp takes_first?({{:., _, [{:__aliases__, _, [:List]}, :first]}, _, _}), do: true
  defp takes_first?(_), do: false

  defp build_issue(meta) do
    %Issue{
      rule: :filter_then_first,
      message:
        "Filtering just to take the first match scans the whole collection " <>
          "and builds the full result list. Use `Enum.find(enum, fun)`, which " <>
          "stops at the first match, instead of `Enum.filter(enum, fun) |> " <>
          "List.first()` / `hd(...)`.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
