# credence-file:cross_file_duplicate_block — this module is an AST pattern
#   matcher whose check/2 + Macro.prewalk + build_issue shape is the Rule
#   contract itself, so the structural duplication is inherent to the form
#   rather than a smell
defmodule CredenceRules.CrossFile.ModuleInstability do
  @moduledoc """
  Coupling rule: a module's **instability** is
  `fan_out / (fan_in + fan_out)`. Closer to 1.0 means the module
  depends on many others but few depend on it — it's at the edge of
  the project, free to change. Closer to 0.0 means the module is
  depended on but doesn't reach out — it's stable, hard to change,
  and should be holding the abstractions.

  Robert Martin's **Stable Dependencies Principle**: dependencies
  should flow from unstable modules toward stable ones. A module
  that's both highly-unstable AND highly fanned-out is a likely
  source of churn for everything downstream.

  This rule flags modules that are simultaneously:

  1. Highly unstable (instability ≥ `:max_instability`, default 0.8)
  2. Have non-trivial fan-out (fan_out ≥ `:min_fan_out`, default 5)
  3. Aren't a **composition root**
  4. Show at least `:min_signals` (default 2) **corroborating smells**

  Conditions 1–2 are the raw SDP metric. Conditions 3–4 are
  role-awareness: a high fan-out is only a *smell* when corroborated.
  Per Ousterhout's "deep modules", a narrow interface over a large,
  cohesive implementation is *good design*, not a churn source — so
  instability alone never fires.

  ## Role-awareness

  Set `role_aware: false` to score on the raw metric only. Otherwise:

  **Composition roots are exempt** — wiring collaborators together IS
  their job: `use Application` / `Supervisor` / `DynamicSupervisor`,
  `@behaviour Application` / `Supervisor`, `Mix.Tasks.*`. Process owners
  (GenServer / gen_statem) are NOT exempt — they go through the gate
  below, so a focused one is spared but a god-process still surfaces.

  **Everything else needs ≥ `:min_signals` corroborating smells** from:

  - `:broad_interface` — ≥ `:min_public_api` public functions
    (default 5). A wide public API is a *shallow* module.
  - `:callback_explosion` — ≥ `:min_callbacks` (default 10) GenServer /
    gen_statem callback clauses.
  - `:large_shallow` — large (≥ `:min_loc`, default 100) **and**
    broad-interfaced. Size alone is **not** a signal: a small interface
    over a large body is a *deep* module, so `:high_loc` only counts
    when paired with a broad interface.
  - `:cycle` — the module participates in a dependency cycle (an SCC of
    size ≥ 2).

  A deep protocol module — narrow interface, large cohesive body that
  reaches across crypto / TLV / framing / transport for one vertical
  flow — scores zero signals and is spared. (An earlier `:multi_domain`
  signal counted that fan-out as a smell; it was removed because
  "unrelated vs cohesive" isn't decidable from the dependency graph.)
  A shallow god-module — wide interface that's also large, or sits in a
  cycle, or has a pile of callbacks — trips two and fires.

  When the dependency graph is built from `.beam` files
  (`graph_source: :beam`) a module may have no source AST; such modules
  fall back to the raw metric.

  ## Detection

  Builds the project's dependency graph (via
  `CredenceRules.CrossFile.ModuleGraph`), computes the
  instability metric and the smell signals per module, and emits
  findings for the offenders. Stdlib / third-party deps are excluded —
  only project-local modules count toward fan-in and fan-out.

  ## Carve-outs

  Name specific modules via `:exclude_modules`:

      config :credence_rules,
        rule_opts: %{
          module_instability: [exclude_modules: [MyApp.SomeCoordinator]]
        }

  Tunable opts: `:max_instability` (0.8), `:min_fan_out` (5),
  `:min_signals` (2), `:min_public_api` (5), `:min_loc` (100),
  `:min_callbacks` (10), `:role_aware` (true).

  ## Why advisory

  Instability is a smell metric, not a correctness boundary. Treat
  findings as "should this module be more stable, or are its
  dependents wrong to depend on it?" — not a hard cap.
  """

  @behaviour CredenceRules.CrossFile.Rule

  alias CredenceRules.AstKeyword
  alias CredenceRules.CrossFile.{GraphSource, ModuleGraph}
  alias CredenceRules.PathExclusion
  alias Credence.Issue

  @default_max_instability 0.8
  @default_min_fan_out 5
  @default_min_public_api 5
  @default_min_loc 100
  @default_min_callbacks 10
  @default_min_signals 2

  # Composition roots: modules whose whole job is to wire collaborators
  # together. They fan out by design and are exempt. Process owners
  # (GenServer / gen_statem / …) are NOT exempt — a focused one scores
  # too few signals to fire, but a god-process with a broad interface or
  # callback explosion still surfaces.
  @composition_uses [:Application, :Supervisor, :DynamicSupervisor]
  @composition_behaviours_elixir [:Application, :Supervisor]
  @composition_behaviours_erlang [:application, :supervisor]

  # GenServer / gen_statem callback names — a pile of these clauses is
  # the "callback explosion" smell.
  @callback_names MapSet.new([
                    :handle_call,
                    :handle_cast,
                    :handle_info,
                    :handle_continue,
                    :handle_event,
                    :init,
                    :terminate,
                    :code_change,
                    :format_status
                  ])

  @impl true
  def check(files, opts) do
    thresholds = %{
      max_instability: Keyword.get(opts, :max_instability, @default_max_instability),
      min_fan_out: Keyword.get(opts, :min_fan_out, @default_min_fan_out),
      min_public_api: Keyword.get(opts, :min_public_api, @default_min_public_api),
      min_loc: Keyword.get(opts, :min_loc, @default_min_loc),
      min_callbacks: Keyword.get(opts, :min_callbacks, @default_min_callbacks),
      min_signals: Keyword.get(opts, :min_signals, @default_min_signals),
      role_aware?: Keyword.get(opts, :role_aware, true)
    }

    exclude = opts |> Keyword.get(:exclude_modules, []) |> module_name_set()
    files = PathExclusion.filter_files(files, opts)
    graph = GraphSource.resolve(files, opts)
    signals = build_signal_map(files)
    in_cycle = cycle_members(graph)

    graph.modules
    |> Enum.reject(&MapSet.member?(exclude, &1))
    |> Enum.flat_map(&analyse_module(&1, graph, signals, in_cycle, thresholds))
    |> Enum.sort_by(& &1.meta.path)
  end

  # Modules that participate in a dependency cycle (SCC of size ≥ 2) —
  # one of the corroborating smell signals.
  defp cycle_members(graph) do
    graph
    |> ModuleGraph.strongly_connected_components()
    |> Enum.filter(&match?([_, _ | _], &1))
    |> List.flatten()
    |> MapSet.new()
  end

  # `graph.modules` carries module names as strings; users pass atoms.
  defp module_name_set(mods) do
    mods
    |> Enum.map(fn
      mod when is_atom(mod) -> Atom.to_string(mod) |> String.replace_prefix("Elixir.", "")
      mod when is_binary(mod) -> mod
    end)
    |> MapSet.new()
  end

  defp analyse_module(module, graph, signals, in_cycle, t) do
    fan_out_targets = ModuleGraph.fan_out(graph, module)
    fan_out = length(fan_out_targets)
    fan_in = length(ModuleGraph.fan_in(graph, module))
    sig = Map.get(signals, module)

    cond do
      fan_out < t.min_fan_out ->
        []

      compute_instability(fan_in, fan_out) < t.max_instability ->
        []

      # role_aware gates BOTH the framework exemption and the
      # multi-signal corroboration. Disable it for the raw metric.
      not t.role_aware? ->
        [issue(module, graph, fan_in, fan_out, t, sig, [])]

      # Composition roots (Application / Supervisor / Mix task) wire
      # collaborators together by design.
      composition_root?(sig) ->
        []

      # No source AST (BEAM-only graph): fall back to the raw metric.
      is_nil(sig) ->
        [issue(module, graph, fan_in, fan_out, t, sig, [])]

      true ->
        present = smell_signals(sig, module, in_cycle, t)

        if length(present) >= t.min_signals,
          do: [issue(module, graph, fan_in, fan_out, t, sig, present)],
          else: []
    end
  end

  defp compute_instability(0, 0), do: 0.0
  defp compute_instability(fan_in, fan_out), do: fan_out / (fan_in + fan_out)

  defp composition_root?(%{composition_root?: true}), do: true
  defp composition_root?(_), do: false

  # High instability + fan-out alone is normal for a coordinator or a
  # deep module. We only warn when it's corroborated by ≥ `:min_signals`
  # independent smells:
  #
  # - `:broad_interface` — a wide public API (a shallow module).
  # - `:callback_explosion` — a pile of GenServer / gen_statem callbacks.
  # - `:large_shallow` — large AND wide-interfaced. Size alone is NOT a
  #   signal: a small interface over a large body is a *deep* module
  #   (good design), so `:high_loc` only counts when paired with a broad
  #   interface.
  # - `:cycle` — participates in a dependency cycle.
  #
  # `:multi_domain` was removed: a deep protocol module legitimately
  # spans crypto / TLV / framing / transport in one vertical flow, and
  # "unrelated vs cohesive" isn't decidable from the dependency graph.
  defp smell_signals(sig, module, in_cycle, t) do
    broad? = sig.public_api >= t.min_public_api

    [
      {:broad_interface, broad?},
      {:callback_explosion, sig.callbacks >= t.min_callbacks},
      {:large_shallow, broad? and sig.loc >= t.min_loc},
      {:cycle, MapSet.member?(in_cycle, module)}
    ]
    |> Enum.filter(fn {_name, present?} -> present? end)
    |> Enum.map(fn {name, _} -> name end)
  end

  defp issue(module, graph, fan_in, fan_out, t, signals, present) do
    path = Map.get(graph.module_to_file, module)
    rounded = Float.round(compute_instability(fan_in, fan_out), 2)
    %{public_api: public_api, loc: loc} = signals || %{public_api: nil, loc: nil}

    %Issue{
      rule: :module_instability,
      message:
        "`#{module}` has instability #{rounded} " <>
          "(#{fan_out} fan-out, #{fan_in} fan-in; threshold #{t.max_instability})" <>
          signals_clause(present) <>
          ". Modules with high instability AND high fan-out are churn sources — " <>
          "every dependency change ripples outward. Either pull the volatile " <>
          "logic into smaller leaf modules, or have fewer modules depend on " <>
          "this one (Stable Dependencies Principle).",
      meta: %{
        line: nil,
        path: path,
        instability: rounded,
        fan_in: fan_in,
        fan_out: fan_out,
        public_api: public_api,
        loc: loc,
        signals: present
      }
    }
  end

  defp signals_clause([]), do: ""
  defp signals_clause(present), do: ", corroborated by #{Enum.join(present, ", ")}"

  # Per-module role signals from the source AST: is it a composition
  # root, how broad is its public API, how large is it. Keyed by the
  # same module-name strings the graph uses.
  defp build_signal_map(files) do
    Enum.reduce(files, %{}, fn {_path, ast}, acc ->
      case defmodule_node(ast) do
        {name, body} -> Map.put(acc, name, signals_from(name, body))
        nil -> acc
      end
    end)
  end

  defp signals_from(name, body) do
    %{
      composition_root?: composition_root_source?(name, body),
      public_api: public_api_count(body),
      loc: line_span(body),
      callbacks: callback_clause_count(body)
    }
  end

  # A composition root: Application / Supervisor / DynamicSupervisor, or
  # a Mix task. Process owners (GenServer / gen_statem) are deliberately
  # NOT here — they go through the smell-signal gate.
  defp composition_root_source?(name, body) do
    mix_task?(name) or composition_use?(body) or composition_behaviour?(body)
  end

  defp mix_task?(name), do: String.starts_with?(name, "Mix.Tasks.")

  defp composition_use?(body) do
    any_node?(body, fn
      {:use, _, [{:__aliases__, _, segs} | _]} -> List.last(segs) in @composition_uses
      _ -> false
    end)
  end

  defp composition_behaviour?(body) do
    any_node?(body, fn
      {:@, _, [{:behaviour, _, [{:__aliases__, _, segs}]}]} ->
        List.last(segs) in @composition_behaviours_elixir

      {:@, _, [{:behaviour, _, [erlang]}]} when is_atom(erlang) ->
        erlang in @composition_behaviours_erlang

      _ ->
        false
    end)
  end

  # Distinct public function names. Multi-clause defs count once;
  # `defp` and `defdelegate` don't count — a facade built from
  # delegations is a coordinator, not a broad API.
  defp public_api_count(body) do
    {_ast, names} =
      Macro.prewalk(body, [], fn
        {:def, _, [head | _]} = node, acc ->
          case def_name(head) do
            nil -> {node, acc}
            name -> {node, [name | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    names |> MapSet.new() |> MapSet.size()
  end

  # Total `def`/`defp` clauses whose name is a GenServer / gen_statem
  # callback. Counts CLAUSES (not distinct names): twelve `handle_event`
  # heads is an explosion, even though it's one function name.
  defp callback_clause_count(body) do
    {_ast, count} =
      Macro.prewalk(body, 0, fn
        {kind, _, [head | _]} = node, acc when kind in [:def, :defp] ->
          if def_name(head) in @callback_names, do: {node, acc + 1}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    count
  end

  defp def_name({:when, _, [inner | _]}), do: def_name(inner)
  defp def_name({name, _, _}) when is_atom(name), do: name
  defp def_name(_), do: nil

  # Line span of the module body — max line minus min line across all
  # metadata. Approximates LOC without the source text.
  defp line_span(body) do
    {_ast, lines} =
      Macro.prewalk(body, [], fn
        {_form, meta, _args} = node, acc when is_list(meta) ->
          case Keyword.get(meta, :line) do
            nil -> {node, acc}
            line -> {node, [line | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    case lines do
      [] -> 0
      lines -> Enum.max(lines) - Enum.min(lines) + 1
    end
  end

  defp any_node?(ast, pred) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        _node, true -> {[], true}
        node, false -> {node, pred.(node)}
      end)

    found?
  end

  # The defining module: first `defmodule` in the file. Returns
  # `{module_name_string, body_ast}` or nil.
  defp defmodule_node({:defmodule, _, [alias_node, kw]}) when is_list(kw) do
    case {ModuleGraph.module_name(alias_node), AstKeyword.get(kw, :do)} do
      {name, body} when is_binary(name) -> {name, body}
      _ -> nil
    end
  end

  defp defmodule_node({:__block__, _, statements}) do
    Enum.find_value(statements, &defmodule_node/1)
  end

  defp defmodule_node(_), do: nil
end
