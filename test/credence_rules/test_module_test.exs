defmodule CredenceRules.TestModuleTest do
  use ExUnit.Case, async: true

  alias CredenceRules.TestModule

  defp parse(source), do: Code.string_to_quoted!(source)

  describe "exunit_file?/1" do
    test "true for `use ExUnit.Case`" do
      source = ~S"""
      defmodule MyTest do
        use ExUnit.Case
        test "x", do: :ok
      end
      """

      assert TestModule.exunit_file?(parse(source))
    end

    test "true for `use ExUnit.Case, async: true`" do
      source = ~S"""
      defmodule MyTest do
        use ExUnit.Case, async: true
      end
      """

      assert TestModule.exunit_file?(parse(source))
    end

    test "true for `use ExUnit.CaseTemplate`" do
      source = ~S"""
      defmodule MyAppCase do
        use ExUnit.CaseTemplate
      end
      """

      assert TestModule.exunit_file?(parse(source))
    end

    test "false for a module with a custom `test/2` DSL macro" do
      source = ~S"""
      defmodule MyDsl do
        defmacro test(name, opts), do: nil
        test "in DSL", do: :ok
      end
      """

      refute TestModule.exunit_file?(parse(source))
    end

    test "false for a module that uses Phoenix.ConnTest but not ExUnit.Case directly" do
      # This is the DSL-overlap case the gate guards against: a
      # test-adjacent module with `test/2`-shaped macros but without
      # the canonical ExUnit declaration.
      source = ~S"""
      defmodule MyAppWeb.SomeCase do
        use Phoenix.ConnTest
      end
      """

      refute TestModule.exunit_file?(parse(source))
    end

    test "false for plain lib code" do
      refute TestModule.exunit_file?(parse("defmodule MyApp.Foo do\nend"))
    end
  end
end
