defmodule CredenceRules.Pattern.SleepInGenServerCallback do
  @moduledoc """
  Boundary rule: `Process.sleep/1` / `:timer.sleep/1` inside a GenServer
  callback blocks the *entire* mailbox.

  A GenServer callback runs in the same process that's supposed to be
  draining the mailbox. While `Process.sleep(2_000)` is sitting on the
  clock, no other `handle_call/cast/info/continue` runs for two
  seconds — even the `:DOWN` from a monitored child you'd want to
  react to. The whole point of a process is that it's a serialized
  message loop; sleep is the one operation that breaks that
  serialization while pretending not to.

  This is thread-import thinking: in Java/Python, `Thread.sleep` only
  pauses one thread among many, so retry/backoff loops sprinkle sleeps
  freely. In Elixir, the right "sleep then do work" idiom is to
  schedule a future message and return to the loop:

      Process.send_after(self(), :retry, @backoff_ms)
      {:noreply, state}

      def handle_info(:retry, state), do: do_the_work(state)

  This keeps the mailbox open so other messages (cancellations,
  shutdown signals, monitor :DOWNs) can interleave with the wait.

  ## Bad

      def handle_call(:fetch, _from, state) do
        Process.sleep(@retry_delay)
        do_fetch(state)
      end

  ## Good

      def handle_call(:fetch, from, state) do
        Process.send_after(self(), {:resume_fetch, from}, @retry_delay)
        {:noreply, state}
      end

      def handle_info({:resume_fetch, from}, state) do
        result = do_fetch(state)
        GenServer.reply(from, result)
        {:noreply, state}
      end
  """

  use CredenceRules.Rule

  alias CredenceRules.OtpModule

  @callback_names MapSet.new([
                    :handle_call,
                    :handle_cast,
                    :handle_info,
                    :handle_continue,
                    :handle_event,
                    :init,
                    :terminate,
                    :code_change,
                    :format_status
                  ])

  @impl true
  def priority, do: 470

  @impl true
  def check(ast, _opts) do
    # Scan defmodule-by-defmodule. Only modules that actually `use
    # GenServer` (or `GenStage`) have a mailbox that sleeps would
    # block — a plain module with `def handle_info` is just a
    # function happening to be named that.
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
        # `Process.sleep(_)`
        {{:., _, [{:__aliases__, _, [:Process]}, :sleep]}, meta, [_]} = node, acc ->
          {node, [build_issue(meta, "Process.sleep") | acc]}

        # `:timer.sleep(_)`
        {{:., _, [:timer, :sleep]}, meta, [_]} = node, acc ->
          {node, [build_issue(meta, ":timer.sleep") | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp build_issue(meta, label) do
    %Issue{
      rule: :sleep_in_genserver_callback,
      message:
        "`#{label}/1` inside a GenServer callback blocks the entire mailbox " <>
          "while it waits — no other `handle_call/cast/info/continue` runs " <>
          "for the duration. Use `Process.send_after(self(), msg, ms)` plus " <>
          "a `handle_info/2` clause so the callback returns to the loop and " <>
          "the wait happens between messages.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
