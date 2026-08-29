defmodule CredenceRules.Pattern.AlternativeReturnTypesTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.AlternativeReturnTypes

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    AlternativeReturnTypes.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags a function returning {:ok, %Struct{}} | %Struct{} via if" do
      # The shape the rule reliably catches: tagged tuple alongside a
      # naked literal (struct here). Bare-variable returns (`x` in
      # `if cond, do: x, else: {:ok, x}`) are intentionally NOT flagged —
      # without types we can't tell what shape the var holds.
      source = ~S"""
      def fetch(id, opts) do
        if opts[:raw], do: %User{id: id}, else: {:ok, %User{id: id}}
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :alternative_return_types
      assert issue.message =~ "fetch/2"
    end

    test "flags case mixing {:ok, _} with naked nil" do
      source = ~S"""
      def lookup(id) do
        case do_lookup(id) do
          {:ok, x} -> {:ok, x}
          :missing -> nil
        end
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag {:ok, _} | {:error, _}" do
      source = ~S"""
      def fetch(id) do
        case do_fetch(id) do
          {:ok, x} -> {:ok, x}
          {:error, e} -> {:error, e}
        end
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag :ok | :error sentinel pair" do
      source = ~S"""
      def save(id) do
        case do_save(id) do
          :ok -> :ok
          {:error, _} -> :error
        end
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag a function returning a consistent struct" do
      source = ~S"""
      def build(id) do
        %MyApp.User{id: id}
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag a function that always returns through a call" do
      source = ~S"""
      def lookup(id) do
        Repo.get(MyApp.User, id)
      end
      """

      # Function calls are opaque — no classification → not mixed.
      assert analyze(source) == []
    end
  end
end
