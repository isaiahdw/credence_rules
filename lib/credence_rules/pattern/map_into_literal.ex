defmodule CredenceRules.Pattern.MapIntoLiteral do
  @moduledoc """
  Refactor rule: `Enum.map(..., fun) |> Enum.into(%{})` (or
  `Enum.into(Enum.map(...), %{})`) walks the enumerable twice. Use
  `Map.new/2`, which takes the same mapper.

  ## Bad

      users |> Enum.map(fn u -> {u.id, u} end) |> Enum.into(%{})

  ## Good

      Map.new(users, fn u -> {u.id, u} end)

  Ported from
  [`ExSlop.Check.Refactor.MapIntoLiteral`](https://hex.pm/packages/ex_slop).
  """

  use CredenceRules.Rule

  @impl true
  def priority, do: 400

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn node, acc ->
        case match_map_into(node) do
          {:ok, meta} -> {node, [build_issue(meta) | acc]}
          :error -> {node, acc}
        end
      end)

    Enum.reverse(issues)
  end

  # Enum.map(...) |> Enum.into(%{})
  defp match_map_into(
         {:|>, _,
          [
            {{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, _},
            {{:., meta, [{:__aliases__, _, [:Enum]}, :into]}, _, [{:%{}, _, []}]}
          ]}
       ),
       do: {:ok, meta}

  # ... |> Enum.map(...) |> Enum.into(%{})
  defp match_map_into(
         {:|>, _,
          [
            {:|>, _, [_, {{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, _}]},
            {{:., meta, [{:__aliases__, _, [:Enum]}, :into]}, _, [{:%{}, _, []}]}
          ]}
       ),
       do: {:ok, meta}

  # Enum.into(Enum.map(...), %{})
  defp match_map_into(
         {{:., meta, [{:__aliases__, _, [:Enum]}, :into]}, _,
          [
            {{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, _},
            {:%{}, _, []}
          ]}
       ),
       do: {:ok, meta}

  defp match_map_into(_), do: :error

  defp build_issue(meta) do
    %Issue{
      rule: :map_into_literal,
      message:
        "`Enum.map(...) |> Enum.into(%{})` walks the enumerable twice. Use " <>
          "`Map.new(enum, fn ... end)` — same mapper, single pass.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
