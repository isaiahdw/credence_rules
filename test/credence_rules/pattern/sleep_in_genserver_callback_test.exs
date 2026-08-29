defmodule CredenceRules.Pattern.SleepInGenServerCallbackTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.SleepInGenServerCallback

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    SleepInGenServerCallback.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags Process.sleep in handle_call of a GenServer module" do
      source = ~S"""
      defmodule Worker do
        use GenServer

        def handle_call(:fetch, _from, state) do
          Process.sleep(2_000)
          {:reply, :ok, state}
        end
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :sleep_in_genserver_callback
      assert issue.message =~ "Process.sleep"
    end

    test "flags :timer.sleep in handle_info" do
      source = ~S"""
      defmodule Worker do
        use GenServer

        def handle_info(:retry, state) do
          :timer.sleep(1_000)
          do_retry(state)
        end
      end
      """

      assert [issue] = analyze(source)
      assert issue.message =~ ":timer.sleep"
    end

    test "flags sleep in init/1, handle_continue, handle_cast, terminate" do
      source = ~S"""
      defmodule Worker do
        use GenServer

        def init(_), do: Process.sleep(100)
        def handle_continue(:go, s), do: Process.sleep(100)
        def handle_cast(:tick, s), do: Process.sleep(100)
        def terminate(_, _), do: Process.sleep(100)
      end
      """

      assert length(analyze(source)) == 4
    end

    test "flags sleep inside nested case in callback" do
      source = ~S"""
      defmodule Worker do
        use GenServer

        def handle_call(:x, _from, state) do
          case state.mode do
            :fast -> :ok
            _ -> Process.sleep(500)
          end

          {:reply, :ok, state}
        end
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag sleep in a non-callback function" do
      source = ~S"""
      defmodule Worker do
        use GenServer

        def public_helper do
          Process.sleep(100)
          :ok
        end
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag Process.send_after" do
      source = ~S"""
      defmodule Worker do
        use GenServer

        def handle_call(:fetch, _from, state) do
          Process.send_after(self(), :retry, 1_000)
          {:noreply, state}
        end
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag handle_* in a plain module (no `use GenServer`)" do
      # Just because a function is named `handle_info` doesn't mean it
      # runs in a GenServer mailbox. A plain helper module gets a pass.
      source = ~S"""
      defmodule Parser do
        def handle_info(arg) do
          Process.sleep(100)
          arg
        end
      end
      """

      assert analyze(source) == []
    end
  end
end
