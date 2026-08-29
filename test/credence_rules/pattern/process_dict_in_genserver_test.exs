defmodule CredenceRules.Pattern.ProcessDictInGenServerTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.ProcessDictInGenServer

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    ProcessDictInGenServer.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags Process.put inside a `use GenServer` module" do
      source = ~S"""
      defmodule Publisher do
        use GenServer
        def handle_cast({:set, h}, state) do
          Process.put(:hostname, h)
          {:noreply, state}
        end
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :process_dict_in_genserver
      assert issue.message =~ "Process.put"
    end

    test "flags Process.get and Process.delete" do
      source = ~S"""
      defmodule Publisher do
        use GenServer
        def handle_call(:get, _from, state), do: {:reply, Process.get(:k), state}
        def handle_cast(:clear, state) do
          Process.delete(:k)
          {:noreply, state}
        end
      end
      """

      issues = analyze(source)
      assert length(issues) == 2
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag Process.put in a plain module" do
      source = ~S"""
      defmodule Helpers do
        def remember(v), do: Process.put(:k, v)
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag a `use GenServer` module that never touches the process dict" do
      source = ~S"""
      defmodule Cache do
        use GenServer
        def handle_call(:get, _from, %{v: v} = state), do: {:reply, v, state}
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag Process.send_after / Process.alive? etc." do
      source = ~S"""
      defmodule Cache do
        use GenServer
        def init(_) do
          Process.send_after(self(), :tick, 1000)
          {:ok, %{}}
        end
      end
      """

      assert analyze(source) == []
    end
  end
end
