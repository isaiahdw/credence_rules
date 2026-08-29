defmodule CredenceRules.CrossFile.BeamGraph do
  @moduledoc """
  Module-dependency graph built from compiled `.beam` files in the
  project's build directory. Alternative source for the cross-file
  coupling rules (`CircularDependency`, `HubModule`,
  `ModuleInstability`) — same `%ModuleGraph{}` output shape, so
  rules don't need to know which source produced their graph.

  ## AST source vs BEAM source — tradeoffs

  | Concern | `ModuleGraph` (AST) | `BeamGraph` (BEAM) |
  |---|---|---|
  | Build requirement | None | Project must be compiled |
  | Dynamic dispatch (`apply/3`) | Misses | Misses (same as `mix xref`) |
  | Struct-only references (`%Foo{}`) | **Sees** | **Misses** — structs don't generate function calls so they don't appear in `:imports` |
  | Typespec-only references (`@spec ... :: Foo.t()`) | Sees | Misses |
  | Behaviour-callback dispatch | Sees the `@behaviour` line | Sees the actual call site |
  | Macro-emitted calls | Misses (macros expanded post-AST-parse) | **Sees** (BEAM is post-expansion) |
  | Aliased-only references (`alias Foo`) | Sees, even if unused | **Misses** — alias without use → no import |
  | Speed | Fast (walking files we'd parse anyway) | Fast (one BEAM read per module) |

  Neither is strictly better — pick based on what you're trying
  to catch. BEAM is closer to "runtime truth" (what `mix xref`
  reports). AST is closer to "what the author wrote." For coupling
  rules where the question is "are these modules really
  interlinked at runtime?" BEAM is the right answer; for rules
  where struct/typespec references count (e.g. some architectural
  boundary rules), AST wins.

  ## Cost / requirements

  - Project must be compiled (`mix.exs` build path must contain
    `.beam` files). Call `Mix.Task.run("compile", [])` before
    `BeamGraph.build/0` if you're not sure.
  - Reads every `.beam` in `Mix.Project.compile_path/0`. O(N modules).
  - Pure-Erlang `:beam_lib.chunks/2` — no shelling out.

  ## What's a "project-local" module

  Only modules under `Mix.Project.compile_path/0` count as nodes —
  third-party deps and stdlib are excluded the same way the AST
  source does it. Edges to non-local modules are dropped.
  """

  alias CredenceRules.CrossFile.ModuleGraph

  @doc """
  Build a `%ModuleGraph{}` from the compiled BEAMs at
  `Mix.Project.compile_path/0`.

  Returns `{:error, reason}` if the build dir doesn't exist or
  `:beam_lib` can't read the chunks. Callers should fall back to
  the AST source on error.
  """
  @spec build() :: {:ok, ModuleGraph.t()} | {:error, term()}
  def build do
    compile_path = Mix.Project.compile_path()

    with {:ok, beam_files} <- list_beams(compile_path),
         {:ok, project_modules} <- {:ok, beam_files_to_modules(beam_files)},
         {:ok, forward} <- {:ok, build_forward_edges(beam_files, project_modules)} do
      reverse = invert(forward)
      module_to_file = beams_to_paths(beam_files)

      {:ok,
       %ModuleGraph{
         modules: project_modules,
         forward: forward,
         reverse: reverse,
         module_to_file: module_to_file
       }}
    end
  end

  defp list_beams(compile_path) do
    case File.ls(compile_path) do
      {:ok, entries} ->
        beams =
          entries
          |> Enum.filter(&String.ends_with?(&1, ".beam"))
          |> Enum.map(&Path.join(compile_path, &1))

        {:ok, beams}

      {:error, reason} ->
        {:error, {:compile_path_missing, compile_path, reason}}
    end
  end

  defp beam_files_to_modules(beam_files) do
    beam_files
    |> Enum.map(&beam_module_name/1)
    |> MapSet.new()
  end

  defp beam_module_name(path) do
    path
    |> Path.basename(".beam")
    |> normalise_module_name()
  end

  # BEAM filename is `Elixir.Foo.Bar.beam` for module `Foo.Bar`,
  # or `foo.beam` for Erlang module `:foo`. We treat both, but
  # surface in the same dotted-string form ModuleGraph uses.
  defp normalise_module_name("Elixir." <> rest), do: rest
  defp normalise_module_name(name), do: name

  defp beams_to_paths(beam_files) do
    Map.new(beam_files, fn path -> {beam_module_name(path), path} end)
  end

  defp build_forward_edges(beam_files, project_modules) do
    Enum.reduce(beam_files, %{}, fn beam_file, acc ->
      source = beam_module_name(beam_file)

      case extract_imports(beam_file) do
        {:ok, imports} ->
          targets =
            imports
            |> Enum.map(&module_to_string/1)
            |> Enum.filter(fn name -> name != source and MapSet.member?(project_modules, name) end)
            |> MapSet.new()

          if MapSet.size(targets) > 0,
            do: Map.update(acc, source, targets, &MapSet.union(&1, targets)),
            else: Map.put_new(acc, source, MapSet.new())

        {:error, _reason} ->
          # A bad BEAM (truncated, wrong cookie) shouldn't kill the whole
          # graph. Skip it; the module appears as a node with no edges.
          Map.put_new(acc, source, MapSet.new())
      end
    end)
  end

  # `:beam_lib.chunks/2` with `:imports` returns the list of
  # `{module, function, arity}` triples this BEAM calls into. Map
  # to module names for our graph.
  defp extract_imports(beam_file) do
    case :beam_lib.chunks(String.to_charlist(beam_file), [:imports]) do
      {:ok, {_module, [{:imports, mfas}]}} ->
        modules = mfas |> Enum.map(fn {m, _f, _a} -> m end) |> Enum.uniq()
        {:ok, modules}

      {:error, _which, reason} ->
        {:error, reason}
    end
  end

  defp module_to_string(module) when is_atom(module) do
    case Atom.to_string(module) do
      "Elixir." <> rest -> rest
      erl -> erl
    end
  end

  defp invert(forward) do
    Enum.reduce(forward, %{}, fn {source, targets}, acc ->
      Enum.reduce(targets, acc, fn target, inner_acc ->
        Map.update(inner_acc, target, MapSet.new([source]), &MapSet.put(&1, source))
      end)
    end)
  end

  @doc """
  Returns the list of module names (`"Foo.Bar"` strings) that the
  given module imports — same data the full graph build uses, but
  for a single module. Used by per-file rules like
  `forbidden_module_dependency` that want BEAM-precision dependency
  data without paying for a full graph build.

  Returns `{:error, reason}` if the module isn't compiled or its
  BEAM is unreadable. Callers should fall back to AST-based
  scanning on error.
  """
  @spec imports_for(String.t() | module()) :: {:ok, [String.t()]} | {:error, term()}
  def imports_for(module) when is_binary(module) do
    # Resolve the beam file first — string input may name a module
    # whose atom isn't loaded yet, in which case `:code.which/1`
    # returns `:non_existing` even though the BEAM exists on disk.
    # Fall through to a direct filesystem lookup so per-file rules
    # under `:beam` source don't silently fall back to AST just
    # because the rule analyser hasn't touched the module.
    case beam_path_for(module) do
      {:ok, path} -> read_imports(path)
      {:error, reason} -> {:error, reason}
    end
  end

  def imports_for(module) when is_atom(module) do
    case :code.which(module) do
      :non_existing ->
        # Atom exists but the module isn't loaded. Try the
        # filesystem path before giving up.
        imports_for(module_to_string(module))

      :preloaded ->
        {:ok, []}

      file when is_list(file) ->
        read_imports(file)

      _ ->
        {:error, :unknown_location}
    end
  end

  # Three-step resolution: prefer a loaded-module path (fastest
  # path via :code.which), else look in the current project's
  # compile_path, else scan ALL ebin directories on the code path
  # (covers umbrella sub-apps + dep ebins where the .beam lives
  # somewhere other than `Mix.Project.compile_path/0`).
  defp beam_path_for(module_name) when is_binary(module_name) do
    with :error <- loaded_beam_path(module_name),
         :error <- compile_path_beam_for(module_name),
         :error <- code_path_beam_for(module_name) do
      {:error, :not_compiled}
    end
  end

  defp loaded_beam_path(module_name) do
    atom = "Elixir." <> module_name

    # `to_existing_atom` rather than `to_atom` keeps the atom table
    # bounded — if the atom doesn't exist the module hasn't been
    # loaded, so :code.which would return :non_existing anyway.
    try do
      case :code.which(String.to_existing_atom(atom)) do
        file when is_list(file) -> {:ok, file}
        _ -> :error
      end
    rescue
      ArgumentError -> :error
    end
  end

  defp compile_path_beam_for(module_name) do
    case mix_compile_path() do
      {:ok, dir} -> beam_path_in_dir(dir, module_name)
      :error -> :error
    end
  end

  # `Mix.Project.compile_path/0` calls
  # `GenServer.call(Mix.ProjectStack, ...)`, which **exits** (not
  # raises) when Mix.ProjectStack isn't started — e.g. raw
  # `elixir` invocations without `-S mix`. A plain `rescue`
  # doesn't catch exits; we need `try/catch :exit, _` so the
  # `code_path_beam_for/1` fallback gets a chance to run.
  defp mix_compile_path do
    {:ok, Mix.Project.compile_path()}
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  # Scan every ebin directory the VM knows about. Covers:
  # - umbrella sub-app builds (each sub-app has its own ebin)
  # - dep ebins (when scanning consumer-project modules whose
  #   .beam isn't in the project's own compile_path)
  # - raw `elixir` invocations without Mix.Project loaded
  defp code_path_beam_for(module_name) do
    filename = "Elixir." <> module_name <> ".beam"

    Enum.find_value(:code.get_path(), :error, fn dir_charlist ->
      candidate = Path.join(List.to_string(dir_charlist), filename)
      if File.exists?(candidate), do: {:ok, String.to_charlist(candidate)}, else: false
    end)
  end

  defp beam_path_in_dir(dir, module_name) do
    path = Path.join(dir, "Elixir." <> module_name <> ".beam")
    if File.exists?(path), do: {:ok, String.to_charlist(path)}, else: :error
  end

  defp read_imports(beam_path) do
    case :beam_lib.chunks(beam_path, [:imports]) do
      {:ok, {_module, [{:imports, mfas}]}} ->
        modules =
          mfas
          |> Enum.map(fn {m, _f, _a} -> module_to_string(m) end)
          |> Enum.uniq()

        {:ok, modules}

      {:error, _which, reason} ->
        {:error, reason}
    end
  end
end
