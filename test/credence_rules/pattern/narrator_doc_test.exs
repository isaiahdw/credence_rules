defmodule CredenceRules.Pattern.NarratorDocTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.NarratorDoc

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    NarratorDoc.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test ~s(flags `@moduledoc "This module provides …"`) do
      source = ~S"""
      defmodule MyApp.Auth do
        @moduledoc "This module provides functionality for handling auth."
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :narrator_doc
      assert issue.meta.tag == :moduledoc
      assert issue.message =~ "restates the name"
    end

    test ~s(flags `@doc "This function creates …"`) do
      source = ~S"""
      defmodule MyApp.User do
        @doc "This function creates a new user."
        def create(_attrs), do: :ok
      end
      """

      assert [issue] = analyze(source)
      assert issue.meta.tag == :doc
    end

    test ~s(flags `@moduledoc "The supervisor manages …"`) do
      source = ~S"""
      defmodule MyApp.Sup do
        @moduledoc "The supervisor manages worker lifecycle."
      end
      """

      assert [_] = analyze(source)
    end

    test ~s(flags heredoc `@moduledoc """ This module handles …"""`) do
      source = ~S'''
      defmodule MyApp.X do
        @moduledoc """
        This module handles incoming requests.

        Long form description goes on.
        """
      end
      '''

      assert [_] = analyze(source)
    end

    test "flags is-responsible-for / is-used-to phrasings" do
      source1 = ~S"""
      defmodule MyApp.X do
        @moduledoc "This module is responsible for caching."
      end
      """

      source2 = ~S"""
      defmodule MyApp.Y do
        @moduledoc "This module is used to render templates."
      end
      """

      assert [_] = analyze(source1)
      assert [_] = analyze(source2)
    end
  end

  describe "check/2 — not flagged" do
    test "ignores `@doc false`" do
      source = ~S"""
      defmodule MyApp.X do
        @doc false
        def internal, do: :ok
      end
      """

      assert [] = analyze(source)
    end

    test "ignores informative docs without narrator shape" do
      source = ~S'''
      defmodule MyApp.Auth do
        @moduledoc """
        Wraps Bcrypt and session token generation. Rate-limits login
        attempts per IP via a sliding window.
        """

        @doc """
        Passwords must be at least 12 characters. Returns
        `{:error, :weak_password}` for common dictionary words.
        """
        def create_user(_attrs), do: :ok
      end
      '''

      assert [] = analyze(source)
    end

    test "ignores `This <noun> …` when no narrator verb is present" do
      source = ~S"""
      defmodule MyApp.X do
        @moduledoc "This module ships a struct named Foo."
      end
      """

      assert [] = analyze(source)
    end

    test "ignores plain code" do
      assert [] = analyze("defmodule MyApp.X do\nend\n")
    end
  end
end
