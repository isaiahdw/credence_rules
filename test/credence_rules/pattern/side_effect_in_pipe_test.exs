defmodule CredenceRules.Pattern.SideEffectInPipeTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.SideEffectInPipe

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    SideEffectInPipe.check(ast, source: source)
  end

  defp analyze_sourceror(source) do
    {:ok, ast} = Sourceror.parse_string(source)
    SideEffectInPipe.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "Logger call in the middle of a pipe" do
      assert [issue] = analyze(~S{record |> normalize() |> Logger.info("done") |> persist()})
      assert issue.rule == :side_effect_in_pipe
      assert issue.meta.call == "Logger.info"
    end

    test "IO.puts in the middle of a pipe" do
      assert [_] = analyze("x |> a() |> IO.puts() |> b()")
    end

    test "two side-effect stages → two findings" do
      source = ~S"""
      x
      |> Logger.info("a")
      |> f()
      |> Logger.error("b")
      |> g()
      """

      assert [_, _] = analyze(source)
    end

    test "flags under Sourceror parse (production path)" do
      source = ~S"""
      defmodule M do
        def run(x), do: x |> a() |> Logger.info("x") |> b()
      end
      """

      assert [_] = analyze_sourceror(source)
    end
  end

  describe "check/2 — not flagged" do
    test "side-effect call as the LAST pipe stage" do
      assert [] = analyze(~S{x |> build() |> Logger.info()})
    end

    test "IO.inspect threads its argument through" do
      assert [] = analyze("x |> a() |> IO.inspect() |> b()")
    end

    test "pipe with no side-effect stages" do
      assert [] = analyze("x |> a() |> b() |> c()")
    end

    test "two-stage pipe ending in a Logger call" do
      assert [] = analyze(~S{x |> Logger.info()})
    end

    test "a plain Logger statement (not in a pipe)" do
      assert [] = analyze(~S{Logger.info("hello")})
    end
  end
end
