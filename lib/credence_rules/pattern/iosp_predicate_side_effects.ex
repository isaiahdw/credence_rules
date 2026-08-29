defmodule CredenceRules.Pattern.IospPredicateSideEffects do
  @moduledoc """
  IOSP rule: a function whose name ends in `?` is a predicate.
  Predicates should be **deterministic** — pure operations that
  decide yes/no from their arguments. Calling `Repo.*`, an HTTP
  client, the filesystem, a GenServer, or any other side-effecting
  module from inside a predicate breaks the contract callers rely
  on.

  Readers see `if active?(user) do ... end` and assume `active?/1`
  is a cheap, side-effect-free check. If `active?/1` actually queries
  the database every call, the function is mis-named — the work
  belongs in an integration layer that loads the data and passes it
  to a pure predicate.

  ## Bad

      def active?(user) do
        Repo.exists?(from s in Subscription, where: s.user_id == ^user.id)
      end

      def has_pending_jobs?(account) do
        Oban.Job
        |> where(account_id: ^account.id, state: "available")
        |> Repo.exists?()
      end

      def authorised?(token) do
        case Req.get("https://auth.example.com/verify", json: %{token: token}) do
          {:ok, %{status: 200}} -> true
          _ -> false
        end
      end

  Each predicate is making the side effect every time it's called.
  In a `for user <- users, active?(user)` filter, that's N database
  hits.

  ## Good — load once, decide many

      def list_users_with_active_status do
        # Integration: load the data the predicate needs.
        user_ids_with_subs =
          Subscription
          |> select([s], s.user_id)
          |> Repo.all()
          |> MapSet.new()

        for user <- list_users(), do: {user, active?(user, user_ids_with_subs)}
      end

      # Operation: pure predicate, deterministic from its args.
      def active?(user, user_ids_with_subs) do
        MapSet.member?(user_ids_with_subs, user.id)
      end

  ## Detection

  Flags any `def` / `defp` whose function name ends in `?` AND whose
  body contains a call into a configured side-effecting module.
  Default side-effect modules:

  - **Persistence**: `Repo`, `Ecto.Repo` (any `*.Repo` alias too)
  - **HTTP**: `Req`, `HTTPoison`, `Finch`, `Tesla`, `Mint`, `Hackney`
  - **Filesystem**: `File`
  - **OS**: `System`, `IO`
  - **Concurrency**: `GenServer`, `Task`, `Process`
  - **Erlang storage**: `:ets`, `:dets`, `:mnesia`, `:persistent_term`
  - **Async jobs**: `Oban`
  - **PubSub**: `Phoenix.PubSub`

  Override with the `:side_effect_modules` rule option:

      mix credence.check --paths lib
      # or:
      CredenceRules.Pattern.IospPredicateSideEffects.check(ast,
        side_effect_modules: ["Repo", "Req", "MyApp.Mailer"]
      )

  Matches by trailing alias segment, so `MyApp.Repo` matches a
  `Repo` entry and `MyApp.Web.Mailer` matches a `Mailer` entry —
  no need to enumerate every aliased path.

  ## defguard exemption

  `defguard foo?(x) when …` is pure by construction (guards can't
  call user-fns or have side effects). Not flagged.

  ## Why advisory

  Some predicate names are conventional for impure work
  (`File.exists?/1`, `Map.has_key?/2`). Treat findings as "is the
  side effect intentional and named accurately, or should the
  predicate be pure and the loading lifted to an integration
  function?" — not a hard cap.

  ## Liveness-predicate exemption

  One well-defined class breaks the "lift the side effect to an
  integration function" recommendation: **liveness predicates**.

      def session_reusable?(%{exchange_mgr: mgr}) when is_pid(mgr),
        do: Process.alive?(mgr)

      def case_session_defunct?(state) do
        case state.exchange_mgr do
          mgr when is_pid(mgr) ->
            if Process.alive?(mgr) do
              peer_silent_too_long?(state, ExchangeManager.last_peer_activity_at(mgr))
            else
              true
            end

          _ -> false
        end
      end

  Both ask "is this thing still alive?" Lifting `Process.alive?(mgr)`
  to the call site doesn't help — by the time the now-pure predicate
  evaluates, the cached `alive?` is stale. The process can die between
  the lift and the check. The reason the inline form is correct is
  precisely that the predicate reads the runtime at the latest
  possible moment. Lifting introduces a TOCTOU window that doesn't
  exist in the current shape.

  Compare: a clock predicate (`valid_time?`) is fine to lift — `now`
  doesn't go backwards, the staleness window is bounded. A liveness
  predicate is not — `alive?` flips monotonically from true to false
  exactly once, and you need to know which side of the transition
  you're on at the moment of decision.

  The rule exempts these specific calls (treats them as non-side-
  effects) when scanning a body:

  - `Process.alive?/1`
  - `Process.info/1`, `Process.info/2`
  - `Process.whereis/1`
  - `:erlang.is_process_alive/1`
  - `Port.info/1` or `Port.info/2`

  These are the canonical liveness / introspection markers.

  The exemption is **per-call**, not whole-function. A predicate
  whose body composes an introspection call with another side
  effect — e.g. `Process.alive?(pid) and Repo.exists?(...)` —
  still fires on the `Repo.exists?` call. Earlier versions
  applied the exemption to the whole function and silently hid
  the Repo call alongside the harmless `Process.alive?`. That
  scope was too generous; the fix is more precise but slightly
  stricter: composed-liveness shapes that also call
  `GenServer.call(pid, …)` will now flag the GenServer call.
  If that's intentional, lift the call into a helper or accept
  the finding.

  ## Mix tasks

  All defs inside `defmodule Mix.Tasks.* do … end` are skipped.
  Mix tasks ARE orchestration + I/O; expecting them to obey IOSP
  separation is the wrong model for CLI entry points.
  """

  use CredenceRules.Rule

  alias CredenceRules.{AstKeyword, IospExemptions}

  @hint """
  Two-step fix: lift the side effect into an integration function,
  then call the pure predicate against pre-loaded data.

      # Before — predicate does a DB hit per call
      def active?(user) do
        Repo.exists?(from s in Subscription, where: s.user_id == ^user.id)
      end

      for user <- users, active?(user), do: render(user)
      # N queries in the filter

      # After — load once, decide many
      def list_users_with_status do
        user_ids_with_subs =
          Subscription |> select([s], s.user_id) |> Repo.all() |> MapSet.new()

        Enum.map(list_users(), &{&1, active?(&1, user_ids_with_subs)})
      end

      def active?(user, user_ids_with_subs) do
        MapSet.member?(user_ids_with_subs, user.id)
      end

  The predicate now takes the loaded data as an arg — deterministic,
  cheap, callable in tight loops.
  """

  @carve_outs [
    "Process.alive?/info/whereis, :erlang.is_process_alive, Port.info — per-call exemption (can't be lifted without TOCTOU). The body keeps scanning for other side effects, so predicates that compose introspection with a real side effect still fire on the real one.",
    "Inside Mix.Tasks.* modules — orchestration + I/O IS the point. Rule auto-skips the whole module.",
    "Composed liveness with a GenServer.call on the same pid — currently flags the GenServer.call (was previously silently exempted). If intentional, lift to a helper or accept the finding."
  ]

  @default_side_effect_modules ~w(
    Repo Ecto.Repo
    Req HTTPoison Finch Tesla Mint Hackney
    File System IO
    GenServer Task Process
    Oban
    Phoenix.PubSub
  )

  # Bare-atom Erlang modules — checked separately, since they're
  # parsed as raw atoms rather than `__aliases__` nodes.
  @default_side_effect_erlang_atoms ~w(ets dets mnesia persistent_term)a

  @impl true
  def priority, do: 460

  @impl true
  def check(ast, opts) do
    modules = Keyword.get(opts, :side_effect_modules, @default_side_effect_modules)
    erlang = Keyword.get(opts, :side_effect_erlang_atoms, @default_side_effect_erlang_atoms)

    side_effect_alias_tails =
      modules
      |> Enum.map(&alias_tail/1)
      |> MapSet.new()

    erlang_set = MapSet.new(erlang)

    if IospExemptions.mix_task_module?(ast) do
      []
    else
      collect_predicates(ast, side_effect_alias_tails, erlang_set)
    end
  end

  defp collect_predicates(ast, side_effect_alias_tails, erlang_set) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {def_kind, _meta, [head, kw]} = node, acc when def_kind in [:def, :defp] and is_list(kw) ->
          case predicate_name_and_body(head, kw) do
            {name, line, body} ->
              # Per-call exemption: `has_side_effect_call?/3` skips
              # Process.alive?/info/whereis, :erlang.is_process_alive,
              # and Port.info calls as it walks, so a predicate that
              # composes liveness with another side effect (e.g.
              # `Process.alive?(pid) and Repo.exists?(...)`) still
              # fires on the Repo call. A whole-function exemption
              # here would hide the Repo call too, so the gate is
              # per-call only.
              if has_side_effect_call?(body, side_effect_alias_tails, erlang_set),
                do: {node, [build_issue(name, line) | acc]},
                else: {node, acc}

            :no ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  # Extract function name + line + body if this def's head is a
  # predicate (name ends in `?`). Skip defguards (pure by construction).
  defp predicate_name_and_body({:when, _, [inner, _guard]}, kw),
    do: predicate_name_and_body(inner, kw)

  defp predicate_name_and_body({name, meta, params}, kw)
       when is_atom(name) and is_list(params) do
    name_str = Atom.to_string(name)

    if String.ends_with?(name_str, "?") do
      body = AstKeyword.get(kw, :do)
      {name, Keyword.get(meta, :line), body}
    else
      :no
    end
  end

  defp predicate_name_and_body(_, _), do: :no

  defp has_side_effect_call?(nil, _alias_tails, _erlang_set), do: false

  defp has_side_effect_call?(body, alias_tails, erlang_set) do
    {_ast, found?} =
      Macro.prewalk(body, false, fn
        _node, true ->
          {[], true}

        # Aliased call: `Repo.insert(...)`, `MyApp.Repo.get(...)`,
        # `Phoenix.PubSub.broadcast(...)`. Match on the trailing
        # alias segment so callers don't have to enumerate every
        # aliased path. Process / Port introspection calls skip
        # without short-circuiting — the walk continues looking
        # for OTHER side effects in the same body.
        {{:., _, [{:__aliases__, _, segments}, fun]}, _, _} = node, _ ->
          cond do
            IospExemptions.introspection_call?(segments, fun) -> {node, false}
            alias_matches?(segments, alias_tails) -> {node, true}
            true -> {node, false}
          end

        # Bare-atom call: `:ets.lookup(...)`, `:persistent_term.put(...)`.
        # Sourceror wraps bare atoms as `{:__block__, _, [:ets]}` — unwrap.
        # `:erlang.is_process_alive/1` skips here too (same per-call
        # exemption shape as the aliased introspection calls).
        {{:., _, [erl_atom, fun]}, _, _} = node, _ ->
          cond do
            IospExemptions.introspection_erlang_call?(erl_atom, fun) -> {node, false}
            erlang_atom?(erl_atom, erlang_set) -> {node, true}
            true -> {node, false}
          end

        node, acc ->
          {node, acc}
      end)

    found?
  end

  # Match a configured side-effect name against an alias's tail.
  # Single-segment configs (`"Repo"`) match any alias ending in
  # `Repo`. Multi-segment configs (`"Phoenix.PubSub"`) match aliases
  # whose tail equals the segment list.
  defp alias_matches?(segments, alias_tails) do
    Enum.any?(alias_tails, fn tail ->
      tail_matches?(segments, tail)
    end)
  end

  defp tail_matches?(segments, tail_segments) do
    seg_len = length(segments)
    tail_len = length(tail_segments)

    seg_len >= tail_len and
      Enum.drop(segments, seg_len - tail_len) == tail_segments
  end

  defp erlang_atom?(atom, set) when is_atom(atom), do: MapSet.member?(set, atom)
  defp erlang_atom?({:__block__, _, [atom]}, set) when is_atom(atom), do: MapSet.member?(set, atom)
  defp erlang_atom?(_, _), do: false

  defp alias_tail(name) when is_binary(name) do
    name
    |> String.split(".")
    |> Enum.map(&String.to_atom/1)
  end

  defp build_issue(name, line) do
    %Issue{
      rule: :iosp_predicate_side_effects,
      message:
        "`#{name}` looks like a predicate (ends in `?`) but its body calls into a " <>
          "side-effecting module (Repo, HTTP client, GenServer, etc.). Predicates " <>
          "should be deterministic — readers assume `if active?(x)` is cheap and " <>
          "side-effect-free. Lift the side effect into an integration function " <>
          "(load the data once), then pass the result to a pure predicate.",
      meta: %{line: line, function: name}
    }
  end
end
