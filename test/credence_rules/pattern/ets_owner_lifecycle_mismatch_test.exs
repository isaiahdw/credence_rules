defmodule CredenceRules.Pattern.EtsOwnerLifecycleMismatchTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.EtsOwnerLifecycleMismatch

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    EtsOwnerLifecycleMismatch.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags :ets.new + :ignore return" do
      source = ~S"""
      def init(_) do
        :ets.new(:my_table, [:named_table, :public])
        :ignore
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :ets_owner_lifecycle_mismatch
      assert issue.message =~ ":persistent_term"
    end

    test "flags when :ets.new is in shared prelude AND any branch returns :ignore" do
      # The :ets.new runs unconditionally; both `:ignore` and `{:ok, _}`
      # branches reach it. The `:ignore`-returning path destroys the
      # table → flag.
      source = ~S"""
      def init(opts) do
        :ets.new(:my_table, [:named_table])
        if opts[:bail], do: :ignore, else: {:ok, %{}}
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag :ets.new + {:ok, state} return" do
      source = ~S"""
      def init(_) do
        :ets.new(:my_table, [:named_table, :public])
        {:ok, %{}}
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag :ignore-returning init/1 without :ets.new" do
      source = ~S"""
      def init(_) do
        for {k, v} <- load_seed() do
          :persistent_term.put({__MODULE__, k}, v)
        end
        :ignore
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag :ets.new in a non-init function" do
      source = ~S"""
      def public_create do
        :ets.new(:my_table, [])
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag disjoint branches — :ets.new in one branch, :ignore in another" do
      # `:ignore` branch never executes `:ets.new`. The other branch
      # builds the table and returns `{:ok, _}`, which is the correct
      # long-lived-owner shape.
      source = ~S"""
      def init(opts) do
        if opts[:bail] do
          :ignore
        else
          :ets.new(:my_table, [:named_table])
          {:ok, %{}}
        end
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag case-based disjoint branches" do
      source = ~S"""
      def init(opts) do
        case opts[:mode] do
          :skip ->
            :ignore

          :start ->
            :ets.new(:my_table, [:named_table])
            {:ok, %{}}
        end
      end
      """

      assert analyze(source) == []
    end
  end
end
