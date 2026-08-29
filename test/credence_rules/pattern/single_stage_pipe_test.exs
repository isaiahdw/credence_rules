defmodule CredenceRules.Pattern.SingleStagePipeTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.SingleStagePipe

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    SingleStagePipe.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags `x |> foo()`" do
      assert [issue] = analyze("x |> String.trim()")
      assert issue.rule == :single_stage_pipe
    end

    test "flags `x |> foo(arg)` (single-stage with extra arg)" do
      assert [_] = analyze(~s{x |> String.replace("a", "b")})
    end

    test "flags `nested |> foo()` inside a function arg" do
      assert [_] = analyze("wrap(x |> String.trim())")
    end

    test "flags inside a lambda body" do
      assert [_] = analyze("Enum.map(list, fn x -> x |> String.trim() end)")
    end

    test "reports the line of the pipe" do
      source = ~S"""
      def go(x) do
        x = preprocess(x)
        result = x |> String.trim()
        result
      end
      """

      assert [issue] = analyze(source)
      assert issue.meta.line == 3
    end

    test "flags each single-stage pipe separately" do
      source = ~S"""
      def go(a, b) do
        x = a |> String.trim()
        y = b |> String.trim()
        {x, y}
      end
      """

      assert [first, second] = analyze(source)
      assert first.meta.line == 2
      assert second.meta.line == 3
    end
  end

  describe "check/2 — not flagged" do
    test "ignores 2-stage pipes" do
      assert [] = analyze("x |> String.trim() |> String.downcase()")
    end

    test "ignores 3-stage pipes" do
      assert [] = analyze(~s{x |> String.trim() |> String.downcase() |> String.split(" ")})
    end

    test "ignores plain function calls" do
      assert [] = analyze("String.trim(x)")
    end

    test "ignores plain expressions and bindings" do
      assert [] = analyze("x = 1")
      assert [] = analyze("user.name")
    end

    test "ignores a 2-stage chain even when one stage takes extra args" do
      assert [] = analyze(~s{x |> String.replace("a", "b") |> String.downcase()})
    end

    test "ignores deeply nested 2-stage chain inside a function arg" do
      assert [] = analyze("wrap(x |> String.trim() |> String.downcase())")
    end

    test "ignores `user.name |> foo()` — field access on bare value still flags? no, it does flag" do
      # `user.name |> String.upcase()` — the docstring shows this as bad.
      # The LHS `user.name` is a bare field access, so this fires.
      # (Regression-guarding the docstring contract.)
      assert [_] = analyze("user.name |> String.upcase()")
    end

    test "ignores `f(x) |> g(y)` — function-call LHS is a real first stage" do
      # Two distinct transformations chained via a pipe — the canonical
      # two-stage pattern. The rule used to fire on this because the LHS
      # wasn't a `|>`. Tightened to require a bare-value LHS.
      assert [] = analyze(":crypto.hash(:sha256, x) |> binary_part(0, 20)")
      assert [] = analyze("f(x) |> g(y)")
      assert [] = analyze("Bitwise.bsr(raw, 24) |> Bitwise.band(0xFF)")
    end

    test "ignores map / struct / tuple literal LHS — builder pattern" do
      assert [] = analyze("%{a: 1} |> Map.put(:b, 2)")
      assert [] = analyze("%MyStruct{x: 1} |> MyStruct.set_y(2)")
      assert [] = analyze("{:ok, value} |> elem(1)")
    end

    test "ignores binary-construction LHS" do
      assert [] = analyze(~S{<<1, 2, 3>> |> Base.encode16()})
    end

    test "ignores 0-arity remote calls on the LHS — same AST shape as field access but a real transformation" do
      # `Module.function()` parses as `{{:., _, [{:__aliases__, _, _}, fun]}, _, []}`,
      # which shares the same arity-list shape as field access (`user.name`).
      # These are two distinct ops chained via a pipe — not single-stage.
      assert [] = analyze("DateTime.utc_now() |> DateTime.to_iso8601()")
      assert [] = analyze("Module.function() |> Enum.each(fn x -> x end)")
      assert [] = analyze("Foo.Bar.baz() |> Enum.map(&to_string/1)")
      assert [] = analyze("Storage.list_devices() |> Enum.filter(&active?/1)")
    end

    test "still flags field access on a variable (the docstring case)" do
      assert [_] = analyze("user.name |> String.upcase()")
      assert [_] = analyze("config.timeout |> Integer.to_string()")
    end
  end
end
