# credence-file:repeated_subtree_in_function — this module is an AST pattern
#   matcher whose check/2 + Macro.prewalk + build_issue shape is the Rule
#   contract itself, so the structural duplication is inherent to the form
#   rather than a smell
defmodule CredenceRules.Pattern.TaggedTupleElemAccess do
  @moduledoc """
  Idiom rule: code that destructures `{:ok, value}` / `{:error,
  reason}` style tuples via `elem/2` is almost always doing it
  the wrong way. Pattern matching is what Elixir provides for
  this; `elem` reads as positional-index access and loses the
  shape claim.

  ## Bad

      if elem(result, 0) == :ok do
        process(elem(result, 1))
      else
        :error
      end

      case elem(result, 0) do
        :ok -> elem(result, 1)
        :error -> :error
      end

  Two problems:

  1. **No shape assertion**: `elem(result, 0)` doesn't claim
     `result` is a tuple of any particular size. If `result` is
     somehow `{:ok, value, extra}` or `{:fancy_error, reason,
     :details}`, the code reads `:ok` from position 0 and
     `value`/`reason` from position 1 — silently treating
     different shapes as the same.
  2. **No binding of the matched value**: the code reads `elem(...,
     1)` separately from the condition. There's nothing tying the
     `:ok`-ness of position 0 to the value at position 1; pattern
     matching does that in one step.

  ## Good

      case result do
        {:ok, value} -> process(value)
        {:error, _} -> :error
      end

  The pattern asserts the shape (`{atom, value}` two-tuple) AND
  binds `value` in one step. Mismatched shapes hit the catch-all
  or raise `CaseClauseError` instead of silently misreading.

  ## Detection

  Flags `elem(<x>, 0)` or `elem(<x>, 1)` calls inside:

  - **`if` condition** comparing to an atom — `if elem(r, 0) ==
    :ok, do: ...` (when body uses `elem(r, _)` too)
  - **`case` discriminator** — `case elem(r, 0) do :ok -> ...
    end` (when any branch uses `elem(r, _)`)

  Both forms are flagged on the OUTER `if` / `case` line. The
  rule deliberately does NOT flag standalone `elem/2` calls in
  app code — metaprogramming, AST manipulation, and similar
  use `elem` legitimately on positional tuples that aren't
  `{:ok, _}` / `{:error, _}` style.

  ## Why severity:medium + advisory

  This is safety-adjacent — `elem/2` raises `ArgumentError` when
  the tuple is too small for the index, so a bad guess can
  crash. But the most common shape is mild misuse (LLM didn't
  reach for pattern matching), not a crashing bug. Advisory
  keeps reviewer attention without gating CI.
  """

  use CredenceRules.Rule

  @severity :medium
  @confidence :high

  @hint """
  Use a `case` (or `with`) that pattern-matches the tuple shape:

      # Before
      if elem(result, 0) == :ok do
        process(elem(result, 1))
      else
        :error
      end

      # After
      case result do
        {:ok, value} -> process(value)
        {:error, _} -> :error
      end

  Pattern matching asserts the shape AND binds the value in one
  step — `elem/2` does neither.

  For `with`-chain shapes:

      with {:ok, body} <- Jason.decode(json),
           {:ok, user} <- build_user(body) do
        {:ok, user}
      end

  Don't replace `elem` with `:erlang.element/2` — same problem,
  Erlang spelling.
  """

  @carve_outs [
    "Genuine positional-tuple manipulation (AST nodes, parser output, multi-element tuples that aren't `{:ok, _}`/`{:error, _}` shaped) — the rule scope is the conditional-context use, not standalone `elem`.",
    "`Tuple.delete_at/2` / `put_elem/3` — index-based operations on tuples where position matters. Not flagged.",
    "Macros / metaprogramming code that inspects AST tuples by position. Standalone `elem` calls outside conditional contexts are not flagged."
  ]

  @impl true
  def priority, do: 486

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        # `if <elem-comparison>, do: <body>` — comparison must be
        # against an atom (the tag). Body must also contain
        # `elem(<same_target>, _)`.
        {:if, meta, [cond, kw]} = node, acc when is_list(kw) ->
          case if_elem_smell?(cond, kw) do
            {:ok, target} ->
              {node, [build_issue(meta, :if, target) | acc]}

            :no ->
              {node, acc}
          end

        # `case elem(<x>, 0/1) do ... end` — case discriminator
        # is an elem call. Flag if any branch uses elem on the
        # same target.
        {:case, meta, [{{:., _, [_, :elem]}, _, _} = elem_call, [do: clauses]]} = node, acc ->
          case extract_elem_target(elem_call) do
            {:ok, target} ->
              if any_clause_uses_elem?(clauses, target),
                do: {node, [build_issue(meta, :case, target) | acc]},
                else: {node, acc}

            :no ->
              {node, acc}
          end

        # Bare `elem(x, 0/1)` form (Kernel.elem/2 without module qualifier)
        {:case, meta, [{:elem, _, _} = elem_call, [do: clauses]]} = node, acc ->
          case extract_elem_target(elem_call) do
            {:ok, target} ->
              if any_clause_uses_elem?(clauses, target),
                do: {node, [build_issue(meta, :case, target) | acc]},
                else: {node, acc}

            :no ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp if_elem_smell?(cond, kw) do
    case extract_elem_compare(cond) do
      {:ok, target} ->
        body = Keyword.get(kw, :do)
        else_body = Keyword.get(kw, :else)

        if body_uses_elem?(body, target) or body_uses_elem?(else_body, target),
          do: {:ok, target},
          else: :no

      :no ->
        :no
    end
  end

  # `elem(x, 0) == :tag` or `:tag == elem(x, 0)` — comparison
  # against an atom. Returns the target var.
  defp extract_elem_compare({op, _, [left, right]}) when op in [:==, :===] do
    cond do
      atom_literal?(right) and elem_call_target(left) -> {:ok, elem_call_target(left)}
      atom_literal?(left) and elem_call_target(right) -> {:ok, elem_call_target(right)}
      true -> :no
    end
  end

  defp extract_elem_compare(_), do: :no

  defp atom_literal?(atom) when is_atom(atom), do: true
  defp atom_literal?({:__block__, _, [atom]}) when is_atom(atom), do: true
  defp atom_literal?(_), do: false

  # Match `elem(<target>, 0)` or `elem(<target>, 1)` — return the target.
  defp elem_call_target({:elem, _, [target, index]}) when is_integer(index) and index in 0..1,
    do: target

  defp elem_call_target({:elem, _, [target, {:__block__, _, [index]}]})
       when is_integer(index) and index in 0..1,
       do: target

  defp elem_call_target(_), do: nil

  defp extract_elem_target({{:., _, [_, :elem]}, _, [target, _]}), do: {:ok, target}
  defp extract_elem_target({:elem, _, [target, _]}), do: {:ok, target}
  defp extract_elem_target(_), do: :no

  defp body_uses_elem?(nil, _target), do: false

  defp body_uses_elem?(body, target) do
    {_, found?} =
      Macro.prewalk(body, false, fn
        _node, true ->
          {[], true}

        {:elem, _, [t, _]} = node, _ ->
          if ast_eq?(t, target), do: {node, true}, else: {node, false}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp any_clause_uses_elem?(clauses, target) when is_list(clauses) do
    Enum.any?(clauses, fn
      {:->, _, [_pattern, body]} -> body_uses_elem?(body, target)
      _ -> false
    end)
  end

  defp any_clause_uses_elem?(_, _), do: false

  defp ast_eq?(a, b) do
    normalize(a) == normalize(b)
  end

  defp normalize(ast) do
    Macro.prewalk(ast, fn node ->
      Macro.update_meta(node, fn _ -> [] end)
    end)
  end

  defp build_issue(meta, form, target) do
    %Issue{
      rule: :tagged_tuple_elem_access,
      message:
        "`#{form}` branches on `elem(#{Macro.to_string(target)}, 0)` and the body " <>
          "reads `elem(#{Macro.to_string(target)}, _)`. Pattern-match the tuple " <>
          "shape with `case ... do {:ok, value} -> ...; {:error, _} -> ... end` " <>
          "instead. `elem/2` doesn't assert the tuple's shape — different-arity " <>
          "tuples silently read the wrong position.",
      meta: %{line: Keyword.get(meta, :line), form: form}
    }
  end
end
