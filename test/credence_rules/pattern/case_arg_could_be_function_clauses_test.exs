defmodule CredenceRules.Pattern.CaseArgCouldBeFunctionClausesTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.CaseArgCouldBeFunctionClauses

  defp analyze(source, opts \\ []) do
    {:ok, ast} = Code.string_to_quoted(source)
    CaseArgCouldBeFunctionClauses.check(ast, [source: source] ++ opts)
  end

  describe "check/2 — flagged" do
    test "def with case on arg (3+ clauses)" do
      source = ~S"""
      defmodule M do
        def handle(event) do
          case event do
            {:opened, id} -> open(id)
            {:closed, id} -> close(id)
            {:updated, id, attrs} -> update(id, attrs)
            _ -> :ignore
          end
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "defp / defmacro variants" do
      for kw <- ~w(defp defmacro defmacrop) do
        source = """
        defmodule M do
          #{kw} handle(event) do
            case event do
              :a -> 1
              :b -> 2
              :c -> 3
            end
          end
        end
        """

        assert [_] = analyze(source), "expected to flag #{kw}"
      end
    end

    test "honours :min_clauses opt" do
      source = ~S"""
      defmodule M do
        def handle(event) do
          case event do
            :a -> 1
            :b -> 2
          end
        end
      end
      """

      # Default min_clauses: 3 → not flagged
      assert [] = analyze(source)

      # Lower to 2 → flagged
      assert [_] = analyze(source, min_clauses: 2)
    end
  end

  describe "check/2 — not flagged" do
    test "pre-work before the case" do
      source = ~S"""
      defmodule M do
        def handle(event) do
          log(:received, event)
          case event do
            :a -> 1
            :b -> 2
            :c -> 3
          end
        end
      end
      """

      assert [] = analyze(source)
    end

    test "post-work after the case" do
      source = ~S"""
      defmodule M do
        def handle(event) do
          result =
            case event do
              :a -> 1
              :b -> 2
              :c -> 3
            end

          log(:done)
          result
        end
      end
      """

      assert [] = analyze(source)
    end

    test "case discriminator is NOT an arg" do
      source = ~S"""
      defmodule M do
        def handle(event) do
          case classify(event) do
            :a -> 1
            :b -> 2
            :c -> 3
          end
        end
      end
      """

      assert [] = analyze(source)
    end

    test "fewer than 3 clauses (small dispatch)" do
      source = ~S"""
      defmodule M do
        def handle(event) do
          case event do
            :a -> 1
            :b -> 2
          end
        end
      end
      """

      assert [] = analyze(source)
    end

    test "function already uses multi-clause heads" do
      source = ~S"""
      defmodule M do
        def handle(:a), do: 1
        def handle(:b), do: 2
        def handle(:c), do: 3
      end
      """

      assert [] = analyze(source)
    end

    test "plain code" do
      assert [] = analyze("x = 1")
    end
  end
end
