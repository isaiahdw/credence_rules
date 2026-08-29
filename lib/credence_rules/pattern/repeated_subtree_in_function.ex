# credence-file:cross_file_duplicate_block — this module is an AST pattern
#   matcher whose check/2 + Macro.prewalk + build_issue shape is the Rule
#   contract itself, so the structural duplication is inherent to the form
#   rather than a smell
defmodule CredenceRules.Pattern.RepeatedSubtreeInFunction do
  @moduledoc """
  DRY rule: within a single function body, the same normalised AST
  subtree appearing 2+ times signals an extract-a-helper opportunity.

  ## Bad

      def normalize_users(users) do
        owner =
          users
          |> Enum.filter(& &1.role == :owner)
          |> Enum.map(& &1.name)
          |> Enum.sort()

        admin =
          users
          |> Enum.filter(& &1.role == :admin)
          |> Enum.map(& &1.name)
          |> Enum.sort()

        {owner, admin}
      end

  Both pipelines have the same shape (filter by role, project name,
  sort). Extract:

      def normalize_users(users) do
        {names_by_role(users, :owner), names_by_role(users, :admin)}
      end

      defp names_by_role(users, role) do
        users
        |> Enum.filter(& &1.role == role)
        |> Enum.map(& &1.name)
        |> Enum.sort()
      end

  ## Detection

  For each `def` / `defp` body, walk every subtree, canonicalise it
  (variable names → `_var_`, literal values → `_lit_`, metadata
  stripped — see `CredenceRules.AstNormalize`), and group by
  hash. Clusters with 2+ occurrences are flagged.

  Trivial subtrees (single calls, bare expressions) are filtered by
  `meaningful?/2` with a node-count threshold of 14. Tuned from an
  initial floor of 8 — the lower threshold surfaced mostly
  dispatch-table calls (`Path.join(dir, "x")` twice in a row) which
  aren't extraction candidates. 14 nodes is roughly a 3-line case
  body or a `with` chain — the size at which extracting a helper
  starts paying for itself.

  When subtrees nest — a parent cluster's hash collides AND a child's
  does — only the largest enclosing cluster is reported. Each cluster
  carries the line range of every occurrence (first-line and last-line
  metadata across the subtree); a cluster is dropped if every one of
  its occurrence ranges is fully contained inside a larger cluster's
  occurrence ranges. Without this, a duplicated paragraph would
  generate findings for itself, every sentence inside it, and every
  word.

  ## Data tables aren't duplication

  Clusters whose every occurrence is a *pure data literal* — a row of a
  lookup table (`[0, 1, 2, …]`), a TLV tag/type tuple, an argument
  keyword list with per-row values — are dropped. They collide only
  because the normaliser erases their literal values, but those values
  are the whole point: each row is its own canonical entry in a table,
  and the enclosing list already names it. Extracting a helper would
  force the varying leaves through a positional interface and make the
  code worse. See `CredenceRules.AstClassify.pure_data?/1`. Pass
  `flag_pure_data_duplicates: true` to report them anyway.

  ## Logging idioms aren't duplication

  Clusters that are log / format-message shapes —
  `Logger.error("…: \#{inspect(reason)}")` and friends — with no call
  into a project module are dropped too. Log lines recur across a
  healthy codebase by design; the shared shape often spans branches
  with opposite policies (`{:stop, reason}` vs degrade gracefully), so
  a `log_X/3` helper would either merge the differing responses or be
  too thin to name. See
  `CredenceRules.AstClassify.formatting_only?/2`; pass
  `flag_logging_idioms: true` to report them anyway.
  """

  use CredenceRules.Rule

  alias CredenceRules.{AstClassify, AstNormalize}

  @min_nodes 14

  @impl true
  def priority, do: 400

  @impl true
  def check(ast, opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {kind, _meta, [_head, [{:do, body} | _]]} = node, acc when kind in [:def, :defp] ->
          {node, find_duplicates(body, opts) ++ acc}

        # Sourceror-wrapped do-block key.
        {kind, _meta, [_head, kw]} = node, acc when kind in [:def, :defp] and is_list(kw) ->
          case CredenceRules.AstKeyword.get(kw, :do) do
            nil -> {node, acc}
            body -> {node, find_duplicates(body, opts) ++ acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.sort_by(issues, & &1.meta.line)
  end

  defp find_duplicates(body, opts) do
    body
    |> collect_subtrees()
    |> Enum.filter(fn {_node, _range, size} -> size >= @min_nodes end)
    |> Enum.group_by(fn {node, _range, _size} -> AstNormalize.hash(node) end)
    |> Enum.filter(fn {_h, occs} -> match?([_, _ | _], occs) end)
    |> Enum.map(fn {hash, occs} ->
      [{node, _r, size} | _] = occs
      ranges = Enum.map(occs, fn {_n, r, _s} -> r end)
      %{hash: hash, node: node, ranges: ranges, size: size, count: length(occs)}
    end)
    |> reject_boilerplate(opts)
    |> drop_subsumed()
    |> Enum.map(&build_issue/1)
  end

  # Some clusters hash alike without being extractable logic:
  #
  # - Pure data literals (lookup-table rows, tuple specs, argument
  #   keyword lists) — the surrounding list / call site is already their
  #   home; the rows match only because normalisation erases their
  #   per-row literal values.
  # - Logging idioms (`Logger.error("…: \#{inspect(reason)}")`) — log
  #   lines recur all over a healthy codebase; that's how Elixir logs,
  #   not a missing helper.
  #
  # Both are dropped by default and re-enabled per opt. See
  # `CredenceRules.AstClassify`.
  defp reject_boilerplate(clusters, opts) do
    Enum.reject(clusters, &AstClassify.boilerplate_duplicate?(&1.node, opts))
  end

  # Walk the body, collecting {subtree, {first_line, last_line}, node_count}
  # for each AST node.
  defp collect_subtrees(body) do
    {_ast, list} =
      Macro.prewalk(body, [], fn
        {_form, meta, _args} = node, acc when is_list(meta) ->
          range = line_range(node)
          size = AstNormalize.count_nodes(node)
          {node, [{node, range, size} | acc]}

        node, acc ->
          {node, acc}
      end)

    list
  end

  # `{min_line, max_line}` across every metadata in the subtree.
  defp line_range(node) do
    {_ast, lines} =
      Macro.prewalk(node, [], fn
        {_form, meta, _args} = inner, acc when is_list(meta) ->
          case Keyword.get(meta, :line) do
            nil -> {inner, acc}
            line -> {inner, [line | acc]}
          end

        inner, acc ->
          {inner, acc}
      end)

    case lines do
      [] -> nil
      lines -> Enum.min_max(lines)
    end
  end

  # A cluster is "subsumed" by another if every one of its occurrence
  # ranges is fully contained inside some occurrence range of the
  # other cluster, AND the other cluster is strictly larger.
  #
  # Sort by size descending so larger clusters are considered first;
  # mark their ranges as taken and drop later clusters whose ranges
  # all fall inside.
  defp drop_subsumed(clusters) do
    sorted = Enum.sort_by(clusters, &(-&1.size))

    {kept, _taken} =
      Enum.reduce(sorted, {[], []}, fn cluster, {kept, taken} ->
        if all_inside?(cluster.ranges, taken) do
          {kept, taken}
        else
          {[cluster | kept], cluster.ranges ++ taken}
        end
      end)

    Enum.reverse(kept)
  end

  defp all_inside?(ranges, taken_ranges) do
    Enum.all?(ranges, fn r -> Enum.any?(taken_ranges, &range_contains?(&1, r)) end)
  end

  defp range_contains?(nil, _), do: false
  defp range_contains?(_, nil), do: false
  defp range_contains?({a_lo, a_hi}, {b_lo, b_hi}), do: a_lo <= b_lo and b_hi <= a_hi

  defp build_issue(%{ranges: ranges, count: count, size: size}) do
    first_line = min_lo(ranges)

    %Issue{
      rule: :repeated_subtree_in_function,
      message:
        "Duplicated subtree (#{size} nodes, #{count} occurrences in this " <>
          "function). Extract a private helper — the duplication is structural " <>
          "(variable names and literal values ignored), so the helper takes the " <>
          "varying pieces as args.",
      meta: %{line: first_line, occurrences: count, size: size}
    }
  end

  # Single-pass minimum of the `lo` field across a list of {lo, hi}
  # ranges (and nils). Replaces a `reject(nil) |> map(lo) |> min` chain
  # that traversed the list three times.
  defp min_lo(ranges) do
    Enum.reduce(ranges, nil, fn
      nil, acc -> acc
      {lo, _hi}, nil -> lo
      {lo, _hi}, acc -> min(lo, acc)
    end)
  end
end
