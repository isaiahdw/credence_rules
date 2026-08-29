defmodule CredenceRules.Pattern.PathExpandPrivTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.PathExpandPriv

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    PathExpandPriv.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags Path.expand with :code.priv_dir as base" do
      assert [issue] =
               analyze(~S|Path.expand("schema.json", :code.priv_dir(:my_app))|)

      assert issue.rule == :path_expand_priv
      assert issue.message =~ "Path.join"
    end

    test "flags Path.expand with priv_dir embedded in path arg" do
      assert [_] =
               analyze(~S|Path.expand(:code.priv_dir(:my_app) <> "/schema.json")|)
    end

    test "flags pipe form" do
      source = ~S"""
      :code.priv_dir(:my_app) |> Path.expand("schema.json")
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag Path.join with priv_dir" do
      assert analyze(~S|Path.join(:code.priv_dir(:my_app), "schema.json")|) == []
    end

    test "does NOT flag Path.expand on a regular path" do
      assert analyze(~S|Path.expand("./schema.json")|) == []
    end

    test "does NOT flag priv_dir on its own" do
      assert analyze(~S|:code.priv_dir(:my_app)|) == []
    end
  end
end
