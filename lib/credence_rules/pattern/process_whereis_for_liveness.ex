defmodule CredenceRules.Pattern.ProcessWhereisForLiveness do
  @moduledoc """
  Concurrency rule: `Process.whereis/1` used as an "is process alive?"
  check has a time-of-check-vs-time-of-use race.

      if Process.whereis(Foo) do
        GenServer.call(Foo, :bar)   # Foo may have crashed between
      end                            # whereis and call

  In the window between `whereis` returning a pid and your subsequent
  `GenServer.call`, the target process can crash and restart with a
  new pid (or fail to restart). Your call then either reaches the
  *new* process out-of-context, or raises `:noproc` — exactly the
  failure mode the check was meant to prevent.

  Correct patterns:

  - **Register via a Registry** and call `via_tuple` form — `GenServer`
    handles the lookup atomically.
  - **Monitor and react to `:DOWN`** — handle the absence as a positive
    signal rather than polling.
  - **Just call** — let `:noproc` surface as `{:error, :noproc}` (catch
    it explicitly with `try/catch :exit`) and trust the supervisor.

  ## Detected shapes

  - `if Process.whereis(X), do: …` / `unless Process.whereis(X), do: …`
  - `if Process.whereis(X) != nil, do: …` (and `== nil` / `is_nil`)
  - `case Process.whereis(X) do nil -> … pid -> … end`

  Assignments like `pid = Process.whereis(X); send(pid, msg)` are *also*
  racy but aren't flagged here — they're best caught by a separate
  "use Registry" architectural review.

  ## Bad

      if Process.whereis(Foo) do
        GenServer.call(Foo, :ping)
      end

  ## Good — use a Registry

      def call_foo(msg) do
        GenServer.call({:via, Registry, {MyReg, Foo}}, msg)
      catch
        :exit, {:noproc, _} -> {:error, :down}
      end
  """

  use CredenceRules.Rule

  @impl true
  def priority, do: 350

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        # Skip ExUnit case modules — tests legitimately probe process
        # existence for setup/assertion. The production TOCTOU concern
        # doesn't translate when the test owns the process lifecycle.
        {:defmodule, _meta, [_alias, [{:do, body}]]} = node, acc ->
          if exunit_case?(body),
            do: {[], acc},
            else: {node, acc}

        # `if Process.whereis(X), do: ...` / `unless ...`
        {kw, meta, [cond_expr | _]} = node, acc when kw in [:if, :unless] ->
          if liveness_check?(cond_expr),
            do: {node, [build_issue(meta, kw) | acc]},
            else: {node, acc}

        # `case Process.whereis(X) do ... end`
        {:case, meta, [subject, _arms]} = node, acc ->
          if whereis_call?(subject),
            do: {node, [build_issue(meta, :case) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    issues
    |> Enum.uniq_by(& &1.meta.line)
    |> Enum.sort_by(& &1.meta.line)
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

  defp liveness_check?(expr) do
    whereis_call?(expr) or whereis_comparison?(expr) or whereis_is_nil?(expr)
  end

  defp whereis_call?({{:., _, [{:__aliases__, _, [:Process]}, :whereis]}, _, [_]}), do: true
  defp whereis_call?(_), do: false

  # `Process.whereis(X) != nil`, `== nil`
  defp whereis_comparison?({op, _, [lhs, nil]}) when op in [:==, :!=],
    do: whereis_call?(lhs)

  defp whereis_comparison?({op, _, [nil, rhs]}) when op in [:==, :!=],
    do: whereis_call?(rhs)

  defp whereis_comparison?(_), do: false

  # `is_nil(Process.whereis(X))` and `not is_nil(...)`
  defp whereis_is_nil?({:is_nil, _, [arg]}), do: whereis_call?(arg)

  defp whereis_is_nil?({:not, _, [{:is_nil, _, [arg]}]}),
    do: whereis_call?(arg)

  defp whereis_is_nil?(_), do: false

  defp build_issue(meta, shape) do
    %Issue{
      rule: :process_whereis_for_liveness,
      message:
        "`#{shape} Process.whereis(_)`-as-liveness-check has a TOCTOU race: " <>
          "the process can crash between `whereis` and the subsequent call. " <>
          "Register via a `Registry` and use `{:via, Registry, …}` tuples, " <>
          "or call and rescue `:exit, :noproc`.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
