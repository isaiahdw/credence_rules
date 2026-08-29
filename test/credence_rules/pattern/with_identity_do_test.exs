defmodule CredenceRules.Pattern.WithIdentityDoTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.WithIdentityDo

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    WithIdentityDo.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags `with {:ok, r} <- f() do {:ok, r} end`" do
      source = ~S"""
      with {:ok, result} <- do_something() do
        {:ok, result}
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :with_identity_do
    end

    test "flags single-binding identity" do
      source = ~S"""
      with value <- f() do
        value
      end
      """

      assert [_] = analyze(source)
    end

    test "flags atom-tag identity" do
      source = ~S"""
      with :ok <- f() do
        :ok
      end
      """

      assert [_] = analyze(source)
    end

    test "reports the line of the with" do
      source = ~S"""
      def go(input) do
        with {:ok, v} <- f(input) do
          {:ok, v}
        end
      end
      """

      assert [issue] = analyze(source)
      assert issue.meta.line == 2
    end
  end

  describe "check/2 — not flagged" do
    test "ignores with whose do block does something else" do
      source = ~S"""
      with {:ok, result} <- do_something() do
        format(result)
      end
      """

      assert [] = analyze(source)
    end

    test "ignores with that has an else block (owned by with_identity_else)" do
      source = ~S"""
      with {:ok, result} <- do_something() do
        {:ok, result}
      else
        {:error, e} -> {:error, e}
      end
      """

      assert [] = analyze(source)
    end

    test "ignores multi-clause with" do
      source = ~S"""
      with {:ok, a} <- f(),
           {:ok, b} <- g(a) do
        {:ok, b}
      end
      """

      assert [] = analyze(source)
    end

    test "ignores with that returns a transformed shape" do
      source = ~S"""
      with {:ok, v} <- f() do
        {:ok, normalize(v)}
      end
      """

      assert [] = analyze(source)
    end

    test "ignores with where do body unwraps the binding" do
      source = ~S"""
      with {:ok, v} <- f() do
        v
      end
      """

      # The pattern is `{:ok, v}` and the do-body is `v` (just the
      # binding). Those are not AST-equal, so the rule does not fire.
      assert [] = analyze(source)
    end

    test "ignores plain expressions" do
      assert [] = analyze("do_something()")
    end
  end
end
