# credence-file:repeated_subtree_in_module — this module is an AST pattern
#   matcher whose check/2 + Macro.prewalk + build_issue shape is the Rule
#   contract itself, so the structural duplication is inherent to the form
#   rather than a smell
defmodule CredenceRules.CrossFile.ModuleGraph do
  @moduledoc """
  Shared module dependency graph builder for cross-file coupling
  rules (`CircularDependency`, `ModuleInstability`, `HubModule`).

  Walks every file's AST, extracts the defining module plus every
  module it references, and produces a directed graph plus reverse
  graph for fan-in queries.

  ## Project-local filter

  Only **project-local** modules count as nodes. Calls to `Enum`,
  `Map`, `Repo`, `Phoenix`, etc. are excluded — coupling rules care
  about your own modules' relationships, not your dependency tree.

  Locality is determined by collecting every module that appears as
  a `defmodule X` in any scanned file. Anything else (third-party
  deps, stdlib) is ignored.

  ## Reference detection

  A "reference" is any `{:__aliases__, _, segments}` node anywhere
  in the file — same shape that `alias`, `import`, `use`, `require`,
  fully-qualified calls (`Foo.bar(...)`), structs (`%Foo{}`), and
  typespecs (`@spec foo() :: Foo.t()`) all share. Self-references
  (a module referencing itself) are filtered out.

  ## Build cost

  O(total AST nodes across files). Built once per `mix credence.check`
  run and passed to every coupling rule, so the cost is paid once
  regardless of how many coupling rules are enabled.
  """

  @type module_name :: String.t()
  @type edges :: %{module_name() => MapSet.t(module_name())}

  @type t :: %__MODULE__{
          modules: MapSet.t(module_name()),
          forward: edges(),
          reverse: edges(),
          module_to_file: %{module_name() => Path.t()}
        }

  defstruct modules: MapSet.new(),
            forward: %{},
            reverse: %{},
            module_to_file: %{}

  @doc """
  Build the graph from a list of `{path, ast}` tuples. Reference
  collection skips modules not declared in the scanned corpus.
  """
  @spec build([{Path.t(), Macro.t()}]) :: t()
  def build(files) do
    file_modules = collect_file_modules(files)
    project_locals = file_modules |> Map.keys() |> MapSet.new()

    {forward, reverse} =
      Enum.reduce(files, {%{}, %{}}, fn {_path, ast}, {fwd, rev} ->
        case defining_module(ast) do
          nil ->
            {fwd, rev}

          source ->
            targets =
              ast
              |> collect_references()
              |> Enum.filter(fn name -> name != source and MapSet.member?(project_locals, name) end)
              |> MapSet.new()

            {add_targets(fwd, source, targets), add_reverse(rev, source, targets)}
        end
      end)

    %__MODULE__{
      modules: project_locals,
      forward: forward,
      reverse: reverse,
      module_to_file: file_modules
    }
  end

  @doc "Modules that `source` depends on (outgoing edges)."
  @spec fan_out(t(), module_name()) :: [module_name()]
  def fan_out(%__MODULE__{forward: forward}, source) do
    forward |> Map.get(source, MapSet.new()) |> Enum.sort()
  end

  @doc "Modules that depend on `target` (incoming edges)."
  @spec fan_in(t(), module_name()) :: [module_name()]
  def fan_in(%__MODULE__{reverse: reverse}, target) do
    reverse |> Map.get(target, MapSet.new()) |> Enum.sort()
  end

  @doc """
  Strongly connected components (Tarjan). Each SCC is a list of
  module names. SCCs with size ≥ 2 are circular-dependency clusters.
  Self-loops (one-element SCCs with a self-edge) aren't reported
  because we filtered self-references out at build time.
  """
  @spec strongly_connected_components(t()) :: [[module_name()]]
  def strongly_connected_components(%__MODULE__{modules: modules, forward: forward}) do
    state = %{
      index: 0,
      indices: %{},
      lowlinks: %{},
      on_stack: MapSet.new(),
      stack: [],
      sccs: []
    }

    state =
      Enum.reduce(modules, state, fn node, st ->
        if Map.has_key?(st.indices, node), do: st, else: tarjan_strongconnect(node, forward, st)
      end)

    state.sccs
  end

  defp tarjan_strongconnect(node, forward, state) do
    state =
      state
      |> Map.update!(:indices, &Map.put(&1, node, state.index))
      |> Map.update!(:lowlinks, &Map.put(&1, node, state.index))
      |> Map.update!(:index, &(&1 + 1))
      |> Map.update!(:stack, &[node | &1])
      |> Map.update!(:on_stack, &MapSet.put(&1, node))

    successors = Map.get(forward, node, MapSet.new())

    state =
      Enum.reduce(successors, state, fn succ, st ->
        cond do
          not Map.has_key?(st.indices, succ) ->
            recursed = tarjan_strongconnect(succ, forward, st)
            update_lowlink(recursed, node, recursed.lowlinks[succ])

          MapSet.member?(st.on_stack, succ) ->
            update_lowlink(st, node, st.indices[succ])

          true ->
            st
        end
      end)

    if state.lowlinks[node] == state.indices[node] do
      {scc, new_stack, new_on_stack} = pop_scc(state.stack, state.on_stack, node, [])
      Map.merge(state, %{stack: new_stack, on_stack: new_on_stack, sccs: [scc | state.sccs]})
    else
      state
    end
  end

  defp update_lowlink(state, node, candidate) do
    Map.update!(state, :lowlinks, fn ll ->
      Map.update!(ll, node, &min(&1, candidate))
    end)
  end

  defp pop_scc([node | rest], on_stack, target, acc) do
    on_stack = MapSet.delete(on_stack, node)
    new_acc = [node | acc]

    if node == target,
      do: {new_acc, rest, on_stack},
      else: pop_scc(rest, on_stack, target, new_acc)
  end

  # File-walking helpers below — same approach as ForbiddenModuleDependency.

  defp collect_file_modules(files) do
    Enum.reduce(files, %{}, fn {path, ast}, acc ->
      case defining_module(ast) do
        nil -> acc
        name -> Map.put(acc, name, path)
      end
    end)
  end

  defp defining_module({:defmodule, _, [alias_node, _body]}), do: module_name(alias_node)

  defp defining_module({:__block__, _, statements}) do
    Enum.find_value(statements, fn
      {:defmodule, _, [alias_node, _body]} -> module_name(alias_node)
      _ -> nil
    end)
  end

  defp defining_module(_), do: nil

  @doc """
  Dotted-string name of an `{:__aliases__, _, segments}` node (or a
  Sourceror block-wrapped one), or `nil` if it isn't an alias. Shared
  with coupling rules that need the defining module's name.
  """
  @spec module_name(Macro.t()) :: module_name() | nil
  def module_name({:__aliases__, _, segments}) when is_list(segments) do
    segments
    |> Enum.map(&segment_to_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(".")
    |> case do
      "" -> nil
      name -> name
    end
  end

  def module_name({:__block__, _, [inner]}), do: module_name(inner)
  def module_name(_), do: nil

  defp segment_to_string({:__block__, _, [seg]}) when is_atom(seg), do: Atom.to_string(seg)
  defp segment_to_string(seg) when is_atom(seg), do: Atom.to_string(seg)
  defp segment_to_string(_), do: nil

  defp collect_references(ast) do
    {_ast, names} =
      Macro.prewalk(ast, [], fn
        # Grouped-alias form: `alias Foo.Bar.{Baz, Qux}` parses as
        # the call `Foo.Bar.{}(Baz, Qux)`. Naively walking emits
        # three refs — the prefix `Foo.Bar` PLUS the unqualified
        # `Baz` and `Qux`. When `Foo.Bar` is a real defined
        # module (a facade), the phantom prefix edge creates
        # false circular-dependency SCCs.
        #
        # Expand here against the prefix, then return a non-AST
        # sentinel (`:grouped_alias_expanded`) so `Macro.prewalk`
        # doesn't recurse into the children's `__aliases__` nodes
        # (which would double-count the unqualified names anyway —
        # those get dropped by the project-local filter, but
        # avoid the work).
        {{:., _, [{:__aliases__, _, prefix_segs}, :{}]}, _, children}, acc
        when is_list(prefix_segs) and is_list(children) ->
          expanded = expand_grouped_alias(prefix_segs, children)
          {:grouped_alias_expanded, expanded ++ acc}

        {:__aliases__, _, segments} = node, acc when is_list(segments) ->
          case module_name(node) do
            nil -> {node, acc}
            name -> {node, [name | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    names |> Enum.uniq() |> Enum.sort()
  end

  # `Foo.Bar.{Baz, Qux}` → ["Foo.Bar.Baz", "Foo.Bar.Qux"]. Drops
  # the prefix-only reference (`Foo.Bar`) — that's syntactic
  # plumbing for introducing children, not a real dependency.
  defp expand_grouped_alias(prefix_segs, children) do
    prefix = prefix_segs |> Enum.map(&segment_to_string/1) |> Enum.reject(&is_nil/1)

    for child <- children,
        child_segs = child_segments(child),
        not is_nil(child_segs),
        full = join_segments(prefix ++ child_segs),
        not is_nil(full),
        do: full
  end

  defp child_segments({:__aliases__, _, segs}) when is_list(segs) do
    segs |> Enum.map(&segment_to_string/1) |> Enum.reject(&is_nil/1)
  end

  defp child_segments(_), do: nil

  defp join_segments([]), do: nil
  defp join_segments(segs), do: Enum.join(segs, ".")

  defp add_targets(map, source, targets) do
    Map.update(map, source, targets, &MapSet.union(&1, targets))
  end

  defp add_reverse(map, source, targets) do
    Enum.reduce(targets, map, fn target, acc ->
      Map.update(acc, target, MapSet.new([source]), &MapSet.put(&1, source))
    end)
  end
end
