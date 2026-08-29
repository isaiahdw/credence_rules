defmodule CredenceRules.Pattern.AnonymousFnCaptureWrapTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.AnonymousFnCaptureWrap

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    AnonymousFnCaptureWrap.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags `fn x -> foo(x) end`" do
      assert [issue] = analyze("Enum.map(list, fn x -> trim(x) end)")
      assert issue.rule == :anonymous_fn_capture_wrap
      assert issue.meta.target == "trim/1"
    end

    test "flags `fn x -> Mod.foo(x) end`" do
      assert [issue] = analyze("Enum.map(list, fn x -> String.trim(x) end)")
      assert issue.meta.target == "String.trim/1"
    end

    test "flags `fn x -> A.B.C.foo(x) end` (nested module)" do
      assert [issue] = analyze("Enum.map(list, fn x -> A.B.C.foo(x) end)")
      assert issue.meta.target == "A.B.C.foo/1"
    end

    test "flags inside Enum.filter / Enum.each" do
      assert [_] = analyze("Enum.filter(list, fn x -> active?(x) end)")
      assert [_] = analyze("Enum.each(list, fn x -> handle(x) end)")
    end

    test "reports the line of the fn" do
      source = ~S"""
      def go(list) do
        Enum.map(list, fn x -> String.trim(x) end)
      end
      """

      assert [issue] = analyze(source)
      assert issue.meta.line == 2
    end

    test "flags each occurrence in a single function" do
      source = ~S"""
      def go(list) do
        a = Enum.map(list, fn x -> trim(x) end)
        b = Enum.filter(a, fn x -> active?(x) end)
        b
      end
      """

      assert [first, second] = analyze(source)
      assert first.meta.target == "trim/1"
      assert second.meta.target == "active?/1"
    end
  end

  describe "check/2 — not flagged" do
    test "ignores multi-arg lambdas" do
      assert [] = analyze("Enum.reduce(list, 0, fn x, acc -> acc + x end)")
      assert [] = analyze("Enum.reduce(list, %{}, fn x, acc -> Map.put(acc, x, true) end)")
    end

    test "ignores lambdas whose body uses the arg in an expression" do
      assert [] = analyze("Enum.map(list, fn x -> x + 1 end)")
      assert [] = analyze("Enum.map(list, fn x -> x.field end)")
    end

    test "ignores lambdas where the call has extra args" do
      assert [] = analyze("Enum.map(list, fn x -> String.replace(x, \"a\", \"b\") end)")
    end

    test "ignores lambdas where the call uses a different binding" do
      assert [] = analyze("Enum.map(list, fn x -> trim(y) end)")
    end

    test "ignores lambdas with multi-line bodies" do
      source = ~S"""
      Enum.map(list, fn x ->
        Logger.debug(x)
        trim(x)
      end)
      """

      assert [] = analyze(source)
    end

    test "ignores zero-arg lambdas" do
      assert [] = analyze("Task.async(fn -> work() end)")
    end

    test "ignores plain capture syntax" do
      assert [] = analyze("Enum.map(list, &String.trim/1)")
    end

    test "ignores `apply` / `not` (special targets)" do
      assert [] = analyze("Enum.map(list, fn x -> not(x) end)")
    end

    test "ignores lambdas whose body returns a tuple (not a single call)" do
      assert [] = analyze("Enum.map(list, fn x -> {:ok, x} end)")
    end
  end
end
