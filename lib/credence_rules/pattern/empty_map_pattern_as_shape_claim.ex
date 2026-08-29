# credence-file:repeated_subtree_in_function — this module is an AST pattern
#   matcher whose check/2 + Macro.prewalk + build_issue shape is the Rule
#   contract itself, so the structural duplication is inherent to the form
#   rather than a smell
defmodule CredenceRules.Pattern.EmptyMapPatternAsShapeClaim do
  @moduledoc """
  Safety rule: `%{}` in a pattern position matches **every map**,
  including ones missing the keys the body assumes exist. The
  pattern claims nothing useful; the body assumes everything.

  From the [Elixir patterns-and-guards docs](https://hexdocs.pm/elixir/patterns-and-guards.html):

  > The map pattern matches any map containing the given keys.
  > The empty map pattern (`%{}`) matches every map.

  An LLM (or a hurried developer) often writes `%{} = params` as
  if it were a shape claim — like saying "make sure this is a
  map." It IS that — but it's also literally every map, so the
  body's assumptions about which keys exist aren't backed by
  the pattern.

  ## Bad

      def handle(%{} = params) do
        process(params.id)         # params might not have :id
      end

      def handle(%{} = payload) do
        decode(payload["body"])    # payload might not have "body"
      end

      case payload do
        %{} -> Map.get(payload, :id)
        _ -> :error
      end

  Each pattern matches all maps (including `%{}` itself or maps
  with completely different keys). The body's key access then
  crashes with `KeyError` or returns `nil` when the assumption
  is wrong.

  ## Good

      def handle(%{id: id}) do
        process(id)
      end

      def handle(%{"body" => body}) do
        decode(body)
      end

      case payload do
        %{id: id} -> {:ok, id}
        _ -> :error
      end

  Or, when the function really does accept any map and shape
  doesn't matter:

      def handle(params) when is_map(params) do
        Map.get(params, :id, :default)
      end

  ## Detection

  Flags function heads and case clauses that use `%{}` (the
  EMPTY map pattern — no keys) as the matched pattern AND
  whose body accesses specific keys via:

  - `var.field` (dot access)
  - `Map.get(var, key)` / `Map.fetch(var, key)` / `Map.fetch!(var, key)`
  - `var[key]` (bracket access)

  Match shapes flagged:

  - `def f(%{} = name)` / `def f(name = %{})`
  - `case x do %{} -> body end` (clause body uses key access on `x`)

  ## NOT flagged

  - `%{} = x` in non-pattern position (assignment after the
    fact — that's an equality check failing fast).
  - `%{key: _}` with at least one key — that IS a shape claim.
  - `%{}` patterns where the body doesn't access specific keys
    (`def handle(%{}), do: :is_a_map`).
  - `case x do %{} -> :map; _ -> :other end` — pure type
    discrimination, no key extraction.

  ## Why severity:medium

  Real correctness risk — code that compiles silently and
  crashes at runtime when the assumed keys are missing. Confidence
  is `:medium` because the rule can't always tell whether the
  body's key access is gated by other logic (Map.has_key? earlier,
  defensive `Map.get(_, _, default)`). Advisory tier; reviewers
  can accept genuine "I really do accept any map" cases.
  """

  use CredenceRules.Rule

  @severity :medium
  @confidence :medium

  @hint """
  Declare the shape in the pattern; don't assume it in the body:

      # Before
      def handle(%{} = params) do
        process(params.id)
      end

      # After — pattern declares required keys
      def handle(%{id: id}) do
        process(id)
      end

  For function heads with multiple required keys:

      def handle(%{id: id, type: type, ts: ts}) do
        ...
      end

  If you really do accept ANY map and shape doesn't matter:

      def handle(params) when is_map(params) do
        Map.get(params, :id, :default)  # explicit default
      end

  Or use `Map.fetch/2` (`{:ok, value} | :error`) if you need to
  distinguish absent from present-nil.
  """

  @carve_outs [
    "Body that doesn't access specific keys (`def handle(%{}), do: :is_a_map`) — pure type discrimination, not flagged.",
    "Patterns with at least one key (`%{id: _}`, `%{\"type\" => _}`) — real shape claims, not flagged.",
    "Outside pattern position (`map = %{}` assignment for initialization) — not flagged.",
    "Functions with `Map.get(_, _, default)` or `Map.fetch/2` in the body — defensive access. Rule can't tell; reviewer call."
  ]

  @impl true
  def priority, do: 490

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        # def f(args) — check each arg for the %{} pattern.
        {def_kind, _meta, [head, kw]} = node, acc
        when def_kind in [:def, :defp, :defmacro, :defmacrop] and is_list(kw) ->
          case extract_def_match(head, kw) do
            {:ok, var, line} ->
              {node, [build_issue(line, :def_head, var) | acc]}

            :no ->
              {node, acc}
          end

        # case x do %{} -> body end — flag if body uses x's keys
        {:case, _meta, [discriminator, [do: clauses]]} = node, acc when is_list(clauses) ->
          flags = collect_case_clause_flags(discriminator, clauses)
          {node, flags ++ acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  # Look at the def's args + body to detect `%{} = var` followed
  # by key access on var.
  defp extract_def_match(head, kw) do
    body = Keyword.get(kw, :do)

    case extract_head_match(head) do
      {:ok, var, line} ->
        if body && body_accesses_keys?(body, var),
          do: {:ok, var, line},
          else: :no

      :no ->
        :no
    end
  end

  # Match `def f(args)` and look for `%{} = var` or `var = %{}` arg.
  defp extract_head_match({:when, _, [inner, _guard]}), do: extract_head_match(inner)

  defp extract_head_match({_name, _, args}) when is_list(args) do
    Enum.find_value(args, :no, fn arg ->
      case extract_empty_map_binding(arg) do
        {:ok, var, line} -> {:ok, var, line}
        :no -> nil
      end
    end)
  end

  defp extract_head_match(_), do: :no

  # Recognize `%{} = var` or `var = %{}` — empty map pattern bound
  # to a variable.
  defp extract_empty_map_binding({:=, meta, [{:%{}, _, []}, var]}) when is_tuple(var),
    do: {:ok, var, Keyword.get(meta, :line)}

  defp extract_empty_map_binding({:=, meta, [var, {:%{}, _, []}]}) when is_tuple(var),
    do: {:ok, var, Keyword.get(meta, :line)}

  defp extract_empty_map_binding(_), do: :no

  defp collect_case_clause_flags(discriminator, clauses) do
    Enum.flat_map(clauses, fn
      {:->, meta, [[{:%{}, _, []}], body]} ->
        # `%{} -> body` — flag if body uses discriminator's keys
        if body_accesses_keys?(body, discriminator),
          do: [build_issue(Keyword.get(meta, :line), :case_clause, discriminator)],
          else: []

      {:->, meta, [[{:=, _, [{:%{}, _, []}, var]}], body]} ->
        # `%{} = name -> body` — flag if body uses name's keys
        if body_accesses_keys?(body, var),
          do: [build_issue(Keyword.get(meta, :line), :case_clause, var)],
          else: []

      _ ->
        []
    end)
  end

  defp body_accesses_keys?(body, var) do
    normalized = normalize(var)

    {_, found?} =
      Macro.prewalk(body, false, fn
        _node, true ->
          {[], true}

        # var.field — dot access (zero-arity dot call)
        {{:., _, [target, _field]}, _, []} = node, _ ->
          if same?(target, normalized), do: {node, true}, else: {node, false}

        # Map.get(var, _) / Map.fetch(var, _) / Map.fetch!(var, _)
        {{:., _, [{:__aliases__, _, [:Map]}, fun]}, _, [target | _]} = node, _
        when fun in [:get, :fetch, :fetch!] ->
          if same?(target, normalized), do: {node, true}, else: {node, false}

        # var[key]
        {{:., _, [Access, :get]}, _, [target | _]} = node, _ ->
          if same?(target, normalized), do: {node, true}, else: {node, false}

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

  defp build_issue(line, form, var) do
    %Issue{
      rule: :empty_map_pattern_as_shape_claim,
      message:
        "`%{} = #{Macro.to_string(var)}` matches EVERY map (`%{}` is the empty " <>
          "map pattern — subset match), but the body accesses specific keys on " <>
          "`#{Macro.to_string(var)}`. Declare the required keys in the pattern: " <>
          "`%{key: _, other: _} = #{Macro.to_string(var)}`. If you really do " <>
          "accept any map, use `when is_map(#{Macro.to_string(var)})` and " <>
          "`Map.get/3` with a default.",
      meta: %{line: line, form: form}
    }
  end
end
