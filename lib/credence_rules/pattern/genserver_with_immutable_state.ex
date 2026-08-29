defmodule CredenceRules.Pattern.GenServerWithImmutableState do
  @moduledoc """
  Idiomatic rule: targets the "calculator wrapped in a GenServer"
  pattern — a module that `use GenServer` but never mutates state and
  doesn't own a runtime resource.

  This is one signature of "I came from OOP" thinking: the GenServer
  wraps stateless logic the way a class wraps methods. But processes
  in Elixir can be justified by any of several runtime roles, per
  the official
  [process anti-pattern docs](https://hexdocs.pm/elixir/process-anti-patterns.html):

  - mutable state
  - concurrent execution
  - fault isolation
  - shared-resource ownership (an ETS table, a port, a file handle)
  - ordered access serialization

  The rule narrowly fires when **none** of these obvious signals are
  present: every callback returns the same `state` it received, no
  callback mutates state, AND the module doesn't own an ETS table
  (`:ets.new/_` calls inside the module are taken as evidence of
  ownership and skip the rule).

  Even with the skip, the rule is conservative: a process whose role
  is purely "fault isolation" or "ordered access" will still fire,
  because those aren't statically detectable. The rule is best read
  as a "have a second look" prompt, not a hard error.

  ## Heuristic

  Within a `defmodule` that calls `use GenServer` (or `use GenStage`,
  `use ConsumerSupervisor`, etc.), examine every `handle_call/3`,
  `handle_cast/2`, `handle_info/2`, `handle_continue/2`, and the
  return value of `init/1`. The module is flagged when **all** of:

  - every handle_X return tuple's state slot is the exact same
    variable name as the state argument (e.g. `{:reply, x, state}`
    where the head was `(_, _, state)`), AND
  - no handler body contains a state-mutation form: `%{state | _}`,
    `Map.put(state, _, _)`, `Map.update(state, ...)`, `update_in`,
    `put_in`, or a local rebind of `state = …`.

  Either signal alone would over-fire; together they catch genuine
  process-as-namespace patterns.

  ## Bad

      defmodule Cache do
        use GenServer

        def init(_), do: {:ok, %{}}
        def handle_call({:get, k}, _from, state), do: {:reply, Map.get(state, k), state}
        # ...no callback ever puts into state. This is `Map.get/2` with extra steps.
      end

  ## Good — actually mutates state

      defmodule Cache do
        use GenServer
        def init(_), do: {:ok, %{}}
        def handle_call({:get, k}, _from, state), do: {:reply, Map.get(state, k), state}
        def handle_cast({:put, k, v}, state), do: {:noreply, Map.put(state, k, v)}
      end

  ## Good — not a GenServer

      defmodule Cache do
        def get(map, k), do: Map.get(map, k)
        def put(map, k, v), do: Map.put(map, k, v)
      end
  """

  use CredenceRules.Rule

  @callbacks_with_state %{
    handle_call: 3,
    handle_cast: 2,
    handle_info: 2,
    handle_continue: 2
  }

  @impl true
  def priority, do: 470

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [_alias, [{:do, body}]]} = node, acc ->
          case scan_module(body) do
            {:flag, meta, module} -> {node, [build_issue(meta, module) | acc]}
            :ok -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp scan_module(body) do
    stmts = stmt_list(body)

    case find_use_genserver(stmts) do
      nil ->
        :ok

      use_meta ->
        if ets_owner?(body) do
          # GenServer is legitimately playing the "ETS table owner" role.
          # The body's `state` map is often empty or near-empty because
          # the actual mutable state lives in the ETS table, which is
          # destroyed if its owner exits. Skip the rule for these.
          :ok
        else
          callbacks = collect_callbacks(stmts)

          cond do
            callbacks == [] ->
              :ok

            Enum.all?(callbacks, &state_passthrough?/1) and
                not Enum.any?(callbacks, &mutates_state?/1) ->
              {:flag, use_meta, "this GenServer"}

            true ->
              :ok
          end
        end
    end
  end

  # True if the module's body calls `:ets.new/_` anywhere. ETS ownership
  # is a runtime-role justification for the process (per Elixir's
  # [process anti-pattern docs](https://hexdocs.pm/elixir/process-anti-patterns.html)) —
  # processes are justified by mutable state OR concurrency OR fault
  # isolation OR shared-resource ownership. This rule narrowly catches
  # the "calculator wrapped in a GenServer" case; ETS owners get a pass.
  defp ets_owner?(body) do
    {_ast, found?} =
      Macro.prewalk(body, false, fn
        _node, true ->
          {[], true}

        {{:., _, [:ets, :new]}, _, _} = node, _ ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp stmt_list({:__block__, _, stmts}), do: stmts
  defp stmt_list(stmt), do: [stmt]

  # Returns the meta of a `use GenServer` (or related behaviour) call.
  defp find_use_genserver(stmts) do
    Enum.find_value(stmts, fn
      {:use, meta, [{:__aliases__, _, [behaviour]}]} when behaviour in [:GenServer] ->
        meta

      {:use, meta, [{:__aliases__, _, [behaviour]}, _opts]} when behaviour in [:GenServer] ->
        meta

      _ ->
        nil
    end)
  end

  # Collects all `handle_X` defs as `{state_arg_name, body}` tuples.
  defp collect_callbacks(stmts) do
    Enum.flat_map(stmts, fn
      {kind, _, [head, [{:do, body}]]} when kind in [:def, :defp] ->
        case extract_callback(head) do
          {:ok, state_arg} -> [{state_arg, body}]
          :no -> []
        end

      _ ->
        []
    end)
  end

  defp extract_callback({:when, _, [inner, _guard]}), do: extract_callback(inner)

  defp extract_callback({name, _, args}) when is_atom(name) and is_list(args) do
    expected = Map.get(@callbacks_with_state, name)

    cond do
      is_nil(expected) ->
        :no

      expected != length(args) ->
        :no

      true ->
        # State is always the LAST positional arg in the callbacks we track.
        case List.last(args) do
          {state_name, _, ctx} when is_atom(state_name) and is_atom(ctx) ->
            {:ok, state_name}

          _ ->
            :no
        end
    end
  end

  defp extract_callback(_), do: :no

  # True if every return-tuple in the body uses `state_arg` literally in
  # the state slot. Conservative: any return whose state slot isn't a
  # bare `^state_arg` variable counts as "mutated" (so the rule doesn't
  # fire). We're looking for the smoking gun: `{:reply, _, state}`
  # everywhere, where `state` is the same name as the arg.
  defp state_passthrough?({state_arg, body}) do
    returns = collect_returns(body)

    # No returns matched? Don't flag — likely a delegate or complex flow.
    returns != [] and Enum.all?(returns, &same_var?(&1, state_arg))
  end

  # Walks the body collecting the state slot of every `{:reply, _, S}` /
  # `{:noreply, S}` / `{:noreply, S, _}` / `{:stop, _, S}` / `{:stop, _, _, S}`
  # tuple literal in tail position. Tail position is approximated as any
  # tuple that's not the value of a binding.
  defp collect_returns(body) do
    {_ast, returns} =
      Macro.prewalk(body, [], fn
        {:{}, _, [:reply, _reply, state | _]} = node, acc -> {node, [state | acc]}
        {:reply, _reply, state} = node, acc -> {node, [state | acc]}
        # 2-tuple returns are parsed as bare tuples (not via :{} ).
        {:noreply, state} = node, acc -> {node, [state | acc]}
        # 3-tuple {:noreply, state, _} and similar parse as :{} 3-element tuples.
        {:{}, _, [:noreply, state, _]} = node, acc -> {node, [state | acc]}
        {:{}, _, [:stop, _, state]} = node, acc -> {node, [state | acc]}
        {:{}, _, [:stop, _, _reply, state]} = node, acc -> {node, [state | acc]}
        node, acc -> {node, acc}
      end)

    returns
  end

  defp same_var?({name, _, ctx}, name) when is_atom(name) and is_atom(ctx), do: true
  defp same_var?(_, _), do: false

  # True if the body contains any obvious state-mutation idiom.
  defp mutates_state?({state_arg, body}) do
    body
    |> Macro.prewalk(false, fn
      _node, true ->
        {[], true}

      # `%{state | k: v}` — update syntax.
      {:%{}, _, [{:|, _, [{^state_arg, _, _}, _]}]} = node, _ ->
        {node, true}

      # `Map.put(state, _, _)`, `Map.update(state, …)`, `Map.delete(state, _)`,
      # `Map.merge(state, _)`, `Map.replace(state, _, _)`.
      {{:., _, [{:__aliases__, _, [:Map]}, fun]}, _, [{^state_arg, _, _} | _]} = node, _
      when fun in [:put, :update, :update!, :delete, :merge, :replace, :replace!, :pop] ->
        {node, true}

      # `put_in(state.x, _)`, `update_in(state.x, _)`, `pop_in(state.x)`.
      {fn_name, _, [{{:., _, [{^state_arg, _, _}, _]}, _, _} | _]} = node, _
      when fn_name in [:put_in, :update_in, :pop_in, :get_and_update_in] ->
        {node, true}

      # `state = …` rebind — covers `Map.put` returning a value bound to state.
      {:=, _, [{^state_arg, _, _}, _rhs]} = node, _ ->
        {node, true}

      node, found ->
        {node, found}
    end)
    |> elem(1)
  end

  defp build_issue(meta, _module) do
    %Issue{
      rule: :genserver_with_immutable_state,
      message:
        "This module `use GenServer` but every callback returns the same " <>
          "state it received and no handler mutates state via `%{state | …}` " <>
          "/ `Map.put(state, …)` / rebind. A GenServer that doesn't manage " <>
          "mutable state is process-as-namespace — use plain functions on a " <>
          "struct, or remove the `use GenServer`.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
