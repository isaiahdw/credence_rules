# credence-file:repeated_case_arm_body — this module is an AST pattern matcher
#   whose check/2 + Macro.prewalk + build_issue shape is the Rule contract
#   itself, so the structural duplication is inherent to the form rather than a
#   smell
defmodule CredenceRules.Pattern.NoGenServerCallbackMissingImpl do
  @moduledoc """
  Idiomatic rule: requires `@impl true` (or `@impl GenServer`) on every
  GenServer callback definition.

  `@impl` lets the compiler warn when:

  - a callback is mistyped (`handle_calll/3`) — without `@impl` the
    function just sits there silently dead;
  - the behaviour drops or renames a callback in a future release — your
    stale callback becomes a regular function and the GenServer falls
    back to the default implementation;
  - the callback signature drifts (e.g. an arity change) — `@impl` makes
    the compiler refuse the build.

  LLMs frequently omit `@impl` because the callback's name + arity alone
  is enough to make the code work *today*. This rule encodes the rule of
  thumb that callbacks are an interface — typed at the module level via
  `@impl`, not by convention.

  ## Detected callbacks

  Anything in the GenServer / GenStateMachine / Supervisor /
  Application / `:gen_event` callback set:

  `init/1`, `handle_call/3`, `handle_cast/2`, `handle_info/2`,
  `handle_continue/2`, `handle_event/4` (gen_statem), `terminate/2`,
  `code_change/3`, `format_status/2`, `start/2` (Application),
  `stop/1` (Application).

  ## Bad

      defmodule Counter do
        use GenServer
        def handle_call(:get, _from, state), do: {:reply, state, state}
      end

  ## Good

      defmodule Counter do
        use GenServer
        @impl true
        def handle_call(:get, _from, state), do: {:reply, state, state}
      end

  ## Why not just rely on the compiler warning?

  The compiler warns on `@impl` *mismatch* (declared but unused), not on
  its absence. Empirically this is the most common omission in
  LLM-generated OTP code, so a lint rule is the right place to enforce
  presence.

  ## Behaviour gate

  Only modules that declare a relevant behaviour are scanned —
  modules with `use GenServer` / `use Supervisor` / `use Application`
  / `use Agent` / `use GenStage` / `@behaviour GenServer` /
  `@behaviour :gen_statem` / `@behaviour :gen_event` / `@behaviour
  Supervisor` / `@behaviour Application`. Ordinary modules that
  happen to define a function called `handle_call/3` (DSLs,
  request routers, custom callback modules) are not flagged.
  """

  use CredenceRules.Rule

  @callback_arities %{
    init: 1,
    handle_call: 3,
    handle_cast: 2,
    handle_info: 2,
    handle_continue: 2,
    handle_event: 4,
    terminate: 2,
    code_change: 3,
    format_status: 2,
    start: 2,
    stop: 1
  }

  @impl true
  def priority, do: 380

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        # Top-level `defmodule Foo do ... end` bodies expose their stmts
        # as either a single statement or a `:__block__` of statements.
        # `__impl_runs__/1` walks one such body, pairing each statement
        # with its predecessor so we can tell if a `def` was preceded by
        # `@impl ...`.
        {:defmodule, _, [_alias, [{:do, body}]]} = node, acc ->
          if behaviour_module?(body),
            do: {node, scan_module_body(body) ++ acc},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  # True if the module body declares one of the OTP-callback-emitting
  # behaviours: `use GenServer` / `use Supervisor` / `use Application`
  # / `use Agent` / `use GenStage`, or `@behaviour Foo` for the same.
  # Without this gate, any plain module with a `handle_call/3`-shaped
  # function (DSLs, request routers, custom callback modules) would
  # get flagged.
  defp behaviour_module?(body) do
    body
    |> top_level_statements()
    |> Enum.any?(&behaviour_declaration?/1)
  end

  defp top_level_statements({:__block__, _, list}), do: list
  defp top_level_statements(single), do: [single]

  defp behaviour_declaration?({:use, _, [arg]}), do: callback_emitting?(arg)
  defp behaviour_declaration?({:use, _, [arg, _opts]}), do: callback_emitting?(arg)

  defp behaviour_declaration?({:@, _, [{:behaviour, _, [arg]}]}),
    do: callback_emitting?(arg)

  defp behaviour_declaration?(_), do: false

  @callback_modules [
    :GenServer,
    :GenStage,
    :GenStateMachine,
    :Supervisor,
    :DynamicSupervisor,
    :Application,
    :Agent,
    :"Task.Supervisor"
  ]

  defp callback_emitting?(arg) do
    case unwrap_block(arg) do
      {:__aliases__, _, [last]} when last in @callback_modules -> true
      {:__aliases__, _, [:Task, :Supervisor]} -> true
      :gen_statem -> true
      :gen_event -> true
      :gen_server -> true
      _ -> false
    end
  end

  defp unwrap_block({:__block__, _, [inner]}), do: inner
  defp unwrap_block(other), do: other

  defp scan_module_body({:__block__, _, stmts}), do: scan_module_body(stmts)

  defp scan_module_body(stmts) when is_list(stmts) do
    # Walk the module body in order. Track which {name, arity} pairs
    # have already had `@impl` declared on a prior clause — subsequent
    # clauses of the same callback don't need their own `@impl` (the
    # idiom is one `@impl` per callback, not per clause). This keeps
    # this rule compatible with Credence's `non_grouped_clauses`, which
    # forbids `@impl` on every clause.
    #
    # `Enum.zip(stmts, [nil | stmts])` yields `[{a, nil}, {b, a}, ...]`,
    # pairing each statement with its predecessor.
    {issues, _seen} =
      stmts
      |> Enum.zip([nil | stmts])
      |> Enum.reduce({[], MapSet.new()}, fn {current, prev}, {issues, seen} ->
        classify_pair(prev, current, seen, issues)
      end)

    Enum.reverse(issues)
  end

  defp scan_module_body(stmt), do: scan_module_body([stmt])

  # `current` is a `def`; either record it as seen-with-impl or emit
  # an issue. Predecessor `prev` may be `@impl ...` or another stmt.
  #
  # Two def shapes to handle:
  #   - `def foo(args), do: body`        — head is `{name, _, args}`
  #   - `def foo(args) when g, do: body` — head is `{:when, _, [{name, _, args}, _guard]}`
  defp classify_pair(prev, {:def, meta, [head, _body]}, seen, issues) do
    case def_name_arity(head) do
      {name, arity} -> classify_def(prev, meta, name, arity, seen, issues)
      :other -> {issues, seen}
    end
  end

  defp classify_pair(_prev, _current, seen, issues), do: {issues, seen}

  defp def_name_arity({:when, _, [{name, _, args}, _guard]})
       when is_atom(name) and is_list(args),
       do: {name, length(args)}

  defp def_name_arity({name, _, args}) when is_atom(name) and is_list(args),
    do: {name, length(args)}

  defp def_name_arity(_), do: :other

  defp classify_def(prev, meta, name, arity, seen, issues) do
    key = {name, arity}

    cond do
      not callback?(name, arity) ->
        {issues, seen}

      impl_attr?(prev) ->
        {issues, MapSet.put(seen, key)}

      MapSet.member?(seen, key) ->
        # Sibling clause of an already-impl'd callback head — fine.
        {issues, seen}

      true ->
        # First clause of an un-impl'd callback. Record it as seen so
        # subsequent sibling clauses don't re-fire — one finding per
        # missing-callback group is enough.
        {[build_issue(meta, name, arity) | issues], MapSet.put(seen, key)}
    end
  end

  defp callback?(name, arity), do: Map.get(@callback_arities, name) == arity

  # `@impl true`, `@impl false`, or `@impl SomeBehaviour`. All three forms
  # parse as `{:@, _, [{:impl, _, [arg]}]}`.
  defp impl_attr?({:@, _, [{:impl, _, _}]}), do: true
  defp impl_attr?(_), do: false

  defp build_issue(meta, name, arity) do
    %Issue{
      rule: :no_genserver_callback_missing_impl,
      message:
        "`def #{name}/#{arity}` looks like a behaviour callback but is missing " <>
          "`@impl true` (or `@impl SomeBehaviour`). Add the annotation so the " <>
          "compiler can warn when the callback is renamed, removed, or its " <>
          "arity changes.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
