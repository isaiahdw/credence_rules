defmodule CredenceRules.Pattern.BangFunctionThatDoesntRaiseTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.BangFunctionThatDoesntRaise

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    BangFunctionThatDoesntRaise.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags `def foo!(...)` that just returns a value" do
      source = ~S"""
      def fetch!(key) do
        Map.get(map, key)
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :bang_function_that_doesnt_raise
      assert issue.message =~ "fetch!/1"
    end

    test "flags `defp foo!(...)` too" do
      source = ~S"""
      defp build!(input) do
        %{a: input}
      end
      """

      assert [_] = analyze(source)
    end

    test "flags a bang function whose `case` returns nil on error" do
      source = ~S"""
      def parse!(input) do
        case Jason.decode(input) do
          {:ok, v} -> v
          {:error, _} -> nil
        end
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag a bang fn that calls `raise`" do
      source = ~S"""
      def fetch!(key) do
        case Map.fetch(map, key) do
          {:ok, v} -> v
          :error -> raise KeyError, key: key
        end
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag a bang fn that delegates to another bang" do
      source = ~S"""
      def fetch!(key), do: Map.fetch!(map, key)
      """

      assert analyze(source) == []
    end

    test "does NOT flag a bang fn that calls a local bang" do
      source = ~S"""
      def fetch!(key), do: do_fetch!(key)
      """

      assert analyze(source) == []
    end

    test "does NOT flag a bang fn that reraises" do
      source = ~S"""
      def run!(arg) do
        try do
          do_work(arg)
        rescue
          e -> reraise(e, __STACKTRACE__)
        end
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag a bang fn that throws" do
      source = ~S"""
      def stop!(arg) do
        throw({:done, arg})
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag a bang fn that calls :erlang.error/1" do
      source = ~S"""
      def crash!(reason) do
        :erlang.error({:boom, reason})
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag clauses whose siblings raise" do
      # `validate_destination!/3` style: most clauses raise on
      # constraint violations, two return `:ok` for valid inputs.
      # The contract is satisfied module-wide — don't flag the
      # passing clauses.
      source = ~S"""
      defp validate!(:ok, _x), do: :ok
      defp validate!(:bad, x), do: raise ArgumentError, "bad: " <> inspect(x)
      defp validate!(:other, _x), do: :ok
      """

      assert analyze(source) == []
    end

    test "flags a multi-clause bang when NO clause raises" do
      source = ~S"""
      def fetch!(map, :missing), do: nil
      def fetch!(map, key), do: Map.get(map, key)
      """

      issues = analyze(source)
      assert length(issues) == 1
      assert hd(issues).message =~ "fetch!/2"
    end

    test "does NOT flag a non-bang function" do
      source = ~S"""
      def fetch(key) do
        Map.get(map, key)
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag a one-char name `!`" do
      # Pathological; just confirms the length guard doesn't crash.
      source = ~S"""
      def !(arg) do
        arg
      end
      """

      assert analyze(source) == []
    end
  end
end
