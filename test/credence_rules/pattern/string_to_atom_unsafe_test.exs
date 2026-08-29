defmodule CredenceRules.Pattern.StringToAtomUnsafeTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.StringToAtomUnsafe

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    StringToAtomUnsafe.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags String.to_atom/1" do
      assert [issue] = analyze(~S"String.to_atom(payload)")
      assert issue.rule == :string_to_atom_unsafe
      assert issue.message =~ "String.to_existing_atom"
    end

    test "flags :erlang.binary_to_atom/1" do
      assert [_] = analyze(~S":erlang.binary_to_atom(bin)")
    end

    test "flags :erlang.binary_to_atom/2" do
      assert [_] = analyze(~S":erlang.binary_to_atom(bin, :utf8)")
    end

    test "flags :erlang.list_to_atom/1" do
      assert [_] = analyze(~S":erlang.list_to_atom(charlist)")
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag String.to_existing_atom" do
      assert analyze(~S"String.to_existing_atom(name)") == []
    end

    test "does NOT flag :erlang.binary_to_existing_atom" do
      assert analyze(~S":erlang.binary_to_existing_atom(bin)") == []
    end

    test "does NOT flag String.to_integer / to_float" do
      assert analyze(~S"String.to_integer(s)") == []
    end
  end

  describe "check/2 — atom-literal interpolation belongs to atom_interpolation" do
    # `:"a_#{b}"` lowers to :erlang.binary_to_atom(<<…>>, :utf8), so
    # without the split this rule reports it with advice that has no
    # sugar form. Ownership of the shape lives in AtomInterpolation.

    test "does NOT flag interpolated atom literals" do
      assert analyze(~S|:"meta_#{key}"|) == []
    end

    test "does NOT flag interpolation with a leading interpolated segment" do
      assert analyze(~S|:"#{name}.Registry"|) == []
    end

    test "DOES still flag binary_to_atom on a non-literal argument" do
      assert [_] = analyze(~S|:erlang.binary_to_atom("meta_" <> key, :utf8)|)
    end

    test "DOES still flag String.to_atom on an interpolated string" do
      # Here the advice fits — String.to_existing_atom/1 accepts the
      # same interpolated binary.
      assert [issue] = analyze(~S|String.to_atom("meta_#{key}")|)
      assert issue.message =~ "String.to_existing_atom"
    end
  end
end
