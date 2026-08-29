# credence-file:repeated_subtree_in_module — this module is an AST pattern
#   matcher whose check/2 + Macro.prewalk + build_issue shape is the Rule
#   contract itself, so the structural duplication is inherent to the form
#   rather than a smell
defmodule CredenceRules.Pattern.RepeatedSubtreeInModule do
  @moduledoc """
  DRY rule: within a single module, the same normalised AST subtree
  appearing across two or more `def` / `defp` bodies signals an
  extract-a-private-function opportunity.

  ## Bad

      defmodule Users do
        def fetch_owners(users) do
          users
          |> Enum.filter(&(&1.role == :owner))
          |> Enum.map(& &1.name)
          |> Enum.sort()
        end

        def fetch_admins(users) do
          users
          |> Enum.filter(&(&1.role == :admin))
          |> Enum.map(& &1.name)
          |> Enum.sort()
        end
      end

  ## Good

      defmodule Users do
        def fetch_owners(users), do: names_by_role(users, :owner)
        def fetch_admins(users), do: names_by_role(users, :admin)

        defp names_by_role(users, role) do
          users
          |> Enum.filter(&(&1.role == role))
          |> Enum.map(& &1.name)
          |> Enum.sort()
        end
      end

  ## Detection

  Walk each `defmodule` body, collect every subtree across every
  `def`/`defp` clause, group by canonical hash (see
  `CredenceRules.AstNormalize`), and flag clusters appearing in
  **2+ distinct functions**. Multiple occurrences inside the same
  function are the `repeated_subtree_in_function` rule's domain.

  Same nesting-subsumption logic as the within-function rule: a
  cluster is dropped if every occurrence range is contained inside a
  larger cluster's occurrence ranges.

  Default size threshold is 16 nodes — higher than the within-function
  rule because cross-function extraction has a higher activation
  energy (you're committing to a private function with a name and an
  interface). Initial floor of 10 surfaced mostly small idioms
  (`{:error, _} = err -> err`, single-call `Mix.raise`) that recur
  but don't decompose into a helper.

  Pure data literals are dropped for the same reason as in the
  within-function rule: three calls to `build_and_sign([serial:
  serial, issuer: dn, …], …)` share the keyword-list shape but compute
  every field differently per variant. The call site is the boundary,
  not a missing helper. See
  `CredenceRules.AstClassify.pure_data?/1`; pass
  `flag_pure_data_duplicates: true` to report them anyway.

  Logging idioms are dropped on the same grounds: a
  `Logger.error("…: \#{inspect(reason)}")` shape recurring across two
  unrelated failure branches (one that stops, one that degrades) shares
  an AST but not a policy, so there's no helper to extract. See
  `CredenceRules.AstClassify.formatting_only?/2`; pass
  `flag_logging_idioms: true` to report them anyway.
  """

  use CredenceRules.Rule

  alias CredenceRules.{AstClassify, AstKeyword, AstNormalize}

  @min_nodes 16

  @impl true
  def priority, do: 410

  @impl true
  def check(ast, opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [_alias, kw]} = node, acc when is_list(kw) ->
          case AstKeyword.get(kw, :do) do
            nil -> {node, acc}
            body -> {node, find_duplicates(body, opts) ++ acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.sort_by(issues, & &1.meta.line)
  end

  defp find_duplicates(module_body, opts) do
    subtrees =
      module_body
      |> def_bodies()
      |> Enum.with_index()
      |> Enum.flat_map(fn {{body, def_line}, fn_idx} ->
        body
        |> collect_subtrees(fn_idx, def_line)
        |> Enum.filter(fn {_node, _range, size, _fn_idx} -> size >= @min_nodes end)
      end)

    subtrees
    |> Enum.group_by(fn {node, _r, _s, _i} -> AstNormalize.hash(node) end)
    |> Enum.filter(fn {_h, occs} -> multi_function?(occs) end)
    |> Enum.map(fn {_hash, occs} ->
      [{node, _r, size, _i} | _] = occs

      ranges = Enum.map(occs, fn {_n, r, _s, _i} -> r end)
      fn_count = occs |> MapSet.new(fn {_n, _r, _s, i} -> i end) |> MapSet.size()

      %{node: node, ranges: ranges, size: size, count: length(occs), fn_count: fn_count}
    end)
    |> reject_boilerplate(opts)
    |> drop_subsumed()
    |> Enum.map(&build_issue/1)
  end

  # Drop clusters that hash alike without being extractable logic:
  # pure data literals (most often a keyword list of arguments to the
  # same builder call — the call site is the boundary, not a missing
  # helper) and logging idioms (`Logger.error("…: \#{inspect(reason)}")`
  # repeated across unrelated failure branches). Both are on by default
  # and re-enabled per opt — see `CredenceRules.AstClassify`.
  defp reject_boilerplate(clusters, opts) do
    Enum.reject(clusters, &AstClassify.boilerplate_duplicate?(&1.node, opts))
  end

  defp def_bodies(module_body) do
    {_ast, list} =
      Macro.prewalk(module_body, [], fn
        {kind, meta, [_head, kw]} = node, acc when kind in [:def, :defp] and is_list(kw) ->
          case AstKeyword.get(kw, :do) do
            nil -> {node, acc}
            body -> {node, [{body, Keyword.get(meta, :line)} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(list)
  end

  defp collect_subtrees(body, fn_idx, _def_line) do
    {_ast, list} =
      Macro.prewalk(body, [], fn
        {_form, meta, _args} = node, acc when is_list(meta) ->
          range = line_range(node)
          size = AstNormalize.count_nodes(node)
          {node, [{node, range, size, fn_idx} | acc]}

        node, acc ->
          {node, acc}
      end)

    list
  end

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

  # Only flag clusters whose occurrences span 2+ distinct functions.
  # Multiple occurrences in the same function are the
  # `repeated_subtree_in_function` rule's concern.
  defp multi_function?(occs) do
    distinct = occs |> Enum.map(fn {_n, _r, _s, i} -> i end) |> Enum.uniq()
    match?([_, _ | _], distinct)
  end

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

  defp build_issue(%{ranges: ranges, count: count, size: size, fn_count: fn_count}) do
    first_line = min_lo(ranges)

    %Issue{
      rule: :repeated_subtree_in_module,
      message:
        "Duplicated subtree (#{size} nodes, #{count} occurrences across #{fn_count} " <>
          "functions). Extract a private helper — the duplication is structural " <>
          "(variable names and literal values ignored), so the helper takes the " <>
          "varying pieces as args.",
      meta: %{line: first_line, occurrences: count, size: size, functions: fn_count}
    }
  end

  defp min_lo(ranges) do
    Enum.reduce(ranges, nil, fn
      nil, acc -> acc
      {lo, _hi}, nil -> lo
      {lo, _hi}, acc -> min(lo, acc)
    end)
  end
end
