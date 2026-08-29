defmodule CredenceRules.Pattern.RepeatedCaseArmBodyTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.RepeatedCaseArmBody

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    RepeatedCaseArmBody.check(ast, source: source)
  end

  defp analyze_sourceror(source) do
    {:ok, ast} = Sourceror.parse_string(source)
    RepeatedCaseArmBody.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags two arms with identical bodies" do
      source = ~S"""
      case status do
        :pending -> {:ok, Map.put(state, :ts, now)}
        :running -> {:ok, Map.put(state, :ts, now)}
        :done -> finalise(state)
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :repeated_case_arm_body
      assert issue.message =~ "2 `case` clauses"
    end

    test "flags three arms with identical bodies" do
      source = ~S"""
      case status do
        :pending -> {:ok, %{state | step: :init}}
        :running -> {:ok, %{state | step: :init}}
        :waiting -> {:ok, %{state | step: :init}}
        :done -> done(state)
      end
      """

      assert [issue] = analyze(source)
      assert issue.message =~ "3 `case` clauses"
    end

    test "flags arms whose bodies are byte-for-byte identical (same vars)" do
      source = ~S"""
      case status do
        {:ok, _} -> bar(state)
        {:fine, _} -> bar(state)
        _ -> :error
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "ignores arms with different bodies" do
      source = ~S"""
      case status do
        :pending -> {:ok, :a}
        :running -> {:ok, :b}
      end
      """

      assert [] = analyze(source)
    end

    test "ignores arms that update different accumulator slots (different vars)" do
      # Same call shape, but each writes a different variable — can't
      # merge into one guarded clause, so not a duplicate.
      source = ~S"""
      case op do
        :a -> Map.put(acc, key_a, value)
        :b -> Map.put(acc, key_b, value)
        _ -> acc
      end
      """

      assert [] = analyze(source)
    end

    test "ignores bodies that differ only in a variable name" do
      source = ~S"""
      case status do
        {:ok, x} -> transform(x, state)
        {:fine, y} -> transform(y, state)
        _ -> :error
      end
      """

      assert [] = analyze(source)
    end

    test "ignores when the duplicate is the wildcard arm" do
      # `_ -> :error` paired with `:bad -> :error` — wildcard is exempt.
      source = ~S"""
      case status do
        :good -> :ok
        :bad -> {:error, :handled, lookup(state)}
        _ -> {:error, :handled, lookup(state)}
      end
      """

      assert [] = analyze(source)
    end

    test "ignores trivial bodies (a single atom or variable)" do
      # `:ok` is below the meaningful threshold; merging
      # `:a -> :ok` and `:b -> :ok` adds little.
      source = ~S"""
      case status do
        :a -> :ok
        :b -> :ok
        _ -> :error
      end
      """

      assert [] = analyze(source)
    end

    test "ignores try/rescue/catch arms" do
      # Only `case` is in scope.
      source = ~S"""
      try do
        do_work()
      rescue
        ArgumentError -> {:error, :handled, state}
        ArithmeticError -> {:error, :handled, state}
      end
      """

      assert [] = analyze(source)
    end

    test "ignores lookup table — bodies same shape, different literal values" do
      # `:a -> 1; :b -> 2; :c -> 3` is a dispatch table. The bodies
      # share structure (a single integer literal) but differ on the
      # actual value. Pre-fix this would flag as "3 clauses share the
      # same body" because every literal normalised to `:_lit_`.
      source = ~S"""
      case status do
        :pending -> 1
        :running -> 2
        :complete -> 3
        :failed -> 4
      end
      """

      assert [] = analyze(source)
    end

    test "ignores lookup table — string returns" do
      source = ~S"""
      case verb do
        :get -> "GET"
        :post -> "POST"
        :put -> "PUT"
        :delete -> "DELETE"
      end
      """

      assert [] = analyze(source)
    end

    test "ignores lookup table — tagged-tuple returns differing literally" do
      # `{:ok, 200}` and `{:ok, 404}` share structure but differ on
      # literal — not a duplicate.
      source = ~S"""
      case result do
        :hit -> {:ok, 200}
        :miss -> {:ok, 404}
        :stale -> {:ok, 304}
      end
      """

      assert [] = analyze(source)
    end

    test "still flags genuine duplication where literals match" do
      # Same body literally — not just structurally.
      source = ~S"""
      case status do
        :pending -> {:ok, Map.put(state, :ts, now)}
        :running -> {:ok, Map.put(state, :ts, now)}
        :complete -> finalise(state)
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — Sourceror-parsed (production path)" do
    test "still flags duplicate arms under Sourceror parse" do
      source = ~S"""
      case status do
        :pending -> {:ok, Map.put(state, :ts, now)}
        :running -> {:ok, Map.put(state, :ts, now)}
        _ -> {:error, :unknown}
      end
      """

      assert [_] = analyze_sourceror(source)
    end
  end
end
