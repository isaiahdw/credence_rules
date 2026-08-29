defmodule CredenceRules.Pattern.StaticApplyTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.StaticApply

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    StaticApply.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags apply(Foo, :bar, [args])" do
      assert [issue] = analyze(~S"apply(Foo, :bar, [1, 2])")
      assert issue.rule == :static_apply
      assert issue.message =~ "Foo.bar"
    end

    test "flags apply(Foo.Bar, :baz, args)" do
      assert [issue] = analyze(~S"apply(Foo.Bar, :baz, [x])")
      assert issue.message =~ "Foo.Bar.baz"
    end

    test "flags apply(__MODULE__, :foo, [])" do
      assert [issue] = analyze(~S"apply(__MODULE__, :foo, [])")
      assert issue.message =~ "__MODULE__.foo"
    end

    test "flags apply with dynamic args (mod + fun are still literal)" do
      assert [_] = analyze(~S"apply(Foo, :bar, [a] ++ rest)")
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag apply with dynamic module" do
      assert analyze(~S"apply(mod, :run, [arg])") == []
    end

    test "does NOT flag apply with dynamic function" do
      assert analyze(~S"apply(Foo, fun, [arg])") == []
    end

    test "does NOT flag apply/2 (fn-passing form)" do
      assert analyze(~S"apply(fun, [a, b])") == []
    end
  end
end
