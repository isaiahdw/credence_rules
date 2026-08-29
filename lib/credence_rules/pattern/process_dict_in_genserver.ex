defmodule CredenceRules.Pattern.ProcessDictInGenServer do
  @moduledoc """
  Idiomatic rule: `Process.put/2` and `Process.get/1,2` inside a module
  that `use GenServer` is state-management-by-side-channel.

  GenServer state is the *first-class* mechanism for persistent
  per-process data — it's the second argument to every callback, it's
  trivially threaded through `{:reply, _, state}`, and it's visible at
  the boundary (`:sys.get_state`, tracing, hot-code-loading). The
  process dictionary is none of those things:

  - **Invisible to debuggers.** `:sys.get_state` won't show it; `:erlang.process_info(pid, :dictionary)` will, but no Elixir tooling routes through there by default.
  - **Bypasses pattern matching.** State usually pattern-matches at the
    head of every callback (`def handle_call(_, _, %{x: x} = state)`). Process-dict reads happen at call sites and silently return `nil`.
  - **Carries over `handle_continue` boundaries unpredictably** if the
    process restarts mid-supervision.

  LLMs reach for the process dictionary because it looks like a Python
  thread-local or a Ruby `Thread.current[…]` — globally available
  state with no plumbing. In Elixir, plumbing state through `state` IS
  the idiom.

  ## Bad

      defmodule Publisher do
        use GenServer

        def handle_call(:get_hostname, _from, state) do
          {:reply, Process.get(:hostname), state}    # invisible to debugger
        end

        def handle_cast({:set_hostname, h}, state) do
          Process.put(:hostname, h)                  # state not threaded
          {:noreply, state}
        end
      end

  ## Good

      defmodule Publisher do
        use GenServer

        def handle_call(:get_hostname, _from, %{hostname: h} = state) do
          {:reply, h, state}
        end

        def handle_cast({:set_hostname, h}, state) do
          {:noreply, %{state | hostname: h}}
        end
      end

  ## Exemptions

  Process dictionary use that ISN'T state — e.g. setting `Logger.metadata`
  via its own API, or `:proc_lib`'s ancestor tracking — is not detected
  here because it doesn't go through `Process.put/get`.
  """

  use CredenceRules.Rule

  @impl true
  def priority, do: 430

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [_alias, [{:do, body}]]} = node, acc ->
          if uses_genserver?(body),
            do: {node, scan_for_proc_dict(body) ++ acc},
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

  defp scan_for_proc_dict(body) do
    {_ast, issues} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, [:Process]}, fun]}, meta, _args} = node, acc
        when fun in [:put, :get, :delete] ->
          {node, [build_issue(meta, fun) | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp build_issue(meta, fun) do
    %Issue{
      rule: :process_dict_in_genserver,
      message:
        "`Process.#{fun}/_` inside a GenServer module manages state via the " <>
          "process dictionary — invisible to `:sys.get_state`, bypasses " <>
          "pattern matching at callback heads, and unpredictable across " <>
          "supervisor restarts. Thread the value through the `state` map / " <>
          "struct instead.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
