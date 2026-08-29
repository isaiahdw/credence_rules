# credence-file:iosp_mixed_function,repeated_subtree_in_function — this module
#   is an AST pattern matcher whose check/2 + Macro.prewalk + build_issue shape
#   is the Rule contract itself, so the structural duplication is inherent to
#   the form rather than a smell
defmodule CredenceRules.Pattern.MapHasKeyThenGet do
  @moduledoc """
  Idiom rule: `if Map.has_key?(map, key), do: Map.get(map, key)`
  is an imperative-style lookup that Elixir's pattern matching
  handles cleaner.

  ## Bad

      if Map.has_key?(params, "id") do
        load_user(Map.get(params, "id"))
      end

      if Map.has_key?(opts, :timeout) do
        sleep(Map.get(opts, :timeout))
      end

  Two lookups for one logical operation. The `has_key?` returns
  a boolean which gates an extraction the rule could do in one
  match.

  ## Good

      case params do
        %{"id" => id} -> load_user(id)
        _ -> nil
      end

      case opts do
        %{timeout: timeout} -> sleep(timeout)
        _ -> nil
      end

  Or as a function head:

      defp handle(%{"id" => id}), do: load_user(id)
      defp handle(_), do: nil

  ## Semantic difference

  Map pattern matching tests **key presence** — same as
  `Map.has_key?/2`. `Map.get(map, key)` with NO default returns
  `nil` for both \"key absent\" AND \"key present, value nil\".

  The pattern-match rewrite is equivalent ONLY for the
  has_key? + get sequence. If your original code was relying on
  `nil`-distinguishes-from-absent semantics, you need
  `Map.fetch/2` (`{:ok, value} | :error`) instead.

  ## Detection

  Flags `if Map.has_key?(<map>, <key>), do: <body>` (with or
  without `else`) when the body contains EITHER:

  - `Map.get(<same_map>, <same_key>)` (any arity), OR
  - `<same_map>[<same_key>]` bracket access

  Structural comparison after metadata strip — same map / same
  key recognized across line numbers.

  ## NOT flagged

  - `if Map.has_key?(m, k), do: log(\"has key\")` — body doesn't
    fetch the value. Pure presence test, no smell.
  - `if Map.has_key?(m, k1), do: Map.get(m, k2)` — different
    keys, different logic.
  - `if Map.has_key?(m, k), do: Map.get(other_map, k)` — different
    maps, not the same lookup.
  - `if params[\"id\"], do: load(params[\"id\"])` — truthy-on-bracket
    shape; owned by `truthy_access_reused_in_body`.
  """

  use CredenceRules.Rule

  @severity :medium
  @confidence :medium

  @hint """
  Replace `if Map.has_key? + Map.get` with a pattern match:

      # Before
      if Map.has_key?(params, "id") do
        load_user(Map.get(params, "id"))
      end

      # After
      case params do
        %{"id" => id} -> load_user(id)
        _ -> nil
      end

  For function heads with multiple shapes:

      defp handle(%{"id" => id}), do: load_user(id)
      defp handle(_), do: nil

  Note: `Map.has_key?` and the pattern match BOTH check key
  presence (not the value's truthy-ness). `Map.get` without a
  default returns `nil` for absent keys AND nil-valued keys; the
  pattern match preserves that — both reach the `_ -> nil`
  branch when the key is absent. If you need to distinguish
  \"absent\" from \"present-and-nil,\" use `Map.fetch/2` instead.
  """

  @carve_outs [
    "Body that doesn't fetch the value (`if Map.has_key?(m, k), do: log(\"present\")`) — pure presence test, not flagged.",
    "Different key in `has_key?` vs `get` (`if Map.has_key?(m, k1), do: Map.get(m, k2)`) — that's intentional, not a smell.",
    "Different map in body (`if Map.has_key?(m1, k), do: Map.get(m2, k)`) — different lookups.",
    "`if params[\"id\"], do: load(params[\"id\"])` — truthy-on-bracket shape. Owned by `truthy_access_reused_in_body`; this rule scopes to the explicit `Map.has_key?` form."
  ]

  @impl true
  def priority, do: 488

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        # if Map.has_key?(map, key), do: body
        {:if, meta, [cond, kw]} = node, acc when is_list(kw) ->
          case extract_has_key(cond) do
            {:ok, map, key} ->
              body = Keyword.get(kw, :do)
              else_body = Keyword.get(kw, :else)

              if body_fetches?(body, map, key) or body_fetches?(else_body, map, key),
                do: {node, [build_issue(meta, key) | acc]},
                else: {node, acc}

            :no ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  # Map.has_key?(map, key) — exact Map module
  defp extract_has_key({{:., _, [{:__aliases__, _, [:Map]}, :has_key?]}, _, [map, key]}),
    do: {:ok, map, key}

  defp extract_has_key(_), do: :no

  defp body_fetches?(nil, _map, _key), do: false

  defp body_fetches?(body, map, key) do
    normalized_map = normalize(map)
    normalized_key = normalize(key)

    {_, found?} =
      Macro.prewalk(body, false, fn
        _node, true ->
          {[], true}

        # Map.get(<map>, <key>, _?)
        {{:., _, [{:__aliases__, _, [:Map]}, :get]}, _, [m, k | _]} = node, _ ->
          if normalize(m) == normalized_map and normalize(k) == normalized_key,
            do: {node, true},
            else: {node, false}

        # <map>[<key>] — Access.get/2
        {{:., _, [Access, :get]}, _, [m, k]} = node, _ ->
          if normalize(m) == normalized_map and normalize(k) == normalized_key,
            do: {node, true},
            else: {node, false}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp normalize(ast) do
    Macro.prewalk(ast, fn node ->
      Macro.update_meta(node, fn _ -> [] end)
    end)
  end

  defp build_issue(meta, key) do
    %Issue{
      rule: :map_has_key_then_get,
      message:
        "`if Map.has_key?(_, #{Macro.to_string(key)}), do: Map.get(_, " <>
          "#{Macro.to_string(key)})` — two lookups for one logical operation. " <>
          "Pattern-match the key directly: `case map do %{#{Macro.to_string(key)} " <>
          "=> value} -> use(value); _ -> nil end`. Equivalent semantics: both " <>
          "the original and the rewrite test for key presence (not value truthiness).",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
