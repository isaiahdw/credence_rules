defmodule CredenceRules.Pattern.GenserverAsKvStoreTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.GenserverAsKvStore

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    GenserverAsKvStore.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags a GenServer whose API is only get/put/delete" do
      source = ~S"""
      defmodule Cache do
        use GenServer

        def get(k), do: GenServer.call(__MODULE__, {:get, k})
        def put(k, v), do: GenServer.call(__MODULE__, {:put, k, v})
        def delete(k), do: GenServer.call(__MODULE__, {:delete, k})

        @impl true
        def init(_), do: {:ok, %{}}

        @impl true
        def handle_call({:get, k}, _from, state), do: {:reply, Map.get(state, k), state}
        @impl true
        def handle_call({:put, k, v}, _from, state), do: {:reply, :ok, Map.put(state, k, v)}
        @impl true
        def handle_call({:delete, k}, _from, state), do: {:reply, :ok, Map.delete(state, k)}
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :genserver_as_kv_store
      assert issue.message =~ "ETS"
    end

    test "flags broader KV vocabulary (fetch, has_key?, keys)" do
      source = ~S"""
      defmodule Store do
        use GenServer

        def get(k), do: nil
        def fetch(k), do: nil
        def has_key?(k), do: false
        def keys, do: []
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag a GenServer with a domain method" do
      source = ~S"""
      defmodule Auction do
        use GenServer

        def get(id), do: :ok
        def place_bid(id, amount), do: :ok    # domain — not in KV vocab
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag a single-method GenServer" do
      # Single public method isn't an "API" — need >= 2.
      source = ~S"""
      defmodule Singleton do
        use GenServer

        def get, do: :ok
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag a plain Map-wrapper module (no use GenServer)" do
      source = ~S"""
      defmodule Cache do
        def get(map, k), do: Map.get(map, k)
        def put(map, k, v), do: Map.put(map, k, v)
      end
      """

      assert analyze(source) == []
    end
  end
end
