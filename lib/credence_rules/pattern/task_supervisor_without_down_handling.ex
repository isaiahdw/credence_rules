# credence-file:iosp_mixed_function,repeated_subtree_in_module — this module is
#   an AST pattern matcher whose check/2 + Macro.prewalk + build_issue shape is
#   the Rule contract itself, so the structural duplication is inherent to the
#   form rather than a smell
defmodule CredenceRules.Pattern.TaskSupervisorWithoutDownHandling do
  @moduledoc """
  Boundary rule: `Task.Supervisor.async_nolink/2,3` inside a GenServer
  module requires `handle_info/2` clauses for both the success message
  (`{ref, result}`) and the failure message (`{:DOWN, ref, :process,
  _, reason}`). Without them, the messages pile up unhandled in the
  mailbox.

  `Task.Supervisor.async_nolink/3` is the explicit "spawn work, get
  notified" pattern. The Task contract:

  - Success: the parent receives `{ref, result}` where `ref` is the
    `%Task{}.ref`.
  - Failure: the parent receives `{:DOWN, ref, :process, _, reason}`
    via the monitor.

  Both arrive in the parent's mailbox via `handle_info/2`. If you
  handle only success, a crashing task leaks a `:DOWN` message
  forever. If you handle only `:DOWN`, every successful task leaks
  its result. Either way the GenServer's mailbox grows, slowing
  message lookup and eventually crashing on out-of-memory.

  LLMs often skip these because they think of Task as a Promise/Future
  whose runtime cleans up lifecycle bookkeeping (Python `asyncio`,
  JS `Promise`). In OTP, the lifecycle bookkeeping IS the API — the
  messages have to be received.

  Book reference: Elixir Patterns, ch.7 — Task response handling.

  ## Detection

  Flags a module if:

  1. It calls `use GenServer` (or `GenStage`);
  2. It calls `Task.Supervisor.async_nolink/2,3` **inside a callback
     body** (`handle_call/3`, `handle_cast/2`, `handle_info/2`,
     `handle_continue/2`, `init/1`, `terminate/2`); AND
  3. It does NOT have a `handle_info/2` clause that pattern-matches
     a task-success message (`{ref, _}` with `Process.demonitor(ref, _)`
     in the body OR an `is_reference(ref)` guard); OR it does NOT
     have a `handle_info/2` clause matching the full
     `{:DOWN, _, :process, _, _}` 5-tuple.

  The callback-body scoping in (2) is what makes "is the GenServer
  the receiver?" decidable. An `async_nolink` call from a helper
  like `def spawn_untracked, do: Task.Supervisor.async_nolink(...)` is
  invoked by *callers* in their own process, so the messages don't
  land in this GenServer's mailbox — and the rule correctly stays
  quiet. If the helper is called *from* a callback the message
  *will* arrive here, but tracking that requires call-graph analysis
  this rule doesn't do; inline the call into the callback (or
  document the helper's mailbox contract) to surface the contract.

  Suppression: use `Task.Supervisor.start_child/2` instead of
  `async_nolink` if you don't care about the result — that one
  doesn't send messages back.

  ## Bad

      defmodule Worker do
        use GenServer

        def handle_call(:start_job, _from, state) do
          Task.Supervisor.async_nolink(MySup, fn -> work() end)
          {:reply, :ok, state}
        end

        # …no handle_info for {ref, result} or {:DOWN, ref, ...}.
      end

  ## Good

      defmodule Worker do
        use GenServer

        def handle_call(:start_job, _from, state) do
          task = Task.Supervisor.async_nolink(MySup, fn -> work() end)
          {:reply, :ok, Map.put(state, task.ref, true)}
        end

        def handle_info({ref, _result}, state) when is_map_key(state, ref) do
          Process.demonitor(ref, [:flush])
          {:noreply, Map.delete(state, ref)}
        end

        def handle_info({:DOWN, ref, :process, _, _reason}, state) do
          {:noreply, Map.delete(state, ref)}
        end
      end
  """

  use CredenceRules.Rule

  alias CredenceRules.OtpModule

  @callback_names MapSet.new([
                    :handle_call,
                    :handle_cast,
                    :handle_info,
                    :handle_continue,
                    :init,
                    :terminate
                  ])

  @impl true
  def priority, do: 470

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [_alias, [{:do, body}]]} = node, acc ->
          if OtpModule.uses_genserver?(body),
            do: {node, scan_module(body) ++ acc},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    issues
    |> Enum.uniq_by(& &1.meta.line)
    |> Enum.sort_by(& &1.meta.line)
  end

  defp scan_module(body) do
    spawns = find_async_nolinks_in_callbacks(body)

    if spawns == [] do
      []
    else
      handle_info_defs = handle_info_defs(body)
      has_ref_handler? = Enum.any?(handle_info_defs, &task_ref_handler?/1)
      has_down_handler? = Enum.any?(handle_info_defs, &task_down_handler?/1)

      if has_ref_handler? and has_down_handler? do
        []
      else
        missing =
          [
            if(!has_ref_handler?,
              do:
                "`handle_info({ref, _result}, _)` with `Process.demonitor(ref, _)` " <>
                  "(or an `is_reference(ref)` guard)"
            ),
            if(!has_down_handler?, do: "`handle_info({:DOWN, _, :process, _, _}, _)`")
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" and ")

        Enum.map(spawns, &build_issue(&1, missing))
      end
    end
  end

  # `Task.Supervisor.async_nolink/2,3` calls **inside callback bodies**.
  # Calls in regular helpers (e.g. `def spawn_untracked, do: …`) run in
  # the *caller's* process, so the messages don't land in this
  # GenServer's mailbox; we don't flag those. `async_stream_nolink` is
  # also NOT included: it returns a stream whose lifecycle is consumed
  # by enumeration.
  defp find_async_nolinks_in_callbacks(body) do
    body
    |> callback_bodies()
    |> Enum.flat_map(&find_async_nolinks/1)
  end

  defp callback_bodies(body) do
    {_ast, bodies} =
      Macro.prewalk(body, [], fn
        {kind, _, [head, [{:do, def_body}]]} = node, acc when kind in [:def, :defp] ->
          if callback?(head),
            do: {node, [def_body | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(bodies)
  end

  defp callback?({:when, _, [inner, _]}), do: callback?(inner)

  defp callback?({name, _, args}) when is_atom(name) and is_list(args),
    do: MapSet.member?(@callback_names, name)

  defp callback?(_), do: false

  defp find_async_nolinks(body) do
    {_ast, metas} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, [:Task, :Supervisor]}, :async_nolink]}, meta, _} = node, acc ->
          {node, [meta | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(metas)
  end

  # Returns a list of `{pattern, guard_or_nil, body}` triples — one per
  # `handle_info/2` clause in the module. We need pattern AND
  # guard/body for the strict task-handler check.
  defp handle_info_defs(body) do
    {_ast, clauses} =
      Macro.prewalk(body, [], fn
        {kind, _, [head, [{:do, def_body}]]} = node, acc when kind in [:def, :defp] ->
          case extract_head(head) do
            {:handle_info, [pattern | _], guard} ->
              {node, [{pattern, guard, def_body} | acc]}

            _ ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(clauses)
  end

  defp extract_head({:when, _, [{name, _, args}, guard]}) when is_atom(name) and is_list(args),
    do: {name, args, guard}

  defp extract_head({name, _, args}) when is_atom(name) and is_list(args),
    do: {name, args, nil}

  defp extract_head(_), do: :other

  # A task-success handler is `handle_info({var, _}, _)` where the body
  # demonitors `var`, OR the head's guard asserts `is_reference(var)`.
  #
  # Without one of these signals, a `{tag, payload}` clause for some
  # unrelated tagged message would falsely pass the check.
  defp task_ref_handler?({{{name, _, ctx}, _second}, guard, body})
       when is_atom(name) and is_atom(ctx) do
    demonitors_var?(body, name) or reference_guard?(guard, name)
  end

  defp task_ref_handler?(_), do: false

  # A task-DOWN handler is the full 5-tuple `{:DOWN, _, :process, _, _}`,
  # not just any `:DOWN`-tagged message. Tasks use `Process.monitor`,
  # so the 3rd element is the literal atom `:process`.
  defp task_down_handler?({{:{}, _, [:DOWN, _ref, :process, _, _]}, _guard, _body}), do: true
  defp task_down_handler?(_), do: false

  defp demonitors_var?(body, var_name) do
    body
    |> Macro.prewalk(false, fn
      _node, true ->
        {[], true}

      {{:., _, [{:__aliases__, _, [:Process]}, :demonitor]}, _, [{^var_name, _, ctx} | _]} =
          node,
      _
      when is_atom(ctx) ->
        {node, true}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  # Walks a `when` guard tree looking for `is_reference(var_name)`.
  defp reference_guard?(nil, _), do: false

  defp reference_guard?(guard, var_name) do
    guard
    |> Macro.prewalk(false, fn
      _node, true ->
        {[], true}

      {:is_reference, _, [{^var_name, _, ctx}]} = node, _ when is_atom(ctx) ->
        {node, true}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end

  defp build_issue(meta, missing) do
    %Issue{
      rule: :task_supervisor_without_down_handling,
      message:
        "`Task.Supervisor.async_nolink/_` is called but the module has no " <>
          "#{missing} clause to receive the task's outcome. Without these, " <>
          "every successful or failed task leaks a message into the GenServer's " <>
          "mailbox.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
