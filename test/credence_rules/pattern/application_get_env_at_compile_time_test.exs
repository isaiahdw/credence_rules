defmodule CredenceRules.Pattern.ApplicationGetEnvAtCompileTimeTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.ApplicationGetEnvAtCompileTime

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    ApplicationGetEnvAtCompileTime.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags @adapter Application.get_env(...)" do
      source = ~S"""
      defmodule Foo do
        @adapter Application.get_env(:my_app, :adapter)
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :application_get_env_at_compile_time
      assert issue.message =~ "compile_env"
      assert issue.message =~ "@adapter"
    end

    test "flags @timeout Application.fetch_env!(...)" do
      source = ~S"""
      defmodule Foo do
        @timeout Application.fetch_env!(:my_app, :timeout)
      end
      """

      assert [issue] = analyze(source)
      assert issue.message =~ "compile_env!"
    end

    test "flags Application.get_env inside a pipe in an attribute" do
      source = ~S"""
      defmodule Foo do
        @config :my_app
                |> Application.get_env(:settings)
                |> Map.fetch!(:foo)
      end
      """

      assert [_] = analyze(source)
    end

    test "flags defdelegate to: Application.get_env(...)" do
      source = ~S"""
      defmodule Foo do
        defdelegate run(args), to: Application.get_env(:my_app, :runner)
      end
      """

      assert [issue] = analyze(source)
      assert issue.message =~ "defdelegate"
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag Application.get_env inside a def body" do
      source = ~S"""
      defmodule Foo do
        def adapter, do: Application.get_env(:my_app, :adapter)
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag Application.compile_env in an attribute" do
      source = ~S"""
      defmodule Foo do
        @adapter Application.compile_env(:my_app, :adapter)
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag @moduledoc, @doc, @spec etc." do
      source = ~S"""
      defmodule Foo do
        @moduledoc "Foo"
        @doc "bar"
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag Application.put_env (which is a runtime side-effect)" do
      source = ~S"""
      defmodule Foo do
        @_set Application.put_env(:my_app, :k, :v)
      end
      """

      # Although this is a strange thing to do, put_env at compile time is
      # not the bug this rule targets.
      assert analyze(source) == []
    end
  end
end
