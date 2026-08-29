defmodule CredenceRules.Pattern.SortThenTakeFirstTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.SortThenTakeFirst

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    SortThenTakeFirst.check(ast, source: source)
  end

  defp analyze_sourceror(source) do
    {:ok, ast} = Sourceror.parse_string(source)
    SortThenTakeFirst.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "Enum.sort |> hd" do
      assert [issue] = analyze("scores |> Enum.sort() |> hd()")
      assert issue.rule == :sort_then_take_first
    end

    test "List.last(Enum.sort(x)) nested" do
      assert [_] = analyze("List.last(Enum.sort(scores))")
    end

    test "Enum.sort_by |> hd" do
      assert [_] = analyze("players |> Enum.sort_by(& &1.age) |> hd()")
    end

    test "List.first(Enum.sort(x))" do
      assert [_] = analyze("List.first(Enum.sort(scores))")
    end

    test "flags under Sourceror parse" do
      source = ~S"""
      defmodule M do
        def lowest(s), do: s |> Enum.sort() |> hd()
      end
      """

      assert [_] = analyze_sourceror(source)
    end
  end

  describe "check/2 — not flagged" do
    test "Enum.sort with no take" do
      assert [] = analyze("Enum.sort(scores)")
    end

    test "hd on something that isn't a sort" do
      assert [] = analyze("hd(items)")
    end

    test "Enum.min directly" do
      assert [] = analyze("Enum.min(scores)")
    end
  end
end
