defmodule CredenceRules.Pattern.ModuleWithManyUseStatementsTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.ModuleWithManyUseStatements

  defp analyze(source, opts \\ []) do
    {:ok, ast} = Code.string_to_quoted(source)
    ModuleWithManyUseStatements.check(ast, [source: source] ++ opts)
  end

  defp analyze_sourceror(source, opts \\ []) do
    {:ok, ast} = Sourceror.parse_string(source)
    ModuleWithManyUseStatements.check(ast, [source: source] ++ opts)
  end

  describe "check/2 — flagged" do
    test "flags a module with 4 use statements at default threshold" do
      source = ~S"""
      defmodule M do
        use A
        use B
        use C
        use D
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :module_with_many_use_statements
      assert issue.meta.uses == 4
    end

    test "flags a module with 6 use statements" do
      source = ~S"""
      defmodule M do
        use Ecto.Schema
        use MyApp.AuditableSchema
        use Pow.Ecto.Schema
        use PowEmailConfirmation.Ecto.Schema
        use PowResetPassword.Ecto.Schema
        use SomethingElse
      end
      """

      assert [issue] = analyze(source)
      assert issue.meta.uses == 6
    end

    test "counts `use Foo, opts:` shape" do
      source = ~S"""
      defmodule M do
        use Phoenix.Controller, namespace: MyApp
        use Phoenix.LiveView
        use Phoenix.Component
        use MyAppWeb, :live_view
      end
      """

      assert [_] = analyze(source)
    end

    test "honours custom :max_uses" do
      source = ~S"""
      defmodule M do
        use A
        use B
      end
      """

      assert [_] = analyze(source, max_uses: 2)
    end
  end

  describe "check/2 — not flagged" do
    test "ignores modules with 3 or fewer uses" do
      source = ~S"""
      defmodule M do
        use Phoenix.LiveView
        use Phoenix.Component
      end
      """

      assert [] = analyze(source)
    end

    test "ignores modules with no use statements" do
      assert [] = analyze("defmodule M do\n  def foo, do: :ok\nend")
    end

    test "ignores nested module uses (don't bubble up)" do
      source = ~S"""
      defmodule Outer do
        use A
        use B

        defmodule Inner do
          use C
          use D
        end
      end
      """

      # Outer has 2 (below threshold), Inner has 2 (below threshold) —
      # neither fires.
      assert [] = analyze(source)
    end

    test "ignores `import`, `alias`, `require` — only `use` counts" do
      source = ~S"""
      defmodule M do
        import A
        import B
        import C
        import D
        alias E
        require F
      end
      """

      assert [] = analyze(source)
    end
  end

  describe "check/2 — Sourceror-parsed (production path)" do
    test "still flags 4+ uses under Sourceror parse" do
      source = ~S"""
      defmodule M do
        use A
        use B
        use C
        use D
      end
      """

      assert [_] = analyze_sourceror(source)
    end
  end
end
