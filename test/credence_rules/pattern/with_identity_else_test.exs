defmodule CredenceRules.Pattern.WithIdentityElseTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.WithIdentityElse

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    WithIdentityElse.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags `else {:error, e} -> {:error, e}` identity arm" do
      source = ~S"""
      with {:ok, result} <- do_something() do
        format(result)
      else
        {:error, reason} -> {:error, reason}
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :with_identity_else
    end

    test "flags multi-arm else where each arm is identity" do
      source = ~S"""
      with {:ok, r} <- f() do
        r
      else
        :timeout -> :timeout
        {:error, e} -> {:error, e}
      end
      """

      assert [_] = analyze(source)
    end

    test "flags single-atom identity else" do
      source = ~S"""
      with {:ok, r} <- f() do
        r
      else
        :ignored -> :ignored
      end
      """

      assert [_] = analyze(source)
    end

    test "reports the line of the with" do
      source = ~S"""
      def go(input) do
        with {:ok, v} <- f(input) do
          v
        else
          {:error, e} -> {:error, e}
        end
      end
      """

      assert [issue] = analyze(source)
      assert issue.meta.line == 2
    end
  end

  describe "check/2 — not flagged" do
    test "ignores else that does real work" do
      source = ~S"""
      with {:ok, r} <- f() do
        r
      else
        {:error, e} -> log_and_raise(e)
      end
      """

      assert [] = analyze(source)
    end

    test "ignores else where any single arm is non-identity" do
      source = ~S"""
      with {:ok, r} <- f() do
        r
      else
        :timeout -> :timeout
        {:error, e} -> {:error, {:wrapped, e}}
      end
      """

      assert [] = analyze(source)
    end

    test "ignores else that returns a transformed shape" do
      source = ~S"""
      with {:ok, r} <- f() do
        r
      else
        :timeout -> {:error, :timeout}
      end
      """

      assert [] = analyze(source)
    end

    test "ignores with that has no else (owned by with_identity_do)" do
      source = ~S"""
      with {:ok, r} <- f() do
        r
      end
      """

      assert [] = analyze(source)
    end

    test "ignores plain case (different macro)" do
      source = ~S"""
      case f() do
        {:ok, r} -> r
        {:error, e} -> {:error, e}
      end
      """

      assert [] = analyze(source)
    end
  end
end
