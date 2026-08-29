defmodule CredenceRules.Pattern.AtomInterpolationTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.AtomInterpolation

  doctest CredenceRules.Pattern.AtomInterpolation

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    AtomInterpolation.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags an interpolated atom literal" do
      assert [issue] = analyze(~S|:"handler_#{type}"|)
      assert issue.rule == :atom_interpolation
      assert issue.message =~ "bounded set"
    end

    test "flags a leading interpolated segment" do
      assert [_] = analyze(~S|:"#{name}.Registry"|)
    end

    test "flags each site separately" do
      source = ~S"""
      defmodule MyApp.Keys do
        def a(k), do: :"a_#{k}"
        def b(k), do: :"b_#{k}"
      end
      """

      assert length(analyze(source)) == 2
    end

    test "reports the line of the interpolation" do
      source = ~S"""
      defmodule MyApp.Keys do
        def a(k), do: :"a_#{k}"
      end
      """

      assert [issue] = analyze(source)
      assert issue.meta.line == 2
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag a quoted atom with no interpolation" do
      assert analyze(~S|:"has space"|) == []
    end

    test "does NOT flag a plain atom" do
      assert analyze(~S|:handler|) == []
    end

    test "does NOT flag a hand-written binary_to_atom" do
      # That shape keeps its existing advice under string_to_atom_unsafe.
      assert analyze(~S|:erlang.binary_to_atom(v, :utf8)|) == []
    end

    test "does NOT flag string interpolation that never becomes an atom" do
      assert analyze(~S|"handler_#{type}"|) == []
    end

    test "does NOT flag String.to_existing_atom on an interpolated string" do
      assert analyze(~S|String.to_existing_atom("handler_#{type}")|) == []
    end
  end

  describe "severity" do
    test "reports at :low — the sugar is usually bounded and fine" do
      assert AtomInterpolation.severity() == :low
    end

    test "is classified advisory so --strict does not fail on it" do
      assert CredenceRules.advisory?(:atom_interpolation)
    end
  end

  describe "interpolated_binary?/1" do
    defp first_arg(source) do
      {{:., _, _}, _, [arg | _]} = Code.string_to_quoted!(source)
      arg
    end

    test "matches the binary Elixir builds for an interpolated atom" do
      assert AtomInterpolation.interpolated_binary?(first_arg(~S|:"a_#{b}"|))
    end

    test "does not match a variable argument" do
      refute AtomInterpolation.interpolated_binary?(first_arg(~S|:erlang.binary_to_atom(v)|))
    end

    test "does not match a plain binary literal" do
      refute AtomInterpolation.interpolated_binary?(Code.string_to_quoted!(~S|"plain"|))
    end

    test "matches on the Sourceror parse path too" do
      # The check task parses via Sourceror, so the discriminator has to
      # survive both paths — they carry different metadata.
      {{:., _, _}, _, [arg | _]} = Sourceror.parse_string!(~S|:"a_#{b}"|)
      assert AtomInterpolation.interpolated_binary?(arg)
    end
  end
end
