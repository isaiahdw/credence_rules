defmodule CredenceRules.CrossFile.GraphSource do
  @moduledoc """
  Resolves which dependency-graph source the cross-file coupling
  rules use:

  - `:ast` (default) — walk the source files and treat every
    `{:__aliases__, _, _}` reference as an edge. No build
    requirement; runs anywhere. Over-counts type-only references
    and misses dynamic dispatch.
  - `:beam` — read import chunks from the compiled `.beam` files
    in `Mix.Project.compile_path/0`. Reflects what the compiler
    actually wired up. Requires the project to be compiled
    (callers usually run `mix compile` before `mix credence.check`).
  - `:union` — run both, merge their edges. Better recall: AST
    contributes struct-only / typespec-only / unused-alias refs
    that don't appear in BEAM imports; BEAM contributes macro-
    emitted calls that AST misses (macros expand post-parse).
    Falls back to whichever source succeeds if the other errors.

  Pass via rule opts: `[graph_source: :beam]`. Falls back to `:ast`
  if the BEAM source errors (compile path missing, unreadable
  beams, etc.) — never silently fails the run.

  Set the default project-wide via Application env:

      config :credence_rules, graph_source: :union
  """

  alias CredenceRules.CrossFile.{BeamGraph, ModuleGraph}

  @doc """
  Build a `%ModuleGraph{}` using the configured source. Falls back
  to the AST source if `:beam` is requested but fails. For `:union`,
  uses whichever source(s) succeed.
  """
  @spec resolve([{Path.t(), Macro.t()}], keyword()) :: ModuleGraph.t()
  def resolve(files, opts \\ []) do
    source = source_from(opts)

    case source do
      :ast ->
        ModuleGraph.build(files)

      :beam ->
        case BeamGraph.build() do
          {:ok, graph} -> graph
          {:error, _reason} -> ModuleGraph.build(files)
        end

      :union ->
        union_graph(files)
    end
  end

  defp source_from(opts) do
    case Keyword.get(opts, :graph_source) do
      nil -> Application.get_env(:credence_rules, :graph_source, :ast)
      other -> other
    end
  end

  # Build both graphs and merge them. Modules union; forward edges
  # union per source; reverse rebuilt from the unioned forward map;
  # module_to_file merges with AST winning on path conflicts (AST
  # paths point at .ex source which is friendlier in finding
  # messages than the .beam path).
  defp union_graph(files) do
    ast = ModuleGraph.build(files)

    case BeamGraph.build() do
      {:ok, beam} -> merge(ast, beam)
      {:error, _} -> ast
    end
  end

  defp merge(%ModuleGraph{} = ast, %ModuleGraph{} = beam) do
    modules = MapSet.union(ast.modules, beam.modules)
    forward = merge_edges(ast.forward, beam.forward)
    reverse = invert(forward)
    module_to_file = Map.merge(beam.module_to_file, ast.module_to_file)

    %ModuleGraph{
      modules: modules,
      forward: forward,
      reverse: reverse,
      module_to_file: module_to_file
    }
  end

  defp merge_edges(a, b) do
    Map.merge(a, b, fn _key, a_set, b_set -> MapSet.union(a_set, b_set) end)
  end

  defp invert(forward) do
    Enum.reduce(forward, %{}, fn {source, targets}, acc ->
      Enum.reduce(targets, acc, fn target, inner_acc ->
        Map.update(inner_acc, target, MapSet.new([source]), &MapSet.put(&1, source))
      end)
    end)
  end
end
