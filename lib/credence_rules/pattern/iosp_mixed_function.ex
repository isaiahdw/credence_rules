defmodule CredenceRules.Pattern.IospMixedFunction do
  @moduledoc """
  Architecture rule: Integration / Operation Segregation Principle
  (Ralf Westphal's Flow Design). Every function should be either an
  **Integration** (calls other functions, contains no logic of its
  own) or an **Operation** (contains logic, calls no other functions
  — just stdlib / Kernel). Never both in one body.

  The failure mode it catches is the "do-everything" function: fetch
  + validate + transform + decide + persist + format, all in one
  40-line body that mixes 6 helper calls with 4 `case` branches and
  3 `if`s. Readers can't trace what the function actually does
  without holding all the helpers in their head — and changes to one
  branch ripple through the dispatch logic.

  ## Bad

      def commission_device(device, opts) do
        case fetch_credentials(device) do
          {:ok, creds} ->
            if validate(creds) do
              encrypted = encrypt(creds, opts)

              case persist(device.id, encrypted) do
                {:ok, _} -> format_result(device, :ok)
                {:error, e} -> format_result(device, {:error, e})
              end
            else
              format_result(device, {:error, :invalid_creds})
            end

          {:error, e} ->
            format_result(device, {:error, e})
        end
      end

  Six helper calls. Three `case`/`if` constructs. The function is
  doing both orchestration AND business logic.

  ## Good — Integration

      def commission_device(device, opts) do
        with {:ok, creds} <- fetch_credentials(device),
             :ok <- ensure_valid(creds),
             encrypted = encrypt(creds, opts),
             {:ok, _} <- persist(device.id, encrypted) do
          format_result(device, :ok)
        else
          {:error, e} -> format_result(device, {:error, e})
        end
      end

  `with` chains the calls but has no logic of its own — every step
  is a function call. The `else` is also Integration (no logic
  beyond shape-matching).

  ## Detection

  Flags a `def` / `defp` body when ALL of:

  1. It contains at least 3 **user-fn calls** (calls into modules
     starting with a capital letter — `Foo.bar(...)`, `MyMod.f(...)`).
     Kernel / stdlib calls and local same-module calls don't count.
  2. It contains at least 3 **control-flow constructs** (`if`,
     `unless`, `case`, `cond`). `with` is excluded — it's the
     canonical Integration shape.
  3. The body has at least `:iosp_min_nodes` (default 20) AST nodes,
     so 2-line functions don't fire.
  4. Its **effective control-flow nesting depth** is at least 2 — the
     control-flow is genuinely *nested*, not just a long sequence of
     siblings. The smell is orchestration hidden inside nested
     branching; a flat protocol parser (one top-level `case` whose
     arms run the steps linearly) and a sequential `init/1` (ten
     setup steps, no nesting) pile up control-flow count without
     nesting, and reading them top-to-bottom IS the right shape.

  The effective depth treats a body that *is* a single `case` / `cond`
  / `if` as an integration dispatch: that outermost construct doesn't
  count toward the depth, only branching within its arms does. So
  `case decode(x) do {:ok, e} -> …decrypt…case…verify… end` (one
  dispatch wrapping linear steps, with one nested `case`) has
  effective depth 1 and is spared, while `case fetch(x) do {:ok, c} ->
  if valid?(c), do: …case persist… end` (dispatch → `if` → `case`)
  has effective depth 2 and fires. `with` and `try` never add depth.

  ## Why advisory

  Phoenix contexts violate IOSP constantly by design: many context
  functions legitimately mix `Repo.insert/2` (user-fn call) with a
  `case` on the result and an `if` for some derived rule. The rule
  catches the *severe* cases (`>= 3` of each in one body); it's a
  reviewer hint to ask "is this trying to do too much?" rather than
  a hard architectural cap. Initial defaults of 2+2 surfaced clean
  focused functions (e.g. two `Map.get` lookups in two `case`
  arms) — raised to 3+3 to target the genuine "do-everything"
  shape.

  Tunable thresholds via opts: `:iosp_min_user_calls` (default 3),
  `:iosp_min_control_flow` (default 3), `:iosp_min_nodes` (default 20),
  `:iosp_min_nesting_depth` (default 2). Set the nesting depth to 1 to
  restore the count-only behaviour.

  ## Mix tasks

  All defs inside `defmodule Mix.Tasks.* do … end` are skipped.
  Mix tasks ARE orchestration + I/O + a bit of inline logic;
  that's their shape, not a smell.
  """

  use CredenceRules.Rule

  alias CredenceRules.{AstKeyword, AstNormalize, IospExemptions}

  @hint """
  Pick a side: Integration OR Operation.

  Integration shape — use `with` to chain the calls, no inline logic:

      def commission_device(device, opts) do
        with {:ok, creds} <- fetch_credentials(device),
             :ok <- ensure_valid(creds),
             encrypted = encrypt(creds, opts),
             {:ok, _} <- persist(device.id, encrypted) do
          format_result(device, :ok)
        else
          {:error, e} -> format_result(device, {:error, e})
        end
      end

  Each step is a function call; the `with` chain documents the
  flow without adding logic of its own.

  Operation shape — pure logic, no user-fn calls. Extract the
  helpers each `case`/`if` branch needs into named functions and
  call them from the Integration above.

  The split: orchestration goes in the public function; per-step
  logic goes in private helpers the integration composes.
  """

  @carve_outs [
    "Phoenix context functions: many legitimately mix Repo.insert/2 (user-fn call) with a case on the result and an if for some derived rule. Rule's defaults (>= 3 calls + >= 3 control-flow + >= 20 nodes) target the severe cases.",
    "Inside Mix.Tasks.* modules — orchestration + I/O + a bit of inline logic IS the shape. Auto-skipped.",
    "Flat protocol parsers and sequential init/setup: a single top-level case/with whose arms run steps linearly, or a sequence of setup steps with no nested branching, reads top-to-bottom as the steps. Spared by the effective-nesting-depth gate (default 2); the smell needs control-flow nested inside other control-flow.",
    "Confidence is :medium — heuristic counts. Reviewer: does this body actually do too many concerns, or is the count just structural noise (deep nested case for a small protocol decode)?"
  ]

  @default_min_user_calls 3
  @default_min_control_flow 3
  @default_min_nodes 20
  @default_min_nesting_depth 2

  @control_flow [:if, :unless, :case, :cond]

  @impl true
  def priority, do: 440

  @impl true
  def check(ast, opts) do
    thresholds = %{
      calls: Keyword.get(opts, :iosp_min_user_calls, @default_min_user_calls),
      cf: Keyword.get(opts, :iosp_min_control_flow, @default_min_control_flow),
      nodes: Keyword.get(opts, :iosp_min_nodes, @default_min_nodes),
      nesting: Keyword.get(opts, :iosp_min_nesting_depth, @default_min_nesting_depth)
    }

    if IospExemptions.mix_task_module?(ast) do
      # Mix tasks are CLI entry points — orchestration + I/O + a
      # bit of inline logic is their shape, not a smell.
      []
    else
      collect_findings(ast, thresholds)
    end
  end

  defp collect_findings(ast, thresholds) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {kind, meta, [_head, kw]} = node, acc when kind in [:def, :defp] and is_list(kw) ->
          case AstKeyword.get(kw, :do) do
            nil ->
              {node, acc}

            body ->
              if mixed?(body, thresholds),
                do: {node, [build_issue(meta, body) | acc]},
                else: {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp mixed?(body, thresholds) do
    AstNormalize.count_nodes(body) >= thresholds.nodes and mixed_signals?(body, thresholds)
  end

  defp mixed_signals?(body, thresholds) do
    {user_calls, control_flow} = analyse(body)

    user_calls >= thresholds.calls and
      control_flow >= thresholds.cf and
      effective_nesting_depth(body) >= thresholds.nesting
  end

  # Walk the body counting user-fn calls and control-flow constructs.
  defp analyse(body) do
    {_ast, {calls, cf}} =
      Macro.prewalk(body, {0, 0}, fn
        # `Foo.bar(args)` — uppercase-aliased remote call.
        {{:., _, [{:__aliases__, _, _segs}, fun]}, _, args} = node, {c, f}
        when is_atom(fun) and is_list(args) ->
          {node, {c + 1, f}}

        # `:foo.bar(args)` — erlang module remote calls don't count as
        # "user function" — they're stdlib equivalents.

        # Control-flow constructs. `with` excluded by design — it's
        # the canonical Integration syntax.
        {form, _, _} = node, {c, f} when form in @control_flow ->
          {node, {c, f + 1}}

        node, acc ->
          {node, acc}
      end)

    {calls, cf}
  end

  # The IOSP smell is orchestration *hidden inside nested branching* —
  # the genuine catches were 4–5 control-flow levels deep. A flat
  # protocol parser (`case decode(...) do {:ok, x} -> …decrypt…
  # …verify… end`) reads top-to-bottom as the steps, and a sequential
  # `init/1` that sets up ten things with no nesting is a linear
  # script. Both pile up control-flow *count* without nesting, so a
  # count-only gate over-fires on them.
  #
  # Effective nesting depth = the deepest chain of nested `if`/`unless`/
  # `case`/`cond`. When the whole body is a single such construct, that
  # outermost one is the integration dispatch (not branching logic), so
  # it doesn't count toward the depth — only branching *within* its
  # arms does. `with` and `try` are transparent: neither is branching.
  defp effective_nesting_depth(body) do
    depth = max_cf_depth(body, 0)

    if single_control_flow_body?(body), do: max(depth - 1, 0), else: depth
  end

  defp max_cf_depth({form, _meta, args}, level) when form in @control_flow and is_list(args) do
    next = level + 1
    max(next, children_max(args, next))
  end

  defp max_cf_depth({form, _meta, args}, level) when is_atom(form) and is_atom(args) do
    level
  end

  defp max_cf_depth({form, _meta, args}, level) when is_list(args) do
    max(max_cf_depth(form, level), children_max(args, level))
  end

  defp max_cf_depth({left, right}, level) do
    max(max_cf_depth(left, level), max_cf_depth(right, level))
  end

  defp max_cf_depth(list, level) when is_list(list), do: children_max(list, level)
  defp max_cf_depth(_leaf, level), do: level

  defp children_max(list, level) do
    Enum.max([level | Enum.map(list, &max_cf_depth(&1, level))])
  end

  defp single_control_flow_body?(body) do
    match?([{form, _meta, _args}] when form in @control_flow, top_level_statements(body))
  end

  defp top_level_statements({:__block__, _meta, stmts}) when is_list(stmts), do: stmts
  defp top_level_statements(other), do: [other]

  defp build_issue(meta, body) do
    {calls, cf} = analyse(body)

    %Issue{
      rule: :iosp_mixed_function,
      message:
        "Function mixes Integration and Operation (#{calls} user-fn calls + #{cf} " <>
          "control-flow constructs). IOSP: a function should either *orchestrate* " <>
          "other functions (no logic of its own — use `with` for the chain) OR " <>
          "*do the logic* (no further user-fn calls). Split the orchestration into " <>
          "one function and the logic into separate helpers.",
      meta: %{line: Keyword.get(meta, :line), user_calls: calls, control_flow: cf}
    }
  end
end
