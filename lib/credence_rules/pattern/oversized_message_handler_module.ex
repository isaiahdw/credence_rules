# credence-file:iosp_mixed_function — this module is an AST pattern matcher
#   whose check/2 + Macro.prewalk + build_issue shape is the Rule contract
#   itself, so the structural duplication is inherent to the form rather than a
#   smell
defmodule CredenceRules.Pattern.OversizedMessageHandlerModule do
  @moduledoc """
  Architecture rule: a module that defines too many message-handler
  clauses — `handle_info` + `handle_call` + `handle_cast` +
  `handle_event` summed — is doing too many things. This is the
  cross-behaviour cousin of `genserver_handle_call_explosion`:

  - That rule only fires on modules with `use GenServer` and only
    counts `handle_call/3`. A `:gen_statem` with 40 `handle_event`
    clauses, a `GenEvent` with 20 `handle_call/handle_info`
    clauses, or a hand-rolled behaviour that owns every flavour
    of message — all slip past it.
  - This rule sums every flavour of message-handler clause and
    fires regardless of the `use` macro, so god-process modules
    show up no matter which OTP shape they wear.

  Real motivating case: a `:gen_statem` ReadClient with 40+
  `handle_info` clauses spanning subscription state, ICD wake/sleep,
  mDNS events, Thread events, MRP signals, timer expiry, async-Task
  bookkeeping, and DOWN messages. Each new concern adds a clause
  body; the module grows to 2000+ lines and every reader has to
  trace through unrelated branches to understand any single flow.

  ## Bad

      defmodule MyApp.ReadClient do
        @behaviour :gen_statem

        # 40+ handle_info clauses across unrelated concerns:
        def handle_info(:subscribe, state), do: ...
        def handle_info(:resubscribe, state), do: ...
        def handle_info(:peer_unreachable, state), do: ...
        def handle_info(:liveness_timeout, state), do: ...
        def handle_info(:icd_recheck, state), do: ...
        def handle_info({:subscription_message, ...}, state), do: ...
        def handle_info({:address_resolved, ...}, state), do: ...
        def handle_info({:operational_up, ...}, state), do: ...
        def handle_info({:changed, ...}, state), do: ...
        def handle_info({:icd_check_in, ...}, state), do: ...
        def handle_info({:active_window_expired, _}, state), do: ...
        def handle_info(%Thread.Event.AdapterReady{}, state), do: ...
        def handle_info(%Thread.Event.NetworkAttached{}, state), do: ...
        # ...many more
      end

  ## Good — split by concern, route from a thin dispatcher

      defmodule MyApp.ReadClient do
        # State-machine dispatch + delegating to focused modules.
        def handle_info(msg, state) when subscription_message?(msg),
          do: Subscription.handle(msg, state)

        def handle_info(msg, state) when icd_message?(msg),
          do: ICD.handle(msg, state)

        def handle_info(msg, state) when discovery_message?(msg),
          do: Discovery.handle(msg, state)
      end

  Or, when subjects genuinely share state, split state by ownership
  (per-fabric registry, per-session DynamicSupervisor) and give each
  shard one logical concern.

  ## Detection

  Flags a module when the sum of:

  - `handle_info/2` clauses
  - `handle_call/3` clauses
  - `handle_cast/2` clauses
  - `handle_event/4` clauses (gen_statem)

  exceeds `:max_handlers` (default 20). Each clause head counts as
  one — multi-clause `def` bodies don't double-count. The default
  is calibrated to catch genuine god-modules (40+ in the
  motivating case) without firing on focused state machines that
  legitimately have 10-15 clauses.

  Issues mention the source line count as a secondary signal:
  a 2000-line module with 40 handlers reads differently from a
  500-line module with 25 handlers — both might be problems, but
  the prose tells the reviewer where the weight actually sits.

  ## Carve-outs

  - **Test modules** (`use ExUnit.Case` / `ExUnit.CaseTemplate`)
    are skipped — test files often define many `handle_info` /
    `handle_call` shims for mock servers.
  - **`:exclude_modules`** option for known-legitimate modules
    (state-machine routers, protocol decoders) that don't fit the
    "too many concerns" framing.

  ## Why architecture, not concurrency

  `genserver_handle_call_explosion` lives in `:concurrency` because
  every `handle_call` reader serialises through the same mailbox —
  a runtime bottleneck. This rule covers all four handler shapes,
  including `handle_event` for `:gen_statem`, where the bottleneck
  framing doesn't apply directly. The shared smell is **shape**:
  one module owns too many message subjects. That's an architecture
  concern.

  ## Why advisory

  Some legitimate modules handle many message types (state-machine
  routers with one clause per (event, state) tuple, protocol
  parsers with one clause per opcode). Treat findings as "are
  these handlers really one concern?" — not a hard cap. Tunable
  via `:max_handlers` and `:exclude_modules`.
  """

  use CredenceRules.Rule

  alias CredenceRules.{AstKeyword, TestModule}

  @hint """
  Identify the message groups handled by this module — e.g.
  subscription lifecycle, ICD wake/sleep, mDNS discovery, MRP
  signals — and extract each group into a focused module that
  exposes a `handle/2` entry point:

      defmodule MyApp.Subscription.Lifecycle do
        def handle(:subscribe, state), do: ...
        def handle(:resubscribe, state), do: ...
        def handle(:peer_unreachable, state), do: ...
      end

  Then the original module becomes a thin dispatcher whose
  `handle_info` clauses route by message shape:

      def handle_info(msg, state) when lifecycle_message?(msg),
        do: Lifecycle.handle(msg, state)

      def handle_info(msg, state) when icd_message?(msg),
        do: ICD.handle(msg, state)

  Alternative: if many subjects genuinely share state, shard the
  process — one logical owner per fabric / session / connection —
  via Registry + DynamicSupervisor. That moves the split from
  "split the work" to "shard the work."
  """

  @carve_outs [
    "State-machine routers / protocol decoders with one clause per (event, state) or opcode — naturally many clauses, one logical concern. Add to :exclude_modules.",
    "Test mock servers (ExUnit / ExUnit.CaseTemplate) — automatically skipped.",
    "Modules whose handler count reflects per-instance state pieces, not multiple concerns — raise :max_handlers per project."
  ]

  @default_max_handlers 20

  @handler_specs [
    {:handle_info, 2},
    {:handle_call, 3},
    {:handle_cast, 2},
    {:handle_event, 4}
  ]

  @impl true
  def priority, do: 440

  @impl true
  def check(ast, opts) do
    if TestModule.exunit_file?(ast) do
      []
    else
      max_handlers = Keyword.get(opts, :max_handlers, @default_max_handlers)
      exclude = Keyword.get(opts, :exclude_modules, []) |> MapSet.new()
      source = Keyword.get(opts, :source)
      line_count = line_count(source)

      {_ast, issues} =
        Macro.prewalk(ast, [], fn
          {:defmodule, meta, [alias_node, kw]} = node, acc when is_list(kw) ->
            case AstKeyword.get(kw, :do) do
              nil ->
                {node, acc}

              body ->
                module_name = module_alias(alias_node)

                if MapSet.member?(exclude, module_name) do
                  {node, acc}
                else
                  counts = count_handlers(body)
                  total = Enum.reduce(counts, 0, fn {_kind, n}, acc -> acc + n end)

                  if total > max_handlers,
                    do: {node, [build_issue(meta, total, max_handlers, counts, line_count) | acc]},
                    else: {node, acc}
                end
            end

          node, acc ->
            {node, acc}
        end)

      Enum.reverse(issues)
    end
  end

  defp module_alias({:__aliases__, _, parts}), do: Module.concat(parts)
  defp module_alias(_), do: nil

  defp line_count(source) when is_binary(source) do
    source |> String.split("\n") |> length()
  end

  defp line_count(_), do: nil

  defp count_handlers(body) do
    statements = top_level_statements(body)

    Map.new(@handler_specs, fn {name, arity} ->
      {name, Enum.count(statements, &handler_def?(&1, name, arity))}
    end)
  end

  defp top_level_statements({:__block__, _, list}), do: list
  defp top_level_statements(single), do: [single]

  defp handler_def?({:def, _, [head, _kw]}, name, arity),
    do: match?({^name, ^arity}, def_head(head))

  defp handler_def?(_, _, _), do: false

  defp def_head({:when, _, [inner, _guard]}), do: def_head(inner)

  defp def_head({name, _meta, params}) when is_atom(name) and is_list(params),
    do: {name, length(params)}

  defp def_head({name, _meta, nil}) when is_atom(name), do: {name, 0}

  defp def_head(_), do: nil

  defp build_issue(meta, total, threshold, counts, line_count) do
    breakdown = format_breakdown(counts)
    lines_suffix = format_lines_suffix(line_count)

    %Issue{
      rule: :oversized_message_handler_module,
      message:
        "Module defines #{total} message-handler clauses (threshold #{threshold})#{lines_suffix}. " <>
          "Breakdown: #{breakdown}. " <>
          "One module owning many message subjects mixes unrelated concerns — " <>
          "split by subject and route from a thin dispatcher, or shard state " <>
          "per logical owner.",
      meta: %{
        line: Keyword.get(meta, :line),
        handler_clauses: total,
        threshold: threshold,
        breakdown: counts,
        line_count: line_count
      }
    }
  end

  defp format_breakdown(counts) do
    counts
    |> Enum.filter(fn {_name, n} -> n > 0 end)
    |> Enum.sort_by(fn {_name, n} -> -n end)
    |> Enum.map_join(", ", fn {name, n} -> "#{name}=#{n}" end)
  end

  defp format_lines_suffix(nil), do: ""
  defp format_lines_suffix(n), do: " in a #{n}-line module"
end
