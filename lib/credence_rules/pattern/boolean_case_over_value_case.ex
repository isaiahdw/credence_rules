defmodule CredenceRules.Pattern.BooleanCaseOverValueCase do
  @moduledoc """
  Idiom rule: `case <boolean-predicate>(value) do true -> use(value);
  false -> default end` is a strong LLM tell. The author wrote
  the boolean form because they're thinking imperatively
  ("check the condition, then branch"). The Elixir form matches
  the VALUE directly.

  ## Bad

      case Map.has_key?(params, "id") do
        true -> load_user(params["id"])
        false -> :missing
      end

      case match?({:ok, _}, result) do
        true -> elem(result, 1)
        false -> :error
      end

      case is_nil(value) do
        true -> :default
        false -> use(value)
      end

  Each `case` discriminates on a predicate (`Map.has_key?`,
  `match?`, `is_nil`), then the body re-reads the original value
  from inside the branch.

  ## Good

      case params do
        %{"id" => id} -> load_user(id)
        _ -> :missing
      end

      case result do
        {:ok, value} -> value
        _ -> :error
      end

      case value do
        nil -> :default
        value -> use(value)
      end

  Match the value directly. The pattern asserts the shape AND
  binds the parts in one step; the predicate-based form does
  neither.

  ## Detection

  Flags `case <predicate>(<args>) do true -> ...; false -> ... end`
  where:

  - The discriminator is a known boolean predicate:
    - `Map.has_key?` / `Keyword.has_key?`
    - `is_nil`, `is_atom`, `is_pid`, `is_binary`, etc.
    - `match?` (already covered by `match_test_then_extract`
      when used in if; this rule covers the `case` form)
    - `Enum.member?` / `Enum.empty?`
    - Trailing-`?` function calls (boolean by convention)
  - The clauses are `true -> ...` and `false -> ...` (any order)

  ## NOT flagged

  - `case` over a value (the goal shape) — `case x do {:ok, v} -> ...`
  - `case` over `true`/`false` literals in clauses without matching
    against predicates (e.g., `case x do true -> :y; false -> :n end`
    where `x` is a stored boolean — that's correct).
  - `cond` — different smell.

  ## Why advisory

  The rule is very LLM-specific. Real-world Elixir rarely writes
  `case predicate() do true -> ...`, but LLMs generate it
  because it matches the JS/Python branch shape. High-confidence
  detection, advisory tier because some edge cases (boolean-
  storing variables specifically named like predicates) are
  intentional.
  """

  use CredenceRules.Rule

  @severity :medium
  @confidence :high

  @hint """
  Match the value, not the boolean:

      # Before
      case Map.has_key?(params, "id") do
        true -> load_user(params["id"])
        false -> :missing
      end

      # After
      case params do
        %{"id" => id} -> load_user(id)
        _ -> :missing
      end

      # Before
      case match?({:ok, _}, result) do
        true -> elem(result, 1)
        false -> :error
      end

      # After
      case result do
        {:ok, value} -> value
        _ -> :error
      end

  The value-match form asserts the shape AND binds the parts in
  one step. The predicate form re-reads the value inside the
  branch — same smell as `truthy_access_reused_in_body` /
  `match_test_then_extract`, different syntactic shape.
  """

  @carve_outs [
    "`case` over a value (already the goal shape) — not flagged.",
    "`case` clauses with `true`/`false` heads when the discriminator is NOT a predicate call (e.g., reading a stored boolean from config) — not flagged.",
    "Pattern matching on `true` / `false` in a `with` chain — different shape, not flagged."
  ]

  @boolean_kernel_funs ~w(
    is_atom is_binary is_bitstring is_boolean is_exception
    is_float is_function is_integer is_list is_map
    is_map_key is_nil is_number is_pid is_port is_reference
    is_struct is_tuple
  )a

  @impl true
  def priority, do: 492

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:case, meta, [discriminator, [do: clauses]]} = node, acc when is_list(clauses) ->
          if predicate_discriminator?(discriminator) and true_false_clauses?(clauses),
            do: {node, [build_issue(meta, discriminator) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  # Recognize predicate-returning expressions in the discriminator.
  defp predicate_discriminator?({:match?, _, _}), do: true

  defp predicate_discriminator?({fun, _, _}) when fun in @boolean_kernel_funs, do: true

  defp predicate_discriminator?({{:., _, [_module, fun]}, _, _args}) when is_atom(fun) do
    # `?` suffix is a boolean convention. Also catches stdlib like
    # `Map.has_key?`, `Enum.member?`, `Enum.empty?`.
    name = Atom.to_string(fun)
    fun in @boolean_kernel_funs or String.ends_with?(name, "?")
  end

  defp predicate_discriminator?({:not, _, [inner]}), do: predicate_discriminator?(inner)

  defp predicate_discriminator?(_), do: false

  # Clauses must be exactly `true -> ...` and `false -> ...` (any order).
  # Both arms required so we know the case discriminates by boolean.
  defp true_false_clauses?(clauses) do
    heads =
      Enum.map(clauses, fn
        {:->, _, [[head], _body]} -> head
        _ -> :other
      end)

    Enum.sort(heads) == [false, true]
  end

  defp build_issue(meta, discriminator) do
    %Issue{
      rule: :boolean_case_over_value_case,
      message:
        "`case #{Macro.to_string(discriminator)} do true -> ...; false -> ... end` " <>
          "branches on a boolean predicate, then re-reads the original value " <>
          "from inside the branch. Match the value directly: `case <value> do " <>
          "<pattern> -> ...; _ -> ... end`. The pattern asserts the shape AND " <>
          "binds the parts in one step.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
