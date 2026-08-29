defmodule CredenceRules.Pattern.BinaryToTermWithoutSafeTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.BinaryToTermWithoutSafe

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    BinaryToTermWithoutSafe.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags :erlang.binary_to_term/1" do
      source = ~S"""
      :erlang.binary_to_term(bin)
      """

      assert [issue] = analyze(source)
      assert issue.rule == :binary_to_term_without_safe
      assert issue.message =~ ":safe"
    end

    test "flags :erlang.binary_to_term/2 with opts that lack :safe" do
      source = ~S"""
      :erlang.binary_to_term(bin, [:used])
      """

      assert [_] = analyze(source)
    end

    test "flags :erlang.binary_to_term/2 with empty opts" do
      source = ~S"""
      :erlang.binary_to_term(bin, [])
      """

      assert [_] = analyze(source)
    end

    test "flags non-literal opts conservatively" do
      # We can't statically prove the variable includes :safe, so the rule
      # warns. If this turns out noisy, users can suppress per-line.
      source = ~S"""
      :erlang.binary_to_term(bin, opts)
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag with [:safe]" do
      source = ~S"""
      :erlang.binary_to_term(bin, [:safe])
      """

      assert analyze(source) == []
    end

    test "does NOT flag with [:safe, :used]" do
      source = ~S"""
      :erlang.binary_to_term(bin, [:safe, :used])
      """

      assert analyze(source) == []
    end

    test "does NOT flag unrelated :erlang calls" do
      source = ~S"""
      :erlang.term_to_binary(term)
      """

      assert analyze(source) == []
    end
  end
end
