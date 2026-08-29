defmodule CredenceRules.Pattern.RepeatedCaseArmBody do
  @moduledoc """
  DRY rule: within a single `case`, two (or more) clauses whose bodies
  are structurally identical signal that the clauses can be merged.

  ## Bad

      case status do
        :pending -> {:ok, %{}}
        :running -> {:ok, %{}}
        :complete -> finalise(state)
        _ -> {:error, :unknown}
      end

  ## Good — merge identical bodies

      case status do
        s when s in [:pending, :running] -> {:ok, %{}}
        :complete -> finalise(state)
        _ -> {:error, :unknown}
      end

  Or, if the patterns are more varied:

      case status do
        :pending -> ok_empty()
        :running -> ok_empty()
        # …if patterns can't be merged into a single clause, at
        # least extract the body so the duplication has a name.
      end

  ## Detection

  Within one `case` expression, group `do` arms by their **exact**
  body (source position stripped, but structure, literals, AND
  variables preserved). Flag any cluster with 2+ arms — minus the
  wildcard `_` clause, which is by convention the "fallthrough" arm
  and often legitimately shares a body with a specific arm.

  Only the `do:` arms are scanned. `rescue` / `catch` / `after`
  clauses in `try` blocks are out of scope for this rule (their
  patterns have different semantics).

  Bodies must be at least 2 AST nodes — single-token bodies like
  `:ok`, `:error`, or a bare variable are NOT flagged. Merging
  single-token arms doesn't reduce duplication enough to be worth
  the loss of explicit pattern enumeration.

  ## Exact-body comparison

  Two arms cluster only when their bodies are **identical** — same
  structure, same literal values, AND same variables — because that's
  the only case where they can collapse into one guarded clause.

  Two kinds of false positive this rules out:

  - **Lookup tables** — `:a -> 1; :b -> 2; :c -> 3`. Same shape,
    different literal returns; not duplicates, a dispatch table.
  - **Different accumulator slots** — `:a -> store(acc, key_a); :b ->
    store(acc, key_b)`. Same shape, but each writes a different
    variable. You can't merge them into `pat when pat in [...] ->
    store(acc, ???)`, so they aren't duplicates. `bar(x)` and
    `bar(y)` likewise don't cluster.

  Only arms that are byte-for-byte the same body (e.g. two arms that
  both return `{:ok, Map.put(state, :ts, now)}`) — which genuinely
  merge — are flagged.
  """

  @body_min_nodes 2

  use CredenceRules.Rule

  alias CredenceRules.{AstKeyword, AstNormalize}

  @impl true
  def priority, do: 400

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:case, meta, [_subject, kw]} = node, acc when is_list(kw) ->
          case AstKeyword.get(kw, :do) do
            arms when is_list(arms) ->
              {node, find_clusters(arms, meta) ++ acc}

            _ ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    issues
    |> Enum.uniq_by(&{&1.meta.line, &1.meta[:cluster]})
    |> Enum.sort_by(& &1.meta.line)
  end

  # Group arms by canonicalised body hash; emit one issue per cluster
  # with >= 2 non-wildcard arms.
  defp find_clusters(arms, case_meta) do
    arms
    |> Enum.filter(&match?({:->, _, [_pat, _body]}, &1))
    |> Enum.reject(&wildcard_clause?/1)
    |> Enum.filter(fn {:->, _, [_pat, body]} -> AstNormalize.meaningful?(body, @body_min_nodes) end)
    |> Enum.group_by(fn {:->, _, [_pat, body]} -> body_key(body) end)
    |> Enum.filter(fn {_hash, arms} -> match?([_, _ | _], arms) end)
    |> Enum.map(fn {hash, dup_arms} ->
      first_line =
        dup_arms
        |> Enum.map(fn {:->, m, _} -> Keyword.get(m, :line) end)
        |> Enum.reject(&is_nil/1)
        |> Enum.min(fn -> Keyword.get(case_meta, :line) end)

      build_issue(first_line, length(dup_arms), hash)
    end)
  end

  defp wildcard_clause?({:->, _, [[{:_, _, ctx}], _body]}) when is_atom(ctx), do: true
  defp wildcard_clause?(_), do: false

  # Two arms cluster only when their bodies are *identical* — same
  # structure, same literals, AND same variables — so they can actually
  # collapse into one guarded clause. Strip metadata (source position)
  # but preserve everything else.
  #
  # Variables are NOT normalised: `store(acc, key_a)` and `store(acc,
  # key_b)` update different accumulator slots; you can't merge them
  # into `pat when pat in [...] -> store(acc, ???)`, so they aren't
  # duplicates. (Literals already differed under the old hash — `1` and
  # `2` never clustered — but variable positions did, which produced
  # false "duplicates".)
  defp body_key(body) do
    body
    |> Macro.prewalk(fn node -> Macro.update_meta(node, fn _ -> [] end) end)
    |> :erlang.phash2()
  end

  defp build_issue(line, arm_count, cluster_hash) do
    %Issue{
      rule: :repeated_case_arm_body,
      message:
        "#{arm_count} `case` clauses share the same body. Merge with a guard " <>
          "(`pat1 when pat1 in [a, b] -> body`) or extract the body so the " <>
          "duplication has a name. The wildcard `_` arm is exempt — by " <>
          "convention it falls through.",
      meta: %{line: line, cluster: cluster_hash}
    }
  end
end
