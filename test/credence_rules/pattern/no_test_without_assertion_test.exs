defmodule CredenceRules.Pattern.NoTestWithoutAssertionTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.NoTestWithoutAssertion

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    NoTestWithoutAssertion.check(ast, [])
  end

  describe "check/2" do
    test "flags a test block with no assertion" do
      source = ~S"""
      defmodule MyTest do
        use ExUnit.Case

        test "creates a user" do
          Accounts.create_user(%{email: "a@b.c"})
        end
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :no_test_without_assertion
      assert issue.message =~ "creates a user"
    end

    test "does not flag a test with `assert`" do
      source = ~S"""
      defmodule MyTest do
        use ExUnit.Case

        test "creates a user" do
          assert {:ok, _} = Accounts.create_user(%{})
        end
      end
      """

      assert analyze(source) == []
    end

    test "does not flag a test with `refute`" do
      source = ~S"""
      defmodule MyTest do
        use ExUnit.Case

        test "is not allowed" do
          refute Authz.allowed?(:nobody, :anything)
        end
      end
      """

      assert analyze(source) == []
    end

    test "does not flag a test with `assert_raise`" do
      source = ~S"""
      defmodule MyTest do
        use ExUnit.Case

        test "raises on missing key" do
          assert_raise KeyError, fn -> Map.fetch!(%{}, :missing) end
        end
      end
      """

      assert analyze(source) == []
    end

    test "does not flag a test with `assert_receive`" do
      source = ~S"""
      defmodule MyTest do
        use ExUnit.Case

        test "broadcasts an event" do
          send(self(), {:ping, 1})
          assert_receive {:ping, _}
        end
      end
      """

      assert analyze(source) == []
    end

    test "treats `assert_*` family by prefix" do
      source = ~S"""
      defmodule MyTest do
        use ExUnit.Case

        test "renders the show template" do
          assert_response_ok(conn)
        end
      end
      """

      # `assert_response_ok` isn't in the explicit list but starts with
      # `assert_`, so the prefix heuristic counts it.
      assert analyze(source) == []
    end

    test "honors :extra_assertion_macros option" do
      source = ~S"""
      defmodule MyTest do
        use ExUnit.Case

        test "sends an event" do
          expect_event(:ping)
        end
      end
      """

      {:ok, ast} = Code.string_to_quoted(source)
      assert NoTestWithoutAssertion.check(ast, []) != []

      assert NoTestWithoutAssertion.check(ast, extra_assertion_macros: [:expect_event]) ==
               []
    end

    test "flags multiple tests independently" do
      source = ~S"""
      defmodule MyTest do
        use ExUnit.Case

        test "one fine" do
          assert :ok = run()
        end

        test "two has none" do
          run()
        end

        test "three has none either" do
          run()
        end
      end
      """

      issues = analyze(source)
      assert length(issues) == 2
      assert Enum.all?(issues, &(&1.rule == :no_test_without_assertion))
    end

    test "ignores nested-test-like names that aren't `test`" do
      source = ~S"""
      defmodule MyTest do
        use ExUnit.Case

        # not the ExUnit `test` macro; should not be flagged
        my_test "fixture only" do
          setup_world()
        end
      end
      """

      assert analyze(source) == []
    end
  end

  describe "check/2 — ExUnit-file gate" do
    test "does NOT flag `test/2` in a non-ExUnit module (DSL/macro author)" do
      # Module defines its own test/2 macro for a custom test DSL.
      # No `use ExUnit.Case` — the gate skips the file entirely.
      source = ~S"""
      defmodule MyDsl do
        defmacro test(name, do: block) do
          quote do
            unquote(name)
            unquote(block)
          end
        end

        # Looks like a test call but it's calling MyDsl.test/2,
        # not ExUnit's. Wouldn't be a real assertion-check candidate.
        test "no assertion here" do
          do_stuff()
        end
      end
      """

      assert analyze(source) == []
    end

    test "flags inside `use ExUnit.CaseTemplate` (test helper modules)" do
      source = ~S"""
      defmodule MyTemplate do
        use ExUnit.CaseTemplate

        test "no assertion" do
          do_stuff()
        end
      end
      """

      assert [_] = analyze(source)
    end
  end
end
