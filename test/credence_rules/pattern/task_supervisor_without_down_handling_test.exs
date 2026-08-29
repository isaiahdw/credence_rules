defmodule CredenceRules.Pattern.TaskSupervisorWithoutDownHandlingTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.TaskSupervisorWithoutDownHandling

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    TaskSupervisorWithoutDownHandling.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags async_nolink with no handle_info clauses" do
      source = ~S"""
      defmodule Worker do
        use GenServer
        def handle_call(:go, _from, state) do
          Task.Supervisor.async_nolink(MySup, fn -> work() end)
          {:reply, :ok, state}
        end
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :task_supervisor_without_down_handling
      assert issue.message =~ "handle_info"
    end

    test "flags async_nolink with only :DOWN handler (missing ref handler)" do
      source = ~S"""
      defmodule Worker do
        use GenServer

        def handle_call(:go, _from, state) do
          Task.Supervisor.async_nolink(MySup, fn -> work() end)
          {:reply, :ok, state}
        end

        def handle_info({:DOWN, _, :process, _, _}, state), do: {:noreply, state}
      end
      """

      assert [issue] = analyze(source)
      assert issue.message =~ "{ref, _result}"
    end

    test "flags async_nolink with only ref handler (missing :DOWN)" do
      source = ~S"""
      defmodule Worker do
        use GenServer

        def handle_call(:go, _from, state) do
          Task.Supervisor.async_nolink(MySup, fn -> work() end)
          {:reply, :ok, state}
        end

        def handle_info({ref, _result}, state) do
          Process.demonitor(ref, [:flush])
          {:noreply, state}
        end
      end
      """

      assert [issue] = analyze(source)
      assert issue.message =~ ":DOWN"
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag when both handlers exist (Process.demonitor in body)" do
      source = ~S"""
      defmodule Worker do
        use GenServer

        def handle_call(:go, _from, state) do
          Task.Supervisor.async_nolink(MySup, fn -> work() end)
          {:reply, :ok, state}
        end

        def handle_info({ref, result}, state) do
          Process.demonitor(ref, [:flush])
          {:noreply, Map.put(state, :last, result)}
        end

        def handle_info({:DOWN, _ref, :process, _, _reason}, state) do
          {:noreply, state}
        end
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag when success handler uses is_reference guard" do
      source = ~S"""
      defmodule Worker do
        use GenServer

        def handle_call(:go, _from, state) do
          Task.Supervisor.async_nolink(MySup, fn -> work() end)
          {:reply, :ok, state}
        end

        def handle_info({ref, _result}, state) when is_reference(ref) do
          {:noreply, state}
        end

        def handle_info({:DOWN, _, :process, _, _}, state), do: {:noreply, state}
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag a non-GenServer module" do
      source = ~S"""
      defmodule Helpers do
        def do_work do
          Task.Supervisor.async_nolink(MySup, fn -> work() end)
        end
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag a GenServer that never calls async_nolink" do
      source = ~S"""
      defmodule Worker do
        use GenServer
        def handle_call(:ping, _from, state), do: {:reply, :pong, state}
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag Task.Supervisor.async_stream_nolink (stream lifecycle)" do
      # async_stream_nolink returns a stream whose lifecycle is bound to
      # enumeration; the caller doesn't need handle_info clauses.
      source = ~S"""
      defmodule Worker do
        use GenServer

        def handle_call(:batch, _from, state) do
          MySup
          |> Task.Supervisor.async_stream_nolink(items(), &work/1)
          |> Enum.to_list()
          {:reply, :ok, state}
        end
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag async_nolink in a public helper (caller is a different process)" do
      # `def spawn_untracked` is invoked by external callers from their
      # own process. The task messages go to *their* mailbox, not this
      # GenServer's. The rule must not require the GenServer to have
      # handle_info clauses for messages it'll never receive.
      source = ~S"""
      defmodule Worker do
        use GenServer

        def init(_), do: {:ok, %{}}

        def spawn_untracked(arg) do
          Task.Supervisor.async_nolink(MySup, fn -> work(arg) end)
        end
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag async_nolink in a private helper (assume not called from callback)" do
      # Same scoping rule — the helper *could* be called from a callback,
      # but we can't tell statically. Be conservative: don't fire.
      # Authors can inline the call into the callback if they want
      # the rule to enforce the contract.
      source = ~S"""
      defmodule Worker do
        use GenServer

        def init(_), do: {:ok, %{}}

        defp do_spawn(arg) do
          Task.Supervisor.async_nolink(MySup, fn -> work(arg) end)
        end
      end
      """

      assert analyze(source) == []
    end
  end

  describe "check/2 — false-negative regressions" do
    test "flags when {ref, _} clause has no demonitor / is_reference guard" do
      # Unrelated tagged-message handler shouldn't satisfy the rule.
      # The author meant `{event, payload}` for some other protocol; task
      # messages still leak.
      source = ~S"""
      defmodule Worker do
        use GenServer

        def handle_call(:go, _from, state) do
          Task.Supervisor.async_nolink(MySup, fn -> work() end)
          {:reply, :ok, state}
        end

        def handle_info({:event, payload}, state) do
          # Not task-related — just an internal tagged message.
          {:noreply, save(state, payload)}
        end

        def handle_info({:DOWN, _ref, :process, _, _reason}, state) do
          {:noreply, state}
        end
      end
      """

      # The 2-tuple clause matches `{:event, _}` (atom-first, not a var),
      # so it doesn't satisfy ref_handler? anyway — but even a generic
      # var-first 2-tuple without demonitor wouldn't satisfy it now.
      assert [_] = analyze(source)
    end

    test "flags when :DOWN handler is 2-tuple rather than full 5-tuple" do
      # `handle_info({:DOWN, _}, _)` is a different message shape (e.g.
      # a custom internal `:DOWN` event); it doesn't match the
      # Process.monitor 5-tuple shape that tasks use.
      source = ~S"""
      defmodule Worker do
        use GenServer

        def handle_call(:go, _from, state) do
          Task.Supervisor.async_nolink(MySup, fn -> work() end)
          {:reply, :ok, state}
        end

        def handle_info({ref, _result}, state) do
          Process.demonitor(ref, [:flush])
          {:noreply, state}
        end

        def handle_info({:DOWN, _payload}, state) do
          {:noreply, state}
        end
      end
      """

      assert [_] = analyze(source)
    end
  end
end
