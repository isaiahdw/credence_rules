defmodule CredenceRules.Pattern.TruthyGuardNonBoolean do
  @moduledoc """
  Safety rule: a `when` guard must evaluate to the **literal
  boolean `true`** for the clause to match. Truthy non-boolean
  values (atoms, integers, lists, maps) do NOT pass the guard —
  the clause is silently skipped.

  This is one of the most common ways LLMs misapply patterns
  learned from JavaScript / Python / Ruby. In those languages,
  `if value` and `if value != null` are interchangeable. In
  Elixir guards, they're not:

      def handle(value) when value do      # ← BUG: only matches when value === true
        process(value)
      end

  If `value` is `:ok`, `[1, 2]`, `42`, or any non-`true` truthy
  value, the clause is **skipped without warning**. The function
  may raise `FunctionClauseError`, fall through to a less-specific
  clause, or silently misbehave depending on the other clauses.

  From the [Elixir patterns-and-guards docs](https://hexdocs.pm/elixir/patterns-and-guards.html):

  > If an expression evaluates to a non-boolean value (i.e. any
  > value other than `true` or `false`), the entire guard
  > expression fails to match.

  ## Bad

      def handle(value) when value do
        process(value)
      end

      def handle(%{enabled: enabled}) when enabled do
        start()
      end

      def fetch(state) when state.socket do
        :socket.send(state.socket, "hi")
      end

      def lookup(opts) when Map.get(opts, :id) do
        find(Map.get(opts, :id))
      end

  Each guard uses a value as if it were a boolean test. The
  clause matches only when the value is literally `true`.

  ## Good

  Two reliable rewrites:

  **Explicit nil/false rejection in the guard:**

      def handle(value) when value != nil and value != false do
        process(value)
      end

      def fetch(state) when state.socket != nil do
        :socket.send(state.socket, "hi")
      end

  **Pattern-match the boolean directly:**

      def handle(%{enabled: true}) do
        start()
      end

      def handle(%{enabled: false}), do: :disabled

  ## Detection

  Flags `def` / `defp` / `defmacro` / `defmacrop` heads with a
  `when` guard whose guard expression is a **non-boolean shape**:

  - **Bare variable**: `when value`
  - **Dot field access**: `when state.flag`, `when conn.assigns.user`
  - **`Map.get/2,3`**: `when Map.get(opts, :id)` (exact `Map`
    module — `MyApp.Map.get` doesn't match)
  - **`Keyword.get/2,3`**: same
  - **Bracket access**: `when opts[:flag]`

  Compound guards (`when state.flag and is_pid(x)`) are flagged
  on the non-boolean half if it's the leftmost / sole problem —
  conservative detection focuses on the obvious cases. Once a
  guard contains any comparison / boolean predicate / `is_*` /
  `match?` / boolean operator that's the SOLE guard, it's not
  flagged.

  ## What's NOT flagged

  - `when is_atom(value)`, `when is_pid(x)`, etc. — boolean predicates
  - `when value != nil`, `when x > 0` — comparisons
  - `when value in [:a, :b, :c]`, `when n in 1..10` — `in` operator (boolean)
  - `when match?({:ok, _}, result)` — `match?/2` returns boolean
  - `when not is_nil(value)` — explicit nil check
  - `when value === true` — explicit boolean compare
  - Any guard whose top-level operator is a known boolean

  ## Why boundary + severity:high + confidence:high

  This rule catches a real semantic bug — code that compiles
  without warnings but behaves incorrectly at runtime. The
  detection is structural and unambiguous. `--strict` should
  gate on it.
  """

  use CredenceRules.Rule

  @severity :high
  @confidence :high

  @hint """
  Guards require `true` (literally), not truthy. Two fixes:

      # Explicit nil/false rejection
      def handle(value) when value != nil and value != false do
        process(value)
      end

      # Pattern-match the boolean directly
      def handle(%{enabled: true}) do
        start()
      end

      def handle(%{enabled: false}), do: :disabled

  For maps with a field that could be `nil` OR `false` OR a real
  value, use a separate pattern:

      def fetch(%{socket: socket}) when socket != nil and socket != false do
        :socket.send(socket, "hi")
      end
  """

  @carve_outs [
    "Guards using `is_*` predicates (`is_atom`, `is_pid`, `is_binary`, ...) — return boolean. Auto-skipped.",
    "Guards using comparison operators (`>`, `<`, `==`, `===`, `!=`, `!==`, `>=`, `<=`) — return boolean. Auto-skipped.",
    "Guards using `match?/2` — returns boolean. Auto-skipped.",
    "Guards using boolean operators (`and`, `or`, `not`) where ALL operands are themselves boolean expressions. Conservative: a compound guard with a non-boolean operand is still flagged."
  ]

  # Known boolean-returning function names allowed bare in guards.
  # `is_*` are all booleans by convention. Plus explicit boolean
  # functions that exist in the Kernel guard whitelist.
  @boolean_kernel_funs ~w(
    is_atom is_binary is_bitstring is_boolean is_exception
    is_float is_function is_integer is_list is_map
    is_map_key is_nil is_number is_pid is_port is_reference
    is_struct is_tuple
    not and or
  )a

  @boolean_comparison_ops ~w(< > <= >= == === != !==)a

  @impl true
  def priority, do: 485

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        # Match def / defp / defmacro / defmacrop heads with a guard
        {def_kind, _meta, [{:when, when_meta, [head, guard]}, _kw]} = node, acc
        when def_kind in [:def, :defp, :defmacro, :defmacrop] ->
          case non_boolean_problem(guard) do
            nil ->
              {node, acc}

            problem_expr ->
              name = head_name(head)
              {node, [build_issue(when_meta, name, problem_expr) | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  # Returns the offending non-boolean sub-expression, or nil if the
  # guard is fine.
  #
  # Conservative: only inspect the TOP-LEVEL guard expression. If
  # it's a known boolean shape, accept. Otherwise flag.
  defp non_boolean_problem(guard) do
    if boolean_shape?(guard), do: nil, else: extract_non_boolean(guard)
  end

  # Recognize known-boolean guard shapes.
  defp boolean_shape?({op, _, _}) when op in @boolean_comparison_ops, do: true

  # `in` operator — Kernel.in/2 returns boolean. Common in guards:
  # `when level in [:high, :medium, :low]`, `when fun in @list`,
  # `when length(args) in 1..2`.
  defp boolean_shape?({:in, _, _}), do: true

  defp boolean_shape?({:not, _, _}), do: true

  defp boolean_shape?({op, _, [left, right]}) when op in [:and, :or] do
    # Compound is boolean iff BOTH sides are boolean shapes.
    boolean_shape?(left) and boolean_shape?(right)
  end

  defp boolean_shape?({:match?, _, _}), do: true

  defp boolean_shape?({fun, _, _}) when fun in @boolean_kernel_funs, do: true

  # Aliased call: `Kernel.is_nil`, `Module.boolean_check?` — boolean
  # convention. Match trailing `?` suffix and known is_* names.
  defp boolean_shape?({{:., _, [_module, fun]}, _, _args}) when is_atom(fun) do
    name = Atom.to_string(fun)
    fun in @boolean_kernel_funs or String.ends_with?(name, "?")
  end

  # Bare-atom call (e.g., `:erlang.is_pid/1`).
  defp boolean_shape?({{:., _, [:erlang, fun]}, _, _}) when fun in @boolean_kernel_funs, do: true

  defp boolean_shape?(true), do: true
  defp boolean_shape?(false), do: true

  defp boolean_shape?(_), do: false

  # Pick the offending sub-expression for the message.
  # For compound `and`/`or`, return the non-boolean half.
  defp extract_non_boolean({op, _, [left, right]}) when op in [:and, :or] do
    cond do
      not boolean_shape?(left) -> left
      not boolean_shape?(right) -> right
      true -> nil
    end
  end

  defp extract_non_boolean(other), do: other

  defp head_name({:when, _, [inner, _]}), do: head_name(inner)
  defp head_name({name, _, _}) when is_atom(name), do: name
  defp head_name(_), do: :unknown

  defp build_issue(meta, name, problem_expr) do
    %Issue{
      rule: :truthy_guard_non_boolean,
      message:
        "`def #{name}(...) when #{Macro.to_string(problem_expr)}` — guards require " <>
          "the literal boolean `true`, not just truthy. If `#{Macro.to_string(problem_expr)}` " <>
          "is anything other than `true` or `false`, this clause is SILENTLY skipped. " <>
          "Use `when #{Macro.to_string(problem_expr)} != nil and #{Macro.to_string(problem_expr)} != false` " <>
          "or pattern-match the boolean directly in the head.",
      meta: %{line: Keyword.get(meta, :line), function: name}
    }
  end
end
