defmodule CredenceRules.Pattern.NoGenServerCallbackMissingImplTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.NoGenServerCallbackMissingImpl

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    NoGenServerCallbackMissingImpl.check(ast, [])
  end

  describe "check/2" do
    test "flags handle_call/3 without @impl" do
      source = ~S"""
      defmodule Counter do
        use GenServer
        def handle_call(:get, _from, state), do: {:reply, state, state}
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :no_genserver_callback_missing_impl
      assert issue.message =~ "handle_call/3"
    end

    test "does NOT flag handle_call/3 with @impl true" do
      source = ~S"""
      defmodule Counter do
        use GenServer
        @impl true
        def handle_call(:get, _from, state), do: {:reply, state, state}
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag handle_call/3 with @impl GenServer" do
      source = ~S"""
      defmodule Counter do
        use GenServer
        @impl GenServer
        def handle_call(:get, _from, state), do: {:reply, state, state}
      end
      """

      assert analyze(source) == []
    end

    test "flags every missing-impl callback in the module" do
      source = ~S"""
      defmodule Counter do
        use GenServer

        @impl true
        def init(state), do: {:ok, state}

        def handle_call(:get, _from, state), do: {:reply, state, state}
        def handle_cast(:inc, n), do: {:noreply, n + 1}
        def handle_info(:tick, state), do: {:noreply, state}
      end
      """

      issues = analyze(source)
      flagged = Enum.map(issues, & &1.message)
      assert length(issues) == 3
      assert Enum.any?(flagged, &(&1 =~ "handle_call/3"))
      assert Enum.any?(flagged, &(&1 =~ "handle_cast/2"))
      assert Enum.any?(flagged, &(&1 =~ "handle_info/2"))
    end

    test "does NOT flag a plain helper function with a callback-shaped name" do
      # `init/1` in a plain module is just a function. Without a
      # `use GenServer` / `@behaviour` declaration the gate stops
      # the rule from firing — see the behaviour-gate describe
      # block below.
      source = ~S"""
      defmodule Helpers do
        def init(arg), do: {:ok, arg}
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag non-callback arities" do
      source = ~S"""
      defmodule Counter do
        use GenServer
        # handle_call/4 isn't a real callback — arity doesn't match
        def handle_call(:get, _from, state, _extra), do: {:reply, state, state}
      end
      """

      assert analyze(source) == []
    end

    test "handles a module body with a single statement (no block)" do
      source = ~S"""
      defmodule Counter do
        use GenServer
        def handle_call(:get, _from, state), do: {:reply, state, state}
      end
      """

      assert [_] = analyze(source)
    end

    test "does NOT flag sibling clauses when the first clause has a `when` guard" do
      # Regression test: `def foo(...) when ...` parses with a `:when`
      # node wrapping the head, which the original arity extractor
      # missed. Result: the @impl'd first clause wasn't recorded, so
      # the second (no-guard) clause was incorrectly flagged.
      source = ~S"""
      defmodule Publisher do
        use GenServer

        @impl true
        def handle_call({:publish, x}, _from, state) when is_atom(x) do
          {:reply, :ok, state}
        end

        def handle_call({:publish, x}, _from, state), do: {:reply, {:error, x}, state}
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag sibling clauses of an already-impl'd callback" do
      # Compatible with Credence's `non_grouped_clauses`: that rule
      # requires the `@impl` attribute appear once per callback head,
      # not per clause. Our rule matches the same idiom.
      source = ~S"""
      defmodule Counter do
        use GenServer

        @impl true
        def handle_call(:get, _from, state), do: {:reply, state, state}
        def handle_call(:inc, _from, state), do: {:reply, :ok, state + 1}
        def handle_call(:reset, _from, _state), do: {:reply, :ok, 0}
      end
      """

      assert analyze(source) == []
    end

    test "flags a SECOND callback if neither clause has @impl" do
      source = ~S"""
      defmodule Counter do
        use GenServer

        @impl true
        def handle_call(:get, _from, state), do: {:reply, state, state}

        def handle_info(:tick, state), do: {:noreply, state}
        def handle_info(_other, state), do: {:noreply, state}
      end
      """

      # handle_info/2 has no @impl and is a different name/arity, so its
      # FIRST clause gets flagged (sibling tracking is per name/arity).
      issues = analyze(source)
      assert length(issues) == 1
      assert hd(issues).message =~ "handle_info/2"
    end

    test "covers handle_continue/2 and terminate/2" do
      source = ~S"""
      defmodule Counter do
        use GenServer
        def handle_continue(:load, state), do: {:noreply, state}
        def terminate(_reason, _state), do: :ok
      end
      """

      issues = analyze(source)
      messages = Enum.map(issues, & &1.message)
      assert Enum.any?(messages, &(&1 =~ "handle_continue/2"))
      assert Enum.any?(messages, &(&1 =~ "terminate/2"))
    end
  end

  describe "check/2 — behaviour gate" do
    test "does NOT flag handle_call/3 in a plain module (no behaviour declared)" do
      # DSL / custom callback module that happens to define a
      # `handle_call/3`-shaped function. Without the gate this would
      # fire on every such module.
      source = ~S"""
      defmodule MyRouter do
        def handle_call(:foo, _from, state), do: {:reply, :ok, state}
      end
      """

      assert analyze(source) == []
    end

    test "flags inside `use Supervisor` modules" do
      source = ~S"""
      defmodule MySup do
        use Supervisor
        def init(_), do: {:ok, []}
      end
      """

      assert [_] = analyze(source)
    end

    test "flags inside `use Application` modules" do
      source = ~S"""
      defmodule MyApp.Application do
        use Application
        def start(_, _), do: {:ok, self()}
      end
      """

      assert [_] = analyze(source)
    end

    test "flags inside `use Agent` modules" do
      source = ~S"""
      defmodule Counter do
        use Agent
        def init(state), do: {:ok, state}
      end
      """

      assert [_] = analyze(source)
    end

    test "flags inside `@behaviour :gen_statem` modules" do
      source = ~S"""
      defmodule Fsm do
        @behaviour :gen_statem
        def init(_), do: {:ok, :idle, %{}}
      end
      """

      assert [_] = analyze(source)
    end

    test "flags inside `@behaviour GenServer` modules" do
      source = ~S"""
      defmodule MyServer do
        @behaviour GenServer
        def init(state), do: {:ok, state}
      end
      """

      assert [_] = analyze(source)
    end
  end
end
