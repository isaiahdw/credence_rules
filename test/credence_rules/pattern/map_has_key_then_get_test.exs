defmodule CredenceRules.Pattern.MapHasKeyThenGetTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.MapHasKeyThenGet

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    MapHasKeyThenGet.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "if Map.has_key?(m, k), do: Map.get(m, k)" do
      source = ~S|if Map.has_key?(params, "id"), do: load_user(Map.get(params, "id"))|
      assert [_] = analyze(source)
    end

    test "atom-key variant" do
      source = ~S"if Map.has_key?(opts, :timeout), do: sleep(Map.get(opts, :timeout))"
      assert [_] = analyze(source)
    end

    test "with default arg in Map.get" do
      source = ~S"if Map.has_key?(opts, :id), do: load(Map.get(opts, :id, nil))"
      assert [_] = analyze(source)
    end

    test "if-do-else form" do
      source = ~S"""
      if Map.has_key?(params, "id") do
        load_user(Map.get(params, "id"))
      else
        :missing
      end
      """

      assert [_] = analyze(source)
    end

    test "bracket access in body" do
      source = ~S|if Map.has_key?(opts, :timeout), do: sleep(opts[:timeout])|
      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "body doesn't fetch the value (pure presence test)" do
      source = ~S|if Map.has_key?(m, "id"), do: log("has id")|
      assert [] = analyze(source)
    end

    test "different key in body" do
      source = ~S"if Map.has_key?(m, :id), do: Map.get(m, :name)"
      assert [] = analyze(source)
    end

    test "different map in body" do
      source = ~S"if Map.has_key?(m1, :id), do: Map.get(m2, :id)"
      assert [] = analyze(source)
    end

    test "truthy bracket (owned by truthy_access_reused_in_body)" do
      source = ~S|if params["id"], do: load(params["id"])|
      assert [] = analyze(source)
    end

    test "case used directly" do
      source = ~S"""
      case params do
        %{"id" => id} -> load_user(id)
        _ -> nil
      end
      """

      assert [] = analyze(source)
    end

    test "non-stdlib Map.has_key? (wrong module)" do
      source = ~S|if MyApp.Map.has_key?(m, :id), do: MyApp.Map.get(m, :id)|
      assert [] = analyze(source)
    end

    test "plain code" do
      assert [] = analyze("x = 1")
    end
  end
end
