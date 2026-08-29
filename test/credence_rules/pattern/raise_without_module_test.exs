defmodule CredenceRules.Pattern.RaiseWithoutModuleTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.RaiseWithoutModule

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    RaiseWithoutModule.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test ~s|flags `raise "..."`| do
      assert [issue] = analyze(~S(raise "user not found"))
      assert issue.rule == :raise_without_module
      assert issue.message =~ "RuntimeError"
    end

    test "flags interpolated raise" do
      assert [_] = analyze(~S(raise "user #{id} not found"))
    end

    test "flags concatenated raise" do
      assert [_] = analyze(~S(raise "prefix " <> reason))
    end

    test "flags empty-string raise" do
      assert [_] = analyze(~S(raise ""))
    end

    test "flags raise of a multi-line heredoc string" do
      source = ~S'''
      raise """
      something went wrong
      """
      '''

      assert [_] = analyze(source)
    end

    test "reports the line of the raise" do
      source = ~S"""
      def check(input) do
        if invalid?(input) do
          raise "bad input"
        end
      end
      """

      assert [issue] = analyze(source)
      assert issue.meta.line == 3
    end

    test "flags each occurrence separately" do
      source = ~S"""
      def check(a, b) do
        if invalid?(a), do: raise "bad a"
        if invalid?(b), do: raise "bad b"
      end
      """

      assert [first, second] = analyze(source)
      assert first.meta.line < second.meta.line
    end
  end

  describe "check/2 — not flagged" do
    test "ignores `raise SomeError`" do
      assert [] = analyze("raise ArgumentError")
    end

    test ~s|ignores `raise SomeError, "..."`| do
      assert [] = analyze(~S(raise ArgumentError, "bad input"))
    end

    test "ignores `raise SomeError, opt: value`" do
      assert [] = analyze(~S(raise KeyError, key: :missing))
    end

    test "ignores `raise variable`" do
      assert [] = analyze("raise reason")
    end

    test "ignores `raise %SomeError{...}` (struct literal)" do
      assert [] = analyze(~S(raise %ArgumentError{message: "bad"}))
    end

    test "ignores `raise build_exception(...)`" do
      assert [] = analyze("raise build_exception(id)")
    end

    test "ignores plain function calls" do
      assert [] = analyze("do_work()")
    end

    test "ignores `reraise e, __STACKTRACE__`" do
      # reraise has different AST node, not :raise
      source = ~S"""
      try do
        do_work()
      rescue
        e -> reraise e, __STACKTRACE__
      end
      """

      assert [] = analyze(source)
    end
  end
end
