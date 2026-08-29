defmodule CredenceRules.Pattern.TruthyGuardNonBooleanTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.TruthyGuardNonBoolean

  defp analyze(source, opts \\ []) do
    {:ok, ast} = Code.string_to_quoted(source)
    TruthyGuardNonBoolean.check(ast, [source: source] ++ opts)
  end

  defp analyze_sourceror(source) do
    {:ok, ast} = Sourceror.parse_string(source)
    TruthyGuardNonBoolean.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags bare variable in guard" do
      source = ~S"""
      defmodule M do
        def handle(value) when value do
          process(value)
        end
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :truthy_guard_non_boolean
      assert issue.meta.function == :handle
    end

    test "flags dot field access in guard" do
      source = ~S"""
      defmodule M do
        def fetch(state) when state.socket, do: state.socket
      end
      """

      assert [_] = analyze(source)
    end

    test "flags nested dot field access" do
      source = ~S"""
      defmodule M do
        def lookup(conn) when conn.assigns.current_user, do: conn
      end
      """

      assert [_] = analyze(source)
    end

    test "flags Map.get in guard" do
      source = ~S"""
      defmodule M do
        def lookup(opts) when Map.get(opts, :id), do: find()
      end
      """

      assert [_] = analyze(source)
    end

    test "flags Keyword.get in guard" do
      source = ~S"""
      defmodule M do
        def lookup(opts) when Keyword.get(opts, :id), do: find()
      end
      """

      assert [_] = analyze(source)
    end

    test "flags bracket access in guard" do
      source = ~S"""
      defmodule M do
        def lookup(opts) when opts[:flag], do: enable()
      end
      """

      assert [_] = analyze(source)
    end

    test "flags map-destructure binding used as bare guard" do
      source = ~S"""
      defmodule M do
        def handle(%{enabled: enabled}) when enabled, do: start()
      end
      """

      assert [_] = analyze(source)
    end

    test "flags defp / defmacro / defmacrop too" do
      for kw <- ~w(defp defmacro defmacrop) do
        source = """
        defmodule M do
          #{kw} handle(value) when value, do: :ok
        end
        """

        assert [_] = analyze(source), "expected to flag #{kw}"
      end
    end

    test "flags compound guard where one side is non-boolean" do
      source = ~S"""
      defmodule M do
        def handle(state, x) when state.flag and is_pid(x), do: :ok
      end
      """

      assert [_] = analyze(source)
    end

    test "flags multiple bad clauses in one module" do
      source = ~S"""
      defmodule M do
        def a(value) when value, do: :a
        def b(state) when state.flag, do: :b
      end
      """

      assert length(analyze(source)) == 2
    end
  end

  describe "check/2 — not flagged" do
    test "is_* predicates (boolean by convention)" do
      sources = [
        ~S|defmodule M do; def f(x) when is_atom(x), do: :ok; end|,
        ~S|defmodule M do; def f(x) when is_pid(x), do: :ok; end|,
        ~S|defmodule M do; def f(x) when is_binary(x), do: :ok; end|,
        ~S|defmodule M do; def f(x) when is_nil(x), do: :ok; end|,
        ~S|defmodule M do; def f(x) when is_map(x), do: :ok; end|
      ]

      for source <- sources do
        assert [] = analyze(source), "expected not to flag: #{source}"
      end
    end

    test "comparison operators" do
      sources = [
        ~S|defmodule M do; def f(x) when x > 0, do: :ok; end|,
        ~S|defmodule M do; def f(x) when x != nil, do: :ok; end|,
        ~S|defmodule M do; def f(x) when x === :ok, do: :ok; end|,
        ~S|defmodule M do; def f(x) when x <= 10, do: :ok; end|
      ]

      for source <- sources do
        assert [] = analyze(source), "expected not to flag: #{source}"
      end
    end

    test "in operator (membership, boolean)" do
      sources = [
        ~S|defmodule M do; def f(x) when x in [:a, :b, :c], do: :ok; end|,
        ~S|defmodule M do; def f(n) when n in 1..10, do: :ok; end|,
        ~S|defmodule M do; @list [:a, :b]; def f(x) when x in @list, do: :ok; end|,
        ~S|defmodule M do; def f(args) when length(args) in 1..2, do: :ok; end|
      ]

      for source <- sources do
        assert [] = analyze(source), "expected not to flag: #{source}"
      end
    end

    test "match?/2 in guard (returns boolean)" do
      source = ~S"""
      defmodule M do
        def f(x) when match?({:ok, _}, x), do: :ok
      end
      """

      assert [] = analyze(source)
    end

    test "not is_nil pattern" do
      source = ~S"""
      defmodule M do
        def f(x) when not is_nil(x), do: x
      end
      """

      assert [] = analyze(source)
    end

    test "compound guard where both sides are boolean" do
      source = ~S"""
      defmodule M do
        def f(x, y) when is_pid(x) and is_atom(y), do: :ok
        def g(x, y) when is_pid(x) or is_port(x), do: :ok
      end
      """

      assert [] = analyze(source)
    end

    test "compound with comparison + is_*" do
      source = ~S"""
      defmodule M do
        def f(x) when is_integer(x) and x > 0, do: :ok
      end
      """

      assert [] = analyze(source)
    end

    test "explicit `=== true` comparison" do
      source = ~S"""
      defmodule M do
        def f(state) when state.flag === true, do: :ok
      end
      """

      assert [] = analyze(source)
    end

    test "trailing-? function in guard (boolean by convention)" do
      # `Code.ensure_loaded?` is `?`-suffix → boolean
      source = ~S"""
      defmodule M do
        defguard available?(mod) when Code.ensure_loaded?(mod)
      end
      """

      assert [] = analyze(source)
    end

    test "def without a guard" do
      source = ~S"""
      defmodule M do
        def handle(value), do: process(value)
      end
      """

      assert [] = analyze(source)
    end

    test "plain code (no defmodule, no def)" do
      assert [] = analyze("x = 1")
    end
  end

  describe "check/2 — Sourceror-parsed (production path)" do
    test "still flags bare-var guard under Sourceror" do
      source = ~S"""
      defmodule M do
        def handle(value) when value do
          process(value)
        end
      end
      """

      assert [_] = analyze_sourceror(source)
    end

    test "still skips is_* predicate under Sourceror" do
      source = ~S"""
      defmodule M do
        def f(x) when is_atom(x), do: :ok
      end
      """

      assert [] = analyze_sourceror(source)
    end
  end
end
