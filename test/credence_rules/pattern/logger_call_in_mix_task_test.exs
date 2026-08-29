defmodule CredenceRules.Pattern.LoggerCallInMixTaskTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.LoggerCallInMixTask

  defp analyze(source, opts \\ []) do
    {:ok, ast} = Code.string_to_quoted(source)
    LoggerCallInMixTask.check(ast, [source: source] ++ opts)
  end

  defp analyze_sourceror(source, opts \\ []) do
    {:ok, ast} = Sourceror.parse_string(source)
    LoggerCallInMixTask.check(ast, [source: source] ++ opts)
  end

  describe "check/2 — flagged (Logger calls in Mix.Tasks.*)" do
    test "flags Logger.info inside a Mix.Tasks.* module" do
      source = ~S"""
      defmodule Mix.Tasks.MyApp.Seed do
        use Mix.Task
        require Logger
        def run(_), do: Logger.info("seeding")
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :logger_call_in_mix_task
      assert issue.meta.level == :info
    end

    test "flags every level macro" do
      source = ~S"""
      defmodule Mix.Tasks.MyApp.Seed do
        require Logger
        def run(_) do
          Logger.debug("d")
          Logger.info("i")
          Logger.notice("n")
          Logger.warning("w")
          Logger.warn("legacy w")
          Logger.error("e")
          Logger.critical("c")
          Logger.alert("a")
          Logger.emergency("em")
        end
      end
      """

      assert length(analyze(source)) == 9
    end

    test "flags nested Mix.Tasks.* with multi-segment names" do
      source = ~S"""
      defmodule Mix.Tasks.MyApp.SubGroup.Sync do
        require Logger
        def run(_), do: Logger.info("syncing")
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag Logger calls in plain modules (Logger is correct there)" do
      source = ~S"""
      defmodule MyApp.Worker do
        require Logger
        def go, do: Logger.info("working")
      end
      """

      assert [] = analyze(source)
    end

    test "does NOT flag Logger.configure / metadata / put_application_level" do
      source = ~S"""
      defmodule Mix.Tasks.MyApp.Setup do
        require Logger
        def run(_) do
          Logger.configure(level: :info)
          Logger.metadata(request_id: "abc")
          Logger.put_application_level(:my_app, :debug)
          Logger.flush()
        end
      end
      """

      # These are configuration, not logging — auto-skipped via
      # explicit level allowlist.
      assert [] = analyze(source)
    end

    test "does NOT flag random module with 'Logger' in its name" do
      source = ~S"""
      defmodule Mix.Tasks.MyApp.Audit do
        def run(_), do: MyApp.AuditLogger.info("audit")
      end
      """

      # MyApp.AuditLogger isn't in default :logger_modules; the
      # rule treats it as unrelated.
      assert [] = analyze(source)
    end

    test "honours :logger_modules — custom Logger wrappers" do
      source = ~S"""
      defmodule Mix.Tasks.MyApp.Audit do
        def run(_), do: MyApp.AuditLog.info("audit event")
      end
      """

      assert [] = analyze(source)
      assert [_] = analyze(source, logger_modules: ~w(Logger MyApp.AuditLog))
    end

    test "does NOT flag plain code (no defmodule)" do
      assert [] = analyze("Logger.info(\"top\")")
    end
  end

  describe "check/2 — Sourceror-parsed" do
    test "still flags Logger.info in Mix.Tasks.* under Sourceror" do
      source = ~S"""
      defmodule Mix.Tasks.MyApp.Seed do
        require Logger
        def run(_), do: Logger.info("seeding")
      end
      """

      assert [_] = analyze_sourceror(source)
    end

    test "still skips Logger in plain module under Sourceror" do
      source = ~S"""
      defmodule MyApp.Worker do
        require Logger
        def go, do: Logger.info("working")
      end
      """

      assert [] = analyze_sourceror(source)
    end
  end
end
