defmodule CredenceRules.Pattern.GenServerWithImmutableStateTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.GenServerWithImmutableState

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    GenServerWithImmutableState.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags a GenServer whose every callback passes state through" do
      source = ~S"""
      defmodule Cache do
        use GenServer

        def init(_), do: {:ok, %{}}

        def handle_call({:get, k}, _from, state) do
          {:reply, Map.get(state, k), state}
        end

        def handle_cast(:noop, state) do
          {:noreply, state}
        end
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :genserver_with_immutable_state
      assert issue.message =~ "process-as-namespace"
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag a GenServer that puts into state via %{state | …}" do
      source = ~S"""
      defmodule Cache do
        use GenServer

        def init(_), do: {:ok, %{count: 0}}

        def handle_call(:get, _from, state) do
          {:reply, state.count, state}
        end

        def handle_cast(:inc, state) do
          {:noreply, %{state | count: state.count + 1}}
        end
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag a GenServer that uses Map.put on state" do
      source = ~S"""
      defmodule Cache do
        use GenServer
        def handle_cast({:put, k, v}, state), do: {:noreply, Map.put(state, k, v)}
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag a GenServer that rebinds state" do
      source = ~S"""
      defmodule Cache do
        use GenServer
        def handle_cast({:put, k, v}, state) do
          state = Map.put(state, k, v)
          {:noreply, state}
        end
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag a plain module (no `use GenServer`)" do
      source = ~S"""
      defmodule Helpers do
        def passthrough(state), do: {:reply, :ok, state}
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag a GenServer that calls put_in on state" do
      source = ~S"""
      defmodule Cache do
        use GenServer
        def handle_cast({:set, k, v}, state) do
          {:noreply, put_in(state.items[k], v)}
        end
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag a GenServer that owns an ETS table" do
      # The state map is empty because all the real state lives in the
      # ETS table — the process exists to own the table (the table is
      # destroyed when its owner exits). That's a valid runtime role
      # per the official process anti-pattern doc.
      source = ~S"""
      defmodule AclStore do
        use GenServer

        def init(_) do
          :ets.new(:acl, [:named_table, :public])
          {:ok, %{}}
        end

        def handle_call({:lookup, k}, _from, state) do
          {:reply, :ets.lookup(:acl, k), state}
        end

        def handle_call({:put, k, v}, _from, state) do
          :ets.insert(:acl, {k, v})
          {:reply, :ok, state}
        end
      end
      """

      assert analyze(source) == []
    end
  end
end
