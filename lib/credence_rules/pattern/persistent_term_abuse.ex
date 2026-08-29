# credence-file:cross_file_duplicate_block — this module is an AST pattern
#   matcher whose check/2 + Macro.prewalk + build_issue shape is the Rule
#   contract itself, so the structural duplication is inherent to the form
#   rather than a smell
defmodule CredenceRules.Pattern.PersistentTermAbuse do
  @moduledoc """
  Boundary rule: inside a `use GenServer` module, `:persistent_term.put/2,3`
  anywhere other than `init/1` treats `:persistent_term` like a mutable
  dictionary.

  `:persistent_term` is a read-mostly global table. Every `put` triggers
  a **full global GC** of all processes that hold references to the
  previous value, so writes are expensive — often hundreds of
  milliseconds on a busy node. The intended use is "set once at startup
  (or rarely on config reload), then read forever."

  The book's hydration pattern (Elixir Patterns, ch.5) is the
  reference shape: a one-shot init/1 process that loads data into
  `:persistent_term`, then returns `:ignore` so the process exits.
  Reads happen anywhere; writes don't recur.

  LLMs reach for `:persistent_term.put` inside `handle_call` /
  `handle_cast` because it resembles Java/C# static caches or Ruby
  `$globals` — store-and-fetch with no plumbing. The detector flags
  these write sites.

  ## Detection — narrow on purpose

  Only `:persistent_term.put/2,3` and `:persistent_term.erase/1` calls
  inside a `use GenServer` module, in any `def`/`defp` other than
  `init/1`, are flagged.

  `terminate/2` is exempt for `erase/1` only: a process shutting down
  pays the global-GC cost exactly once on its way out, which is when
  you want it. `put/2,3` inside `terminate/2` is still flagged —
  there's no legitimate reason to write hot data during shutdown.

  Plain modules using the lazy-cache pattern (read-with-default, write
  on miss) — common for one-time fabric/config resolution — are NOT
  flagged. Those modules have no `init/1` to do the write in;
  resolving on first read and caching is idiomatic. If you want to
  catch those too, write a project-specific check; the broader form
  has a high false-positive rate in real Elixir codebases.

  ## Bad

      defmodule Cache do
        use GenServer

        def handle_call({:set, k, v}, _from, state) do
          :persistent_term.put({__MODULE__, k}, v)    # GCs all readers
          {:reply, :ok, state}
        end
      end

  ## Good — one-shot hydration in init/1, then reads only

      defmodule ConfigCache do
        use GenServer

        def init(_) do
          for {k, v} <- load_from_disk() do
            :persistent_term.put({__MODULE__, k}, v)
          end

          :ignore
        end

        def get(k), do: :persistent_term.get({__MODULE__, k}, nil)
      end

  ## Frequent writes? Use ETS instead.

  If a value needs to update during the application's lifetime, that
  value belongs in ETS (owned by a long-lived process), not in
  `:persistent_term`. ETS writes don't trigger global GC and are
  ~100x faster.
  """

  use CredenceRules.Rule

  alias CredenceRules.OtpModule

  @write_funs ~w(put erase)a

  @impl true
  def priority, do: 460

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        # Only scan modules that `use GenServer` — plain modules using
        # `:persistent_term` as a lazy cache (read-with-default, write-on-miss)
        # are idiomatic and not the failure mode this rule targets.
        {:defmodule, _meta, [_alias, [{:do, body}]]} = node, acc ->
          if OtpModule.uses_genserver?(body),
            do: {node, scan_module(body) ++ acc},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    issues
    |> Enum.uniq_by(& &1.meta.line)
    |> Enum.sort_by(& &1.meta.line)
  end

  defp scan_module(body) do
    {_ast, issues} =
      Macro.prewalk(body, [], fn
        {kind, _meta, [head, [{:do, def_body}]]} = node, acc when kind in [:def, :defp] ->
          cond do
            init_def?(head) -> {node, acc}
            terminate_def?(head) -> {node, scan_body(def_body, [:put]) ++ acc}
            true -> {node, scan_body(def_body, @write_funs) ++ acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp init_def?({:when, _, [inner, _]}), do: init_def?(inner)
  defp init_def?({:init, _, [_]}), do: true
  defp init_def?(_), do: false

  # `terminate/2` is the GenServer shutdown callback. `erase/1` here is
  # one-shot cleanup at process death — exactly when the global-GC cost
  # is acceptable. `put/2,3` still fires.
  defp terminate_def?({:when, _, [inner, _]}), do: terminate_def?(inner)
  defp terminate_def?({:terminate, _, [_, _]}), do: true
  defp terminate_def?(_), do: false

  defp scan_body(body, allowed_funs) do
    {_ast, issues} =
      Macro.prewalk(body, [], fn
        {{:., _, [:persistent_term, fun]}, meta, args} = node, acc
        when is_list(args) ->
          if fun in allowed_funs,
            do: {node, [build_issue(meta, fun, length(args)) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp build_issue(meta, fun, arity) do
    %Issue{
      rule: :persistent_term_abuse,
      message:
        "`:persistent_term.#{fun}/#{arity}` outside `init/1` treats persistent_term " <>
          "as a mutable dictionary. Every write triggers a full GC of every " <>
          "process holding the old value — hundreds of ms on a busy node. " <>
          "Move writes into one-shot `init/1` hydration (returning `:ignore`), " <>
          "or use ETS owned by a long-lived process if the value needs to " <>
          "update during the app's lifetime.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
