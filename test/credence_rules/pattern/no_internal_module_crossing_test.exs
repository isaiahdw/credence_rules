defmodule CredenceRules.Pattern.NoInternalModuleCrossingTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.NoInternalModuleCrossing

  defp analyze(source, opts \\ []) do
    {:ok, ast} = Code.string_to_quoted(source)
    NoInternalModuleCrossing.check(ast, opts)
  end

  defp analyze_sourceror(source, opts \\ []) do
    {:ok, ast} = Sourceror.parse_string(source)
    NoInternalModuleCrossing.check(ast, opts)
  end

  describe "check/2 — flagged" do
    test "flags cross-context reach into another context's Internal" do
      source = ~S"""
      defmodule MyApp.Devices.Sync do
        alias MyApp.Accounts.Internal.PasswordReset

        def sync(user) do
          PasswordReset.invalidate_all(user)
        end
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :no_internal_module_crossing
      assert issue.meta.source == "MyApp.Devices.Sync"
      assert issue.meta.target == "MyApp.Accounts.Internal.PasswordReset"
      assert issue.meta.context == "MyApp.Accounts"
    end

    test "flags reach from a sibling top-level context" do
      source = ~S"""
      defmodule MyApp.Billing do
        def process do
          MyApp.Accounts.Internal.UserStore.fetch_all()
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "flags reach into a same-app Internal from outside-app code" do
      source = ~S"""
      defmodule SomeOtherApp.Adapter do
        def go, do: MyApp.Accounts.Internal.UserStore.fetch_all()
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "ignores same-context reach (Accounts → Accounts.Internal)" do
      source = ~S"""
      defmodule MyApp.Accounts do
        defdelegate fetch_user(id), to: MyApp.Accounts.Internal.UserStore, as: :fetch
      end
      """

      assert [] = analyze(source)
    end

    test "ignores sub-module-of-context reach" do
      source = ~S"""
      defmodule MyApp.Accounts.Sessions do
        def list, do: MyApp.Accounts.Internal.SessionStore.all()
      end
      """

      assert [] = analyze(source)
    end

    test "ignores Internal-to-Internal within the same context" do
      source = ~S"""
      defmodule MyApp.Accounts.Internal.PasswordReset do
        def invalidate(user) do
          MyApp.Accounts.Internal.UserStore.touch(user)
        end
      end
      """

      assert [] = analyze(source)
    end

    test "ignores files that reference no Internal modules" do
      source = ~S"""
      defmodule MyApp.Devices.Sync do
        def sync(user), do: MyApp.Accounts.fetch_user(user.id)
      end
      """

      assert [] = analyze(source)
    end

    test "ignores files with no defmodule (scripts, configs)" do
      source = ~S"""
      MyApp.Accounts.Internal.PasswordReset.invalidate_all(:x)
      """

      assert [] = analyze(source)
    end
  end

  describe "check/2 — configuration" do
    test "honours custom :internal_marker_pattern" do
      source = ~S"""
      defmodule MyApp.Devices.Sync do
        def sync(user), do: MyApp.Accounts.Private.PasswordReset.invalidate(user)
      end
      """

      # Default marker is `.Internal.` — Private isn't recognized.
      assert [] = analyze(source)

      assert [_] =
               analyze(source, internal_marker_pattern: ~r/\.Private(?:\.|$)/)
    end
  end

  describe "check/2 — Sourceror-parsed (production path)" do
    test "still flags cross-context reach under Sourceror parse" do
      source = ~S"""
      defmodule MyApp.Devices.Sync do
        alias MyApp.Accounts.Internal.PasswordReset

        def sync(user) do
          PasswordReset.invalidate_all(user)
        end
      end
      """

      assert [_] = analyze_sourceror(source)
    end
  end
end
