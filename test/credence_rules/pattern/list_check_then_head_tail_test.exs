defmodule CredenceRules.Pattern.ListCheckThenHeadTailTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.ListCheckThenHeadTail

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    ListCheckThenHeadTail.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "length(x) > 0 + hd(x)" do
      source = ~S"if length(items) > 0, do: hd(items)"
      assert [_] = analyze(source)
    end

    test "length(x) >= 1 + hd(x)" do
      source = ~S"if length(items) >= 1, do: hd(items)"
      assert [_] = analyze(source)
    end

    test "x != [] + tl(x)" do
      source = ~S"if items != [], do: tl(items)"
      assert [_] = analyze(source)
    end

    test "[] != x + hd(x)" do
      source = ~S"if [] != items, do: hd(items)"
      assert [_] = analyze(source)
    end

    test "length(x) > 0 + List.first(x)" do
      source = ~S"if length(items) > 0, do: List.first(items)"
      assert [_] = analyze(source)
    end

    test "not Enum.empty?(x) + Enum.at(x, 0)" do
      source = ~S"if not Enum.empty?(items), do: Enum.at(items, 0)"
      assert [_] = analyze(source)
    end

    test "Enum.empty?(x) == false + List.last(x)" do
      source = ~S"if Enum.empty?(items) == false, do: List.last(items)"
      assert [_] = analyze(source)
    end

    test "multi-line if-do-end" do
      source = ~S"""
      if length(items) > 0 do
        process(hd(items), tl(items))
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "non-empty check WITHOUT head/tail extraction" do
      source = ~S|if length(items) > 0, do: log("has items")|
      assert [] = analyze(source)
    end

    test "length(x) > N where N >= 1 (real threshold)" do
      source = ~S"if length(items) > 5, do: hd(items)"
      assert [] = analyze(source)
    end

    test "standalone hd(x) without preceding check" do
      source = ~S"value = hd(items)"
      assert [] = analyze(source)
    end

    test "case directly (correct shape)" do
      source = ~S"""
      case items do
        [head | tail] -> process(head, tail)
        [] -> nil
      end
      """

      assert [] = analyze(source)
    end

    test "different list in body" do
      source = ~S"if length(items) > 0, do: hd(other_items)"
      assert [] = analyze(source)
    end

    test "plain code" do
      assert [] = analyze("x = 1")
    end
  end
end
