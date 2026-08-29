# credence-file:cross_file_duplicate_block — this module is an AST pattern
#   matcher whose check/2 + Macro.prewalk + build_issue shape is the Rule
#   contract itself, so the structural duplication is inherent to the form
#   rather than a smell
defmodule CredenceRules.CrossFile.CircularDependency do
  @moduledoc """
  Coupling rule: detects cycles in the module dependency graph.

  Two modules `A` and `B` that depend on each other (directly or
  through any chain) form a strongly connected component (SCC).
  Cycles couple the modules' build, test, and reasoning lifetimes:
  you can't compile, test, or understand one without the other.
  They also block extracting either to a library, splitting them
  into apps, or replacing one's implementation.

  LLMs ship cycles surprisingly often because they reach for
  whichever module name is "nearby" when adding a helper, without
  noticing the back-edge. The compiler doesn't catch most cycles
  (Elixir resolves them at runtime), so they accumulate silently.

  ## Bad

      defmodule MyApp.Accounts do
        def list_admins, do: Enum.filter(list_users(), &MyApp.Users.admin?/1)
      end

      defmodule MyApp.Users do
        def admin?(user), do: MyApp.Accounts.admin_role() == user.role
      end

  Accounts → Users → Accounts. Changes to either ripple through both.

  ## Good — pick one to depend on the other

  The dependency should flow one direction. `Users` defines the data
  contract; `Accounts` consumes it. `admin_role()` either belongs in
  `Users` (since `admin?` is the only caller) or in a separate
  policy module that both depend on.

  ## Detection

  Builds the project's module dependency graph (via
  `CredenceRules.CrossFile.ModuleGraph`), runs Tarjan's SCC
  algorithm, and emits one finding per SCC of size ≥ 2. The finding
  attaches to the lexicographically-smallest module's file for
  determinism (any module in the cycle could fairly own the
  finding — the smallest-name choice is just so the report doesn't
  flip between runs).

  Stdlib / dependency modules (`Enum`, `Repo`, `Phoenix`, …) are
  filtered out at graph-build time, so they can't cause cycles in
  the report.

  ## Why boundary

  Cycles are a structural problem: they don't get easier with more
  features, and "I'll just add one more back-edge" makes them
  exponentially worse. Boundary-tier: `--strict` fails. Pair with
  the baseline gate to pin existing cycles and only fail on new
  ones.
  """

  @behaviour CredenceRules.CrossFile.Rule

  alias CredenceRules.CrossFile.{GraphSource, ModuleGraph}
  alias CredenceRules.PathExclusion
  alias Credence.Issue

  # Modules named in the prose message before it truncates. Six fits a
  # terminal line and covers essentially every hand-written cycle.
  @cycle_display_limit 6

  @impl true
  def check(files, opts) do
    graph = files |> PathExclusion.filter_files(opts) |> GraphSource.resolve(opts)

    graph
    |> ModuleGraph.strongly_connected_components()
    |> Enum.filter(&match?([_, _ | _], &1))
    |> Enum.map(&build_issue(&1, graph))
    |> Enum.sort_by(& &1.meta.path)
  end

  defp build_issue(scc, %ModuleGraph{module_to_file: m2f}) do
    [attach_to | _] = sorted = Enum.sort(scc)
    path = Map.get(m2f, attach_to)

    %Issue{
      rule: :circular_module_dependency,
      message:
        "Circular module dependency: " <>
          render_cycle(sorted) <>
          ". Modules in a cycle share build, test, and reasoning lifetimes — " <>
          "you can't change one without considering the others. Pick the " <>
          "natural dependency direction and route the back-edge through a " <>
          "third module both can depend on.",
      meta: %{line: nil, path: path, cycle: sorted}
    }
  end

  # A small cycle IS its list — you need every name to see the loop, and
  # that's the actionable content. A large one isn't: the facts that
  # matter are how big it is and where it attaches, while the full
  # enumeration is thousands of characters on a single line (one
  # 142-module cycle rendered at ~7 KB, burying every other finding in
  # the run, and in `github` format becoming one unreadable annotation).
  #
  # `meta.cycle` carries the complete sorted list either way, so machine
  # consumers lose nothing to the truncation.
  defp render_cycle(sorted) do
    case Enum.split(sorted, @cycle_display_limit) do
      {shown, []} ->
        Enum.join(shown, " ↔ ")

      {shown, rest} ->
        "#{length(sorted)} modules — " <>
          Enum.join(shown, " ↔ ") <> " ↔ … (+#{length(rest)} more)"
    end
  end
end
