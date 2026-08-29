defmodule CredenceRules.Pattern.CondShapeChecksShouldCaseTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.CondShapeChecksShouldCase

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    CondShapeChecksShouldCase.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "cond with is_* shape tests on same value + extraction" do
      source = ~S"""
      cond do
        is_binary(value) ->
          parse_binary(value)

        is_map(value) and Map.has_key?(value, :id) ->
          parse_id(Map.get(value, :id))

        true ->
          :unknown
      end
      """

      assert [_] = analyze(source)
    end

    test "two is_* branches on same value" do
      source = ~S"""
      cond do
        is_atom(x) -> handle_atom(x)
        is_binary(x) -> handle_binary(x)
        true -> :other
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "unrelated boolean conditions (the right cond use case)" do
      source = ~S"""
      cond do
        retries > 5 -> :give_up
        Process.alive?(server) -> :ready
        config[:fallback] -> :use_fallback
        true -> :wait
      end
      """

      assert [] = analyze(source)
    end

    test "pure predicate cond (no shape testing)" do
      source = ~S"""
      cond do
        score > 90 -> :excellent
        score > 70 -> :good
        true -> :ok
      end
      """

      assert [] = analyze(source)
    end

    test "single shape-check branch (too small)" do
      source = ~S"""
      cond do
        is_binary(value) -> parse(value)
        true -> :unknown
      end
      """

      assert [] = analyze(source)
    end

    test "is_* branches but body doesn't extract from the value" do
      source = ~S"""
      cond do
        is_binary(x) -> :is_string
        is_atom(x) -> :is_atom
        true -> :other
      end
      """

      # Body returns atoms, doesn't use x → not flagged.
      assert [] = analyze(source)
    end

    test "case (already correct shape)" do
      source = ~S"""
      case value do
        x when is_binary(x) -> parse(x)
        %{id: id} -> parse_id(id)
        _ -> :unknown
      end
      """

      assert [] = analyze(source)
    end

    test "plain code" do
      assert [] = analyze("x = 1")
    end
  end
end
