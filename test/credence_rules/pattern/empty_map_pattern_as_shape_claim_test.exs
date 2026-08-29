defmodule CredenceRules.Pattern.EmptyMapPatternAsShapeClaimTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.EmptyMapPatternAsShapeClaim

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    EmptyMapPatternAsShapeClaim.check(ast, source: source)
  end

  describe "check/2 — flagged (def head)" do
    test "def f(%{} = params) with body using params.field" do
      source = ~S"""
      defmodule M do
        def handle(%{} = params) do
          process(params.id)
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "var = %{} form" do
      source = ~S"""
      defmodule M do
        def handle(params = %{}) do
          process(params.id)
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "body uses Map.get(var, key)" do
      source = ~S"""
      defmodule M do
        def handle(%{} = payload) do
          decode(Map.get(payload, :body))
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "body uses var[key]" do
      source = ~S"""
      defmodule M do
        def handle(%{} = payload) do
          decode(payload["body"])
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "defp / defmacro variants" do
      for kw <- ~w(defp defmacro defmacrop) do
        source = """
        defmodule M do
          #{kw} handle(%{} = params) do
            params.id
          end
        end
        """

        assert [_] = analyze(source), "expected to flag #{kw}"
      end
    end
  end

  describe "check/2 — flagged (case clause)" do
    test "case x do %{} -> body uses x.field end" do
      source = ~S"""
      case payload do
        %{} -> payload.id
        _ -> :error
      end
      """

      assert [_] = analyze(source)
    end

    test "case clause `%{} = name -> body uses name.field`" do
      source = ~S"""
      case payload do
        %{} = p -> p.id
        _ -> :error
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "pattern declares at least one key (real shape claim)" do
      source = ~S"""
      defmodule M do
        def handle(%{id: id} = params) do
          process(id, params)
        end
      end
      """

      assert [] = analyze(source)
    end

    test "body doesn't access specific keys" do
      source = ~S"""
      defmodule M do
        def handle(%{} = params) do
          {:ok, params}
        end
      end
      """

      assert [] = analyze(source)
    end

    test "case discrimination without key access" do
      source = ~S"""
      case x do
        %{} -> :is_a_map
        _ -> :other
      end
      """

      assert [] = analyze(source)
    end

    test "function head with guard (is_map)" do
      source = ~S"""
      defmodule M do
        def handle(params) when is_map(params) do
          Map.get(params, :id, :default)
        end
      end
      """

      assert [] = analyze(source)
    end

    test "plain code" do
      assert [] = analyze("x = 1")
    end
  end
end
