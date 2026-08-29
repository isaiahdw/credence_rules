defmodule CredenceRules.Pattern.ApplicationPutEnvInCodeTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.ApplicationPutEnvInCode

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    ApplicationPutEnvInCode.check(ast, [])
  end

  defp analyze_sourceror(source) do
    {:ok, ast} = Sourceror.parse_string(source)
    ApplicationPutEnvInCode.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags Application.put_env/3" do
      assert [issue] = analyze(~S"Application.put_env(:my_app, :k, :v)")
      assert issue.rule == :application_put_env_in_code
      assert issue.message =~ "Application.put_env"
    end

    test "flags Application.put_env/2 (2-arity form for keyword updates)" do
      assert [_] = analyze(~S"Application.put_env(:my_app, k: :v)")
    end

    test "flags Application.put_all_env" do
      assert [_] = analyze(~S"Application.put_all_env([{:my_app, [k: :v]}])")
    end

    test "flags Application.delete_env" do
      assert [_] = analyze(~S"Application.delete_env(:my_app, :k)")
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag Application.get_env / fetch_env" do
      assert analyze(~S"Application.get_env(:my_app, :k)") == []
      assert analyze(~S"Application.fetch_env!(:my_app, :k)") == []
    end

    test "does NOT flag put_env on another module" do
      assert analyze(~S"OtherModule.put_env(:k, :v)") == []
    end

    test "does NOT flag put_env inside a Mix.Task" do
      # Mix tasks are CLI entry points whose explicit purpose can
      # legitimately include mutating Application config.
      source = ~S"""
      defmodule Mix.Tasks.Interop.Commission do
        use Mix.Task

        def run(_args) do
          Application.put_env(:my_app, :handler, MyApp.Handler)
          :ok
        end
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag put_env inside an ExUnit.Case (test setup pattern)" do
      # `setup do Application.put_env(...) end` paired with `on_exit/1`
      # is the standard test-override pattern. Scoped to the case;
      # not the hidden-mutation smell this rule targets.
      source = ~S"""
      defmodule MyApp.WorkerTest do
        use ExUnit.Case, async: false

        setup do
          original = Application.get_env(:my_app, :handler)
          Application.put_env(:my_app, :handler, MyApp.TestHandler)
          on_exit(fn -> Application.put_env(:my_app, :handler, original) end)
          :ok
        end
      end
      """

      assert analyze(source) == []
    end

    test "DOES flag put_env in a non-Mix-task module" do
      source = ~S"""
      defmodule MyApp.Worker do
        def configure(mod) do
          Application.put_env(:my_app, :adapter, mod)
        end
      end
      """

      assert [_] = analyze(source)
    end
  end

  # Production parses via Sourceror, which wraps the `:do` key.
  # The Mix.Task exemption used to silently misfire because the
  # destructure `[{:do, body}]` never matched Sourceror's AST.
  describe "check/2 — Sourceror-parsed (production path)" do
    test "exemption fires for Mix.Task under Sourceror parse" do
      source = ~S"""
      defmodule Mix.Tasks.Interop.Commission do
        use Mix.Task

        def run(_args) do
          Application.put_env(:my_app, :thread_enabled, false)
          :ok
        end
      end
      """

      assert analyze_sourceror(source) == []
    end

    test "exemption fires for ExUnit.Case under Sourceror parse" do
      source = ~S"""
      defmodule MyApp.WorkerTest do
        use ExUnit.Case, async: false

        setup do
          Application.put_env(:my_app, :handler, MyApp.TestHandler)
          :ok
        end
      end
      """

      assert analyze_sourceror(source) == []
    end

    test "still flags put_env in a non-exempt module under Sourceror parse" do
      source = ~S"""
      defmodule MyApp.Worker do
        def configure(mod) do
          Application.put_env(:my_app, :adapter, mod)
        end
      end
      """

      assert [_] = analyze_sourceror(source)
    end
  end
end
