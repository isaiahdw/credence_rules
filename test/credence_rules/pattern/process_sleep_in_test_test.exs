defmodule CredenceRules.Pattern.ProcessSleepInTestTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.ProcessSleepInTest

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    ProcessSleepInTest.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags Process.sleep in `use ExUnit.Case` modules" do
      source = ~S"""
      defmodule MyApp.WorkerTest do
        use ExUnit.Case

        test "does the thing" do
          Process.sleep(200)
        end
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :process_sleep_in_test
      assert issue.message =~ "real signal"
    end

    test "flags Process.sleep in `use ExUnit.CaseTemplate` modules" do
      source = ~S"""
      defmodule MyApp.WorkerCase do
        use ExUnit.CaseTemplate

        using do
          quote do
            def wait do
              Process.sleep(50)
            end
          end
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "flags multiple sleeps and reports each line" do
      source = ~S"""
      defmodule MyApp.WorkerTest do
        use ExUnit.Case, async: true

        test "step 1" do
          Process.sleep(100)
          Process.sleep(200)
        end
      end
      """

      assert [a, b] = analyze(source)
      assert a.meta.line < b.meta.line
    end
  end

  describe "check/2 — not flagged" do
    test "ignores Process.sleep in plain library modules" do
      source = ~S"""
      defmodule MyApp.Backoff do
        def retry(n) do
          Process.sleep(:timer.seconds(n))
        end
      end
      """

      assert [] = analyze(source)
    end

    test "ignores test files with no sleeps" do
      source = ~S"""
      defmodule MyApp.WorkerTest do
        use ExUnit.Case
        test "does the thing", do: assert :ok == :ok
      end
      """

      assert [] = analyze(source)
    end
  end
end
