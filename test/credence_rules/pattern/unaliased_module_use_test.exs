defmodule CredenceRules.Pattern.UnaliasedModuleUseTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.UnaliasedModuleUse

  defp analyze(source, opts \\ []) do
    {:ok, ast} = Code.string_to_quoted(source)
    UnaliasedModuleUse.check(ast, [source: source] ++ opts)
  end

  describe "check/2 — flagged" do
    test "flags a fully-qualified module used 3+ times in one function" do
      source = ~S"""
      defmodule MyApp.Checker do
        def run(source_file) do
          Credo.Code.prewalk(source_file, fn x, acc -> {x, acc} end, [])
          Credo.Code.remove_metadata(pattern)
          Credo.Code.remove_metadata(body)
        end
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :unaliased_module_use
      assert issue.meta.name == "Credo.Code"
      assert issue.meta.count == 3
    end

    test "flags one issue per module per function" do
      source = ~S"""
      defmodule MyApp.M do
        def run(x) do
          Credo.Code.prewalk(x, &id/1, [])
          Credo.Code.remove_metadata(x)
          Credo.Code.remove_metadata(x)
          MyApp.Inner.Mod.a(x)
          MyApp.Inner.Mod.b(x)
          MyApp.Inner.Mod.c(x)
        end
      end
      """

      issues = analyze(source)
      assert length(issues) == 2
      assert Enum.map(issues, & &1.meta.name) |> Enum.sort() == ["Credo.Code", "MyApp.Inner.Mod"]
    end

    test "respects min_count override" do
      source = ~S"""
      defmodule MyApp.M do
        def run(x) do
          Credo.Code.a(x)
          Credo.Code.b(x)
        end
      end
      """

      assert [] = analyze(source, min_count: 3)
      assert [_] = analyze(source, min_count: 2)
    end
  end

  describe "check/2 — not flagged" do
    test "ignores already-aliased modules" do
      source = ~S"""
      defmodule MyApp.Checker do
        alias Credo.Code

        def run(source_file) do
          Credo.Code.prewalk(source_file, &id/1, [])
          Credo.Code.remove_metadata(pattern)
          Credo.Code.remove_metadata(body)
        end
      end
      """

      assert [] = analyze(source)
    end

    test "ignores single-segment modules (Enum, String, …)" do
      source = ~S"""
      defmodule MyApp.M do
        def run(list) do
          Enum.map(list, &String.trim/1)
          Enum.filter(list, &String.contains?(&1, "x"))
          Enum.each(list, &String.upcase/1)
          Enum.count(list)
          Enum.reverse(list)
        end
      end
      """

      assert [] = analyze(source)
    end

    test "ignores modules with fewer uses than the threshold" do
      source = ~S"""
      defmodule MyApp.M do
        def run(x) do
          Credo.Code.a(x)
          Credo.Code.b(x)
        end
      end
      """

      assert [] = analyze(source)
    end

    test "ignores uses spread across multiple functions" do
      source = ~S"""
      defmodule MyApp.M do
        def a(x), do: Credo.Code.a(x)
        def b(x), do: Credo.Code.b(x)
        def c(x), do: Credo.Code.c(x)
      end
      """

      assert [] = analyze(source)
    end
  end
end
