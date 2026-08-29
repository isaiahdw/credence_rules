defmodule CredenceRules.Pattern.MixShellOutsideMixTask do
  @moduledoc """
  Safety rule: `Mix.shell()` and `Mix.raise/1,2` belong inside
  Mix tasks. Used anywhere else, they couple application code to
  the Mix build tool — which is **not available in releases**.

  From the [Mix release docs](https://hexdocs.pm/mix/Mix.Tasks.Release.html):

  > `config/runtime.exs` MUST NOT access `Mix` in any way, as
  > Mix is a build tool and it is not available inside releases.

  The same warning applies to lib code: any module that calls
  `Mix.shell()` or `Mix.raise/1,2` will raise `UndefinedFunctionError`
  at runtime once deployed via `mix release`.

  ## Bad

      defmodule MyApp.Importer do
        def run(opts) do
          Mix.shell().info("Importing \#{opts[:count]} records")

          if opts[:count] == 0 do
            Mix.raise("nothing to import")
          end
        end
      end

  Works fine under `mix run` (Mix is loaded), crashes in release.

  ## Good

  Two common fixes — `Logger` for production observability, or a
  caller-injected callback for flexible reporting.

      # Option 1: Logger (visible in production logs / aggregation)
      defmodule MyApp.Importer do
        require Logger

        def run(opts) do
          Logger.info("Importing records", count: opts[:count])

          if opts[:count] == 0 do
            raise ArgumentError, "nothing to import"
          end
        end
      end

      # Option 2: notify callback (caller picks Logger or Mix.shell)
      defmodule MyApp.Importer do
        def run(opts) do
          notify = Keyword.get(opts, :notify, fn _ -> :ok end)
          notify.("Importing \#{opts[:count]} records")
          :ok
        end
      end

      # Mix task wires Mix.shell:
      defmodule Mix.Tasks.MyApp.Import do
        use Mix.Task
        def run(_) do
          MyApp.Importer.run(count: 42, notify: &Mix.shell().info/1)
        end
      end

      # Or app code wires Logger:
      require Logger
      MyApp.Importer.run(count: 42, notify: fn msg -> Logger.info(msg) end)

  ## Detection

  Flags any `Mix.shell()` or `Mix.raise/1,2` call in a file whose
  enclosing module is NOT a `Mix.Tasks.*` AND is NOT an ExUnit
  test module (Mix is available in tests).

  Match shapes:

  - `Mix.shell()` (zero-arity, any subsequent `.info` / `.error`
    / etc. chain still triggers because the outer node visits
    the inner `Mix.shell()` call)
  - `Mix.raise/1` and `Mix.raise/2`

  Other `Mix.*` calls (`Mix.env`, `Mix.Project.*`, `Mix.Task.*`,
  etc.) have the same release-availability problem but are kept
  out of this rule for now — they have a higher false-positive
  rate (libraries with conditional Mix usage, compile-time-only
  guards). Tight scope here keeps confidence high.

  ## File-level gates

  Skipped when ANY of:

  - File's outer `defmodule` is `Mix.Tasks.*`
  - File `use ExUnit.Case` / `use ExUnit.CaseTemplate` (Mix is
    available in test mode)
  - Defining module is in the `:allowed_modules` opt (escape
    hatch for code that wraps Mix.shell behind a runtime guard)

  ## Limitations

  The file-level gate is coarse — it checks the file's first
  `defmodule`. Files with multiple modules, one of which is a
  `Mix.Tasks.*`, may under- or over-flag. In practice the
  one-module-per-file convention keeps this accurate. If your
  project mixes a Mix.Tasks module with a regular module in the
  same file, split them.

  ## Configuration

      config :credence_rules,
        rule_opts: %{
          mix_shell_outside_mix_task: [
            allowed_modules: [MyApp.DevTools]
          ]
        }
  """

  use CredenceRules.Rule

  alias CredenceRules.{IospExemptions, TestModule}

  @severity :high
  @confidence :high

  @hint """
  Mix isn't available in releases. Two fixes:

      # Option 1: Logger (production observability)
      defmodule MyApp.Worker do
        require Logger
        def run, do: Logger.info("starting")
      end

      # Option 2: caller-injected notify callback (most flexible)
      defmodule MyApp.Worker do
        def run(opts) do
          notify = Keyword.get(opts, :notify, fn _ -> :ok end)
          notify.("starting")
        end
      end

  Mix tasks then wire `Mix.shell()`; app code wires `Logger`.
  Mix.raise → `raise ArgumentError, "msg"` or a domain-specific
  exception.
  """

  @carve_outs [
    "Code wrapped in `if Code.ensure_loaded?(Mix), do: Mix.shell().info(...)` — the rule doesn't detect this guard. Add the module to `:allowed_modules` or accept the finding.",
    "Test files (`use ExUnit.Case` / `use ExUnit.CaseTemplate`) — Mix is available in test mode. Rule auto-skips these.",
    "Mix.Tasks.* modules — rule auto-skips. The Mix task itself is the right place for Mix.shell.",
    "Libraries that provide BOTH a Mix task and a runtime helper — keep the runtime helper free of Mix and have the task delegate to it."
  ]

  @impl true
  def priority, do: 480

  @impl true
  def check(ast, opts) do
    allowed_modules = Keyword.get(opts, :allowed_modules, [])

    cond do
      # No defmodule → can't determine context (script files,
      # config snippets). Default to not flagging.
      is_nil(defining_module(ast)) ->
        []

      IospExemptions.mix_task_module?(ast) ->
        []

      TestModule.exunit_file?(ast) ->
        []

      allowed_module?(ast, allowed_modules) ->
        []

      true ->
        collect_findings(ast)
    end
  end

  defp allowed_module?(ast, allowed_modules) do
    allowed_set = MapSet.new(allowed_modules, &normalize_allowed/1)

    case defining_module(ast) do
      nil -> false
      name -> MapSet.member?(allowed_set, name)
    end
  end

  defp normalize_allowed(name) when is_atom(name), do: name |> Atom.to_string() |> strip_elixir_prefix()
  defp normalize_allowed(name) when is_binary(name), do: name

  defp strip_elixir_prefix("Elixir." <> rest), do: rest
  defp strip_elixir_prefix(name), do: name

  defp defining_module({:defmodule, _, [alias_node, _body]}), do: module_name(alias_node)

  defp defining_module({:__block__, _, statements}) do
    Enum.find_value(statements, fn
      {:defmodule, _, [alias_node, _body]} -> module_name(alias_node)
      _ -> nil
    end)
  end

  defp defining_module(_), do: nil

  defp module_name({:__aliases__, _, segments}) when is_list(segments) do
    segments
    |> Enum.map(&segment_to_string/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(".")
    |> case do
      "" -> nil
      name -> name
    end
  end

  defp module_name({:__block__, _, [inner]}), do: module_name(inner)
  defp module_name(_), do: nil

  defp segment_to_string({:__block__, _, [seg]}) when is_atom(seg), do: Atom.to_string(seg)
  defp segment_to_string(seg) when is_atom(seg), do: Atom.to_string(seg)
  defp segment_to_string(_), do: nil

  defp collect_findings(ast) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        # Mix.shell() — zero-arity call. Also matches the inner
        # node of `Mix.shell().info(...)` etc.
        {{:., meta, [{:__aliases__, _, [:Mix]}, :shell]}, _, []} = node, acc ->
          {node, [build_shell_issue(meta) | acc]}

        # Mix.raise/1 and Mix.raise/2
        {{:., meta, [{:__aliases__, _, [:Mix]}, :raise]}, _, args} = node, acc
        when is_list(args) and length(args) in 1..2 ->
          {node, [build_raise_issue(meta, length(args)) | acc]}

        node, acc ->
          {node, acc}
      end)

    issues
    # Dedup adjacent findings on the same line — `Mix.shell().info(...)`
    # only registers one Mix.shell() call.
    |> Enum.uniq_by(fn issue -> {issue.meta.line, issue.meta.function} end)
    |> Enum.sort_by(& &1.meta.line)
  end

  defp build_shell_issue(meta) do
    %Issue{
      rule: :mix_shell_outside_mix_task,
      message:
        "`Mix.shell()` called outside a Mix.Tasks.* module. Mix is a build tool " <>
          "and is NOT available in releases — this will crash with " <>
          "`UndefinedFunctionError` at runtime when deployed. Use `Logger` for " <>
          "production observability, or accept a `notify` callback so the caller " <>
          "(Mix task or app code) picks the right reporting tool.",
      meta: %{line: Keyword.get(meta, :line), function: :shell}
    }
  end

  defp build_raise_issue(meta, arity) do
    %Issue{
      rule: :mix_shell_outside_mix_task,
      message:
        "`Mix.raise/#{arity}` called outside a Mix.Tasks.* module. Mix is a " <>
          "build tool and is NOT available in releases — this will crash with " <>
          "`UndefinedFunctionError` at runtime when deployed. Use `raise " <>
          "ArgumentError, \"msg\"` or a domain-specific exception instead.",
      meta: %{line: Keyword.get(meta, :line), function: :raise}
    }
  end
end
