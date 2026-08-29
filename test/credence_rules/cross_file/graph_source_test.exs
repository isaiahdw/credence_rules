defmodule CredenceRules.CrossFile.GraphSourceTest do
  use ExUnit.Case, async: false

  alias CredenceRules.CrossFile.{GraphSource, ModuleGraph}

  defp file(path, source) do
    {:ok, ast} = Sourceror.parse_string(source)
    {path, ast}
  end

  defp ast_corpus do
    [
      file("a.ex", "defmodule A do\n  def go, do: B.go()\nend\n"),
      file("b.ex", "defmodule B do\n  def go, do: :ok\nend\n")
    ]
  end

  describe "resolve/2" do
    test "default source is :ast — builds graph from supplied files" do
      assert %ModuleGraph{} = graph = GraphSource.resolve(ast_corpus())
      assert MapSet.member?(graph.modules, "A")
      assert MapSet.member?(graph.modules, "B")
      assert "B" in ModuleGraph.fan_out(graph, "A")
    end

    test ":ast source explicit" do
      assert %ModuleGraph{} = graph = GraphSource.resolve(ast_corpus(), graph_source: :ast)
      assert MapSet.member?(graph.modules, "A")
    end

    test ":beam source reads our own project beams (ignores supplied files)" do
      # BeamGraph reads from compile_path/0, NOT from the file list
      # we pass. So the result should look like this project's
      # actual module graph, not the synthetic a.ex/b.ex.
      assert %ModuleGraph{} = graph = GraphSource.resolve(ast_corpus(), graph_source: :beam)

      # Synthetic files aren't compiled, so they shouldn't be in
      # the modules set.
      refute MapSet.member?(graph.modules, "A")

      # But our own modules are.
      assert MapSet.member?(graph.modules, "CredenceRules.CrossFile.GraphSource")
    end

    test "Application env :graph_source is honoured when no opt passed" do
      Application.put_env(:credence_rules, :graph_source, :beam)

      try do
        graph = GraphSource.resolve(ast_corpus())
        # Came from BEAM, so synthetic A/B not present
        refute MapSet.member?(graph.modules, "A")
        assert MapSet.member?(graph.modules, "CredenceRules.CrossFile.GraphSource")
      after
        Application.delete_env(:credence_rules, :graph_source)
      end
    end

    test "explicit opt overrides Application env" do
      Application.put_env(:credence_rules, :graph_source, :beam)

      try do
        # Force :ast — should ignore the env's :beam.
        graph = GraphSource.resolve(ast_corpus(), graph_source: :ast)
        assert MapSet.member?(graph.modules, "A")
        assert MapSet.member?(graph.modules, "B")
      after
        Application.delete_env(:credence_rules, :graph_source)
      end
    end
  end

  describe "resolve/2 — :union source" do
    test "merges modules from AST corpus and compiled BEAMs" do
      graph = GraphSource.resolve(ast_corpus(), graph_source: :union)

      # AST contributes synthetic A and B
      assert MapSet.member?(graph.modules, "A")
      assert MapSet.member?(graph.modules, "B")

      # BEAM contributes our own compiled modules
      assert MapSet.member?(graph.modules, "CredenceRules.CrossFile.GraphSource")
      assert MapSet.member?(graph.modules, "CredenceRules.CrossFile.BeamGraph")
    end

    test "unions edges from both sources" do
      graph = GraphSource.resolve(ast_corpus(), graph_source: :union)

      # AST sees A → B (alias reference)
      assert "B" in ModuleGraph.fan_out(graph, "A")

      # BEAM sees GraphSource → BeamGraph (real function call)
      assert "CredenceRules.CrossFile.BeamGraph" in ModuleGraph.fan_out(
               graph,
               "CredenceRules.CrossFile.GraphSource"
             )
    end

    test "reverse graph mirrors the unioned forward edges" do
      graph = GraphSource.resolve(ast_corpus(), graph_source: :union)

      assert "A" in ModuleGraph.fan_in(graph, "B")

      assert "CredenceRules.CrossFile.GraphSource" in ModuleGraph.fan_in(
               graph,
               "CredenceRules.CrossFile.BeamGraph"
             )
    end

    test "AST paths win in module_to_file (.ex > .beam for messages)" do
      graph = GraphSource.resolve(ast_corpus(), graph_source: :union)

      # AST entry — synthetic file path.
      assert Map.get(graph.module_to_file, "A") == "a.ex"

      # BEAM-only modules keep their .beam path (no AST entry to win).
      beam_path = Map.get(graph.module_to_file, "CredenceRules.CrossFile.GraphSource")
      assert String.ends_with?(beam_path, ".beam")
    end

    test "union catches references only AST sees (alias without call)" do
      # AST sees `alias B` even though B is never called → no
      # corresponding BEAM import. Union should still see the edge.
      ast = [
        file("a.ex", "defmodule A do\n  alias B\nend\n"),
        file("b.ex", "defmodule B do\nend\n")
      ]

      graph = GraphSource.resolve(ast, graph_source: :union)

      assert "B" in ModuleGraph.fan_out(graph, "A")
    end
  end
end
