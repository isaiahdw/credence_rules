# credence-file:repeated_subtree_in_module — this module is an AST pattern
#   matcher whose check/2 + Macro.prewalk + build_issue shape is the Rule
#   contract itself, so the structural duplication is inherent to the form
#   rather than a smell
defmodule CredenceRules.Pattern.EtsOwnerLifecycleMismatch do
  @moduledoc """
  Boundary rule: an `init/1` that creates an ETS table and then returns
  `:ignore` destroys the table the moment it returns.

  ETS tables are owned by a process. When the owning process exits,
  the table is destroyed (unless `:heir` is set — but `:heir` doesn't
  apply when the owner *never lives*, it only transfers on later
  death). Returning `:ignore` from `init/1` tells the supervisor "skip
  starting me" and the process exits immediately. If `init/1` created
  the table before returning `:ignore`, the table is gone before any
  caller can use it.

  Two legitimate patterns the book draws (Elixir Patterns, ch.5):

  - **One-shot hydration** — `init/1` populates `:persistent_term`,
    then returns `:ignore`. `:persistent_term` survives the process,
    so this is fine. **ETS does not.**
  - **Long-lived owner** — a process whose `start_link` returns `{:ok,
    pid}` and whose `init/1` creates the ETS table; the process stays
    up for the table's whole lifetime.

  Combining them — `:ets.new` + `:ignore` return — is the LLM-canonical
  "I'll just stash this somewhere" mistake.

  ## Detection

  Flags `:ets.new/2` calls inside an `init/1` body whose tail
  expressions include the literal atom `:ignore`. Both the
  block-tail form and per-branch `:ignore` returns count.

  ## Bad

      def init(_) do
        :ets.new(@table, [:named_table, :public])
        :ignore                                    # table dies here
      end

  ## Good — one-shot hydration into persistent_term

      def init(_) do
        for {k, v} <- load_from_disk() do
          :persistent_term.put({__MODULE__, k}, v)
        end
        :ignore
      end

  ## Good — long-lived owner

      def init(_) do
        :ets.new(@table, [:named_table, :public])
        {:ok, %{}}
      end
  """

  use CredenceRules.Rule

  alias CredenceRules.AstKeyword

  @impl true
  def priority, do: 490

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {kind, _meta, [head, [{:do, body}]]} = node, acc when kind in [:def, :defp] ->
          if init_def?(head),
            do: {node, ets_new_in_ignore_paths(body) ++ acc},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    issues
    |> Enum.uniq_by(& &1.meta.line)
    |> Enum.sort_by(& &1.meta.line)
  end

  defp init_def?({:when, _, [inner, _]}), do: init_def?(inner)
  defp init_def?({:init, _, [_]}), do: true
  defp init_def?(_), do: false

  # Per-branch path analysis. `:ets.new` is only flagged if it lives on
  # a control-flow path that ends in `:ignore`. A disjoint-branch
  # shape like `if x, do: :ignore, else: (:ets.new(...); {:ok, _})`
  # does NOT flag — the `:ignore` branch never executed `:ets.new`.
  defp ets_new_in_ignore_paths(body) do
    body
    |> linear_paths()
    |> Enum.filter(fn {_metas, tail} -> tail == :ignore end)
    |> Enum.flat_map(fn {metas, _tail} -> metas end)
    |> Enum.map(&build_issue/1)
  end

  # Returns a list of `{ets_new_metas_in_path, tail_value}` — one entry
  # per control-flow branch reaching a leaf expression. `:ets.new`
  # metas accumulate ONLY in the branches that actually execute them
  # (prelude statements of a block reach every tail branch; `if` /
  # `case` / `cond` arms are disjoint).
  defp linear_paths({:__block__, _, stmts}) when stmts != [] do
    {prelude, [tail]} = Enum.split(stmts, -1)
    prelude_metas = collect_ets_new_metas(prelude)

    for {tail_metas, tail_val} <- linear_paths(tail) do
      {prelude_metas ++ tail_metas, tail_val}
    end
  end

  defp linear_paths({:if, _, [_cond, branches]}) when is_list(branches) do
    do_paths =
      if AstKeyword.has_key?(branches, :do),
        do: linear_paths(AstKeyword.get(branches, :do)),
        else: [{[], nil}]

    else_paths =
      if AstKeyword.has_key?(branches, :else),
        do: linear_paths(AstKeyword.get(branches, :else)),
        else: [{[], nil}]

    do_paths ++ else_paths
  end

  defp linear_paths({:unless, _, [_cond, branches]}) when is_list(branches) do
    linear_paths({:if, [], [nil, branches]})
  end

  defp linear_paths({:case, _, [_subject, [{:do, arms}]]}) when is_list(arms) do
    Enum.flat_map(arms, fn
      {:->, _, [_pat, rhs]} -> linear_paths(rhs)
      _ -> [{[], :other}]
    end)
  end

  defp linear_paths({:cond, _, [[{:do, arms}]]}) when is_list(arms) do
    Enum.flat_map(arms, fn
      {:->, _, [_cond, rhs]} -> linear_paths(rhs)
      _ -> [{[], :other}]
    end)
  end

  # Leaf — single expression, neither block nor branch.
  defp linear_paths(:ignore), do: [{[], :ignore}]

  defp linear_paths({{:., _, [:ets, :new]}, meta, args} = _node) when is_list(args) do
    [{[meta], :ets_new_value}]
  end

  defp linear_paths(_other), do: [{[], :other}]

  # Walk a list of statements (the prelude of a `__block__`) and
  # collect every `:ets.new` meta. Statements here all execute
  # unconditionally before the tail.
  defp collect_ets_new_metas(stmts) when is_list(stmts) do
    Enum.flat_map(stmts, &ets_new_metas_in_expr/1)
  end

  defp ets_new_metas_in_expr(expr) do
    {_ast, metas} =
      Macro.prewalk(expr, [], fn
        {{:., _, [:ets, :new]}, meta, args} = node, acc when is_list(args) ->
          {node, [meta | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(metas)
  end

  defp build_issue(meta) do
    %Issue{
      rule: :ets_owner_lifecycle_mismatch,
      message:
        "`:ets.new/_` inside an `init/1` that returns `:ignore` — the table " <>
          "is owned by this process, which exits the moment `init/1` returns. " <>
          "The table is destroyed immediately. For one-shot hydration use " <>
          "`:persistent_term` (which survives the process); for a long-lived " <>
          "table, return `{:ok, state}` so the owner stays up.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
