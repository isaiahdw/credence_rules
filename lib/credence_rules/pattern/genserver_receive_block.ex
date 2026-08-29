defmodule CredenceRules.Pattern.GenServerReceiveBlock do
  @moduledoc """
  Concurrency rule: a bare `receive do … end` inside a `use GenServer`
  module bypasses the framework's message dispatch.

  GenServer's whole job is to route incoming messages through
  `handle_call/3`, `handle_cast/2`, and `handle_info/2`. When you put
  a `receive` block in a callback (or in a helper called from a
  callback), the messages you match there:

  - never reach `handle_info/2`,
  - block the callback until they arrive (defeating GenServer's
    asynchronous mailbox semantics),
  - leave OTP debugging (`:sys.trace`, `:sys.statistics`,
    `:debug` opts) blind to the matched messages,
  - and can subtly deadlock if the message you're waiting for can only
    be produced by another process that's calling INTO this GenServer.

  The legitimate cases for `receive` outside a GenServer (one-shot
  procs, `:proc_lib` workers) do not apply inside one — you already
  have a mailbox loop running for you.

  ## Bad

      defmodule Worker do
        use GenServer

        def handle_call(:wait_for_reply, _from, state) do
          receive do
            {:reply, x} -> {:reply, x, state}   # blocks the GenServer
          after
            5_000 -> {:reply, :timeout, state}
          end
        end
      end

  ## Good

      defmodule Worker do
        use GenServer

        # Acceptor sends back via the GenServer's own mailbox; this
        # callback returns immediately, and the reply arrives as a
        # normal handle_info message.
        def handle_call(:wait_for_reply, from, state) do
          send(other_pid, {:request, self()})
          {:noreply, %{state | pending: from}}
        end

        def handle_info({:reply, x}, %{pending: from} = state) do
          GenServer.reply(from, x)
          {:noreply, %{state | pending: nil}}
        end
      end
  """

  use CredenceRules.Rule

  @impl true
  def priority, do: 450

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [_alias, [{:do, body}]]} = node, acc ->
          if uses_genserver?(body),
            do: {node, scan_for_receive(body) ++ acc},
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
      {:use, _, [{:__aliases__, _, [:GenServer]}]} -> true
      {:use, _, [{:__aliases__, _, [:GenServer]}, _opts]} -> true
      _ -> false
    end)
  end

  defp scan_for_receive(body) do
    {_ast, issues} =
      Macro.prewalk(body, [], fn
        {:receive, meta, _clauses} = node, acc ->
          {node, [build_issue(meta) | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp build_issue(meta) do
    %Issue{
      rule: :genserver_receive_block,
      message:
        "`receive do … end` inside a GenServer bypasses the framework: " <>
          "messages matched here never reach `handle_info/2`, the callback " <>
          "blocks while waiting, and OTP tracing goes blind. Send a message " <>
          "out (e.g. via `Task.Supervisor.async_nolink`) and handle the " <>
          "reply in `handle_info/2` / `handle_continue/2` instead.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
