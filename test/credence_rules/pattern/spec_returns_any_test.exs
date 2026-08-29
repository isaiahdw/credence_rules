defmodule CredenceRules.Pattern.SpecReturnsAnyTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.SpecReturnsAny

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    SpecReturnsAny.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags `@spec foo(...) :: any()`" do
      source = ~S"""
      defmodule MyApp.M do
        @spec fetch(integer()) :: any()
        def fetch(_id), do: nil
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :spec_returns_any
      assert issue.meta.kind == :spec
    end

    test "flags `@spec foo() :: term()`" do
      source = ~S"""
      defmodule MyApp.M do
        @spec list() :: term()
        def list, do: []
      end
      """

      assert [_] = analyze(source)
    end

    test "flags union with any() — any() swallows the rest" do
      source = ~S"""
      defmodule MyApp.M do
        @spec fetch(integer()) :: String.t() | any()
        def fetch(_id), do: ""
      end
      """

      assert [_] = analyze(source)
    end

    test "flags union with term() (alias for any)" do
      source = ~S"""
      defmodule MyApp.M do
        @spec fetch() :: nil | term()
        def fetch, do: nil
      end
      """

      assert [_] = analyze(source)
    end

    test "flags `@callback foo() :: any()`" do
      source = ~S"""
      defmodule MyApp.B do
        @callback name() :: any()
      end
      """

      assert [issue] = analyze(source)
      assert issue.meta.kind == :callback
    end

    test "flags `@macrocallback foo() :: any()`" do
      source = ~S"""
      defmodule MyApp.B do
        @macrocallback name() :: any()
      end
      """

      assert [issue] = analyze(source)
      assert issue.meta.kind == :macrocallback
    end

    test "reports the line of the @spec" do
      source = ~S"""
      defmodule MyApp.M do
        @doc "Look up a user."

        @spec lookup(integer()) :: any()
        def lookup(_id), do: nil
      end
      """

      assert [issue] = analyze(source)
      assert issue.meta.line == 4
    end

    test "flags each @spec in a module" do
      source = ~S"""
      defmodule MyApp.M do
        @spec a() :: any()
        def a, do: nil

        @spec b() :: term()
        def b, do: nil
      end
      """

      assert length(analyze(source)) == 2
    end
  end

  describe "check/2 — not flagged" do
    test "ignores concrete return types" do
      source = ~S"""
      defmodule MyApp.M do
        @spec fetch(integer()) :: {:ok, String.t()} | {:error, term()}
        def fetch(_id), do: {:ok, ""}
      end
      """

      # The {:error, term()} arg is INSIDE a parameterized type, NOT the
      # final return; should not fire.
      assert [] = analyze(source)
    end

    test "ignores @spec ... :: :ok" do
      source = ~S"""
      defmodule MyApp.M do
        @spec touch(integer()) :: :ok
        def touch(_id), do: :ok
      end
      """

      assert [] = analyze(source)
    end

    test "ignores parameterized list type `[any()]`" do
      source = ~S"""
      defmodule MyApp.M do
        @spec list() :: [any()]
        def list, do: []
      end
      """

      assert [] = analyze(source)
    end

    test "ignores `@type t :: any()` (different rule territory)" do
      source = ~S"""
      defmodule MyApp.M do
        @type t :: any()
      end
      """

      assert [] = analyze(source)
    end

    test "ignores plain @doc" do
      source = ~S"""
      defmodule MyApp.M do
        @doc "Does the thing."
        def thing, do: :ok
      end
      """

      assert [] = analyze(source)
    end

    test "ignores `:none` / `:no_return`" do
      source = ~S"""
      defmodule MyApp.M do
        @spec crash() :: no_return()
        def crash, do: raise "boom"
      end
      """

      assert [] = analyze(source)
    end
  end
end
