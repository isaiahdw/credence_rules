defmodule CredenceRules.Pattern.PersistentTermAbuseTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.PersistentTermAbuse

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    PersistentTermAbuse.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags :persistent_term.put in handle_call of a GenServer module" do
      source = ~S"""
      defmodule Cache do
        use GenServer

        def handle_call({:set, k, v}, _from, state) do
          :persistent_term.put({__MODULE__, k}, v)
          {:reply, :ok, state}
        end
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :persistent_term_abuse
      assert issue.message =~ "persistent_term.put"
    end

    test "flags :persistent_term.erase in handle_cast" do
      source = ~S"""
      defmodule Cache do
        use GenServer

        def handle_cast({:clear, k}, state) do
          :persistent_term.erase(k)
          {:noreply, state}
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "flags put inside a private helper of a GenServer module" do
      source = ~S"""
      defmodule Cache do
        use GenServer

        def init(_), do: {:ok, %{}}

        defp do_set(k, v) do
          :persistent_term.put({__MODULE__, k}, v)
        end
      end
      """

      # Even though we don't trace callers, a defp that writes
      # persistent_term inside a long-lived GenServer is suspect.
      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag :persistent_term.put inside init/1" do
      source = ~S"""
      defmodule Cache do
        use GenServer

        def init(_) do
          for {k, v} <- load_seed() do
            :persistent_term.put({__MODULE__, k}, v)
          end
          :ignore
        end
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag :persistent_term.get (reads are fine)" do
      source = ~S"""
      defmodule Cache do
        use GenServer

        def handle_call({:get, k}, _from, state) do
          v = :persistent_term.get({__MODULE__, k}, nil)
          {:reply, v, state}
        end
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag in a plain module (lazy-cache pattern is idiomatic)" do
      source = ~S"""
      defmodule LazyCache do
        def fabric_id do
          case :persistent_term.get(:fabric_id, :unset) do
            :unset ->
              id = resolve()
              :persistent_term.put(:fabric_id, id)
              id

            id ->
              id
          end
        end
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag :persistent_term.erase inside terminate/2" do
      source = ~S"""
      defmodule Cache do
        use GenServer

        def init(_), do: {:ok, %{pt_key: {__MODULE__, :pid}}}

        def terminate(_reason, %{pt_key: pt_key}) when pt_key != nil do
          :persistent_term.erase(pt_key)
          :ok
        end
      end
      """

      assert analyze(source) == []
    end

    test "still flags :persistent_term.put inside terminate/2" do
      source = ~S"""
      defmodule Cache do
        use GenServer

        def init(_), do: {:ok, %{}}

        def terminate(_reason, state) do
          :persistent_term.put({__MODULE__, :final}, state)
          :ok
        end
      end
      """

      assert [issue] = analyze(source)
      assert issue.message =~ "persistent_term.put"
    end
  end
end
