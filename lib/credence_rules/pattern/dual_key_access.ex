defmodule CredenceRules.Pattern.DualKeyAccess do
  @moduledoc """
  Boundary rule: `map[:k] || map["k"]` — accessing the same map with
  both an atom key AND its string equivalent as a fallback — is a
  signal that the data shape at this boundary isn't normalized.

  The pattern usually appears when:

  - JSON or another text-protocol payload (string keys) gets mixed
    with internal Elixir data (atom keys) without an explicit decode
    step.
  - Two callers feed the same data structure with different key
    conventions, and the consumer hedges.
  - An LLM "defensively" papers over a shape question it didn't
    investigate.

  The fix is to **normalize at the boundary**. Decide at the data's
  entry point whether you want atom-keyed or string-keyed maps and
  enforce it there:

  - **Coming from JSON** → keep string keys throughout, or decode
    into a struct with `:keys` option.
  - **Going to JSON** → convert atoms to strings explicitly at the
    encode point.
  - **Internal data** → atoms only; raise on unexpected string keys.

  Once a single canonical shape is chosen, downstream code uses one
  access form.

  ## Bad

      def email(user) do
        user[:email] || user["email"]
      end

  ## Good

      # Decided at the boundary: this function expects atom keys.
      def email(%{email: email}), do: email

      # Or, if the data legitimately mixes: convert once at the seam.
      def email(user), do: Map.new(user, fn {k, v} -> {to_string(k), v} end)["email"]

  ## Detection

  Flags `||`/`or` expressions where:

  - Both sides are bracket-access via `Access.get` (i.e. `m[k]`)
  - The receivers are AST-equal (same variable / expression)
  - The two keys are: one atom and one string, OR vice versa

  Single-side bracket access (`m[:k] || other_call()`) is NOT
  flagged — that's a normal default-value pattern.
  """

  use CredenceRules.Rule

  @impl true
  def priority, do: 380

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {op, meta, [lhs, rhs]} = node, acc when op in [:||, :or] ->
          if dual_access?(lhs, rhs),
            do: {node, [build_issue(meta) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp dual_access?(lhs, rhs) do
    with {:ok, c1, k1} <- bracket_access(lhs),
         {:ok, c2, k2} <- bracket_access(rhs),
         true <- containers_match?(c1, c2),
         true <- mixed_atom_and_string_keys?(k1, k2) do
      true
    else
      _ -> false
    end
  end

  # Matches `container[key]` — the `from_brackets: true` meta marks
  # bracket syntax (vs. explicit Access.get/2). Returns `{:ok, container, key}`.
  defp bracket_access({{:., inner_meta, [Access, :get]}, outer_meta, [container, key]}) do
    if Keyword.get(inner_meta, :from_brackets) == true or
         Keyword.get(outer_meta, :from_brackets) == true do
      {:ok, container, key}
    else
      :no
    end
  end

  defp bracket_access(_), do: :no

  # Two containers "match" if they're syntactically identical AST
  # subtrees ignoring meta. Compare by stripping line numbers.
  defp containers_match?(c1, c2) do
    strip_meta(c1) == strip_meta(c2)
  end

  defp strip_meta({head, _meta, children}) when is_list(children) do
    {strip_meta(head), [], Enum.map(children, &strip_meta/1)}
  end

  defp strip_meta({a, b}), do: {strip_meta(a), strip_meta(b)}
  defp strip_meta(list) when is_list(list), do: Enum.map(list, &strip_meta/1)
  defp strip_meta(other), do: other

  defp mixed_atom_and_string_keys?(k1, k2) do
    (is_atom(k1) and is_binary(k2)) or (is_binary(k1) and is_atom(k2))
  end

  defp build_issue(meta) do
    %Issue{
      rule: :dual_key_access,
      message:
        "`map[:k] || map[\"k\"]` (or vice versa) papers over an un-normalized " <>
          "data shape at the boundary. Decide whether atom or string keys are " <>
          "canonical at this seam and enforce it once — don't make every " <>
          "reader handle both.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
