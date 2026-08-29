defmodule CredenceRules.Pattern.MapIntoLiteralTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.MapIntoLiteral

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    MapIntoLiteral.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags `Enum.map(...) |> Enum.into(%{})`" do
      source = "users |> Enum.map(fn u -> {u.id, u} end) |> Enum.into(%{})"
      assert [issue] = analyze(source)
      assert issue.rule == :map_into_literal
    end

    test "flags `Enum.into(Enum.map(...), %{})` non-piped form" do
      source = "Enum.into(Enum.map(users, fn u -> {u.id, u} end), %{})"
      assert [_] = analyze(source)
    end

    test "flags pipe chain with leading source stages" do
      source = "users |> filter() |> Enum.map(fn u -> {u.id, u} end) |> Enum.into(%{})"
      assert [_] = analyze(source)
    end

    test "reports the line of the Enum.into call" do
      source = ~S"""
      def index(users) do
        users
        |> Enum.map(fn u -> {u.id, u} end)
        |> Enum.into(%{})
      end
      """

      assert [issue] = analyze(source)
      assert issue.meta.line == 4
    end

    test "flags each map+into pair when there are multiple" do
      source = ~S"""
      def build(users, items) do
        u = Enum.map(users, fn u -> {u.id, u} end) |> Enum.into(%{})
        i = Enum.into(Enum.map(items, fn i -> {i.id, i} end), %{})
        {u, i}
      end
      """

      assert [a, b] = analyze(source)
      assert a.meta.line == 2
      assert b.meta.line == 3
    end
  end

  describe "check/2 — not flagged" do
    test "ignores Map.new" do
      assert [] = analyze("Map.new(users, fn u -> {u.id, u} end)")
    end

    test "ignores Enum.into into a non-empty target" do
      assert [] = analyze("Enum.map(users, fn u -> {u.id, u} end) |> Enum.into(seed)")
    end

    test "ignores Enum.into without a preceding Enum.map (enum_into_for_map_new owns that)" do
      assert [] = analyze("pairs |> Enum.into(%{})")
    end

    test "ignores `Stream.into(Stream.map(...), %{})` (different module)" do
      assert [] = analyze("Stream.into(Stream.map(users, fn u -> {u.id, u} end), %{})")
    end

    test "ignores Enum.into to a Keyword.new" do
      assert [] = analyze("Enum.map(opts, fn {k, v} -> {k, v} end) |> Enum.into([])")
    end
  end
end
