defmodule CredenceRules.Pattern.MagicTimeoutLiteralTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.MagicTimeoutLiteral

  defp analyze(source, opts \\ []) do
    {:ok, ast} = Code.string_to_quoted(source)
    MagicTimeoutLiteral.check(ast, opts)
  end

  describe "check/2 — flagged" do
    test "flags Process.send_after literal timeout" do
      assert [issue] = analyze(~S"Process.send_after(self(), :tick, 10_000)")
      assert issue.rule == :magic_timeout_literal
      assert issue.message =~ "10000"
      assert issue.message =~ "Process.send_after"
    end

    test "flags :timer.send_interval literal" do
      assert [_] = analyze(~S":timer.send_interval(60_000, :poll)")
    end

    test "flags :timer.sleep literal" do
      assert [_] = analyze(~S":timer.sleep(5_000)")
    end

    test "flags GenServer.call literal timeout" do
      assert [_] = analyze(~S"GenServer.call(server, :req, 30_000)")
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag literals below threshold (100)" do
      assert analyze(~S"Process.send_after(self(), :tick, 0)") == []
      assert analyze(~S"Process.send_after(self(), :tick, 50)") == []
    end

    test "does NOT flag :infinity" do
      assert analyze(~S"GenServer.call(server, :req, :infinity)") == []
    end

    test "does NOT flag module attributes" do
      assert analyze(~S"Process.send_after(self(), :tick, @tick_interval)") == []
    end

    test "does NOT flag variables" do
      assert analyze(~S"Process.send_after(self(), :tick, ms)") == []
    end

    test "respects custom :min_threshold" do
      # Lift threshold above the literal in the call site — should not fire.
      assert analyze(~S"Process.send_after(self(), :tick, 200)",
               min_threshold: 1_000
             ) == []
    end
  end
end
