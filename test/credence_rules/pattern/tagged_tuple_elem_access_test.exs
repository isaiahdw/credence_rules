defmodule CredenceRules.Pattern.TaggedTupleElemAccessTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.TaggedTupleElemAccess

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    TaggedTupleElemAccess.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags `if elem(r, 0) == :ok, do: elem(r, 1)`" do
      source = ~S"if elem(result, 0) == :ok, do: elem(result, 1)"
      assert [_] = analyze(source)
    end

    test "flags reversed comparison `:ok == elem(r, 0)`" do
      source = ~S"if :ok == elem(result, 0), do: elem(result, 1)"
      assert [_] = analyze(source)
    end

    test "flags === comparison" do
      source = ~S"if elem(result, 0) === :error, do: elem(result, 1)"
      assert [_] = analyze(source)
    end

    test "flags multi-line if/do/else" do
      source = ~S"""
      if elem(result, 0) == :ok do
        process(elem(result, 1))
      else
        :error
      end
      """

      assert [_] = analyze(source)
    end

    test "flags `case elem(r, 0) do :ok -> elem(r, 1); _ -> ... end`" do
      source = ~S"""
      case elem(result, 0) do
        :ok -> elem(result, 1)
        _ -> :error
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "standalone elem (no conditional context) — AST manipulation" do
      source = ~S"value = elem(ast_tuple, 2)"
      assert [] = analyze(source)
    end

    test "if elem comparison BUT body doesn't use elem on same target" do
      source = ~S|if elem(result, 0) == :ok, do: log("got ok")|
      # Body uses log/1, not elem on result.
      # However the parser may complain about the escape. Let me use heredoc.
      assert [] = analyze(source)
    end

    test "case discriminator is NOT an elem call" do
      source = ~S"""
      case result do
        {:ok, v} -> v
        _ -> :error
      end
      """

      assert [] = analyze(source)
    end

    test "elem with index > 1 (positional access, not :ok/:error pattern)" do
      source = ~S"if elem(big_tuple, 5) == :marker, do: elem(big_tuple, 6)"
      # Indices 0/1 are the tagged-tuple pattern; >1 is positional.
      assert [] = analyze(source)
    end

    test "if without elem at all" do
      source = ~S"if x > 0, do: y"
      assert [] = analyze(source)
    end

    test "plain code" do
      assert [] = analyze("x = 1")
    end
  end
end
