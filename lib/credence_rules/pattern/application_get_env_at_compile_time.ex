# credence-file:repeated_case_arm_body — this module is an AST pattern matcher
#   whose check/2 + Macro.prewalk + build_issue shape is the Rule contract
#   itself, so the structural duplication is inherent to the form rather than a
#   smell
defmodule CredenceRules.Pattern.ApplicationGetEnvAtCompileTime do
  @moduledoc """
  Correctness rule: `Application.get_env/2,3` evaluated at module-level
  (in an `@attribute` or alongside `defdelegate to:`) captures the
  *build-time* value, not the runtime value.

  This is the most subtle config bug LLMs introduce because the code
  looks correct: `@adapter Application.get_env(:my_app, :adapter)` will
  work in the IEx session it was developed in, then ship a release
  that's pinned to whatever `:adapter` was set to at compile time.
  Production `config/runtime.exs` changes never take effect.

  The fix is `Application.compile_env/2,3` (or `compile_env!/2,3`),
  which tells the compiler about the dependency: changing the config
  in `config/config.exs` will force a recompile of this module, and
  changing it in `config/runtime.exs` is statically *prevented* (since
  runtime config wouldn't be honored anyway).

  Book reference: ch.8.3.2 — the compile-time adapter pattern uses
  `Application.compile_env!/2`, not `get_env`.

  ## Detection

  Flags `Application.get_env/{2,3}` and `Application.fetch_env/1,2`,
  `fetch_env!/1,2` when they appear inside:

  - `@attribute_name <expr>` at module level
  - `defdelegate _, to: <expr>` (the `to:` value)

  Does NOT flag inside `def`/`defp` bodies — those evaluate at runtime
  and `get_env` is correct.

  ## Bad

      @adapter Application.get_env(:my_app, :adapter, MyApp.Adapter.Dev)
      @timeout Application.fetch_env!(:my_app, :timeout)

      defdelegate run(args), to: Application.get_env(:my_app, :runner)

  ## Good

      @adapter Application.compile_env(:my_app, :adapter, MyApp.Adapter.Dev)
      @timeout Application.compile_env!(:my_app, :timeout)

      # For runtime selection, use the run-time adapter pattern instead
      # (function returns the configured module each call):
      def adapter, do: Application.get_env(:my_app, :adapter)
  """

  use CredenceRules.Rule

  alias CredenceRules.AstKeyword

  @runtime_only_calls MapSet.new([
                        :get_env,
                        :fetch_env,
                        :fetch_env!
                      ])

  @impl true
  def priority, do: 460

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn node, acc ->
        case node do
          # Module attribute: @name expr
          {:@, _, [{attr_name, _, [expr]}]}
          when is_atom(attr_name) and
                 attr_name not in [
                   :doc,
                   :moduledoc,
                   :typedoc,
                   :spec,
                   :type,
                   :typep,
                   :opaque,
                   :callback,
                   :macrocallback,
                   :impl,
                   :behaviour,
                   :before_compile,
                   :after_compile
                 ] ->
            {node, scan_expr(expr, {:attr, attr_name}) ++ acc}

          # defdelegate foo(x), to: <expr>
          {:defdelegate, _, [_signature, opts]} when is_list(opts) ->
            case AstKeyword.get(opts, :to) do
              nil -> {node, acc}
              to_expr -> {node, scan_expr(to_expr, :defdelegate) ++ acc}
            end

          _ ->
            {node, acc}
        end
      end)

    issues
    |> Enum.uniq_by(& &1.meta.line)
    |> Enum.sort_by(& &1.meta.line)
  end

  defp scan_expr(expr, context) do
    {_ast, issues} =
      Macro.prewalk(expr, [], fn
        {{:., _, [{:__aliases__, _, [:Application]}, fun]}, meta, _args} = node, acc ->
          if MapSet.member?(@runtime_only_calls, fun),
            do: {node, [build_issue(meta, fun, context) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp build_issue(meta, fun, context) do
    location =
      case context do
        {:attr, name} -> "module attribute `@#{name}`"
        :defdelegate -> "`defdelegate ... to:`"
      end

    replacement =
      case fun do
        :get_env -> "Application.compile_env"
        :fetch_env -> "Application.compile_env"
        :fetch_env! -> "Application.compile_env!"
      end

    %Issue{
      rule: :application_get_env_at_compile_time,
      message:
        "`Application.#{fun}` in #{location} captures the *build-time* " <>
          "value; runtime config changes will not be picked up. Use " <>
          "`#{replacement}/2,3` (which forces a recompile on config change), " <>
          "or move the lookup into a `def` body so it's evaluated each call.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
