defmodule CredenceRules.Pattern.GenServerSelfCallDeadlockTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.GenServerSelfCallDeadlock

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    GenServerSelfCallDeadlock.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags GenServer.call(self(), …) in handle_info" do
      source = ~S"""
      def handle_info(:tick, state) do
        GenServer.call(self(), :compute)
        {:noreply, state}
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :genserver_self_call_deadlock
      assert issue.message =~ "self()"
    end

    test "flags GenServer.call(__MODULE__, …) in handle_call" do
      source = ~S"""
      def handle_call(:get, _from, state) do
        result = GenServer.call(__MODULE__, :compute)
        {:reply, result, state}
      end
      """

      assert [issue] = analyze(source)
      assert issue.message =~ "__MODULE__"
    end

    test "flags inside handle_cast, handle_continue, init, terminate" do
      source = ~S"""
      def handle_cast(:tick, state) do
        GenServer.call(self(), :a)
        {:noreply, state}
      end

      def handle_continue(:load, state) do
        GenServer.call(self(), :b)
        {:noreply, state}
      end

      def init(arg) do
        GenServer.call(self(), :c)
        {:ok, arg}
      end

      def terminate(_reason, state) do
        GenServer.call(self(), :d)
        state
      end
      """

      assert length(analyze(source)) == 4
    end

    test "flags with timeout argument" do
      source = ~S"""
      def handle_info(:tick, state) do
        GenServer.call(self(), :compute, 5_000)
        {:noreply, state}
      end
      """

      assert [_] = analyze(source)
    end

    test "flags when callback head has a `when` guard" do
      source = ~S"""
      def handle_call(:get, _from, state) when is_map(state) do
        GenServer.call(self(), :compute)
        {:reply, :ok, state}
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag GenServer.call to another process" do
      source = ~S"""
      def handle_info(:tick, state) do
        GenServer.call(Other, :compute)
        {:noreply, state}
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag GenServer.call(self(), …) outside a callback" do
      # Pathological but valid: this is a public API helper, not a callback.
      # A user could reasonably want to allow this and the rule shouldn't
      # fire — the cross-process call only deadlocks when made from inside
      # the same process's callback.
      source = ~S"""
      def public_api do
        GenServer.call(self(), :compute)
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag GenServer.cast(self(), …)" do
      # Cast doesn't block, so no deadlock — this is a legitimate
      # "defer until after current callback returns" pattern.
      source = ~S"""
      def handle_info(:tick, state) do
        GenServer.cast(self(), :defer)
        {:noreply, state}
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag a non-GenServer module's `call`" do
      source = ~S"""
      def handle_info(:tick, state) do
        SomeClient.call(self(), :compute)
        {:noreply, state}
      end
      """

      assert analyze(source) == []
    end
  end
end
