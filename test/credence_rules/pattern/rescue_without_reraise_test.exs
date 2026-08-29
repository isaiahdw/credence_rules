defmodule CredenceRules.Pattern.RescueWithoutReraiseTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.RescueWithoutReraise

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    RescueWithoutReraise.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags `rescue e -> Logger.error(...); :error`" do
      source = ~S"""
      try do
        do_work()
      rescue
        e ->
          Logger.error("oops: \#{inspect(e)}")
          :error
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :rescue_without_reraise
      assert issue.message =~ "logs the exception"
    end

    test "flags rescue with `nil` return" do
      source = ~S"""
      try do
        do_work()
      rescue
        e ->
          Logger.warning("ignored: \#{inspect(e)}")
          nil
      end
      """

      assert [_] = analyze(source)
    end

    test "flags rescue with `{:error, :crashed}` (literal tag, no binding)" do
      source = ~S"""
      try do
        do_work()
      rescue
        e ->
          Logger.error("oops")
          {:error, :crashed}
      end
      """

      assert [_] = analyze(source)
    end

    test "flags `e in RuntimeError` rescue pattern too" do
      source = ~S"""
      try do
        do_work()
      rescue
        e in RuntimeError ->
          Logger.error(inspect(e))
          :error
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "ignores rescue that re-raises" do
      source = ~S"""
      try do
        do_work()
      rescue
        e ->
          Logger.error("oops")
          reraise e, __STACKTRACE__
      end
      """

      assert [] = analyze(source)
    end

    test "ignores rescue that returns {:error, Exception.message(e)} (uses binding)" do
      source = ~S"""
      try do
        do_work()
      rescue
        e ->
          Logger.error("oops")
          {:error, Exception.message(e)}
      end
      """

      assert [] = analyze(source)
    end

    test "ignores rescue without a Logger call" do
      source = ~S"""
      try do
        do_work()
      rescue
        _e -> :error
      end
      """

      assert [] = analyze(source)
    end

    test "ignores plain function calls" do
      assert [] = analyze("do_work()")
    end
  end
end
