defmodule CredenceRules.Pattern.NestedCallsShouldPipeTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.NestedCallsShouldPipe

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    NestedCallsShouldPipe.check(ast, source: source)
  end

  defp analyze_sourceror(source) do
    {:ok, ast} = Sourceror.parse_string(source)
    NestedCallsShouldPipe.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "three nested local calls" do
      assert [issue] = analyze("f(g(h(x)))")
      assert issue.rule == :nested_calls_should_pipe
    end

    test "three nested remote calls (Enum chain)" do
      assert [_] = analyze("Enum.map(Enum.filter(Enum.uniq(list), p), f)")
    end

    test "four-deep chain reports once (outermost only)" do
      assert [_] = analyze("f(g(h(i(x))))")
    end

    test "two independent sibling chains in a list" do
      assert [_, _] = analyze("[a(b(c(x))), p(q(r(y)))]")
    end

    test "flags under Sourceror parse (production path)" do
      source = ~S"""
      defmodule M do
        def go(list), do: Enum.map(Enum.filter(Enum.uniq(list), p), f)
      end
      """

      assert [_] = analyze_sourceror(source)
    end
  end

  describe "check/2 — not flagged" do
    test "two-deep nesting" do
      assert [] = analyze("f(g(x))")
    end

    test "value threaded as a non-first argument" do
      assert [] = analyze("g(other, h(x))")
    end

    test "operator chains" do
      assert [] = analyze("a + b + c + d")
    end

    test "nested control-flow" do
      assert [] = analyze("if a do (case b do _ -> c end) end")
    end

    test "honours :min_pipe_depth" do
      # f(g(h(x))) is depth 3; require 4 → spared.
      {:ok, ast} = Code.string_to_quoted("f(g(h(x)))")
      assert [] = NestedCallsShouldPipe.check(ast, min_pipe_depth: 4)
    end

    test "module attribute definitions are not miscounted" do
      # `@x MapSet.new(...)` is a 2-deep value; the attribute name must
      # not add a phantom third layer.
      assert [] = analyze("defmodule M do\n  @x MapSet.new(~w(a b c)a)\nend")
      assert [] = analyze("defmodule M do\n  @lk Map.new(Enum.flat_map(@r, fn x -> x end))\nend")
    end

    test "definition forms and their heads aren't chains" do
      assert [] = analyze("defmodule My.App.Thing do\n  def go(x), do: x\nend")
    end
  end
end
