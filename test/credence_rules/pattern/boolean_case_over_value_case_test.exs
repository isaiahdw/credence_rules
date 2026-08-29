defmodule CredenceRules.Pattern.BooleanCaseOverValueCaseTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.BooleanCaseOverValueCase

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    BooleanCaseOverValueCase.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "case Map.has_key?(...) do true -> ...; false -> ... end" do
      source = ~S"""
      case Map.has_key?(params, "id") do
        true -> load_user(params["id"])
        false -> :missing
      end
      """

      assert [_] = analyze(source)
    end

    test "case match?(...) do true/false ... end" do
      source = ~S"""
      case match?({:ok, _}, result) do
        true -> elem(result, 1)
        false -> :error
      end
      """

      assert [_] = analyze(source)
    end

    test "case is_nil(x) do true/false ... end" do
      source = ~S"""
      case is_nil(value) do
        true -> :default
        false -> use(value)
      end
      """

      assert [_] = analyze(source)
    end

    test "case is_pid(x) do true/false end (any is_* predicate)" do
      source = ~S"""
      case is_pid(p) do
        true -> handle(p)
        false -> :not_a_pid
      end
      """

      assert [_] = analyze(source)
    end

    test "case Enum.member?(list, x) do true/false ... end" do
      source = ~S"""
      case Enum.member?(list, target) do
        true -> :found
        false -> :missing
      end
      """

      assert [_] = analyze(source)
    end

    test "reversed clause order (false first, true second) still flags" do
      source = ~S"""
      case Map.has_key?(m, :id) do
        false -> :missing
        true -> :found
      end
      """

      assert [_] = analyze(source)
    end

    test "trailing-? function call (boolean by convention)" do
      source = ~S"""
      case User.active?(user) do
        true -> render(user)
        false -> :inactive
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "case over a value (already the goal shape)" do
      source = ~S"""
      case result do
        {:ok, value} -> value
        _ -> :error
      end
      """

      assert [] = analyze(source)
    end

    test "case with patterns other than just true/false" do
      source = ~S"""
      case Map.get(m, :status) do
        :active -> :go
        :inactive -> :stop
        _ -> :unknown
      end
      """

      assert [] = analyze(source)
    end

    test "case with true/false BUT discriminator is not a predicate" do
      source = ~S"""
      case some_stored_boolean do
        true -> :go
        false -> :stop
      end
      """

      assert [] = analyze(source)
    end

    test "case with true/false BUT only one clause (degenerate)" do
      source = ~S"""
      case some_predicate?() do
        true -> :go
      end
      """

      # Both true AND false required; not flagged.
      assert [] = analyze(source)
    end

    test "plain code" do
      assert [] = analyze("x = 1")
    end
  end
end
