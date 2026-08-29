defmodule CredenceRules.Pattern.SpecReturnsAny do
  @moduledoc """
  Contract rule: `@spec` declarations whose return type is `any()` (or
  the equivalent alias `term()`) carry no information. They look like
  documentation but they constrain nothing — Dialyzer can't help, and
  callers can't tell what shapes the function actually returns.

  Real return types virtually always live in a small set:
  `:ok | {:error, reason}`, `String.t() | nil`, `[%MySchema{}]`, etc.
  A `:: any()` is almost always "the LLM didn't know what to put there."

  ## Bad

      @spec fetch_user(integer()) :: any()
      def fetch_user(id), do: Repo.get(User, id)

      @spec list_items() :: term()
      def list_items, do: Repo.all(Item)

  ## Good

      @spec fetch_user(integer()) :: User.t() | nil
      def fetch_user(id), do: Repo.get(User, id)

      @spec list_items() :: [Item.t()]
      def list_items, do: Repo.all(Item)

  ## Detection

  Walks for `@spec` and `@callback` declarations whose final return
  type is exactly `any()` or `term()`. Union types like
  `:: String.t() | any()` are also flagged — `any()` swallows every
  other branch of the union, so the rest of the spec is meaningless.
  """

  use CredenceRules.Rule

  @impl true
  def priority, do: 350

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{kind, _, [{:"::", meta, [_lhs, return_type]}]}]} = node, acc
        when kind in [:spec, :callback, :macrocallback] ->
          if contains_unrefined?(return_type),
            do: {node, [build_issue(meta, kind) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp contains_unrefined?({:any, _, []}), do: true
  defp contains_unrefined?({:term, _, []}), do: true
  defp contains_unrefined?({:|, _, args}), do: Enum.any?(args, &contains_unrefined?/1)
  defp contains_unrefined?(_), do: false

  defp build_issue(meta, kind) do
    %Issue{
      rule: :spec_returns_any,
      message:
        "`@#{kind} ... :: any()` (or `:: term()`) carries no information — Dialyzer can't " <>
          "use it and callers can't tell what shapes come back. Spell out the actual return " <>
          "type (`{:ok, _} | {:error, _}`, `String.t() | nil`, `[%MySchema{}]`, etc.) or " <>
          "remove the `@#{kind}`.",
      meta: %{line: Keyword.get(meta, :line), kind: kind}
    }
  end
end
