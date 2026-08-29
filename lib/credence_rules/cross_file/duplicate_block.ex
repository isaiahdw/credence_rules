# credence-file:repeated_subtree_in_module — this module is an AST pattern
#   matcher whose check/2 + Macro.prewalk + build_issue shape is the Rule
#   contract itself, so the structural duplication is inherent to the form
#   rather than a smell
defmodule CredenceRules.CrossFile.DuplicateBlock do
  @moduledoc """
  DRY rule: sliding-window AST-subtree hash across **all scanned
  files**. The cross-file equivalent of
  `CredenceRules.Pattern.RepeatedSubtreeInModule` — same
  canonical form (variables normalised, literals normalised, atoms
  preserved), but the cluster spans the whole project.

  Inspired by [kiron0/dry](https://github.com/kiron0/dry) (VS Code
  extension for JS/TS duplicate detection) but at the AST level:
  immune to whitespace and comment differences, and aware of Elixir
  syntax shapes.

  ## Detection

  For each file, walk every AST node. For each subtree above the
  size threshold, compute a canonical hash. Group occurrences by
  hash. Flag clusters that:

  - Have ≥ 2 occurrences across ≥ 2 distinct files
    (within-file duplicates are the
    `repeated_subtree_in_function` / `repeated_subtree_in_module`
    rules' domain), AND
  - The largest occurrence is at least `:min_nodes` AST nodes (default
    20 — tuned higher than the in-module rule's 16, because cross-file
    extraction has a higher activation energy than module-local).

  Each cluster emits **one** finding, attached to the
  lexicographically-smallest file path (any occurrence's file would
  be fair; smallest-path keeps the report stable across runs). The
  message names every file the cluster appears in, so reviewers can
  navigate without re-running the analysis.

  ## Subsumption

  When a parent cluster's hash collides AND a child's does (a 20-line
  paragraph duplicated in three files contains sub-paragraphs that
  also duplicate), only the largest enclosing cluster reports. Same
  approach as the in-module rule: a cluster is dropped if every
  occurrence's line range is contained inside a larger cluster's
  occurrence ranges.

  ## Language idioms aren't duplication

  A cluster whose subtree touches only stdlib (`Enum`, `Map`,
  `Logger`, `Application`, `File`, …), control-flow, and
  literals/variables — with no call into a project module — is a
  language idiom, not a missing abstraction. `case Map.get(m, k) do nil
  -> d; v -> v end`, `Logger.warning("[M] Failed: \#{inspect(r)}")`,
  and `if Application.get_env(...) do {:ok, x} = Store.load(...); x else
  default end` recur across unrelated modules because that's just how
  Elixir is written; extracting a shared helper would impose a fake
  abstraction over modules that are intentionally independent. Such
  clusters are dropped — see
  `CredenceRules.AstClassify.references_module?/2`. Pass
  `flag_language_idioms: true` to report them, or
  `extra_stdlib_modules: [...]` to widen what counts as stdlib.

  ## Facade / behaviour mirrors aren't duplication

  A behaviour module's `@callback foo(...) :: ret` and a facade's
  matching `@spec foo(...) :: ret` share the inner type signature (the
  `:callback` / `:spec` atoms differ, so the `@` nodes don't cluster,
  but the `name(args) :: ret` signature does). These mirror by design —
  `lib/my_app/thread.ex` <-> `lib/my_app/thread/adapter.ex` is the
  canonical pair. Collapsing the interface into a macro or generic
  dispatch helper would reduce locality and make it harder to read, so
  clusters whose subtree is a type declaration (`@spec` / `@callback` /
  `@type` / …) or a function-spec signature (`name(args) :: ret`) are
  dropped. Pass `flag_interface_mirrors: true` to report them.

  The facade's one-line `def foo(args), do: adapter().foo(args)` bodies
  sit below this rule's node threshold and have no twin in the
  behaviour file, so they don't surface here; their within-facade
  repetition is `repeated_subtree_in_module`'s concern.

  ## Why advisory

  Some cross-file duplication is principled — protocol implementations
  for distinct types, parallel database adapters, near-mirror test
  fixtures. Treat findings as "is this duplication intentional, or is
  there a shared abstraction waiting to be named?" — not a hard cap.
  """

  @behaviour CredenceRules.CrossFile.Rule

  alias CredenceRules.{AstClassify, AstNormalize}
  alias Credence.Issue

  @default_min_nodes 20

  @impl true
  def check(files, opts) do
    min_nodes = Keyword.get(opts, :min_nodes, @default_min_nodes)
    skip_idioms? = not Keyword.get(opts, :flag_language_idioms, false)
    skip_mirrors? = not Keyword.get(opts, :flag_interface_mirrors, false)

    files
    |> CredenceRules.PathExclusion.filter_files(opts)
    |> collect_all_subtrees(min_nodes)
    |> cluster_by_hash()
    |> Enum.filter(&multi_file?/1)
    |> reject_language_idioms(skip_idioms?, opts)
    |> drop_subsumed()
    |> reject_interface_mirrors(skip_mirrors?)
    |> Enum.map(&build_issue/1)
    |> Enum.sort_by(& &1.meta.path)
  end

  # A cross-file duplicate that touches only stdlib (`Enum`, `Map`,
  # `Logger`, `Application`, …), control-flow, and literals is a
  # language idiom — two unrelated modules both reaching for the same
  # `case Map.get(m, k) do nil -> d; v -> v end`, not a shared concept
  # waiting to be named. Cross-file extraction has to justify crossing
  # a module boundary; a subtree with no project-module call doesn't,
  # so it's dropped. See
  # `CredenceRules.AstClassify.references_module?/2`.
  defp reject_language_idioms(clusters, false, _opts), do: clusters

  defp reject_language_idioms(clusters, true, opts) do
    Enum.filter(clusters, fn %{occurrences: [%{node: node} | _]} ->
      AstClassify.references_module?(node, opts)
    end)
  end

  # Facade / behaviour mirror pairs duplicate by design and shouldn't
  # be DRY'd. A behaviour's `@callback foo(...) :: ret` and the
  # facade's matching `@spec foo(...) :: ret` share the inner type
  # signature — the `:callback` / `:spec` atoms differ, so the `@`
  # nodes don't cluster, but the `name(args) :: ret` signature does.
  # Collapsing the interface into a macro or a generic dispatch helper
  # would reduce locality and make it harder to read — the duplication
  # IS the readable interface.
  #
  # See `lib/my_app/thread.ex` <-> `lib/my_app/thread/adapter.ex`.
  # (The facade's one-line `def foo(args), do: adapter().foo(args)`
  # bodies are below this rule's node threshold and have no twin in the
  # behaviour file; their within-facade repetition is
  # `repeated_subtree_in_module`'s concern, not this rule's.)
  #
  # Runs *after* `drop_subsumed/1`, unlike the language-idiom filter: an
  # `@spec` parses to nested clusters (`@` wrapping `spec` wrapping
  # `::`), and only the largest enclosing one is what gets reported.
  # Judging that cluster — not its inner fragments — is both correct
  # and lets `type_declaration?/1` match the `@`-rooted node directly.
  defp reject_interface_mirrors(clusters, false), do: clusters

  defp reject_interface_mirrors(clusters, true) do
    Enum.reject(clusters, fn %{occurrences: [%{node: node} | _]} ->
      interface_mirror?(node)
    end)
  end

  @type_attrs [:spec, :callback, :macrocallback, :type, :typep, :opaque]

  defp interface_mirror?(node) do
    type_declaration?(node) or type_signature?(node)
  end

  # `@spec` / `@callback` / `@type` and friends.
  defp type_declaration?({:@, _, [{attr, _, _}]}) when attr in @type_attrs, do: true
  defp type_declaration?(_), do: false

  # A function-spec signature `name(args) :: return` — the shape shared
  # by a `@spec` and its mirroring `@callback`. The LHS is a
  # call-shaped node (atom name, list args), which distinguishes it
  # from a variable annotation (`x :: t`) or a bitstring segment.
  defp type_signature?({:"::", _, [{fun, _, args}, _ret]}) when is_atom(fun) and is_list(args),
    do: true

  defp type_signature?(_), do: false

  defp collect_all_subtrees(files, min_nodes) do
    Enum.flat_map(files, fn {path, ast} ->
      ast
      |> collect_subtrees(path)
      |> Enum.filter(fn %{size: size} -> size >= min_nodes end)
    end)
  end

  # Single-pass collection: walk the AST bottom-up once, computing each
  # subtree's `size` and `range` from its children's results. The
  # previous implementation called `line_range/1` and `count_nodes/1`
  # for every visited node, each of which did its own `Macro.prewalk`
  # over the subtree — O(N²) for the whole body. This walker is O(N).
  #
  # `size` mirrors `Macro.prewalk`'s visit count exactly: form atoms
  # aren't PRE'd; an args-list inside a 3-tuple isn't PRE'd as a unit
  # (only its elements are); lists at the top level or in 2-tuple
  # halves ARE PRE'd. See the size-by-shape table in Elixir's
  # `Macro.do_traverse/4` source.
  defp collect_subtrees(body, path) do
    {_size, _range, entries} = walk(body, path, [])
    entries
  end

  # 3-tuple with atom form and list args — `{:foo, _meta, [args]}`.
  # PRE on the tuple (+1). Args list is walked via walk_args (no PRE
  # on the list itself, but each element gets PRE'd).
  defp walk({form, meta, args} = node, path, acc) when is_atom(form) and is_list(args) do
    {args_size, args_range, acc} = walk_args(args, path, acc)
    size = 1 + args_size
    range = merge_range(args_range, own_range(meta))
    {size, range, [%{node: node, path: path, range: range, size: size} | acc]}
  end

  # 3-tuple with atom form and atom args — variable like `{:x, _, nil}`.
  # PRE on tuple (+1), no children walks.
  defp walk({form, meta, args} = node, path, acc) when is_atom(form) and is_atom(args) do
    range = own_range(meta)
    {1, range, [%{node: node, path: path, range: range, size: 1} | acc]}
  end

  # 3-tuple with non-atom form (dot call: `{{:., _, _}, _, args}`).
  # PRE on tuple (+1), then walk(form) (which PREs form), then
  # walk_args(args).
  defp walk({form, meta, args} = node, path, acc) when is_list(meta) and is_list(args) do
    {form_size, form_range, acc} = walk(form, path, acc)
    {args_size, args_range, acc} = walk_args(args, path, acc)

    size = 1 + form_size + args_size
    range = merge_range(merge_range(args_range, form_range), own_range(meta))
    {size, range, [%{node: node, path: path, range: range, size: size} | acc]}
  end

  # 2-tuple `{left, right}`. PRE on tuple (+1), PRE on each half via
  # walk (which adds +1 for each).
  defp walk({left, right}, path, acc) do
    {l_size, l_range, acc} = walk(left, path, acc)
    {r_size, r_range, acc} = walk(right, path, acc)
    {1 + l_size + r_size, merge_range(l_range, r_range), acc}
  end

  # List at the top level (or as a 2-tuple half). PRE on the list (+1),
  # then walk_args (each element PRE'd).
  defp walk(list, path, acc) when is_list(list) do
    {child_size, child_range, acc} = walk_args(list, path, acc)
    {1 + child_size, child_range, acc}
  end

  # Leaf (atom, number, string). PRE on leaf (+1), no children.
  defp walk(_other, _path, acc), do: {1, nil, acc}

  # walk_args — caller is a 3-tuple/list walking its args. The args list
  # itself isn't PRE'd; each element is PRE'd via walk.
  defp walk_args(list, _path, acc) when is_atom(list), do: {0, nil, acc}

  defp walk_args(list, path, acc) when is_list(list) do
    Enum.reduce(list, {0, nil, acc}, fn item, {size_so_far, range_so_far, acc_so_far} ->
      {item_size, item_range, acc_next} = walk(item, path, acc_so_far)
      {size_so_far + item_size, merge_range(range_so_far, item_range), acc_next}
    end)
  end

  defp own_range(meta) do
    case Keyword.get(meta, :line) do
      nil -> nil
      line -> {line, line}
    end
  end

  defp merge_range(nil, other), do: other
  defp merge_range(range, nil), do: range
  defp merge_range({a_lo, a_hi}, {b_lo, b_hi}), do: {min(a_lo, b_lo), max(a_hi, b_hi)}

  defp cluster_by_hash(subtrees) do
    subtrees
    |> Enum.group_by(fn %{node: node} -> AstNormalize.hash(node) end)
    |> Enum.filter(fn {_h, occs} -> match?([_, _ | _], occs) end)
    |> Enum.map(fn {hash, occs} ->
      [%{size: size} | _] = occs
      # `:hash` is the subtree-structure hash, threaded through to
      # build_issue/1 → meta[:cluster_id] for stable identity in
      # baseline fingerprints. Without it, two distinct duplicate
      # clusters with the same files/size/count would collide.
      %{occurrences: occs, size: size, hash: hash}
    end)
  end

  defp multi_file?(%{occurrences: occs}) do
    files = occs |> Enum.map(& &1.path) |> Enum.uniq()
    match?([_, _ | _], files)
  end

  # Subsumption: when a parent cluster's hash matches AND a child's
  # does, drop the child. Sort by size descending, then for each
  # cluster check whether all its occurrences (path + line range)
  # are contained inside an already-accepted cluster.
  defp drop_subsumed(clusters) do
    sorted = Enum.sort_by(clusters, &(-&1.size))

    {kept, _taken} =
      Enum.reduce(sorted, {[], []}, fn cluster, {kept, taken} ->
        if all_inside?(cluster.occurrences, taken) do
          {kept, taken}
        else
          {[cluster | kept], cluster.occurrences ++ taken}
        end
      end)

    Enum.reverse(kept)
  end

  defp all_inside?(occurrences, taken) do
    Enum.all?(occurrences, fn occ ->
      Enum.any?(taken, &occurrence_contains?(&1, occ))
    end)
  end

  defp occurrence_contains?(%{path: same, range: outer}, %{path: same, range: inner}),
    do: range_contains?(outer, inner)

  defp occurrence_contains?(_, _), do: false

  defp range_contains?(nil, _), do: false
  defp range_contains?(_, nil), do: false
  defp range_contains?({a_lo, a_hi}, {b_lo, b_hi}), do: a_lo <= b_lo and b_hi <= a_hi

  defp build_issue(%{occurrences: occs, size: size, hash: hash}) do
    [attach_to | rest] = paths = occs |> Enum.map(& &1.path) |> Enum.uniq() |> Enum.sort()

    other_paths = Enum.map_join(rest, ", ", &Path.relative_to_cwd/1)

    %Issue{
      rule: :cross_file_duplicate_block,
      message:
        "Duplicated subtree (#{size} nodes, #{length(occs)} occurrences across " <>
          "#{length(paths)} files). Same shape appears at: #{other_paths}. The " <>
          "duplication is structural (variable names and literal values " <>
          "ignored) — extract a shared helper that takes the varying pieces as " <>
          "args, or accept the duplication if the modules are intentionally " <>
          "independent.",
      meta: %{
        line: nil,
        path: attach_to,
        size: size,
        occurrences: length(occs),
        files: paths,
        # Stable cluster id = subtree-structure hash. Folded into
        # the fingerprint so two distinct duplicate clusters with
        # the same files/size/count don't collide in the baseline.
        cluster_id: cluster_id(hash)
      }
    }
  end

  # Encode the AstNormalize hash as a short hex string — readable
  # in baseline JSON and stable across runs (hash is deterministic
  # over the normalized subtree).
  defp cluster_id(hash) when is_integer(hash) do
    hash
    |> Integer.to_string(16)
    |> String.pad_leading(8, "0")
    |> String.upcase()
  end

  defp cluster_id(hash) when is_binary(hash), do: hash
end
