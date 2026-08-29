defmodule CredenceRules.Pattern.NilCheckElseUsesValueTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.NilCheckElseUsesValue

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    NilCheckElseUsesValue.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "if is_nil(x) do nil else use(x) end" do
      source = ~S"""
      if is_nil(socket) do
        nil
      else
        :socket.close(socket)
      end
      """

      assert [_] = analyze(source)
    end

    test "if x != nil, do: use(x)" do
      source = ~S"if user.email != nil, do: send_email(user.email)"
      assert [_] = analyze(source)
    end

    test "if not is_nil(x), do: use(x)" do
      source = ~S"if not is_nil(value), do: process(value)"
      assert [_] = analyze(source)
    end

    test "if x == nil, do: default, else: use(x)" do
      source = ~S"""
      if value == nil do
        :default
      else
        process(value)
      end
      """

      assert [_] = analyze(source)
    end

    test "if nil == x ... reversed" do
      source = ~S"""
      if nil == value do
        :default
      else
        process(value)
      end
      """

      assert [_] = analyze(source)
    end

    test "=== nil variant" do
      source = ~S"""
      if value === nil do
        :default
      else
        process(value)
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "body doesn't use the checked value" do
      source = ~S|if is_nil(x), do: log("nil")|
      assert [] = analyze(source)
    end

    test "is_nil branch returns without using x (and no else)" do
      # `if is_nil(x), do: :default` — no else, no value use anywhere.
      source = ~S"if is_nil(x), do: :default"
      assert [] = analyze(source)
    end

    test "case form (already correct)" do
      source = ~S"""
      case socket do
        nil -> nil
        socket -> :socket.close(socket)
      end
      """

      assert [] = analyze(source)
    end

    test "plain code" do
      assert [] = analyze("x = 1")
    end
  end
end
