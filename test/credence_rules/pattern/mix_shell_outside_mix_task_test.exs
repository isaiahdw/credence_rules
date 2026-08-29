defmodule CredenceRules.Pattern.MixShellOutsideMixTaskTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.MixShellOutsideMixTask

  defp analyze(source, opts \\ []) do
    {:ok, ast} = Code.string_to_quoted(source)
    MixShellOutsideMixTask.check(ast, [source: source] ++ opts)
  end

  defp analyze_sourceror(source, opts \\ []) do
    {:ok, ast} = Sourceror.parse_string(source)
    MixShellOutsideMixTask.check(ast, [source: source] ++ opts)
  end

  describe "check/2 — flagged (Mix.shell in lib code)" do
    test "flags bare Mix.shell()" do
      source = ~S"""
      defmodule MyApp.Worker do
        def go, do: Mix.shell()
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :mix_shell_outside_mix_task
      assert issue.meta.function == :shell
    end

    test "flags Mix.shell().info — counts the inner Mix.shell() once" do
      source = ~S"""
      defmodule MyApp.Worker do
        def go, do: Mix.shell().info("hello")
      end
      """

      # The outer call is .info; the inner Mix.shell() triggers the rule.
      assert [issue] = analyze(source)
      assert issue.meta.function == :shell
    end

    test "flags Mix.shell().error and Mix.shell().yes?" do
      source = ~S"""
      defmodule MyApp.Worker do
        def go do
          Mix.shell().info("step 1")
          Mix.shell().error("step 2")
          Mix.shell().yes?("step 3")
        end
      end
      """

      # Three Mix.shell() inner calls.
      issues = analyze(source)
      assert length(issues) == 3
    end

    test "flags Mix.raise/1" do
      source = ~S"""
      defmodule MyApp.Worker do
        def go, do: Mix.raise("boom")
      end
      """

      assert [issue] = analyze(source)
      assert issue.meta.function == :raise
    end

    test "flags Mix.raise/2" do
      source = ~S"""
      defmodule MyApp.Worker do
        def go, do: Mix.raise("boom", exit_code: 2)
      end
      """

      assert [_] = analyze(source)
    end

    test "flags inside nested modules" do
      source = ~S"""
      defmodule MyApp.Outer do
        defmodule Inner do
          def go, do: Mix.shell().info("nope")
        end
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged (legitimate uses)" do
    test "skips inside a Mix.Tasks.* module" do
      source = ~S"""
      defmodule Mix.Tasks.MyApp.Sync do
        use Mix.Task
        @impl Mix.Task
        def run(_) do
          Mix.shell().info("syncing")
          Mix.raise("boom")
        end
      end
      """

      assert [] = analyze(source)
    end

    test "skips inside nested-namespace Mix.Tasks.*" do
      source = ~S"""
      defmodule Mix.Tasks.MyApp.SubGroup.Sync do
        def run(_), do: Mix.shell().info("ok")
      end
      """

      assert [] = analyze(source)
    end

    test "skips inside ExUnit test files (Mix is available in test mode)" do
      source = ~S"""
      defmodule MyApp.WorkerTest do
        use ExUnit.Case, async: true

        test "uses Mix.shell in setup" do
          Mix.shell().info("setting up")
          assert true
        end
      end
      """

      assert [] = analyze(source)
    end

    test "skips ExUnit.CaseTemplate files" do
      source = ~S"""
      defmodule MyApp.Case do
        use ExUnit.CaseTemplate
        def helper, do: Mix.shell().info("hi")
      end
      """

      assert [] = analyze(source)
    end

    test "honours :allowed_modules" do
      source = ~S"""
      defmodule MyApp.DevTools do
        def reset, do: Mix.shell().info("resetting")
      end
      """

      # Without allowlist → flagged
      assert [_] = analyze(source)

      # With allowlist → skipped
      assert [] = analyze(source, allowed_modules: ["MyApp.DevTools"])
      # Atom form also works (Elixir.MyApp.DevTools prefix stripped)
      assert [] = analyze(source, allowed_modules: [MyApp.DevTools])
    end

    test "does NOT flag Mix.env / Mix.Project / Mix.Task (out of scope)" do
      # The narrow scope is deliberate — those have higher FP rates
      # (libraries with conditional Mix usage). Surface a separate
      # rule later if we ever want the broader check.
      source = ~S"""
      defmodule MyApp.Helper do
        def env, do: Mix.env()
        def path, do: Mix.Project.compile_path()
        def run, do: Mix.Task.run("compile")
      end
      """

      assert [] = analyze(source)
    end

    test "does NOT flag random module with 'Mix' in its name" do
      source = ~S"""
      defmodule MyApp.AudioMixer do
        def mix(channels), do: Enum.sum(channels)
      end
      """

      assert [] = analyze(source)
    end

    test "does NOT flag plain code (no defmodule)" do
      assert [] = analyze("Mix.shell().info('top-level')")
    end
  end

  describe "check/2 — Sourceror-parsed (production path)" do
    test "still flags Mix.shell under Sourceror" do
      source = ~S"""
      defmodule MyApp.Worker do
        def go, do: Mix.shell().info("hello")
      end
      """

      assert [_] = analyze_sourceror(source)
    end

    test "still skips Mix.Tasks.* under Sourceror" do
      source = ~S"""
      defmodule Mix.Tasks.MyApp.Sync do
        def run(_), do: Mix.shell().info("ok")
      end
      """

      assert [] = analyze_sourceror(source)
    end
  end
end
