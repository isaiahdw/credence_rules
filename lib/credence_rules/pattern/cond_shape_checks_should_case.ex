# credence-file:repeated_subtree_in_function — this module is an AST pattern
#   matcher whose check/2 + Macro.prewalk + build_issue shape is the Rule
#   contract itself, so the structural duplication is inherent to the form
#   rather than a smell
defmodule CredenceRules.Pattern.CondShapeChecksShouldCase do
  @moduledoc """
  Idiom rule: a `cond` whose branches test the SHAPE of a value
  (`is_*` predicates, `Map.has_key?`, etc.) and then extract
  from that value is a `case` written backwards.

  ## Bad

      cond do
        is_binary(value) ->
          parse_binary(value)

        is_map(value) and Map.has_key?(value, :id) ->
          parse_id(Map.get(value, :id))

        true ->
          :unknown
      end

  Each `cond` branch tests `value`'s shape and the body
  re-extracts from `value`. Pattern matching does both jobs in
  one step.

  ## Good

      case value do
        binary when is_binary(binary) ->
          parse_binary(binary)

        %{id: id} ->
          parse_id(id)

        _ ->
          :unknown
      end

  ## When `cond` IS the right choice

  `cond` shines for **unrelated boolean conditions** — checks
  that don't all derive from one value:

      cond do
        retries > 5 -> :give_up
        Process.alive?(server) -> :ready
        config[:fallback] -> :use_fallback
        true -> :wait
      end

  Each line checks something independent. Pattern matching
  doesn't help here — there's no single value to match against.

  ## Detection

  Flags `cond do ... end` when:

  1. There are 2+ branches that test the shape of THE SAME value
     via `is_*` predicates or `Map.has_key?` / similar
  2. At least one branch's body extracts FROM that same value

  ## NOT flagged

  - `cond` branches with unrelated boolean conditions (the
    canonical `cond` use case)
  - Pure predicate `cond` (`score > 90 -> :excellent`) — no
    shape testing, no extraction
  - Single shape-check branch — too small to confidently
    rewrite to `case`

  ## Why advisory

  Heuristic — some shape-checking `cond`s are genuinely clearer
  than the equivalent `case` (especially when conditions are
  compound across multiple values). Reviewer call.
  """

  use CredenceRules.Rule

  @severity :low
  @confidence :medium

  @hint """
  Replace shape-checking `cond` with `case`:

      # Before
      cond do
        is_binary(value) ->
          parse_binary(value)

        is_map(value) and Map.has_key?(value, :id) ->
          parse_id(Map.get(value, :id))

        true ->
          :unknown
      end

      # After
      case value do
        binary when is_binary(binary) ->
          parse_binary(binary)

        %{id: id} ->
          parse_id(id)

        _ ->
          :unknown
      end

  Pattern matching asserts the shape AND binds the values in
  one step. `cond` re-tests and re-extracts on each branch.

  Keep `cond` for unrelated boolean checks (`retries > 5 ->
  ...; Process.alive?(server) -> ...`) — there's no single
  value for `case` to match against.
  """

  @carve_outs [
    "Unrelated boolean conditions (`cond do retries > N -> ...; Process.alive?(server) -> ...; ... end`) — no shared value, `case` doesn't help. Not flagged.",
    "Pure predicate `cond` (`score > 90 -> :excellent`) — no shape testing. Not flagged.",
    "Single shape-check branch — too small to confidently rewrite. Not flagged."
  ]

  @boolean_kernel_funs ~w(
    is_atom is_binary is_bitstring is_boolean is_exception
    is_float is_function is_integer is_list is_map
    is_nil is_number is_pid is_port is_reference
    is_struct is_tuple
  )a

  @impl true
  def priority, do: 495

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:cond, meta, [[do: clauses]]} = node, acc when is_list(clauses) ->
          if shape_checking_cond?(clauses),
            do: {node, [build_issue(meta) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp shape_checking_cond?(clauses) do
    # Per branch: pull out the shape-tested variable (if any),
    # then flag when 2+ branches converge on the same variable —
    # that's `case` in disguise.
    targets =
      Enum.flat_map(clauses, fn
        {:->, _, [[cond_expr], body]} ->
          case shape_test_target(cond_expr) do
            {:ok, target} ->
              if body_extracts_from?(body, target), do: [normalize(target)], else: []

            :no ->
              []
          end

        _ ->
          []
      end)

    # 2+ branches testing the same target = smell.
    targets
    |> Enum.frequencies()
    |> Enum.any?(fn {_target, count} -> count >= 2 end)
  end

  # Recognize `is_*(x)`, `Map.has_key?(x, _)`, and compound forms
  # `is_map(x) and Map.has_key?(x, _)`. Returns the target var.
  defp shape_test_target({fun, _, [target]}) when fun in @boolean_kernel_funs,
    do: {:ok, target}

  defp shape_test_target({{:., _, [{:__aliases__, _, [:Map]}, :has_key?]}, _, [target, _]}),
    do: {:ok, target}

  defp shape_test_target({:and, _, [left, right]}) do
    case shape_test_target(left) do
      {:ok, t} -> {:ok, t}
      :no -> shape_test_target(right)
    end
  end

  defp shape_test_target(_), do: :no

  defp body_extracts_from?(body, target) do
    normalized = normalize(target)

    {_, found?} =
      Macro.prewalk(body, false, fn
        _node, true ->
          {[], true}

        # target.field
        {{:., _, [t, _field]}, _, []} = node, _ ->
          if normalize(t) == normalized, do: {node, true}, else: {node, false}

        # Map.get(target, _)
        {{:., _, [{:__aliases__, _, [:Map]}, :get]}, _, [t | _]} = node, _ ->
          if normalize(t) == normalized, do: {node, true}, else: {node, false}

        # target[key]
        {{:., _, [Access, :get]}, _, [t | _]} = node, _ ->
          if normalize(t) == normalized, do: {node, true}, else: {node, false}

        # Bare reference to target (e.g., `parse_binary(value)`)
        node, _ ->
          if normalize(node) == normalized, do: {node, true}, else: {node, false}
      end)

    found?
  end

  defp normalize(ast) do
    Macro.prewalk(ast, fn node ->
      Macro.update_meta(node, fn _ -> [] end)
    end)
  end

  defp build_issue(meta) do
    %Issue{
      rule: :cond_shape_checks_should_case,
      message:
        "`cond` branches test the shape of the same value AND extract from it. " <>
          "Use `case value do <pattern1> -> ...; <pattern2> -> ...; _ -> ... end` " <>
          "instead — pattern matching asserts shape AND binds values in one step. " <>
          "Keep `cond` for unrelated boolean conditions across different values.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
