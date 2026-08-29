defmodule CredenceRules.CrossFile.HubModule do
  @moduledoc """
  Coupling rule: a module that's depended on by many other modules
  (high fan-in) becomes a bottleneck for change. Every update to the
  hub ripples through every dependent — adding a function, changing
  a typespec, or even renaming a struct field forces re-review across
  the whole web.

  Hubs aren't always wrong: shared types, behaviour modules, and
  central configuration legitimately have high fan-in by design.
  The hazard is when application logic accumulates in a hub, because
  then the application logic carries the same blast radius as the
  shared contract.

  ## Detection

  Per module, count incoming dependencies (project-local modules
  that reference it via alias / call / struct / typespec). Flag
  modules with fan-in ≥ `:max_fan_in` (default 15) **unless** the
  module is tiny — ≤ `:max_vocab_loc` lines (default 60).

  A small module can't be accumulating application logic, which is the
  actual hazard. A high-fan-in *tiny* module is a stable vocabulary
  type (`NodeId`, `Version`, a status enum) whose wide reach is by
  design — so it's auto-exempt rather than needing an `:exclude_modules`
  entry.

  Stdlib / third-party deps are excluded — `Enum`, `Phoenix.Component`,
  and friends can't be flagged because they aren't in the project's
  scanned files.

  ## Carve-outs

  Some modules are intentionally hubs — a project's `Rule`
  behaviour module, a shared `Types` module, a `Config` entry
  point. Pass them in via `:exclude_modules` so they don't fire:

      config :credence_rules,
        rule_opts: %{
          hub_module: [exclude_modules: [MyApp.Types, MyApp.Behaviours.Rule]]
        }

  ## Why advisory

  High fan-in is a smell, not a defect. A shared `types.ex` or a
  behaviour module is *supposed* to have wide reach. Treat findings
  as "does this module deserve its blast radius?" — not a hard cap.
  Pair with the baseline gate if you want CI to fail only on new
  hubs.
  """

  @behaviour CredenceRules.CrossFile.Rule

  alias CredenceRules.CrossFile.{GraphSource, ModuleGraph, ModuleSource}
  alias CredenceRules.PathExclusion
  alias Credence.Issue

  @default_max_fan_in 15
  @default_max_vocab_loc 60

  @impl true
  def check(files, opts) do
    max_fan_in = Keyword.get(opts, :max_fan_in, @default_max_fan_in)
    max_vocab_loc = Keyword.get(opts, :max_vocab_loc, @default_max_vocab_loc)
    exclude = opts |> Keyword.get(:exclude_modules, []) |> module_name_set()

    files = PathExclusion.filter_files(files, opts)
    graph = GraphSource.resolve(files, opts)
    loc = ModuleSource.loc_by_module(files)

    graph.modules
    |> Enum.reject(&MapSet.member?(exclude, &1))
    |> Enum.flat_map(fn module ->
      fan_in = ModuleGraph.fan_in(graph, module) |> length()

      cond do
        fan_in < max_fan_in -> []
        tiny_vocabulary?(module, loc, max_vocab_loc) -> []
        true -> [build_issue(module, graph, fan_in, max_fan_in)]
      end
    end)
    |> Enum.sort_by(& &1.meta.path)
  end

  # A small module can't be accumulating application logic — the actual
  # hazard a hub poses. A high-fan-in *tiny* module is a stable
  # vocabulary type (`NodeId`, `Version`) whose wide reach is by design,
  # so exempt it. Modules with no source AST (BEAM-only graph) aren't
  # known small and still fire.
  defp tiny_vocabulary?(module, loc, max_vocab_loc) do
    case Map.get(loc, module) do
      nil -> false
      lines -> lines <= max_vocab_loc
    end
  end

  # `graph.modules` carries module names as strings ("Foo.Bar"), but
  # users naturally pass module atoms (`Foo.Bar`) in `:exclude_modules`.
  # Normalise both shapes to strings so MapSet membership works.
  defp module_name_set(mods) do
    mods
    |> Enum.map(fn
      mod when is_atom(mod) -> Atom.to_string(mod) |> String.replace_prefix("Elixir.", "")
      mod when is_binary(mod) -> mod
    end)
    |> MapSet.new()
  end

  defp build_issue(module, graph, fan_in, threshold) do
    path = Map.get(graph.module_to_file, module)

    %Issue{
      rule: :hub_module,
      message:
        "`#{module}` has fan-in #{fan_in} (threshold #{threshold}). #{fan_in} other " <>
          "modules depend on it — any change ripples through all of them. If " <>
          "this module holds shared types, behaviours, or constants the wide " <>
          "reach is by design; if it holds application logic, consider " <>
          "splitting by concern so the blast radius is bounded.",
      meta: %{line: nil, path: path, fan_in: fan_in}
    }
  end
end
