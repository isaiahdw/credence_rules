defmodule CredenceRules.Pattern.ApplicationPutEnvInCode do
  @moduledoc """
  Correctness rule: `Application.put_env/2,3,4` belongs in config files
  (`config/*.exs`, `config/runtime.exs`) and test setup, not in `lib/`
  source code.

  `Application.put_env` mutates global, node-wide application
  configuration. In `lib/` code, every call to it is a hidden
  cross-module side effect: another module reading via `get_env` will
  see different values depending on whether your function has run yet.
  Worse, two callers can race on the same key and silently overwrite
  each other.

  Legitimate uses:

  - `config/config.exs` / `config/runtime.exs` — declarative startup
  - Test setup — `setup do Application.put_env(...) end` (often paired
    with `on_exit` to restore)
  - A mix task that exists *to* mutate config

  In application code, the right pattern is one of:

  - **Function arg** — pass the value through, not via global env
  - **GenServer state** — own the value, not the env table
  - **Config file** — set it at startup, never reach for it again

  ## Bad

      def configure_adapter(mod) do
        Application.put_env(:my_app, :adapter, mod)   # global side effect
        :ok
      end

  ## Good

      # In config/runtime.exs:
      config :my_app, :adapter, MyApp.Adapter.HTTP

      # In application code, just read it:
      def adapter, do: Application.get_env(:my_app, :adapter)

  ## Allowlist

  Modules declared as `use Mix.Task`, `use ExUnit.Case`, or
  `use ExUnit.CaseTemplate` are exempt:

  - **Mix tasks** exist precisely to perform one-shot operations
    including config mutation (e.g. `mix interop.commission` setting
    up adapter config before running the harness).
  - **ExUnit cases** routinely use `setup do Application.put_env(...) end`
    paired with `on_exit/1` to override config for a single test —
    this is the standard idiomatic shape and not the hidden-side-effect
    smell the rule targets.

  The rule's correctness concern — *hidden* cross-module config
  mutation in long-lived application code — does not apply when the
  operation is an explicit, user-invoked CLI step or a scoped test
  override.
  """

  use CredenceRules.Rule

  alias CredenceRules.AstKeyword

  @impl true
  def priority, do: 450

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        # `defmodule Foo do use Mix.Task; ... end` — short-circuit the
        # subtree by returning `[]` so prewalk doesn't descend into it.
        # Mix tasks legitimately mutate config (e.g. `mix interop.commission`
        # setting up adapter config before running a harness).
        #
        # Sourceror wraps the `:do` key, so destructuring `[{:do, body}]`
        # fails on the production AST. Use AstKeyword.get/2 so the
        # exemption works regardless of parser.
        {:defmodule, _meta, [_alias, kw]} = node, acc when is_list(kw) ->
          case AstKeyword.get(kw, :do) do
            nil ->
              {node, acc}

            body ->
              if mix_task?(body),
                do: {[], acc},
                else: {node, acc}
          end

        # `Application.put_env/2,3`, `put_all_env/1`, `delete_env/2` —
        # the actual flag. Fires both inside non-Mix-Task `defmodule`s
        # AND at the top level (script / `.exs` files).
        {{:., _, [{:__aliases__, _, [:Application]}, fun]}, meta, args} = node, acc
        when fun in [:put_env, :put_all_env, :delete_env] and is_list(args) ->
          {node, [build_issue(meta, fun, length(args)) | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp mix_task?(body) do
    stmts =
      case body do
        {:__block__, _, list} -> list
        single -> [single]
      end

    Enum.any?(stmts, &exempt_use?/1)
  end

  # Module-level `use` declarations that exempt the module from the rule.
  defp exempt_use?({:use, _, [{:__aliases__, _, [:Mix, :Task]}]}), do: true
  defp exempt_use?({:use, _, [{:__aliases__, _, [:Mix, :Task]}, _]}), do: true
  defp exempt_use?({:use, _, [{:__aliases__, _, [:ExUnit, :Case]}]}), do: true
  defp exempt_use?({:use, _, [{:__aliases__, _, [:ExUnit, :Case]}, _]}), do: true
  defp exempt_use?({:use, _, [{:__aliases__, _, [:ExUnit, :CaseTemplate]}]}), do: true
  defp exempt_use?({:use, _, [{:__aliases__, _, [:ExUnit, :CaseTemplate]}, _]}), do: true
  defp exempt_use?(_), do: false

  defp build_issue(meta, fun, arity) do
    %Issue{
      rule: :application_put_env_in_code,
      message:
        "`Application.#{fun}/#{arity}` mutates global app config from " <>
          "library code — a hidden cross-module side effect that races " <>
          "between callers. Move to `config/*.exs` (declarative), test " <>
          "setup blocks, or pass the value through function args / state.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
