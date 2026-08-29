defmodule CredenceRules.Pattern.WithComplexElseTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.WithComplexElse

  defp analyze(source, opts \\ []) do
    {:ok, ast} = Code.string_to_quoted(source)
    WithComplexElse.check(ast, opts)
  end

  describe "check/2 — flagged" do
    test "flags `with ... else` with 4 arms (default threshold)" do
      source = ~S"""
      with {:ok, a} <- f1(),
           {:ok, b} <- f2(a),
           {:ok, c} <- f3(b) do
        c
      else
        {:error, :one} -> :handle_one
        {:error, :two} -> :handle_two
        {:error, :three} -> :handle_three
        :error -> :handle_generic
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :with_complex_else
      assert issue.message =~ "4 arms"
    end

    test "flags 5-arm else" do
      source = ~S"""
      with {:ok, a} <- f() do
        a
      else
        {:error, :a} -> 1
        {:error, :b} -> 2
        {:error, :c} -> 3
        {:error, :d} -> 4
        _ -> 5
      end
      """

      assert [_] = analyze(source)
    end

    test "respects :else_arm_threshold option (lower)" do
      source = ~S"""
      with {:ok, a} <- f() do
        a
      else
        :a -> 1
        :b -> 2
      end
      """

      # With threshold 2, this 2-arm else fires.
      assert [_] = analyze(source, else_arm_threshold: 2)
      # With default threshold 4, it doesn't.
      assert analyze(source) == []
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag 3-arm else (default threshold = 4)" do
      # Legitimate fine-grained error handling at one boundary —
      # `:ok` + retryable network error + generic error.
      source = ~S"""
      with {:ok, x} <- network_call() do
        x
      else
        :ok -> :ok
        {:error, reason} when reason in [:enetunreach, :ehostunreach] -> :retry
        {:error, _} -> :fail
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag with-without-else" do
      source = ~S"""
      with {:ok, a} <- f1(),
           {:ok, b} <- f2(a) do
        a + b
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag with one-arm else" do
      source = ~S"""
      with {:ok, x} <- f() do
        x
      else
        err -> err
      end
      """

      assert analyze(source) == []
    end
  end
end
