defmodule CredenceRules.Pattern.MatchTestThenExtractTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.MatchTestThenExtract

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    MatchTestThenExtract.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "if match?({:ok, _}, r), do: elem(r, 1)" do
      source = ~S"if match?({:ok, _}, result), do: elem(result, 1)"
      assert [_] = analyze(source)
    end

    test "if match?(%User{}, u), do: u.email" do
      source = ~S"if match?(%User{}, user), do: user.email"
      assert [_] = analyze(source)
    end

    test "if match?(...), do: Map.get(expr, _)" do
      source = ~S"if match?(%{}, data), do: Map.get(data, :id)"
      assert [_] = analyze(source)
    end

    test "if match?(...), do: expr[:key]" do
      source = ~S"if match?(%{}, opts), do: opts[:timeout]"
      assert [_] = analyze(source)
    end

    test "if match?(...) do ... else uses expr too" do
      source = ~S"""
      if match?({:ok, _}, result) do
        elem(result, 1)
      else
        :error
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "match? in body but doesn't extract from expr" do
      source = ~S|if match?({:ok, _}, result), do: log("matched")|
      assert [] = analyze(source)
    end

    test "match? on different expr than body extracts" do
      source = ~S"if match?({:ok, _}, result), do: other_value.field"
      assert [] = analyze(source)
    end

    test "case used directly (correct shape)" do
      source = ~S"""
      case result do
        {:ok, value} -> value
        _ -> nil
      end
      """

      assert [] = analyze(source)
    end

    test "match? in guard (when match?(...))" do
      source = ~S"""
      def f(x) when match?({:ok, _}, x), do: x
      """

      assert [] = analyze(source)
    end

    test "match? in Enum.filter (extraction-free shape test)" do
      source = ~S"Enum.filter(results, fn r -> match?({:ok, _}, r) end)"
      assert [] = analyze(source)
    end

    test "plain code" do
      assert [] = analyze("x = 1")
    end
  end
end
