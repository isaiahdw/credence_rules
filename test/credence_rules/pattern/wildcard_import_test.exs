defmodule CredenceRules.Pattern.WildcardImportTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.WildcardImport

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    WildcardImport.check(ast, source: source)
  end

  defp analyze_sourceror(source) do
    {:ok, ast} = Sourceror.parse_string(source)
    WildcardImport.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags `import Foo` with no options" do
      assert [issue] = analyze("import Logger")
      assert issue.rule == :wildcard_import
      assert issue.message =~ "no options"
    end

    test "flags `import Foo, []` (empty options)" do
      assert [issue] = analyze("import Logger, []")
      assert issue.message =~ "no `:only`"
    end

    test "flags `import Foo, warn: false` (no scope option)" do
      assert [_] = analyze("import Logger, warn: false")
    end

    test "flags multi-segment module aliases" do
      assert [_] = analyze("import Ecto.Query")
      assert [_] = analyze("import Phoenix.LiveView.Helpers")
    end

    test "fires inside a module body" do
      source = ~S"""
      defmodule M do
        import Logger
        def go, do: debug("hi")
      end
      """

      assert [issue] = analyze(source)
      assert issue.meta.line == 2
    end
  end

  describe "check/2 — not flagged" do
    test "ignores `import Foo, only: [...]`" do
      assert [] = analyze("import Logger, only: [debug: 1, info: 1]")
    end

    test "ignores `import Foo, only: :functions`" do
      assert [] = analyze("import Foo, only: :functions")
    end

    test "ignores `import Foo, only: :macros`" do
      assert [] = analyze("import Foo, only: :macros")
    end

    test "ignores `import Foo, except: [...]`" do
      assert [] = analyze("import Logger, except: [warn: 1]")
    end

    test "ignores imports inside a quote block (macro internals)" do
      source = ~S"""
      defmacro using_logger do
        quote do
          import Logger
        end
      end
      """

      assert [] = analyze(source)
    end

    test "ignores plain function calls and aliases" do
      assert [] = analyze("alias Foo.Bar")
      assert [] = analyze("Logger.debug(\"hi\")")
    end
  end

  describe "check/2 — Sourceror-parsed (production path)" do
    test "still flags `import Foo` under Sourceror parse" do
      assert [_] = analyze_sourceror("import Logger")
    end

    test "still allows `import Foo, only: [...]` under Sourceror parse" do
      assert [] = analyze_sourceror("import Logger, only: [debug: 1]")
    end
  end
end
