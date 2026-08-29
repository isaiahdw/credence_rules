# credence-file:iosp_mixed_function — this module is an AST pattern matcher
#   whose check/2 + Macro.prewalk + build_issue shape is the Rule contract
#   itself, so the structural duplication is inherent to the form rather than a
#   smell
defmodule CredenceRules.Pattern.NilCheckElseUsesValue do
  @moduledoc """
  Idiom rule: explicit nil checks (`if is_nil(x)`, `if x == nil`,
  `if x != nil`) followed by a branch that uses `x` as a value
  is the verbose form of pattern matching.

  Sibling of `truthy_access_reused_in_body`, which catches the
  implicit shape (`if x, do: use(x)`). This rule covers the
  explicit-nil-check shape.

  ## Bad

      if is_nil(socket) do
        nil
      else
        :socket.close(socket)
      end

      if user.email != nil do
        send_email(user.email)
      end

      if not is_nil(value) do
        process(value)
      end

  ## Good

      case socket do
        nil -> nil
        socket -> :socket.close(socket)
      end

  Or as a helper with pattern-matched clauses:

      defp close_socket(nil), do: nil
      defp close_socket(socket), do: :socket.close(socket)

  ## Why this is cleaner than the truthy form

  `is_nil/1` is explicit — there's no `false` ambiguity. The
  truthy `if x, do: use(x)` form has to preserve `false` clauses
  in its rewrite (`if x` treats both `nil` AND `false` as
  falsey). `is_nil` only checks `nil`, so the rewrite is exactly:

      case x do
        nil -> ...
        x -> ...
      end

  No `false` clause needed.

  ## Detection

  Flags `if <nil-check>, do: <body>` (with or without else) when
  the body USES the same value:

  Nil checks recognized:
  - `is_nil(<x>)`
  - `<x> == nil` / `nil == <x>`
  - `<x> === nil` / `nil === <x>`
  - `<x> != nil` / `nil != <x>` (negated form — body in `do:` uses x)
  - `<x> !== nil` / `nil !== <x>`
  - `not is_nil(<x>)`

  Value uses recognized (in body):
  - `<x>.field` (dot access)
  - `<x>[key]` (bracket access)
  - `<x>` as an argument to any function call

  Structural comparison after metadata strip — same `x` at
  different lines matches.

  ## NOT flagged

  - Body that doesn't use `x` — pure nil check, no smell.
  - `if x == nil` where body uses `x` only inside the nil branch
    (returning a default that doesn't reference `x`).
  - Already-using `case` / function-head — that's the target shape.
  """

  use CredenceRules.Rule

  @severity :medium
  @confidence :high

  @hint """
  Replace the explicit nil check with `case` or pattern-matched
  helper clauses:

      # Before
      if is_nil(socket) do
        nil
      else
        :socket.close(socket)
      end

      # After
      case socket do
        nil -> nil
        socket -> :socket.close(socket)
      end

  Or, for repeated operations:

      defp close_socket(nil), do: nil
      defp close_socket(socket), do: :socket.close(socket)

  Note: `is_nil/1` is explicit about nil — unlike the truthy
  `if x, do: use(x)` form, no `false` clause is needed in the
  rewrite. `is_nil(false)` is `false`, so the original takes
  the `else` branch when `x` is `false`; the rewritten `case`
  does too (matches the second clause via the catch-all `x`).
  """

  @carve_outs [
    "Body that doesn't use the checked value (pure nil predicate test) — not flagged.",
    "Truthy form (`if x, do: use(x)`) — owned by `truthy_access_reused_in_body`. This rule scopes to EXPLICIT nil checks.",
    "Nil check that's part of a larger boolean expression (`if is_nil(x) and is_pid(y)`) — too compound to confidently rewrite; not flagged."
  ]

  @impl true
  def priority, do: 491

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:if, meta, [cond, kw]} = node, acc when is_list(kw) ->
          case extract_nil_check(cond) do
            {:ok, value_expr, polarity} ->
              # polarity: :nil_branch_first when condition is "is_nil(x)" or "x == nil"
              # polarity: :value_branch_first when condition is "not is_nil(x)" or "x != nil"
              body = Keyword.get(kw, :do)
              else_body = Keyword.get(kw, :else)

              # The "value branch" is the one that uses x.
              value_branch =
                case polarity do
                  :nil_branch_first -> else_body
                  :value_branch_first -> body
                end

              if body_uses_value?(value_branch, value_expr),
                do: {node, [build_issue(meta, value_expr) | acc]},
                else: {node, acc}

            :no ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  # `is_nil(x)` — nil-branch first (do: nil case, else: value case)
  defp extract_nil_check({:is_nil, _, [x]}), do: {:ok, x, :nil_branch_first}

  # `not is_nil(x)` — value-branch first
  defp extract_nil_check({:not, _, [{:is_nil, _, [x]}]}),
    do: {:ok, x, :value_branch_first}

  # `x == nil` / `x === nil` / `nil == x` / `nil === x`
  defp extract_nil_check({op, _, [x, nil]}) when op in [:==, :===],
    do: {:ok, x, :nil_branch_first}

  defp extract_nil_check({op, _, [nil, x]}) when op in [:==, :===],
    do: {:ok, x, :nil_branch_first}

  # `x != nil` / `x !== nil` / `nil != x` / `nil !== x`
  defp extract_nil_check({op, _, [x, nil]}) when op in [:!=, :!==],
    do: {:ok, x, :value_branch_first}

  defp extract_nil_check({op, _, [nil, x]}) when op in [:!=, :!==],
    do: {:ok, x, :value_branch_first}

  defp extract_nil_check(_), do: :no

  defp body_uses_value?(nil, _expr), do: false

  defp body_uses_value?(body, expr) do
    normalized = normalize(expr)

    {_, found?} =
      Macro.prewalk(body, false, fn
        _node, true ->
          {[], true}

        # Direct reference: matches `expr` anywhere in the body's args.
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

  defp build_issue(meta, expr) do
    %Issue{
      rule: :nil_check_else_uses_value,
      message:
        "`if <nil-check on #{Macro.to_string(expr)}>, do: ..., else: ...` where the " <>
          "non-nil branch uses `#{Macro.to_string(expr)}` — rewrite as " <>
          "`case #{Macro.to_string(expr)} do nil -> ...; value -> ... end` or " <>
          "extract to a helper with pattern-matched clauses. `is_nil/1` is " <>
          "explicit (no `false` ambiguity), so the rewrite needs no extra clauses.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
