defmodule CredenceRules.Pattern.ConditionalSupervisorChild do
  @moduledoc """
  Idiomatic rule: don't conditionally include children in a supervisor's
  child list via `if`/`unless`/`case`/`cond`. The child itself should
  return `:ignore` from `start_link/1` (or `init/1`) when it shouldn't
  run.

  This is an explicit antipattern from *Elixir Patterns* (Koutmos &
  Baraúna, §5.x p.187-188). When `init/1` builds a `children` list
  conditionally:

      def init(_) do
        children = [
          Worker,
          if Config.feature_enabled?, do: OptionalWorker
        ]
        |> Enum.reject(&is_nil/1)

        Supervisor.init(children, strategy: :one_for_one)
      end

  …the supervisor topology becomes a function of compile-time *and*
  init-time config inspection, which scatters configuration knowledge
  across the application. The cleaner pattern: always list every child,
  and let each child decide whether to actually run via `:ignore`:

      defmodule OptionalWorker do
        def start_link(_) do
          if Config.feature_enabled?() do
            GenServer.start_link(__MODULE__, ...)
          else
            :ignore
          end
        end
      end

  A child returning `:ignore` is removed from the supervision tree
  *cleanly* — no error, no restart, no special-case in the parent.

  ## Detection

  Flags `if`/`unless`/`case`/`cond` *nodes* that appear directly inside
  a list literal that is then passed as the first arg to:

  - `Supervisor.init/2`
  - `Supervisor.start_link/2,3`
  - `DynamicSupervisor.init/1` (children list lives in opts though, skipped)

  Lists assembled by piping through `Enum.reject`/`Enum.filter` are also
  flagged — the rejection is the same antipattern with extra steps.

  ## Bad

      Supervisor.init(
        [
          Worker,
          if cfg.enabled?, do: OptionalWorker
        ]
        |> Enum.reject(&is_nil/1),
        strategy: :one_for_one
      )

  ## Good

      Supervisor.init([Worker, OptionalWorker], strategy: :one_for_one)

      # …with OptionalWorker.start_link returning :ignore as needed.
  """

  use CredenceRules.Rule

  @sup_calls MapSet.new([
               {:Supervisor, :init},
               {:Supervisor, :start_link}
             ])

  @impl true
  def priority, do: 410

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        # Supervisor.init(children, opts) / Supervisor.start_link(children, opts)
        {{:., _, [{:__aliases__, _, [mod]}, fun]}, meta, [children | _rest]} = node, acc
        when is_atom(mod) and is_atom(fun) ->
          if MapSet.member?(@sup_calls, {mod, fun}) and conditional_children?(children),
            do: {node, [build_issue(meta) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  # Walks the children expression. Flags if any direct member of a list
  # literal is an `if`/`unless`/`case`/`cond` node, OR if the expression
  # contains a `Enum.reject(_, &is_nil/1)` / `Enum.filter` cleanup.
  defp conditional_children?(expr) do
    has_conditional_in_list?(expr) or has_nil_cleanup?(expr)
  end

  defp has_conditional_in_list?(expr) do
    {_ast, found?} =
      Macro.prewalk(expr, false, fn
        _node, true ->
          {[], true}

        # Bare list literal.
        elements, false when is_list(elements) ->
          if Enum.any?(elements, &conditional_node?/1),
            do: {elements, true},
            else: {elements, false}

        node, found ->
          {node, found}
      end)

    found?
  end

  defp conditional_node?({kind, _, _}) when kind in [:if, :unless, :case, :cond],
    do: true

  defp conditional_node?(_), do: false

  defp has_nil_cleanup?(expr) do
    {_ast, found?} =
      Macro.prewalk(expr, false, fn
        _node, true ->
          {[], true}

        # Enum.reject / Enum.filter — match any arity (handles both
        # the eager form `Enum.reject(list, fun)` and pipe form
        # `list |> Enum.reject(fun)` which parses with one arg before
        # being rewritten).
        {{:., _, [{:__aliases__, _, [:Enum]}, fun]}, _, args} = node, _
        when fun in [:reject, :filter] and is_list(args) ->
          {node, true}

        node, found ->
          {node, found}
      end)

    found?
  end

  defp build_issue(meta) do
    %Issue{
      rule: :conditional_supervisor_child,
      message:
        "Children of a supervisor should not be conditionally included via " <>
          "`if`/`unless`/`Enum.reject(&is_nil/1)` in the parent's `init/1`. " <>
          "Let the optional child's own `start_link/1` return `:ignore` when " <>
          "it shouldn't run — the supervisor handles `:ignore` cleanly and " <>
          "the topology stays declarative.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
