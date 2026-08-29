defmodule CredenceRules.Pattern.LoggerCallInMixTask do
  @moduledoc """
  Architecture rule: `Logger.<level>` calls inside `Mix.Tasks.*`
  modules are usually wrong-tool-for-the-layer. Mix tasks have a
  swappable shell (`Mix.shell()`) specifically designed for
  user-facing output: tests can swap in `Mix.Shell.Process` or
  `Mix.Shell.Quiet` to capture or silence output. Logger is for
  application observability and bypasses that mechanism.

  ## Bad

      defmodule Mix.Tasks.MyApp.Seed do
        use Mix.Task
        require Logger

        @impl Mix.Task
        def run(_) do
          Logger.info("Seeding...")
          # ... work ...
          Logger.info("Done.")
        end
      end

  The "Seeding..." message goes to the configured Logger backend
  (often the console formatter), bypasses `Mix.shell()`, and is
  hard to test cleanly because Logger's test capture is global
  state.

  ## Good

      defmodule Mix.Tasks.MyApp.Seed do
        use Mix.Task

        @impl Mix.Task
        def run(_) do
          Mix.shell().info("Seeding...")
          # ... work ...
          Mix.shell().info("Done.")
        end
      end

  `Mix.shell()` returns the configured shell module
  (`Mix.Shell.IO` in interactive use, `Mix.Shell.Process` in
  tests, `Mix.Shell.Quiet` when silenced). Output behaviour
  becomes test-controllable without touching Logger config.

  ## When Logger IS legitimate in a Mix task

  This rule can't tell the difference between:

  - "I'm reporting progress to the developer running this task"
    (use `Mix.shell()`)
  - "I'm logging an operational event because this task runs in
    production as a maintenance job and we want it in our log
    aggregator" (use `Logger`)

  Both are real cases. The rule is **advisory** — flag and let
  reviewers decide. For genuinely-operational tasks, accept the
  finding.

  ## Detection

  Flags any `Logger.<level>(...)` call inside a file whose outer
  `defmodule` is `Mix.Tasks.*`. Levels matched (explicit allowlist):

  - `:debug`, `:info`, `:notice`, `:warning`, `:warn`
  - `:error`, `:critical`, `:alert`, `:emergency`

  `Logger.configure`, `Logger.configure_backend`, `Logger.metadata`,
  `Logger.put_application_level`, `Logger.delete_module_level`,
  etc. are NOT flagged — those configure the logger, they don't
  emit a log line.

  ## File-level gate caveat

  The gate checks the file's outer `defmodule`. A file with both
  `Mix.Tasks.Foo` AND `Foo.Helper` defined inside would flag
  Logger calls in BOTH modules. In practice the one-module-per-
  file convention keeps this accurate. Split such files if it
  matters.

  ## Why advisory

  See "When Logger IS legitimate" above. The rule fires on a
  real smell most of the time, but the carve-outs are common
  enough that strict failure is too aggressive.

  ## Configuration

      config :credence_rules,
        rule_opts: %{
          logger_call_in_mix_task: [
            # Treat additional module names as Logger wrappers
            logger_modules: ~w(Logger MyApp.AuditLog)
          ]
        }
  """

  use CredenceRules.Rule

  alias CredenceRules.IospExemptions

  @severity :low
  @confidence :medium

  @hint """
  Replace `Logger.<level>` with `Mix.shell().info/error` for
  Mix-task UX output:

      # Before
      defmodule Mix.Tasks.MyApp.Seed do
        use Mix.Task
        require Logger
        def run(_), do: Logger.info("Seeding...")
      end

      # After
      defmodule Mix.Tasks.MyApp.Seed do
        use Mix.Task
        def run(_), do: Mix.shell().info("Seeding...")
      end

  `Mix.shell()` returns a swappable shell — tests can use
  `Mix.Shell.Process` to capture output or `Mix.Shell.Quiet` to
  silence it. Logger bypasses that mechanism.

  Keep Logger in a Mix task ONLY when the message is genuinely
  operational (long-running production maintenance task that
  needs aggregation / alerting).
  """

  @carve_outs [
    "Long-running production-shaped maintenance tasks (e.g., `mix myapp.sync_data` run from systemd) where output SHOULD go to production logs. Accept the finding.",
    "Mix tasks that call into app code — the app code's own Logger calls are correct and NOT flagged. Only direct Logger.* calls in the task body trigger.",
    "Logger.configure / Logger.metadata / Logger.put_application_level — these configure the logger, they don't log. Auto-skipped (explicit level allowlist)."
  ]

  @logger_levels ~w(debug info notice warning warn error critical alert emergency)a

  @default_logger_modules ["Logger"]

  @impl true
  def priority, do: 481

  @impl true
  def check(ast, opts) do
    logger_modules = Keyword.get(opts, :logger_modules, @default_logger_modules)
    logger_module_set = MapSet.new(logger_modules)

    if IospExemptions.mix_task_module?(ast) do
      collect_findings(ast, logger_module_set)
    else
      []
    end
  end

  defp collect_findings(ast, logger_module_set) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        # Logger.<level>(...) — match the trailing alias segment
        # so MyApp.Logger.info / aliased `Logger` both work via
        # the configurable :logger_modules list.
        {{:., meta, [{:__aliases__, _, segments}, fun]}, _, args} = node, acc
        when is_atom(fun) and is_list(args) ->
          if logger_call?(segments, fun, logger_module_set),
            do: {node, [build_issue(meta, fun) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    issues
    |> Enum.uniq_by(fn issue -> {issue.meta.line, issue.meta.level} end)
    |> Enum.sort_by(& &1.meta.line)
  end

  defp logger_call?(segments, fun, logger_module_set) do
    fun in @logger_levels and matches_logger_module?(segments, logger_module_set)
  end

  # Match against the FULL alias name (joined). Configurable list
  # defaults to just "Logger" — exact match. Users can add
  # "MyApp.Logger" or similar wrappers via :logger_modules.
  defp matches_logger_module?(segments, logger_module_set) do
    name =
      segments
      |> Enum.map(&segment_to_string/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.join(".")

    MapSet.member?(logger_module_set, name)
  end

  defp segment_to_string({:__block__, _, [seg]}) when is_atom(seg), do: Atom.to_string(seg)
  defp segment_to_string(seg) when is_atom(seg), do: Atom.to_string(seg)
  defp segment_to_string(_), do: nil

  defp build_issue(meta, level) do
    %Issue{
      rule: :logger_call_in_mix_task,
      message:
        "`Logger.#{level}/_` called inside a Mix.Tasks.* module. Mix tasks " <>
          "should use `Mix.shell().info/error` for user-facing output so tests " <>
          "can swap in `Mix.Shell.Process` / `Mix.Shell.Quiet`. Logger bypasses " <>
          "that mechanism. If this task is genuinely operational (production " <>
          "maintenance job that needs aggregation), accept the finding.",
      meta: %{line: Keyword.get(meta, :line), level: level}
    }
  end
end
