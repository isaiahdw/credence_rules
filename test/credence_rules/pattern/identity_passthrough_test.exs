defmodule CredenceRules.Pattern.IdentityPassthroughTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.IdentityPassthrough

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    IdentityPassthrough.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags ok/error rewrap" do
      source = ~S"""
      case do_something() do
        {:ok, value} -> {:ok, value}
        {:error, reason} -> {:error, reason}
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :identity_passthrough
      assert issue.message =~ "Identity `case`"
    end

    test "flags single-value identity (>=2 clauses required)" do
      source = ~S"""
      case x do
        :a -> :a
        :b -> :b
      end
      """

      assert [_] = analyze(source)
    end

    test "flags 3+ clause identity case" do
      source = ~S"""
      case x do
        :a -> :a
        :b -> :b
        :c -> :c
      end
      """

      assert [_] = analyze(source)
    end

    test "reports the line of the case" do
      source = ~S"""
      def go(input) do
        result = case input do
          {:ok, v} -> {:ok, v}
          {:error, e} -> {:error, e}
        end

        result
      end
      """

      assert [issue] = analyze(source)
      assert issue.meta.line == 2
    end
  end

  describe "check/2 — not flagged" do
    test "ignores case where any clause does work" do
      source = ~S"""
      case x do
        {:ok, value} -> {:ok, transform(value)}
        {:error, reason} -> {:error, reason}
      end
      """

      assert [] = analyze(source)
    end

    test "ignores case with only one clause" do
      source = ~S"""
      case x do
        {:ok, value} -> {:ok, value}
      end
      """

      assert [] = analyze(source)
    end

    test "ignores wildcards (clause body doesn't match clause head)" do
      source = ~S"""
      case x do
        {:ok, value} -> value
        _ -> nil
      end
      """

      assert [] = analyze(source)
    end

    test "ignores case where one clause is identity and another isn't" do
      source = ~S"""
      case x do
        {:ok, value} -> {:ok, value}
        {:error, reason} -> {:error, normalize(reason)}
      end
      """

      assert [] = analyze(source)
    end

    test "ignores case where one clause flips arity (single → tuple)" do
      source = ~S"""
      case x do
        :timeout -> {:error, :timeout}
        {:error, e} -> {:error, e}
      end
      """

      assert [] = analyze(source)
    end

    test "ignores `with` (with_identity_do/else own that)" do
      assert [] = analyze("with {:ok, r} <- f() do {:ok, r} end")
    end

    test "ignores plain expressions" do
      assert [] = analyze("do_something()")
    end
  end
end
