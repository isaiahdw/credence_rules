defmodule CredenceRules.AstNormalizeTest do
  use ExUnit.Case, async: true

  alias CredenceRules.AstNormalize

  defp ast(src), do: Code.string_to_quoted!(src)

  describe "canonicalize/1" do
    test "different variable names hash the same" do
      a = ast("x + 1")
      b = ast("result + 1")
      assert AstNormalize.hash(a) == AstNormalize.hash(b)
    end

    test "different literal values hash the same" do
      a = ast(~s("hello"))
      b = ast(~s("world"))
      c = ast("42")
      assert AstNormalize.hash(a) == AstNormalize.hash(b)
      assert AstNormalize.hash(a) == AstNormalize.hash(c)
    end

    test "different function names DO NOT hash the same" do
      a = ast("foo(x)")
      b = ast("bar(x)")
      refute AstNormalize.hash(a) == AstNormalize.hash(b)
    end

    test "different module aliases DO NOT hash the same" do
      a = ast("Foo.bar(x)")
      b = ast("Baz.bar(x)")
      refute AstNormalize.hash(a) == AstNormalize.hash(b)
    end

    test "control-flow keywords are preserved" do
      a = ast("if x, do: y, else: z")
      b = ast("if a, do: b, else: c")
      assert AstNormalize.hash(a) == AstNormalize.hash(b)

      c = ast("unless x, do: y, else: z")
      refute AstNormalize.hash(a) == AstNormalize.hash(c)
    end

    test "preserves operator distinctions" do
      a = ast("x + y")
      b = ast("x - y")
      refute AstNormalize.hash(a) == AstNormalize.hash(b)
    end

    test "ignores line metadata" do
      # Same fragment, parsed with different start lines via offset
      a = ast("x = 1\ny = x")
      b = ast("\n\n\nx = 1\ny = x")
      assert AstNormalize.hash(a) == AstNormalize.hash(b)
    end

    test "structurally identical with different argument counts hashes differently" do
      a = ast("foo(x, y)")
      b = ast("foo(x)")
      refute AstNormalize.hash(a) == AstNormalize.hash(b)
    end
  end

  describe "count_nodes/1 + meaningful?/2" do
    test "single variable is below default threshold" do
      refute AstNormalize.meaningful?(ast("x"))
    end

    test "trivial 1-arg call is below default threshold" do
      refute AstNormalize.meaningful?(ast("foo(x)"))
    end

    test "a remote 2-arg call is meaningful at default threshold" do
      assert AstNormalize.meaningful?(ast("Foo.bar(x, y)"))
    end

    test "a multi-statement block is meaningful at default threshold" do
      assert AstNormalize.meaningful?(ast("x = 1; foo(x); :ok"))
    end

    test "configurable threshold" do
      assert AstNormalize.meaningful?(ast("x"), 1)
      refute AstNormalize.meaningful?(ast("foo(x)"), 100)
    end
  end
end
