defmodule CredenceRules.Pattern.BooleanFlagArgumentTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.BooleanFlagArgument

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    BooleanFlagArgument.check(ast, source: source)
  end

  defp analyze_sourceror(source) do
    {:ok, ast} = Sourceror.parse_string(source)
    BooleanFlagArgument.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "def with a `false` default" do
      assert [issue] = analyze("def render(doc, compact \\\\ false), do: doc")
      assert issue.rule == :boolean_flag_argument
      assert issue.meta.function == :render
      assert issue.meta.flag == :compact
    end

    test "def with a `true` default" do
      assert [_] = analyze("def valid?(x, strict \\\\ true), do: x")
    end

    test "defp with a boolean default" do
      assert [_] = analyze("defp fetch(id, preload \\\\ false), do: id")
    end

    test "guarded head with a boolean default" do
      assert [_] = analyze("def f(x, force \\\\ false) when is_integer(x), do: x")
    end

    test "flags under Sourceror parse (production path)" do
      source = ~S"""
      defmodule M do
        def render(doc, compact \\ false), do: doc
      end
      """

      assert [_] = analyze_sourceror(source)
    end
  end

  describe "check/2 — not flagged" do
    test "non-boolean defaults" do
      assert [] = analyze("def f(x, opts \\\\ []), do: x")
      assert [] = analyze("def f(x, v \\\\ nil), do: x")
      assert [] = analyze("def f(x, timeout \\\\ 5_000), do: x")
    end

    test "boolean parameter with no default" do
      assert [] = analyze("def f(x, flag), do: flag")
    end

    test "no parameters" do
      assert [] = analyze("def f, do: :ok")
    end

    test "ordinary multi-arg function" do
      assert [] = analyze("def combine(a, b, c), do: {a, b, c}")
    end
  end
end
