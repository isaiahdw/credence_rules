defmodule CredenceRules.Pattern.NoSendSelfInInit do
  @moduledoc """
  Idiomatic rule: `send(self(), msg)` inside `init/1` should be
  `{:ok, state, {:continue, msg}}` instead.

  `init/1` is part of `GenServer.start_link/2,3`'s synchronous handshake —
  the caller blocks until `init/1` returns. Anything you put in the
  mailbox during init isn't processed until init returns, so doing
  `send(self(), :load)` to kick off startup work is a polite way of
  doing nothing for a millisecond before the work actually starts.

  `handle_continue/2` was added to OTP specifically for this case: it
  runs *after* `init/1` returns control to the caller, but *before* any
  other message is processed, with no chance of an interleaved message
  jumping the queue. Book ch.5 walks through this pattern.

  LLMs reach for `send(self(), …)` because tutorials in other actor
  frameworks (Akka, Erlang's `gen_server` examples that predate
  `handle_continue`) do exactly this.

  ## Bad

      def init(arg) do
        send(self(), :hydrate)
        {:ok, %{cache: %{}, arg: arg}}
      end

      def handle_info(:hydrate, state), do: {:noreply, do_hydrate(state)}

  ## Good

      def init(arg) do
        {:ok, %{cache: %{}, arg: arg}, {:continue, :hydrate}}
      end

      def handle_continue(:hydrate, state), do: {:noreply, do_hydrate(state)}
  """

  use CredenceRules.Rule

  @impl true
  def priority, do: 410

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {kind, _meta, [head, [{:do, body}]]} = node, acc when kind in [:def, :defp] ->
          if init_head?(head),
            do: {node, scan_for_send_self(body) ++ acc},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    issues
    |> Enum.uniq_by(& &1.meta.line)
    |> Enum.sort_by(& &1.meta.line)
  end

  defp init_head?({:when, _, [inner, _]}), do: init_head?(inner)
  defp init_head?({:init, _, [_]}), do: true
  defp init_head?(_), do: false

  defp scan_for_send_self(body) do
    {_ast, issues} =
      Macro.prewalk(body, [], fn
        {:send, meta, [{:self, _, args}, _msg]} = node, acc
        when args == [] or is_nil(args) ->
          {node, [build_issue(meta) | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp build_issue(meta) do
    %Issue{
      rule: :no_send_self_in_init,
      message:
        "`send(self(), …)` inside `init/1` is the slow-motion form of " <>
          "`{:ok, state, {:continue, msg}}`. Use `handle_continue/2` so " <>
          "the work runs immediately after `init/1` returns control to " <>
          "the caller, with no chance of an interleaved message.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
