defmodule CredenceRules.Pattern.ReraiseWithoutStacktraceTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.ReraiseWithoutStacktrace

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    ReraiseWithoutStacktrace.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags `reraise e, []`" do
      source = ~S"""
      try do
        do_work()
      rescue
        e -> reraise e, []
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :reraise_without_stacktrace
      assert issue.meta.kind == :empty_list
    end

    test "flags `reraise e, nil`" do
      source = ~S"""
      try do
        do_work()
      rescue
        e -> reraise e, nil
      end
      """

      assert [issue] = analyze(source)
      assert issue.meta.kind == :nil_arg
    end

    test "flags 3-arg form with [] stack" do
      source = ~S"""
      try do
        do_work()
      catch
        kind, reason -> reraise kind, reason, []
      end
      """

      assert [_] = analyze(source)
    end

    test "flags 3-arg form with nil stack" do
      source = ~S"""
      try do
        do_work()
      catch
        kind, reason -> reraise kind, reason, nil
      end
      """

      assert [_] = analyze(source)
    end

    test "reports the line of the reraise" do
      source = ~S"""
      def go do
        try do
          do_work()
        rescue
          e ->
            Logger.error(inspect(e))
            reraise e, []
        end
      end
      """

      assert [issue] = analyze(source)
      assert issue.meta.line == 7
    end
  end

  describe "check/2 — not flagged" do
    test "ignores `reraise e, __STACKTRACE__`" do
      source = ~S"""
      try do
        do_work()
      rescue
        e -> reraise e, __STACKTRACE__
      end
      """

      assert [] = analyze(source)
    end

    test "ignores `reraise kind, reason, __STACKTRACE__` (3-arg correct)" do
      source = ~S"""
      try do
        do_work()
      catch
        kind, reason -> reraise kind, reason, __STACKTRACE__
      end
      """

      assert [] = analyze(source)
    end

    test "ignores `reraise e, captured_stack`" do
      source = ~S"""
      try do
        do_work()
      rescue
        e -> reraise e, stack
      end
      """

      assert [] = analyze(source)
    end

    test "ignores plain `raise/1`" do
      assert [] = analyze("raise ArgumentError")
    end

    test "ignores `raise e, []` (single-arg raise with [], not reraise)" do
      # raise takes a struct as second arg, not a stacktrace — we don't
      # flag `raise/2` here at all.
      assert [] = analyze("raise SomeError, []")
    end
  end
end
