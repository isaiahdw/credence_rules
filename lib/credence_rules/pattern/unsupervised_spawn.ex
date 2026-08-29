defmodule CredenceRules.Pattern.UnsupervisedSpawn do
  @moduledoc """
  Boundary rule: bare `spawn*` and bare `Task.start*` create
  unsupervised processes that escape OTP lifecycle management.

  ## The distinction the rule is built on

  Per the official [`Task` docs](https://hexdocs.pm/elixir/Task.html):

  - **`Task.async/1,2`** is linked AND monitored by the caller and
    MUST be awaited. Crashes propagate; results are received. This
    IS supervision for the caller's purposes — **not flagged**.
  - **`Task.start/1,2`** is the *fire-and-forget* form: no link,
    no monitor, the caller never hears back. Equivalent to bare
    `spawn`. **Flagged**.
  - **`Task.start_link/1,2`** is fire-and-forget with a link. The
    crash propagates upward, but there's no supervisor strategy
    and no result protocol. Equivalent to bare `spawn_link`.
    **Flagged.** (The canonical supervised pattern is `{Task, fn}`
    in a `Supervisor`/`DynamicSupervisor` children list, NOT a
    direct `Task.start_link/1` call in regular code.)

  Bare `spawn`, `spawn_link`, `spawn_monitor` skip OTP entirely:

  - **No restart strategy** — a crash terminates the process and
    that's it; no supervisor restarts it.
  - **No `:proc_lib` registration** — `:sys.trace`, `:sys.statistics`,
    and `:debug` tracing don't see the process.
  - **No back-pressure** — nothing limits how many you can spawn.

  The right primitives:

  - **`Task.Supervisor.start_child/2`** — for one-shot work, with
    a supervisor cap on concurrent children.
  - **`DynamicSupervisor`** — for long-lived dynamically-started workers.
  - **`{Task, fn}` in a children list** — the supervised version of
    `Task.start_link`.
  - **`Task.async/1`** — for fire-and-await-result work in the
    caller's lifetime.

  ## What this rule does NOT flag

  - `Task.async/1,2`, `Task.async_stream/2,3` — supervised by the caller.
  - `Task.Supervisor.*` — explicitly the supervised forms.
  - `{Task, fn}` child specs — that's resolved by the supervisor to
    a supervised `start_link`.
  - **`spawn_monitor` in a module that handles `{:DOWN, …}`** — a
    monitored process whose death is observed has precisely the
    property `Task.async` is exempted for above. "Run this so it
    cannot block or deadlock the caller, and observe its death" is
    the correct primitive for work that must not depend on a
    supervisor round-trip. Scoped to the enclosing module: a
    `receive` clause or `handle_info/2` head matching `{:DOWN, …}`
    anywhere in the module clears its `spawn_monitor` calls.
  - **`spawn_link` / `Task.start_link` inside a `start_link/N` body** —
    that function name IS the OTP contract asserting a supervisor is
    starting the process. `{MyModule, opts}` in a children list
    resolves to exactly this `start_link/1`, so flagging it would
    flag the supervised form while recommending it. Bare `spawn` is
    still flagged there — a link is what makes it supervisor-owned.
  - **Function *definitions* named `spawn`** — `def spawn(state, exe,
    args)` is a definition, not a call. A definition head is
    structurally identical to a call in the AST, so the rule walks
    definition bodies only.
  - Modules that `use ExUnit.Case` / `use ExUnit.CaseTemplate` — tests
    legitimately use bare `spawn` for race-condition setup, isolated
    process scenarios, etc. The supervision concern is about production
    code where crashes need to fan out through a supervisor strategy;
    tests own the lifetime of their helper processes.

  ## Bad

      spawn(fn -> work() end)
      spawn_link(fn -> work() end)
      spawn_monitor(fn -> work() end)
      Task.start(fn -> work() end)        # fire-and-forget, no link
      Task.start_link(fn -> work() end)   # linked but no supervisor strategy

  ## Good

      Task.Supervisor.start_child(MySup, fn -> work() end)
      Task.async(fn -> work() end) |> Task.await()

      # In a supervised children list:
      children = [{Task, fn -> work() end}]
  """

  use CredenceRules.Rule

  @def_kinds [:def, :defp, :defmacro, :defmacrop, :defdelegate]

  @impl true
  def priority, do: 440

  @impl true
  def check(ast, _opts) do
    ast
    |> collect([], %{supervised?: false, monitored?: down_observed?(ast)})
    |> Enum.reverse()
  end

  # Two pieces of context decide whether a spawn is actually unsupervised:
  #
  #   * `supervised?` — we're inside a `start_link/N` body, so a link
  #     hands the process to the supervisor that called us.
  #   * `monitored?` — the enclosing module observes `{:DOWN, …}`, so a
  #     monitored process's death is handled. Same property that
  #     exempts `Task.async`.
  defp collect(ast, acc, ctx) do
    {_ast, acc} =
      Macro.prewalk(ast, acc, fn
        # Tests own the lifetime of their helper processes.
        {:defmodule, _meta, [_alias, [{:do, body}]]}, acc ->
          if exunit_case?(body),
            do: {[], acc},
            else: {[], collect(body, acc, %{ctx | monitored?: down_observed?(body)})}

        # A definition head is structurally identical to a call, so
        # `def spawn(state, exe, args)` is indistinguishable from
        # `spawn/3` unless we decline to walk heads. Body only.
        {def_kind, _meta, [head | body]}, acc when def_kind in @def_kinds ->
          {[], collect(body, acc, %{ctx | supervised?: start_link_head?(head)})}

        # Bare locals: spawn/_, spawn_link/_, spawn_monitor/_
        {fun, meta, args} = node, acc when is_atom(fun) and is_list(args) ->
          if flag_local?(fun, ctx),
            do: {node, [build_issue(meta, "#{fun}/#{length(args)}") | acc]},
            else: {node, acc}

        # Task.start/_, Task.start_link/_
        {{:., _, [{:__aliases__, _, [:Task]}, fun]}, meta, args} = node, acc
        when is_atom(fun) and is_list(args) ->
          if flag_task?(fun, ctx),
            do: {node, [build_issue(meta, "Task.#{fun}/#{length(args)}") | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # Bare `spawn` is unsupervised everywhere — no link, no monitor, so
  # neither carve-out can apply to it.
  defp flag_local?(:spawn, _ctx), do: true
  defp flag_local?(:spawn_link, ctx), do: not ctx.supervised?
  defp flag_local?(:spawn_monitor, ctx), do: not ctx.monitored?
  defp flag_local?(_fun, _ctx), do: false

  # `Task.start` is fire-and-forget with no link at all, so `start_link/N`
  # ownership can't rescue it.
  defp flag_task?(:start, _ctx), do: true
  defp flag_task?(:start_link, ctx), do: not ctx.supervised?
  defp flag_task?(_fun, _ctx), do: false

  defp start_link_head?({:when, _, [inner | _]}), do: start_link_head?(inner)
  defp start_link_head?({:start_link, _, args}) when is_list(args), do: true
  defp start_link_head?(_head), do: false

  # `{:DOWN, ref, :process, pid, reason}` is a 5-tuple, so it quotes as
  # `{:{}, _, [:DOWN | _]}` — in a `receive` clause or a `handle_info/2`
  # head alike.
  defp down_observed?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:{}, _, [:DOWN | _]} = node, _acc -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end

  defp exunit_case?(body) do
    stmts =
      case body do
        {:__block__, _, list} -> list
        single -> [single]
      end

    Enum.any?(stmts, fn
      {:use, _, [{:__aliases__, _, [:ExUnit, :Case]}]} -> true
      {:use, _, [{:__aliases__, _, [:ExUnit, :Case]}, _]} -> true
      {:use, _, [{:__aliases__, _, [:ExUnit, :CaseTemplate]}]} -> true
      {:use, _, [{:__aliases__, _, [:ExUnit, :CaseTemplate]}, _]} -> true
      _ -> false
    end)
  end

  defp build_issue(meta, label) do
    %Issue{
      rule: :unsupervised_spawn,
      message:
        "`#{label}` creates an unsupervised process — no restart strategy, " <>
          "no `:sys` tracing, no back-pressure. Use " <>
          "`Task.Supervisor.start_child(MySup, fun)` for one-shot work, " <>
          "`{Task, fn}` in a supervisor's children list, or `Task.async/1` " <>
          "for fire-and-await in the caller's lifetime.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
