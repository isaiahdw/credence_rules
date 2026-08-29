defmodule CredenceRules.Pattern.HdOrTlCallTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.HdOrTlCall

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    HdOrTlCall.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags `hd(list)`" do
      assert [issue] = analyze("first = hd(list)")
      assert issue.rule == :hd_or_tl_call
      assert issue.meta.fun == :hd
    end

    test "flags `tl(list)`" do
      assert [issue] = analyze("rest = tl(list)")
      assert issue.meta.fun == :tl
    end

    test "flags fully-qualified `Kernel.hd(list)`" do
      assert [_] = analyze("first = Kernel.hd(list)")
    end

    test "flags fully-qualified `Kernel.tl(list)`" do
      assert [_] = analyze("rest = Kernel.tl(list)")
    end

    test "flags both in one expression" do
      source = ~S"""
      def process(list) do
        first = hd(list)
        rest = tl(list)
        {first, rest}
      end
      """

      assert [a, b] = analyze(source)
      assert a.meta.fun == :hd
      assert b.meta.fun == :tl
      assert a.meta.line == 2
      assert b.meta.line == 3
    end

    test "flags `hd(some_call(x))` (nested call argument)" do
      assert [_] = analyze("hd(filter(list))")
    end

    test "flags both outer and inner of `hd(hd(list))`" do
      # Macro.prewalk visits both nodes; we don't suppress nested.
      assert issues = analyze("hd(hd(list))")
      assert length(issues) == 2
    end
  end

  describe "check/2 — not flagged" do
    test "ignores List.first / List.last" do
      assert [] = analyze("first = List.first(list)")
      assert [] = analyze(~S|last = List.last(list, :default)|)
    end

    test "ignores pattern matches" do
      assert [] = analyze("[first | rest] = list")
    end

    test "ignores plain code" do
      assert [] = analyze("x = 1")
    end

    test "ignores other 1-arg calls with hd/tl-like names" do
      assert [] = analyze("first = head(list)")
      assert [] = analyze("first = take_first(list)")
    end

    test "ignores `MyMod.hd` (not the Kernel-import)" do
      # Foo.hd(list) is a custom Foo.hd, not the Kernel BIF.
      assert [] = analyze("first = MyMod.hd(list)")
    end

    test "ignores zero-arg `hd()` (degenerate, not a real call)" do
      # `hd()` without args won't compile, but parses fine; we only
      # match `hd(_)` with exactly one argument.
      assert [] = analyze("hd()")
    end
  end
end
