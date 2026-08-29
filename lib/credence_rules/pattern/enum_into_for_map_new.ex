defmodule CredenceRules.Pattern.EnumIntoForMapNew do
  @moduledoc """
  Refactor rule: `Enum.into(pairs, %{})` (and the 3-arg
  `Enum.into(source, %{}, fun)`) is just `Map.new/1,2` with extra
  ceremony. `Map.new` is the idiomatic constructor and reads cleaner.

  ## Bad

      Map.new(...)  # too easy; the LLM goes for Enum.into instead:

      Enum.into(pairs, %{})
      pairs |> Enum.into(%{})
      Enum.into(users, %{}, fn u -> {u.id, u.name} end)

  ## Good

      Map.new(pairs)
      Map.new(users, fn u -> {u.id, u.name} end)

  ## Companion

  `CredenceRules.Pattern.MapIntoLiteral` already catches
  `Enum.map(...) |> Enum.into(%{})` (the double-walk pattern). This
  rule covers the remaining shapes where the source is **not** an
  `Enum.map` — those would be a more egregious flaw and own their own
  rule.
  """

  use CredenceRules.Rule

  @impl true
  def priority, do: 400

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn node, acc ->
        case match_enum_into_map(node) do
          {:ok, meta, form} -> {node, [build_issue(meta, form) | acc]}
          :error -> {node, acc}
        end
      end)

    Enum.reverse(issues)
  end

  # Enum.into(source, %{})
  defp match_enum_into_map({{:., meta, [{:__aliases__, _, [:Enum]}, :into]}, _, [source, {:%{}, _, []}]}) do
    if enum_map?(source), do: :error, else: {:ok, meta, :two_arg}
  end

  # Enum.into(source, %{}, fun)
  defp match_enum_into_map(
         {{:., meta, [{:__aliases__, _, [:Enum]}, :into]}, _, [source, {:%{}, _, []}, _fun]}
       ) do
    if enum_map?(source), do: :error, else: {:ok, meta, :three_arg}
  end

  # source |> Enum.into(%{})
  defp match_enum_into_map(
         {:|>, meta, [source, {{:., _, [{:__aliases__, _, [:Enum]}, :into]}, _, [{:%{}, _, []}]}]}
       ) do
    if pipe_ending_in_enum_map?(source), do: :error, else: {:ok, meta, :piped}
  end

  # source |> Enum.into(%{}, fun)
  defp match_enum_into_map(
         {:|>, meta, [source, {{:., _, [{:__aliases__, _, [:Enum]}, :into]}, _, [{:%{}, _, []}, _fun]}]}
       ) do
    if pipe_ending_in_enum_map?(source), do: :error, else: {:ok, meta, :piped_three_arg}
  end

  defp match_enum_into_map(_), do: :error

  defp enum_map?({{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, _}), do: true
  defp enum_map?(_), do: false

  defp pipe_ending_in_enum_map?({:|>, _, [_, rhs]}), do: enum_map?(rhs)
  defp pipe_ending_in_enum_map?(other), do: enum_map?(other)

  defp build_issue(meta, :three_arg) do
    %Issue{
      rule: :enum_into_for_map_new,
      message:
        "`Enum.into(source, %{}, fun)` is `Map.new(source, fun)`. Same arity, same mapper, " <>
          "but `Map.new` reads as a constructor (which is what it is).",
      meta: %{line: Keyword.get(meta, :line), form: :three_arg}
    }
  end

  defp build_issue(meta, :piped_three_arg) do
    %Issue{
      rule: :enum_into_for_map_new,
      message:
        "`source |> Enum.into(%{}, fun)` is `Map.new(source, fun)`. Use the constructor " <>
          "directly.",
      meta: %{line: Keyword.get(meta, :line), form: :piped_three_arg}
    }
  end

  defp build_issue(meta, form) do
    %Issue{
      rule: :enum_into_for_map_new,
      message:
        "`Enum.into(pairs, %{})` is `Map.new(pairs)`. Use the constructor directly — " <>
          "shorter and clearer about intent.",
      meta: %{line: Keyword.get(meta, :line), form: form}
    }
  end
end
