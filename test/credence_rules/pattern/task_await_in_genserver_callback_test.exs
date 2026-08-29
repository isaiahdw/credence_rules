defmodule CredenceRules.Pattern.TaskAwaitInGenServerCallbackTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.TaskAwaitInGenServerCallback

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    TaskAwaitInGenServerCallback.check(ast, [])
  end

  defp wrap_gs(body), do: "defmodule Worker do\n  use GenServer\n#{body}\nend\n"

  describe "check/2 — flagged" do
    test "flags pipe-form `task |> Task.await()` (zero explicit args)" do
      source =
        wrap_gs(~S"""
          def handle_call(:compute, _from, state) do
            result = Task.async(fn -> work() end) |> Task.await()
            {:reply, result, state}
          end
        """)

      assert [issue] = analyze(source)
      assert issue.rule == :task_await_in_genserver_callback
      assert issue.message =~ "Task.await"
      # Pipe form gets the "(pipe form)" diagnostic so the message
      # doesn't lie about the arity it observed.
      assert issue.message =~ "pipe form"
    end

    test "flags Task.await/2 with timeout (message says /2)" do
      source =
        wrap_gs(~S"""
          def handle_call(:compute, _from, state) do
            Task.await(task, 5_000)
            {:reply, :ok, state}
          end
        """)

      assert [issue] = analyze(source)
      assert issue.message =~ "Task.await/2"
    end

    test "flags Task.await_many/1 (message says /1)" do
      source =
        wrap_gs(~S"""
          def handle_call(:compute, _from, state) do
            Task.await_many(tasks)
            {:reply, :ok, state}
          end
        """)

      assert [issue] = analyze(source)
      assert issue.message =~ "Task.await_many/1"
    end

    test "flags Task.yield_many/2 (message says /2, not /1)" do
      # Regression: the message used to hard-code `/1` even on /2 calls.
      source =
        wrap_gs(~S"""
          def handle_info(:tick, state) do
            Task.yield_many([t1, t2], 1_000)
            {:noreply, state}
          end
        """)

      assert [issue] = analyze(source)
      assert issue.message =~ "Task.yield_many/2"
    end

    test "flags Task.yield/2" do
      source =
        wrap_gs(~S"""
          def handle_info(:tick, state) do
            Task.yield(task, 1_000)
            {:noreply, state}
          end
        """)

      assert [issue] = analyze(source)
      assert issue.message =~ "Task.yield/2"
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag Task.await outside a callback" do
      source =
        wrap_gs(~S"""
          def public_compute do
            Task.async(fn -> work() end) |> Task.await()
          end
        """)

      assert analyze(source) == []
    end

    test "does NOT flag Task.async (spawn, not wait)" do
      source =
        wrap_gs(~S"""
          def handle_call(:start, _from, state) do
            Task.async(fn -> work() end)
            {:noreply, state}
          end
        """)

      assert analyze(source) == []
    end

    test "does NOT flag handle_* in a plain module (no `use GenServer`)" do
      source = ~S"""
      defmodule Helper do
        def handle_call(arg) do
          Task.await(arg)
        end
      end
      """

      assert analyze(source) == []
    end
  end
end
