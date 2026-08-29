defmodule CredenceRules.Pattern.TaskAwaitInGenServerCallback do
  @moduledoc """
  Boundary rule: `Task.await/1,2`, `Task.await_many/1,2`, and
  `Task.yield/1,2` inside a GenServer callback are thread/join thinking.

  A GenServer callback is the body of a message-loop iteration. While
  it's waiting synchronously for a Task to finish, the mailbox is
  blocked — exactly the same problem as `Process.sleep` (see
  `sleep_in_genserver_callback`), but more insidious because the wait
  is data-dependent and may be much longer than expected.

  The book's *work-delegation* pattern (Elixir Patterns, ch. 7) is
  explicit: the GenServer is a coordinator, not a worker. Tasks are
  spawned via `Task.Supervisor.async_nolink/3` and their results
  arrive as messages handled by `handle_info({ref, result}, state)`
  (and `handle_info({:DOWN, ref, :process, _, reason}, state)` for
  failure). The callback returns immediately and the GenServer
  remains responsive while the work happens elsewhere.

  This is one of the clearest "Promise/Future" cross-language
  imports. In Python's `asyncio` and JS's async/await the *runtime*
  hides the lifecycle bookkeeping; in OTP, the lifecycle bookkeeping
  is the API.

  ## Bad

      def handle_call(:compute, _from, state) do
        result =
          Task.Supervisor.async_nolink(MySup, fn -> heavy_work(state) end)
          |> Task.await(:infinity)             # blocks the mailbox

        {:reply, result, state}
      end

  ## Good

      def handle_call(:compute, from, state) do
        task = Task.Supervisor.async_nolink(MySup, fn -> heavy_work(state) end)
        {:noreply, %{state | pending: {task.ref, from}}}
      end

      def handle_info({ref, result}, %{pending: {ref, from}} = state) do
        Process.demonitor(ref, [:flush])
        GenServer.reply(from, result)
        {:noreply, %{state | pending: nil}}
      end

      def handle_info({:DOWN, ref, :process, _, reason}, %{pending: {ref, from}} = state) do
        GenServer.reply(from, {:error, reason})
        {:noreply, %{state | pending: nil}}
      end

  ## Related

  See `unsupervised_task_async` for the orthogonal concern of
  *creating* tasks without supervision. Both rules can co-fire on the
  same line.
  """

  use CredenceRules.Rule

  @callback_names MapSet.new([
                    :handle_call,
                    :handle_cast,
                    :handle_info,
                    :handle_continue,
                    :handle_event,
                    :init,
                    :terminate
                  ])

  @flagged_funs MapSet.new([:await, :await_many, :yield, :yield_many])

  @impl true
  def priority, do: 480

  @impl true
  def check(ast, _opts) do
    # Same guard as `sleep_in_genserver_callback`: only walk modules
    # that actually `use GenServer`. A plain module with a `def
    # handle_info(...)` has no mailbox to block.
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [_alias, [{:do, body}]]} = node, acc ->
          if uses_genserver?(body),
            do: {node, scan_module(body) ++ acc},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    issues
    |> Enum.uniq_by(& &1.meta.line)
    |> Enum.sort_by(& &1.meta.line)
  end

  defp uses_genserver?(body) do
    stmts =
      case body do
        {:__block__, _, list} -> list
        single -> [single]
      end

    Enum.any?(stmts, fn
      {:use, _, [{:__aliases__, _, [m]}]} when m in [:GenServer, :GenStage] -> true
      {:use, _, [{:__aliases__, _, [m]}, _]} when m in [:GenServer, :GenStage] -> true
      _ -> false
    end)
  end

  defp scan_module(body) do
    {_ast, issues} =
      Macro.prewalk(body, [], fn node, acc ->
        case maybe_callback_body(node) do
          {:ok, def_body} -> {node, scan_body(def_body) ++ acc}
          :other -> {node, acc}
        end
      end)

    Enum.reverse(issues)
  end

  defp maybe_callback_body({kind, _, [head, [{:do, body}]]})
       when kind in [:def, :defp] do
    name =
      case head do
        {:when, _, [{name, _, _args}, _guard]} when is_atom(name) -> name
        {name, _, _args} when is_atom(name) -> name
        _ -> nil
      end

    if name && MapSet.member?(@callback_names, name),
      do: {:ok, body},
      else: :other
  end

  defp maybe_callback_body(_), do: :other

  defp scan_body(body) do
    {_ast, issues} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, [:Task]}, fun]}, meta, args} = node, acc
        when is_atom(fun) and is_list(args) ->
          # In pipe form `task |> Task.await()`, the RHS call has zero
          # explicit args (the piped value becomes the first arg at
          # expansion). Match the name only — any arity is suspect for
          # these specific functions inside a callback.
          if MapSet.member?(@flagged_funs, fun),
            do: {node, [build_issue(meta, fun, length(args)) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp build_issue(meta, fun, args_len) do
    # Diagnostic label. The pipe form `task |> Task.await()` parses with
    # `length(args) == 0` (the piped value becomes the first arg at
    # expansion), but as a real call it's still effectively /1. We
    # report the actual function name and the syntactic arity we saw
    # so the message points to the exact call.
    label =
      case args_len do
        0 -> "Task.#{fun}/_  (pipe form)"
        n -> "Task.#{fun}/#{n}"
      end

    %Issue{
      rule: :task_await_in_genserver_callback,
      message:
        "`#{label}` inside a GenServer callback blocks the mailbox " <>
          "while waiting for the task — Promise/Future thinking that doesn't " <>
          "match OTP's message model. Spawn with `Task.Supervisor.async_nolink/3`, " <>
          "stash the ref in `state`, and handle the result via " <>
          "`handle_info({ref, result}, _)` plus `handle_info({:DOWN, ref, …}, _)`.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
