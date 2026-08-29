defmodule CredenceRules.Pattern.ReduceMapPutTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.ReduceMapPut

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    ReduceMapPut.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags Enum.reduce/3 with %{} seed and Map.put body" do
      source = "Enum.reduce(users, %{}, fn u, acc -> Map.put(acc, u.id, u.name) end)"
      assert [issue] = analyze(source)
      assert issue.rule == :reduce_map_put
    end

    test "flags piped Enum.reduce" do
      source = "users |> Enum.reduce(%{}, fn u, acc -> Map.put(acc, u.id, u.name) end)"
      assert [_] = analyze(source)
    end

    test "flags multi-line lambda body that is still just Map.put" do
      source = ~S"""
      Enum.reduce(users, %{}, fn user, acc ->
        Map.put(acc, user.id, user.name)
      end)
      """

      assert [_] = analyze(source)
    end

    test "reports the line of the Enum.reduce" do
      source = ~S"""
      def index(users) do
        Enum.reduce(users, %{}, fn u, acc -> Map.put(acc, u.id, u.name) end)
      end
      """

      assert [issue] = analyze(source)
      assert issue.meta.line == 2
    end

    test "flags each occurrence in one function" do
      source = ~S"""
      def both(a, b) do
        x = Enum.reduce(a, %{}, fn u, acc -> Map.put(acc, u.id, u) end)
        y = Enum.reduce(b, %{}, fn u, acc -> Map.put(acc, u.id, u) end)
        {x, y}
      end
      """

      assert [first, second] = analyze(source)
      assert first.meta.line == 2
      assert second.meta.line == 3
    end
  end

  describe "check/2 — not flagged" do
    test "ignores non-empty seed" do
      source = "Enum.reduce(users, seed, fn u, acc -> Map.put(acc, u.id, u) end)"
      assert [] = analyze(source)
    end

    test "ignores reduce whose body does more than Map.put on acc" do
      source = ~S"""
      Enum.reduce(users, %{}, fn u, acc ->
        if u.active, do: Map.put(acc, u.id, u), else: acc
      end)
      """

      assert [] = analyze(source)
    end

    test "ignores reduce where Map.put isn't on the accumulator" do
      source = "Enum.reduce(users, %{}, fn u, acc -> Map.put(state, u.id, u) end)"
      assert [] = analyze(source)
    end

    test "ignores reduce using Map.update! instead of Map.put" do
      source = "Enum.reduce(users, %{}, fn u, acc -> Map.update!(acc, u.id, &(&1 + 1)) end)"
      assert [] = analyze(source)
    end

    test "ignores reduce using Map.merge" do
      source = "Enum.reduce(users, %{}, fn u, acc -> Map.merge(acc, %{u.id => u}) end)"
      assert [] = analyze(source)
    end

    test "ignores plain Map.new" do
      assert [] = analyze("Map.new(users, fn u -> {u.id, u} end)")
    end

    test "ignores reduce with [] seed (that's reduce_as_map's job)" do
      source = "Enum.reduce(users, [], fn u, acc -> [u | acc] end)"
      assert [] = analyze(source)
    end
  end
end
