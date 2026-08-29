# credence-file:iosp_mixed_function — this module is an AST pattern matcher
#   whose check/2 + Macro.prewalk + build_issue shape is the Rule contract
#   itself, so the structural duplication is inherent to the form rather than a
#   smell
defmodule CredenceRules.Pattern.GenserverHandleCallExplosion do
  @moduledoc """
  Concurrency rule: a GenServer with many `handle_call` clauses
  handling unrelated subjects is doing too many things in one
  process. Every caller serialises through the same mailbox, so the
  process becomes a bottleneck *and* a single point of failure for
  whatever set of unrelated responsibilities it accumulated.

  LLMs grow GenServers organically — start with one purpose, then add
  "while we're at it" message handlers until the same process owns
  cache, config, metrics, and feature flags. SRP for processes: each
  process owns one concern.

  ## Bad

      defmodule MyApp.Hub do
        use GenServer

        def handle_call({:get_user, id}, _, state), do: ...
        def handle_call({:set_user, id, attrs}, _, state), do: ...
        def handle_call({:cache_lookup, k}, _, state), do: ...
        def handle_call({:cache_put, k, v}, _, state), do: ...
        def handle_call(:reload_config, _, state), do: ...
        def handle_call({:metric, name, value}, _, state), do: ...
        def handle_call({:flag, name}, _, state), do: ...
        def handle_call(:stats, _, state), do: ...
      end

  Eight handlers across four unrelated subjects (users, cache, config,
  metrics). A slow metric write blocks user lookups.

  ## Good — split by concern

      defmodule MyApp.UserCache do
        # handle_call for {:get_user, id}, {:set_user, id, attrs}
      end

      defmodule MyApp.GenericCache do
        # handle_call for {:cache_lookup, k}, {:cache_put, k, v}
      end

      defmodule MyApp.Config do
        # handle_call for :reload_config
      end

      # ...etc.

  Or, if many handlers share state genuinely, dispatch through a
  Registry / DynamicSupervisor and own one logical concern per
  process pool.

  ## Detection

  Flags a module when:

  1. It has `use GenServer` (or `use GenStage`, etc.), AND
  2. It defines a threshold number of `handle_call/3` clauses (see
     thresholds below).

  Each multi-clause `def handle_call` head counts as one clause.

  ## Per-instance GenServers get a higher threshold

  The rule's "split by concern: one process per logical owner"
  advice presumes a *singleton* GenServer accumulating unrelated
  concerns. For a *per-instance* GenServer (one process per
  session, per connection, per exchange) the process ALREADY is
  one-per-logical-owner — the clause count just reflects how many
  state pieces that one concern exposes. Splitting would mean two
  processes per session, making the architecture worse.

  The rule recognises per-instance GenServers by their
  registration shape: `start_link/1` calls `GenServer.start_link`
  with `name: {:via, _, _}` (typically `{:via, Registry, ...}`).
  These get `:max_handle_call_per_instance` (default 16) instead
  of the singleton `:max_handle_call` (default 8). A per-instance
  process with 30 handlers is still suspicious, just at a higher
  ceiling than a singleton.

  Singletons (name: `__MODULE__`, or no via-tuple in start_link)
  keep the strict default.

  ## Read-bypass GenServers get a higher threshold

  The "every caller serialises through one mailbox" bottleneck
  argument assumes reads AND writes both go through `handle_call`.
  When a GenServer owns an ETS table and the public read API
  (`get_*`, `list_*`, `fetch_*`, `find_*`, `lookup_*`,
  `member?/exists?`) calls `:ets.*` directly instead of routing
  through `GenServer.call`, reads bypass the mailbox entirely —
  only writes serialise. Write traffic is usually orders of
  magnitude lower than read traffic, so the bottleneck premise
  weakens: the remaining write-side `handle_call` clauses should
  be weighted fractionally against the threshold.

  The rule recognises this pattern when ALL of:

  1. The module body contains an `:ets.new/_` call (declares an
     ETS table this process owns).
  2. At least one public function with a read-name prefix exists
     (`get_*`, `list_*`, `fetch_*`, `find_*`, `lookup_*`,
     `exists?`, `member?`).
  3. Every such read function calls `:ets.*` (proving it actually
     hits the table directly) and contains no `GenServer.call`
     (proving it bypasses the mailbox).

  These get `:max_handle_call_read_bypass` (default 16) — the
  same threshold as per-instance, since the bottleneck reduction
  is comparable. If both exemptions apply, the higher threshold
  wins.

  ## Why concurrency, not architecture

  Process bottlenecks and shared-mailbox serialisation are runtime
  concerns, not just shape. A bloated GenServer is a real
  performance and fault-isolation problem, not a stylistic one.
  Lives in the `:concurrency` category alongside other GenServer
  rules.

  ## Why advisory

  Some legitimate GenServers handle many related messages
  (state-machine implementations, protocol routers). Treat findings
  as "are these handlers really one concern?" — not a hard cap.
  Tunable via `:max_handle_call`, `:max_handle_call_per_instance`,
  and `:max_handle_call_read_bypass`.
  """

  use CredenceRules.Rule

  alias CredenceRules.AstKeyword

  @hint """
  Split the GenServer by concern. Identify the message groups —
  e.g. cache lookups, config reads, metric writes, feature flags —
  and extract each group into its own GenServer module:

      defmodule MyApp.Cache do
        use GenServer
        def handle_call({:get, key}, _, state), do: ...
        def handle_call({:put, k, v}, _, state), do: ...
      end

      defmodule MyApp.Config do
        use GenServer
        def handle_call(:reload, _, state), do: ...
      end

  Each new module gets its own `start_link/1` and registers with
  `name: __MODULE__`. Callers that previously dispatched via
  `GenServer.call(MyApp.Hub, {:get_user, id})` now use the
  concern-specific API.

  Alternative: if many handlers genuinely share state, dispatch
  through a Registry + DynamicSupervisor with one process per
  logical owner (per session, per connection). That moves the
  scaling from "split the work" to "shard the work."
  """

  @carve_outs [
    "Per-instance GenServers registered via {:via, Registry, ...} — handlers reflect per-process state, not multiple concerns. Use :max_handle_call_per_instance (default 16).",
    "ETS-owning GenServers whose read API (get_*/list_*/fetch_*/lookup_*/exists?/member?) calls :ets.* directly — reads bypass the mailbox; only writes serialise. Use :max_handle_call_read_bypass (default 16).",
    "State machines (gen_statem-like) where each handle_call clause is a transition for one logical state. Splitting would mean threading state through every transition."
  ]

  @default_max 8
  @default_max_per_instance 16
  @default_max_read_bypass 16

  @read_name_prefixes ~w(get_ list_ fetch_ find_ lookup_)
  @read_name_exact ~w(exists? member?)a

  @impl true
  def priority, do: 450

  @impl true
  def check(ast, opts) do
    max_singleton = Keyword.get(opts, :max_handle_call, @default_max)
    max_per_instance = Keyword.get(opts, :max_handle_call_per_instance, @default_max_per_instance)
    max_read_bypass = Keyword.get(opts, :max_handle_call_read_bypass, @default_max_read_bypass)

    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:defmodule, meta, [_alias, kw]} = node, acc when is_list(kw) ->
          case AstKeyword.get(kw, :do) do
            nil ->
              {node, acc}

            body ->
              if genserver_module?(body) do
                count = count_handle_call_clauses(body)

                threshold =
                  resolve_threshold(body, %{
                    singleton: max_singleton,
                    per_instance: max_per_instance,
                    read_bypass: max_read_bypass
                  })

                if count >= threshold,
                  do: {node, [build_issue(meta, count, threshold) | acc]},
                  else: {node, acc}
              else
                {node, acc}
              end
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  # Combine exemptions — pick the highest threshold that applies.
  # Per-instance and read-bypass are independent: a per-instance
  # GenServer can also bypass reads to ETS, and either reason
  # alone justifies relaxing the singleton default.
  defp resolve_threshold(body, thresholds) do
    candidates =
      Enum.reject(
        [
          thresholds.singleton,
          if(per_instance?(body), do: thresholds.per_instance),
          if(read_bypass?(body), do: thresholds.read_bypass)
        ],
        &is_nil/1
      )

    Enum.max(candidates)
  end

  # Per-instance recognition: the module declares a `{:via, _, _}`
  # registration tuple anywhere — typically inline in `start_link/1`
  # (`name: {:via, Registry, {Foo, opts[:id]}}`) or in a helper
  # (`defp via_tuple(id), do: {:via, Registry, {Foo, id}}`). Scanning
  # the whole module catches both shapes; a stray `{:via, …}` literal
  # for some other purpose is rare enough to ignore.
  defp per_instance?(body) do
    {_ast, found?} =
      Macro.prewalk(body, false, fn
        _node, true ->
          {[], true}

        # 3-tuple literal: AST'd as `{:{}, _, [elem1, elem2, elem3]}`.
        # `{:via, Registry, {Foo, key}}` matches this with elem1 == :via.
        {:{}, _, [first | _]} = node, _ ->
          if via_atom?(first), do: {node, true}, else: {node, false}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp via_atom?(:via), do: true
  defp via_atom?({:__block__, _, [:via]}), do: true
  defp via_atom?(_), do: false

  # Read-bypass detection: module owns an ETS table AND every public
  # read-named function (get_/list_/fetch_/find_/lookup_/exists?/
  # member?) calls `:ets.*` directly without going through
  # `GenServer.call`. Reads bypass the mailbox → bottleneck premise
  # weakens for the remaining write-side handle_call clauses.
  defp read_bypass?(body) do
    statements = top_level_statements(body)
    read_defs = Enum.filter(statements, &public_read_def?/1)

    cond do
      # No ETS table → no bypass possible
      not has_ets_new?(statements) -> false
      # No read functions → can't claim "reads bypass"; the
      # GenServer might only have writes or might dispatch reads
      # via call/cast tuples (which IS the bottleneck pattern).
      read_defs == [] -> false
      # Every read function hits :ets directly and skips GenServer.call
      Enum.all?(read_defs, &bypasses_genserver_call?/1) -> true
      true -> false
    end
  end

  defp has_ets_new?(statements) do
    Enum.any?(statements, fn stmt ->
      {_ast, found?} =
        Macro.prewalk(stmt, false, fn
          _node, true -> {[], true}
          {{:., _, [:ets, :new]}, _, _} = node, _ -> {node, true}
          {{:., _, [{:__block__, _, [:ets]}, :new]}, _, _} = node, _ -> {node, true}
          node, acc -> {node, acc}
        end)

      found?
    end)
  end

  defp public_read_def?({:def, _, [head, _kw]}) do
    case def_head(head) do
      {name, _arity} -> read_named?(name)
      _ -> false
    end
  end

  defp public_read_def?(_), do: false

  defp read_named?(name) when name in @read_name_exact, do: true

  defp read_named?(name) when is_atom(name) do
    name_str = Atom.to_string(name)
    Enum.any?(@read_name_prefixes, &String.starts_with?(name_str, &1))
  end

  defp read_named?(_), do: false

  # True if the def body calls `:ets.*` AND has no `GenServer.call`.
  defp bypasses_genserver_call?({:def, _, [_head, kw]}) when is_list(kw) do
    body = AstKeyword.get(kw, :do)
    body && hits_ets?(body) && not calls_genserver_call?(body)
  end

  defp bypasses_genserver_call?(_), do: false

  defp hits_ets?(body) do
    {_ast, found?} =
      Macro.prewalk(body, false, fn
        _node, true -> {[], true}
        {{:., _, [:ets, _fun]}, _, _} = node, _ -> {node, true}
        {{:., _, [{:__block__, _, [:ets]}, _fun]}, _, _} = node, _ -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end

  defp calls_genserver_call?(body) do
    {_ast, found?} =
      Macro.prewalk(body, false, fn
        _node, true ->
          {[], true}

        {{:., _, [{:__aliases__, _, [:GenServer]}, :call]}, _, _} = node, _ ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp genserver_module?(body) do
    body
    |> top_level_statements()
    |> Enum.any?(&genserver_use?/1)
  end

  defp top_level_statements({:__block__, _, list}), do: list
  defp top_level_statements(single), do: [single]

  defp genserver_use?({:use, _, [{:__aliases__, _, [last]}]})
       when last in [:GenServer, :GenStage],
       do: true

  defp genserver_use?({:use, _, [{:__aliases__, _, [last]}, _opts]})
       when last in [:GenServer, :GenStage],
       do: true

  defp genserver_use?(_), do: false

  defp count_handle_call_clauses(body) do
    body
    |> top_level_statements()
    |> Enum.count(&handle_call_def?/1)
  end

  defp handle_call_def?({:def, _, [head, _kw]}),
    do: match?({:handle_call, 3}, def_head(head))

  defp handle_call_def?(_), do: false

  defp def_head({:when, _, [inner, _guard]}), do: def_head(inner)

  defp def_head({name, _meta, params}) when is_atom(name) and is_list(params),
    do: {name, length(params)}

  # `def foo, do: …` — no parens, no args. Sourceror and the plain
  # parser both AST this with `params = nil`. Arity 0.
  defp def_head({name, _meta, nil}) when is_atom(name), do: {name, 0}

  defp def_head(_), do: nil

  defp build_issue(meta, count, threshold) do
    %Issue{
      rule: :genserver_handle_call_explosion,
      message:
        "GenServer has #{count} `handle_call/3` clauses (threshold #{threshold}). " <>
          "Every caller serialises through one mailbox — a bloated handler set " <>
          "makes the process both a bottleneck and a single point of failure for " <>
          "whatever responsibilities accumulated here. Split by concern: one " <>
          "process per logical owner.",
      meta: %{line: Keyword.get(meta, :line), handle_call_clauses: count}
    }
  end
end
