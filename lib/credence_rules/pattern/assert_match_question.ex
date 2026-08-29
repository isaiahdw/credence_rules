defmodule CredenceRules.Pattern.AssertMatchQuestion do
  @moduledoc """
  Test-quality rule: `assert match?(pattern, expr)` should be
  `assert pattern = expr` when there's only one pattern being asserted.

  `match?/2` is for cases where the result of "does this match?" is
  data — e.g. as a guard inside `or`/`and`/`Enum.filter`. As the entire
  body of `assert`, it gives you a worse failure message than the
  `assert =` form:

      assert match?({:ok, _}, result)
      # Failure: "Expected truthy, got false"

      assert {:ok, _} = result
      # Failure: "match (=) failed. expression: {:ok, _} = result
      #          left: {:ok, _}    right: {:error, :timeout}"

  Plus `assert =` binds variables from the pattern for use in
  subsequent assertions:

      assert {:ok, user} = create_user(attrs)
      assert user.email == "a@b.c"

  ## Detection

  Fires when `match?` is the *sole* expression inside `assert`. The
  multi-pattern disjunction form `assert match?(a, expr) or match?(b, expr)`
  is NOT flagged — that's a legitimate use of `match?` because
  `assert =` can't express it.

  ## Bad

      assert match?({:ok, _}, fetch(id))

  ## Good

      assert {:ok, _} = fetch(id)

      # Or, for the legitimate disjunction case:
      assert match?({:ok, _}, fetch(id)) or match?({:error, :timeout}, fetch(id))
  """

  use CredenceRules.Rule

  @impl true
  def priority, do: 240

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:assert, meta, [body]} = node, acc ->
          if bare_match_question?(body),
            do: {node, [build_issue(meta) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp bare_match_question?({:match?, _, [_pattern, _expr]}), do: true
  # If the body is an `or`/`and` expression, even if both sides are
  # match?, we don't flag — the user explicitly needs match? for the
  # disjunction.
  defp bare_match_question?(_), do: false

  defp build_issue(meta) do
    %Issue{
      rule: :assert_match_question,
      message:
        "`assert match?(pattern, expr)` gives worse failure messages and " <>
          "doesn't bind variables. Prefer `assert pattern = expr`. (The " <>
          "disjunction form `assert match?(a, x) or match?(b, x)` is fine.)",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
