defmodule CredenceRules.Pattern.FilterThenFirstTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.FilterThenFirst

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    FilterThenFirst.check(ast, source: source)
  end

  defp analyze_sourceror(source) do
    {:ok, ast} = Sourceror.parse_string(source)
    FilterThenFirst.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "Enum.filter |> List.first" do
      assert [issue] = analyze("users |> Enum.filter(p) |> List.first()")
      assert issue.rule == :filter_then_first
    end

    test "hd(Enum.filter(...)) nested" do
      assert [_] = analyze("hd(Enum.filter(users, p))")
    end

    test "flags under Sourceror parse" do
      source = ~S"""
      defmodule M do
        def first_admin(u), do: u |> Enum.filter(p) |> List.first()
      end
      """

      assert [_] = analyze_sourceror(source)
    end
  end

  describe "check/2 — not flagged" do
    test "Enum.find directly" do
      assert [] = analyze("Enum.find(users, p)")
    end

    test "Enum.filter with no take" do
      assert [] = analyze("Enum.filter(users, p)")
    end

    test "List.first of a non-filter" do
      assert [] = analyze("List.first(users)")
    end
  end
end
