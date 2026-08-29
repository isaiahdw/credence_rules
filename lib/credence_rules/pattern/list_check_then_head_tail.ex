# credence-file:iosp_mixed_function,repeated_subtree_in_function — this module
#   is an AST pattern matcher whose check/2 + Macro.prewalk + build_issue shape
#   is the Rule contract itself, so the structural duplication is inherent to
#   the form rather than a smell
defmodule CredenceRules.Pattern.ListCheckThenHeadTail do
  @moduledoc """
  Idiom rule: code that checks "is this list non-empty?" then
  reaches for `hd/1`, `tl/1`, `List.first/1`, or `Enum.at(list,
  0)` is doing in two steps what `[head | tail]` pattern matching
  does in one — and with better error messages.

  ## Bad

      if length(items) > 0 do
        process(hd(items), tl(items))
      end

      if items != [] do
        first = List.first(items)
        # ...
      end

      if not Enum.empty?(items) do
        Enum.at(items, 0)
      end

  Two operations: emptiness check, then "trust me, just grab the
  head." `hd([])` and `tl([])` both raise `ArgumentError` if you
  miss the guard. Pattern matching does both jobs in one step
  with a `MatchError` that names the offending value.

  ## Good

      case items do
        [head | tail] -> process(head, tail)
        [] -> nil
      end

      case items do
        [first | _] -> use(first)
        [] -> nil
      end

  Or in function heads:

      defp handle([head | tail]), do: process(head, tail)
      defp handle([]), do: nil

  ## Why pattern matching is better

  - **Asserts the shape** instead of trusting it
  - **Binds in one step** — no separate `hd`/`tl` calls
  - **Better error**: `MatchError` names the value; `hd([])`
    raises a generic `ArgumentError`
  - **Faster**: pattern match compiles to a single decision tree
  - **Self-documenting**: `[head | tail]` says "non-empty list"

  ## Detection

  Flags `if <emptiness check>, do: <body with head/tail access>`
  where:

  **Emptiness check** is any of:
  - `length(<x>) > 0` or `length(<x>) >= 1`
  - `<x> != []` or `[] != <x>`
  - `not Enum.empty?(<x>)` or `Enum.empty?(<x>) == false`

  **Body access** is any of (on the same list):
  - `hd(<x>)` or `tl(<x>)`
  - `List.first(<x>)` or `List.last(<x>)`
  - `Enum.at(<x>, 0)`

  Strict length comparison ONLY — `length(<x>) > 5` is a real
  threshold check, not a non-empty check. Same for ranges.

  ## NOT flagged

  - Non-emptiness check without subsequent access — pure
    predicate use, no extraction smell.
  - `length(<x>) > N` where N ≥ 1 — that's a real threshold, not
    a non-empty check.
  - `hd(<x>)` / `tl(<x>)` in standalone code without the
    preceding emptiness check — separate concern (use pattern
    matching), but not this rule's scope.
  """

  use CredenceRules.Rule

  @severity :medium
  @confidence :high

  @hint """
  Replace the check + extraction with a pattern match:

      # Before
      if length(items) > 0 do
        process(hd(items), tl(items))
      end

      # After
      case items do
        [head | tail] -> process(head, tail)
        [] -> nil
      end

      # Or as function heads
      defp handle([head | tail]), do: process(head, tail)
      defp handle([]), do: nil

  `MatchError` names the value at the failure point; `hd([])` /
  `tl([])` raise a generic `ArgumentError`.

  For first-only access: `[first | _] -> use(first)`.
  For last-only: pattern matching can't grab the last element of
  an arbitrary-length list — `List.last/1` is fine when you
  genuinely need it; the smell is the GUARDED form, not the
  call itself.
  """

  @carve_outs [
    "`length(x) > N` where N >= 1 — real threshold check, not non-empty. Not flagged.",
    "Standalone `hd(x)` / `tl(x)` calls without a preceding emptiness check — different smell (just use pattern matching), out of this rule's scope.",
    "`List.last(list)` when you genuinely need the last element — pattern matching can't grab the tail's last element from an arbitrary list. The smell flagged here is the GUARDED form."
  ]

  @impl true
  def priority, do: 489

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:if, meta, [cond, kw]} = node, acc when is_list(kw) ->
          case extract_non_empty_check(cond) do
            {:ok, list_expr} ->
              body = Keyword.get(kw, :do)

              if body_uses_head_tail?(body, list_expr),
                do: {node, [build_issue(meta, list_expr) | acc]},
                else: {node, acc}

            :no ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  # `length(x) > 0` / `length(x) >= 1`
  defp extract_non_empty_check({:>, _, [{:length, _, [x]}, 0]}), do: {:ok, x}
  defp extract_non_empty_check({:>=, _, [{:length, _, [x]}, 1]}), do: {:ok, x}

  # `x != []` / `[] != x`
  defp extract_non_empty_check({:!=, _, [x, []]}), do: {:ok, x}
  defp extract_non_empty_check({:!=, _, [[], x]}), do: {:ok, x}

  # `not Enum.empty?(x)`
  defp extract_non_empty_check({:not, _, [{{:., _, [{:__aliases__, _, [:Enum]}, :empty?]}, _, [x]}]}),
    do: {:ok, x}

  # `Enum.empty?(x) == false`
  defp extract_non_empty_check({:==, _, [{{:., _, [{:__aliases__, _, [:Enum]}, :empty?]}, _, [x]}, false]}),
    do: {:ok, x}

  defp extract_non_empty_check(_), do: :no

  defp body_uses_head_tail?(nil, _list_expr), do: false

  defp body_uses_head_tail?(body, list_expr) do
    normalized = normalize(list_expr)

    {_, found?} =
      Macro.prewalk(body, false, fn
        _node, true ->
          {[], true}

        # hd(list) / tl(list)
        {fun, _, [target]} = node, _ when fun in [:hd, :tl] ->
          if same?(target, normalized), do: {node, true}, else: {node, false}

        # List.first(list) / List.last(list)
        {{:., _, [{:__aliases__, _, [:List]}, fun]}, _, [target | _]} = node, _
        when fun in [:first, :last] ->
          if same?(target, normalized), do: {node, true}, else: {node, false}

        # Enum.at(list, 0)
        {{:., _, [{:__aliases__, _, [:Enum]}, :at]}, _, [target, 0 | _]} = node, _ ->
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

  defp build_issue(meta, list_expr) do
    %Issue{
      rule: :list_check_then_head_tail,
      message:
        "Non-emptiness check on `#{Macro.to_string(list_expr)}` followed by " <>
          "`hd`/`tl`/`List.first`/`List.last`/`Enum.at(_, 0)`. Pattern-match " <>
          "the list shape: `case #{Macro.to_string(list_expr)} do [head | tail] " <>
          "-> ...; [] -> ... end`. Better error message on shape mismatch and " <>
          "compiles to a single decision tree.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
