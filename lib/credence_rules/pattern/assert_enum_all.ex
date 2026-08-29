defmodule CredenceRules.Pattern.AssertEnumAll do
  @moduledoc """
  Test-quality rule (advisory): `assert Enum.all?(enum, fun)` collapses
  every element's truth value into a single boolean, so the failure
  message tells you nothing about which element failed.

  Per Chris Keathley's *Good and Bad Elixir*
  ([keathley.io](https://keathley.io/blog/good-and-bad-elixir.html)),
  the idiomatic shape is to assert per-element inside a comprehension
  so the failure message points at the specific item:

  ## Bad

      assert Enum.all?(users, fn user -> user.active end)
      # On failure: `Expected truthy, got false`.

  ## Good

      for user <- users do
        assert user.active, "expected \#{user.id} to be active"
      end
      # On failure: shows exactly which user failed.

  ## Detection

  AST shape `{:assert, _, [{{:., _, [Enum, :all?]}, _, args}]}` — i.e.
  `Enum.all?` is the sole argument to `assert`. Joining with `or`/`and`
  (`assert Enum.all?(...) or other_check`) is NOT flagged — that's
  a legitimate boolean composition where the per-element message
  wouldn't be more informative.
  """

  use CredenceRules.Rule

  @impl true
  def priority, do: 230

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:assert, meta, [body]} = node, acc ->
          if enum_all_call?(body),
            do: {node, [build_issue(meta) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp enum_all_call?({{:., _, [{:__aliases__, _, [:Enum]}, :all?]}, _, args})
       when is_list(args) and length(args) in 1..2,
       do: true

  defp enum_all_call?(_), do: false

  defp build_issue(meta) do
    %Issue{
      rule: :assert_enum_all,
      message:
        "`assert Enum.all?(enum, fun)` collapses every element into a " <>
          "single boolean — the failure message just says `Expected truthy, " <>
          "got false`. Use a comprehension: " <>
          "`for x <- enum, do: assert pred.(x), \"context for #\{x.id}\"` " <>
          "so the failure points at the specific element.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
