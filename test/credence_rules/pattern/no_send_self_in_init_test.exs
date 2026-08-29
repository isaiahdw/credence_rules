defmodule CredenceRules.Pattern.NoSendSelfInInitTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.NoSendSelfInInit

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    NoSendSelfInInit.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags send(self(), msg) in init/1" do
      source = ~S"""
      def init(arg) do
        send(self(), :hydrate)
        {:ok, arg}
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :no_send_self_in_init
      assert issue.message =~ "handle_continue"
    end

    test "flags inside init/1 with a guard" do
      source = ~S"""
      def init(arg) when is_map(arg) do
        send(self(), :start)
        {:ok, arg}
      end
      """

      assert [_] = analyze(source)
    end

    test "flags multiple sends in one init/1" do
      source = ~S"""
      def init(arg) do
        send(self(), :a)
        send(self(), :b)
        {:ok, arg}
      end
      """

      assert length(analyze(source)) == 2
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag send(self(), …) in handle_info" do
      source = ~S"""
      def handle_info(:tick, state) do
        send(self(), :next)
        {:noreply, state}
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag send(other_pid, …) in init/1" do
      source = ~S"""
      def init(arg) do
        send(arg.parent, :ready)
        {:ok, arg}
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag init/2 (wrong arity)" do
      source = ~S"""
      def init(a, b) do
        send(self(), :go)
        {:ok, {a, b}}
      end
      """

      assert analyze(source) == []
    end
  end
end
