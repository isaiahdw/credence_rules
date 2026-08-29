defmodule CredenceRules.Pattern.FilterThenCountTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.FilterThenCount

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    FilterThenCount.check(ast, source: source)
  end

  defp analyze_sourceror(source) do
    {:ok, ast} = Sourceror.parse_string(source)
    FilterThenCount.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "Enum.filter |> Enum.count" do
      assert [issue] = analyze("users |> Enum.filter(p) |> Enum.count()")
      assert issue.rule == :filter_then_count
    end

    test "length(Enum.filter(...)) nested" do
      assert [_] = analyze("length(Enum.filter(users, p))")
    end

    test "Enum.count(Enum.filter(...)) nested" do
      assert [_] = analyze("Enum.count(Enum.filter(users, p))")
    end

    test "flags under Sourceror parse" do
      source = ~S"""
      defmodule M do
        def active_count(u), do: u |> Enum.filter(p) |> Enum.count()
      end
      """

      assert [_] = analyze_sourceror(source)
    end
  end

  describe "check/2 — not flagged" do
    test "Enum.count/2 directly" do
      assert [] = analyze("Enum.count(users, p)")
    end

    test "Enum.filter with no count" do
      assert [] = analyze("Enum.filter(users, p)")
    end

    test "length of a non-filter" do
      assert [] = analyze("length(users)")
    end
  end
end
