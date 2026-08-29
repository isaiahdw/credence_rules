defmodule CredenceRules.Pattern.NestedOkErrorCasesCouldWithTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.NestedOkErrorCasesCouldWith

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    NestedOkErrorCasesCouldWith.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "two-level nested case with passthrough errors" do
      source = ~S"""
      case fetch_user(id) do
        {:ok, user} ->
          case authorize(user) do
            {:ok, auth} -> {:ok, auth}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
      """

      # The outer case (with nested case in :ok branch) is flagged.
      # The inner case alone isn't flagged because it doesn't have
      # a nested case in ITS :ok branch.
      assert [_] = analyze(source)
    end

    test "three-level nested chain — flags both nestable layers" do
      source = ~S"""
      case fetch_user(id) do
        {:ok, user} ->
          case authorize(user) do
            {:ok, auth} ->
              case create_session(user, auth) do
                {:ok, session} -> {:ok, session}
                {:error, reason} -> {:error, reason}
              end

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
      """

      # Outer + middle both fire — each has a nested case in its
      # :ok branch.
      assert length(analyze(source)) == 2
    end

    test "reversed clause order (error before ok)" do
      source = ~S"""
      case fetch(id) do
        {:error, reason} -> {:error, reason}
        {:ok, x} ->
          case load(x) do
            {:error, r} -> {:error, r}
            {:ok, y} -> {:ok, y}
          end
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "single-level case (no nesting)" do
      source = ~S"""
      case fetch(id) do
        {:ok, x} -> {:ok, x}
        {:error, e} -> {:error, e}
      end
      """

      assert [] = analyze(source)
    end

    test "error branch has special handling" do
      source = ~S"""
      case fetch(id) do
        {:ok, user} ->
          case authorize(user) do
            {:ok, auth} -> {:ok, auth}
            {:error, :forbidden} -> redirect()
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
      """

      # Inner case has 3 clauses — doesn't match the 2-clause shape.
      # Outer case's :ok branch's nested case isn't recognized as
      # nested-passthrough, so outer doesn't fire.
      assert [] = analyze(source)
    end

    test "case with patterns other than ok/error" do
      source = ~S"""
      case x do
        :foo -> :a
        :bar -> :b
      end
      """

      assert [] = analyze(source)
    end

    test "ok branch does work BEFORE the nested case" do
      source = ~S"""
      case fetch(id) do
        {:ok, user} ->
          enriched = enrich(user)
          case authorize(enriched) do
            {:ok, auth} -> {:ok, auth}
            {:error, r} -> {:error, r}
          end

        {:error, r} -> {:error, r}
      end
      """

      # The :ok body is a __block__ — `enriched = ...` then case.
      # The block's FIRST statement isn't a case, so not flagged.
      assert [] = analyze(source)
    end

    test "already using with (correct shape)" do
      source = ~S"""
      with {:ok, user} <- fetch(id),
           {:ok, auth} <- authorize(user) do
        {:ok, auth}
      end
      """

      assert [] = analyze(source)
    end

    test "plain code" do
      assert [] = analyze("x = 1")
    end
  end
end
