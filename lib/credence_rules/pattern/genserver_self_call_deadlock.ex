# credence-file:repeated_case_arm_body,repeated_subtree_in_function — this
#   module is an AST pattern matcher whose check/2 + Macro.prewalk + build_issue
#   shape is the Rule contract itself, so the structural duplication is inherent
#   to the form rather than a smell
defmodule CredenceRules.Pattern.GenServerSelfCallDeadlock do
  @moduledoc """
  Safety rule: `GenServer.call(self(), …)` (or `__MODULE__`) inside a
  GenServer callback is a guaranteed deadlock.

  A `GenServer.call/2,3` from inside `handle_call|cast|info|continue`
  enqueues a message to the same mailbox the callback is draining. The
  caller blocks waiting for the reply that the same process can't get
  around to producing — `:timeout` exit after the default 5s.

  LLMs reach for `GenServer.call(__MODULE__, …)` to "reuse my own public
  API" the way an OO class would call its own method. In Elixir, the
  public API is a function call; only cross-process work goes through
  the GenServer's mailbox.

  ## Bad

      def handle_info(:tick, state) do
        # Deadlocks: this message goes to our own mailbox, which we
        # can't service until handle_info returns.
        result = GenServer.call(__MODULE__, :compute)
        {:noreply, %{state | last: result}}
      end

  ## Good

      def handle_info(:tick, state) do
        result = do_compute(state)         # plain function call
        {:noreply, %{state | last: result}}
      end
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

  @impl true
  def priority, do: 460

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn node, acc ->
        case maybe_callback_body(node) do
          {:ok, body} -> {node, scan_body(body) ++ acc}
          :other -> {node, acc}
        end
      end)

    issues
    |> Enum.uniq_by(& &1.meta.line)
    |> Enum.sort_by(& &1.meta.line)
  end

  # Returns `{:ok, body}` if the AST node is a `def`/`defp` of one of the
  # known GenServer callbacks (any arity — we don't gate on /3 vs /2 here
  # because all the named callbacks have characteristic arities and the
  # false-positive risk on a non-callback `handle_call/2` is negligible).
  defp maybe_callback_body({kind, _, [head, [{:do, body}]]})
       when kind in [:def, :defp] do
    case head do
      {:when, _, [{name, _, _args}, _guard]} when is_atom(name) ->
        if MapSet.member?(@callback_names, name), do: {:ok, body}, else: :other

      {name, _, _args} when is_atom(name) ->
        if MapSet.member?(@callback_names, name), do: {:ok, body}, else: :other

      _ ->
        :other
    end
  end

  defp maybe_callback_body(_), do: :other

  defp scan_body(body) do
    {_ast, issues} =
      Macro.prewalk(body, [], fn
        # `GenServer.call(target, _msg, _timeout?)` where target is self()/__MODULE__.
        {{:., _, [{:__aliases__, _, [:GenServer]}, :call]}, meta, [target | _]} = node, acc ->
          if self_target?(target),
            do: {node, [build_issue(meta, target) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp self_target?({:self, _, args}) when args == [] or is_nil(args), do: true
  defp self_target?({:__MODULE__, _, _}), do: true
  defp self_target?(_), do: false

  defp build_issue(meta, target) do
    label =
      case target do
        {:self, _, _} -> "self()"
        {:__MODULE__, _, _} -> "__MODULE__"
      end

    %Issue{
      rule: :genserver_self_call_deadlock,
      message:
        "`GenServer.call(#{label}, …)` inside a GenServer callback deadlocks: " <>
          "the call enqueues a message to the same mailbox this callback is " <>
          "draining. Use a plain function call (or `GenServer.cast` if you " <>
          "genuinely need to defer until after the current callback returns).",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
