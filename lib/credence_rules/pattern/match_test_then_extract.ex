# credence-file:iosp_mixed_function,repeated_subtree_in_function — this module
#   is an AST pattern matcher whose check/2 + Macro.prewalk + build_issue shape
#   is the Rule contract itself, so the structural duplication is inherent to
#   the form rather than a smell
defmodule CredenceRules.Pattern.MatchTestThenExtract do
  @moduledoc """
  Idiom rule: `match?/2` is for **testing** whether a value
  matches a pattern. If the body then needs to extract data from
  that value, you should have matched the pattern with `case` or
  function-head — `match?` discards the binding by design.

  ## Bad

      if match?({:ok, _}, result) do
        elem(result, 1)
      end

      if match?(%User{}, user) do
        user.email
      end

      if match?({:ok, _, _}, response) do
        process(response)
      end

  The `match?` call confirms the shape but throws the pieces
  away. The body then has to dig them back out — manually with
  `elem`, with field access, or by re-doing the work the match
  already did.

  ## Good

      case result do
        {:ok, value} -> value
        _ -> nil
      end

      case user do
        %User{email: email} -> email
        _ -> nil
      end

      case response do
        {:ok, head, tail} -> process_with(head, tail)
        _ -> nil
      end

  The pattern asserts the shape AND binds the parts in one step.

  ## Detection

  Flags `if match?(<pattern>, <expr>), do: <body>` (with or
  without else) where the body USES `<expr>` as a value:

  - `<expr>.field` — dot field access
  - `elem(<expr>, _)` — tuple positional read
  - `Map.get(<expr>, _)` / `Keyword.get(<expr>, _)` — map/kw lookup
  - `<expr>[<key>]` — bracket access

  The check is structural (recursive metadata-strip then `==`),
  so the same expression at different lines matches.

  ## NOT flagged

  - `if match?(pattern, expr), do: side_effect()` where body
    doesn't use `expr` — pure shape test, no extraction smell.
  - `match?` in a guard (`when match?(...)`) — that's valid
    boolean usage.
  - `case` clauses with `match?` in the body — `case` handles
    pattern matching natively, but bare `match?` use isn't
    necessarily wrong.

  ## Why advisory + medium

  The rule catches a real smell most of the time, but `match?`
  is sometimes correct — e.g., checking an opt's shape inside a
  guard expression isn't possible without it. Advisory tier.
  """

  use CredenceRules.Rule

  @severity :medium
  @confidence :high

  @hint """
  Replace `if match?(pattern, expr)` with a `case` that binds
  the parts directly:

      # Before
      if match?({:ok, _}, result) do
        elem(result, 1)
      end

      # After
      case result do
        {:ok, value} -> value
        _ -> nil
      end

      # Before
      if match?(%User{}, user) do
        user.email
      end

      # After
      case user do
        %User{email: email} -> email
        _ -> nil
      end

  The pattern asserts the shape AND binds the values in one
  step — `match?/2` discards the bindings by design.

  Keep `match?` for guards (`when match?(...)`) and for shape-
  testing without extraction (`Enum.filter(&match?({:ok, _}, &1))`).
  """

  @carve_outs [
    "`if match?(pattern, expr), do: side_effect_only()` — body doesn't extract from expr. Pure shape test, not flagged.",
    "`when match?(...)` in guards — boolean shape test, perfectly valid.",
    "`Enum.filter(&match?({:ok, _}, &1))` — shape-test for filtering, not extraction. Not flagged."
  ]

  @impl true
  def priority, do: 487

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        # if match?(pattern, expr), do: body
        {:if, meta, [cond, kw]} = node, acc when is_list(kw) ->
          case extract_match_target(cond) do
            {:ok, expr} ->
              body = Keyword.get(kw, :do)
              else_body = Keyword.get(kw, :else)

              if uses_as_value?(body, expr) or uses_as_value?(else_body, expr),
                do: {node, [build_issue(meta, expr) | acc]},
                else: {node, acc}

            :no ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  # match?(pattern, expr) — extract `expr`. Accepts both bare and
  # Kernel-qualified forms.
  defp extract_match_target({:match?, _, [_pattern, expr]}), do: {:ok, expr}

  defp extract_match_target({{:., _, [{:__aliases__, _, [:Kernel]}, :match?]}, _, [_pattern, expr]}),
    do: {:ok, expr}

  defp extract_match_target(_), do: :no

  # Walk body for "uses of expr as a value" — extracting from it,
  # not just testing it again.
  defp uses_as_value?(nil, _expr), do: false

  defp uses_as_value?(body, expr) do
    normalized_expr = normalize(expr)

    {_, found?} =
      Macro.prewalk(body, false, fn
        _node, true ->
          {[], true}

        # elem(expr, _)
        {:elem, _, [target, _]} = node, _ ->
          if same?(target, normalized_expr), do: {node, true}, else: {node, false}

        # expr.field
        {{:., _, [target, _field]}, _, []} = node, _ ->
          if same?(target, normalized_expr), do: {node, true}, else: {node, false}

        # Map.get(expr, _) / Keyword.get(expr, _)
        {{:., _, [{:__aliases__, _, [mod]}, :get]}, _, [target | _]} = node, _
        when mod in [:Map, :Keyword] ->
          if same?(target, normalized_expr), do: {node, true}, else: {node, false}

        # expr[:key]
        {{:., _, [Access, :get]}, _, [target | _]} = node, _ ->
          if same?(target, normalized_expr), do: {node, true}, else: {node, false}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp same?(a, normalized_b), do: normalize(a) == normalized_b

  defp normalize(ast) do
    Macro.prewalk(ast, fn node ->
      Macro.update_meta(node, fn _ -> [] end)
    end)
  end

  defp build_issue(meta, expr) do
    %Issue{
      rule: :match_test_then_extract,
      message:
        "`if match?(pattern, #{Macro.to_string(expr)})` confirms the shape but " <>
          "throws the bindings away — then the body re-extracts from " <>
          "`#{Macro.to_string(expr)}`. Replace with `case #{Macro.to_string(expr)} " <>
          "do <pattern with bindings> -> ...; _ -> ... end` so the match asserts " <>
          "the shape AND binds the values in one step.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
