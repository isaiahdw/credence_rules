defmodule CredenceRules.Pattern.EnumIntoForMapNewTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.EnumIntoForMapNew

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    EnumIntoForMapNew.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags `Enum.into(pairs, %{})`" do
      assert [issue] = analyze("Enum.into(pairs, %{})")
      assert issue.rule == :enum_into_for_map_new
      assert issue.meta.form == :two_arg
    end

    test "flags `pairs |> Enum.into(%{})`" do
      assert [issue] = analyze("pairs |> Enum.into(%{})")
      assert issue.meta.form == :piped
    end

    test "flags 3-arg form with mapper" do
      assert [issue] = analyze("Enum.into(users, %{}, fn u -> {u.id, u.name} end)")
      assert issue.meta.form == :three_arg
    end

    test "flags piped 3-arg form" do
      assert [issue] = analyze("users |> Enum.into(%{}, fn u -> {u.id, u.name} end)")
      assert issue.meta.form == :piped_three_arg
    end

    test "flags Enum.into where source is a function call" do
      assert [_] = analyze("Enum.into(get_pairs(), %{})")
    end

    test "reports the line of the Enum.into call" do
      source = ~S"""
      def to_map(pairs) do
        cleaned = clean(pairs)
        Enum.into(cleaned, %{})
      end
      """

      assert [issue] = analyze(source)
      assert issue.meta.line == 3
    end

    test "flags each occurrence in a single function" do
      source = ~S"""
      def both(a, b) do
        x = Enum.into(a, %{})
        y = b |> Enum.into(%{})
        {x, y}
      end
      """

      assert [first, second] = analyze(source)
      assert first.meta.form == :two_arg
      assert second.meta.form == :piped
    end
  end

  describe "check/2 — not flagged" do
    test "ignores `Enum.map(...) |> Enum.into(%{})` (map_into_literal owns this)" do
      assert [] = analyze("users |> Enum.map(fn u -> {u.id, u} end) |> Enum.into(%{})")
    end

    test "ignores `Enum.into(Enum.map(...), %{})` (map_into_literal owns this)" do
      assert [] = analyze("Enum.into(Enum.map(users, fn u -> {u.id, u} end), %{})")
    end

    test "ignores `... |> Enum.map(...) |> Enum.into(%{})` deeper chain (map_into_literal)" do
      assert [] = analyze("a |> b() |> Enum.map(fn u -> {u.id, u} end) |> Enum.into(%{})")
    end

    test "ignores Enum.into to non-empty target" do
      assert [] = analyze("Enum.into(pairs, seed)")
    end

    test "ignores Enum.into to a keyword list" do
      assert [] = analyze("Enum.into(opts, [])")
    end

    test "ignores Map.new direct usage" do
      assert [] = analyze("Map.new(pairs)")
    end

    test "ignores Stream.into (different module)" do
      assert [] = analyze("Stream.into(stream, %{})")
    end
  end
end
