defmodule CredenceRules.Pattern.IfValueElseNilTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.IfValueElseNil

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    IfValueElseNil.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags `if value, do: value, else: nil`" do
      assert [issue] = analyze("if user, do: user, else: nil")
      assert issue.rule == :if_value_else_nil
    end

    test "flags `if value, do: value` (implicit nil else)" do
      assert [_] = analyze("if user, do: user")
    end

    test "flags struct-field shapes (`if user.name, do: user.name`)" do
      assert [_] = analyze("if user.name, do: user.name, else: nil")
    end

    test "flags block form `if x do x else nil end`" do
      source = ~S"""
      if user do
        user
      else
        nil
      end
      """

      assert [_] = analyze(source)
    end

    test "flags block form without else" do
      source = ~S"""
      if user do
        user
      end
      """

      assert [_] = analyze(source)
    end

    test "flags Map-access shape (`if m[:k], do: m[:k], else: nil`)" do
      assert [_] = analyze("if m[:k], do: m[:k], else: nil")
    end

    test "reports the line of the if" do
      source = ~S"""
      def maybe(user) do
        x = preprocess(user)
        if x, do: x, else: nil
      end
      """

      assert [issue] = analyze(source)
      assert issue.meta.line == 3
    end

    test "flags each occurrence in a single function" do
      source = ~S"""
      def both(a, b) do
        x = if a, do: a, else: nil
        y = if b, do: b, else: nil
        {x, y}
      end
      """

      assert [first, second] = analyze(source)
      assert first.meta.line == 2
      assert second.meta.line == 3
    end
  end

  describe "check/2 — not flagged" do
    test "ignores if with different do-value" do
      assert [] = analyze("if user, do: user.name, else: nil")
    end

    test "ignores if with non-nil else" do
      assert [] = analyze("if user, do: user, else: default")
    end

    test "ignores if with literal do-value that isn't the condition" do
      assert [] = analyze("if user, do: true, else: nil")
    end

    test "ignores plain expressions" do
      assert [] = analyze("user")
      assert [] = analyze("user || nil")
    end

    test "ignores unless (different macro)" do
      # `unless cond, do: cond, else: nil` is also redundant but is a
      # separate shape; we don't claim to catch it.
      assert [] = analyze("unless user, do: user, else: nil")
    end
  end
end
