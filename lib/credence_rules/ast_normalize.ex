defmodule CredenceRules.AstNormalize do
  @moduledoc """
  Canonical-form + hashing helpers for AST subtrees — the foundation
  for the DRY rules (`repeated_subtree_in_function`,
  `repeated_subtree_in_module`, `repeated_case_arm_body`, and the
  cross-file duplicate engine).

  ## What "normalised" means

  Two subtrees are considered the same shape if they differ only in:

  - Variable names (`x` and `result` both become `_var_`)
  - Literal values (string contents, numbers, charlists become `_lit_`)
  - Metadata (line numbers, trivia, sourceror block wrappers)

  Operator names, function names, module aliases, keyword keys, atom
  values, and control-flow constructs are preserved — they're what
  makes the subtree mean something. Atoms specifically are NOT
  normalised: in Elixir they're often values (`:ok`, `:error`,
  state-machine states, message tags), not labels.

  Hashing the canonical form lets us detect near-duplicates without
  false-matching on cosmetic differences.

  This is the same idea as the kiron0/dry VS Code extension's
  "normalised structural matching" mode, but at the AST level instead
  of the text level. AST-level normalisation is more robust (immune
  to whitespace, comments, and the Sourceror block-wrapping that bit
  us with the keyword-key rules) at the cost of being Elixir-specific.

  ## Choosing a minimum size

  `meaningful?/2` filters out trivial subtrees (bare atoms, single
  variables, two-element tuples) that would generate noise. Default
  threshold is 5 AST nodes, tuneable per rule.

  ## Public API

  - `canonicalize/1` — replace variables with `_var_`, literals with
    `_lit_`, strip metadata. Returns a deterministic Elixir term.
  - `hash/1` — `:erlang.phash2/1` of `canonicalize/1`. Cheap, stable
    within one VM, suitable for clustering subtrees within a single
    analyser run. Not cryptographic.
  - `meaningful?/2` — true if the subtree has at least `min_nodes`
    AST nodes after canonicalisation. Use to filter out trivial
    subtrees before reporting.
  - `count_nodes/1` — node count of an AST subtree. Helper for
    `meaningful?/2` and for size-ranking duplicate clusters.
  """

  @type canonical :: term()

  @doc """
  Strip metadata and replace variables / literals with placeholders.

  Variables → `{:_var_, [], nil}`
  Numbers, strings, charlists → `:_lit_`
  Sourceror block-wrapped literals are unwrapped first.

  Preserves atoms (status atoms / module aliases / function names
  carry meaning in Elixir), operator nodes, keyword keys, and
  control-flow constructs (`:if`, `:case`, `:with`, `:fn`, `:->`, etc).

  Pass `preserve_literals: true` to keep number / string / charlist
  values verbatim — useful for rules that distinguish lookup tables
  (`:a -> 1; :b -> 2`) from genuine duplicates. Defaults to `false`
  (literals normalised).
  """
  @spec canonicalize(Macro.t(), keyword()) :: canonical()
  def canonicalize(ast, opts \\ []) do
    preserve_literals = Keyword.get(opts, :preserve_literals, false)

    {canon, _acc} =
      Macro.prewalk(ast, nil, fn node, acc ->
        {normalise_node(node, preserve_literals), acc}
      end)

    canon
  end

  @doc """
  FNV-style hash of the canonical form, suitable for clustering.

  Pass `preserve_literals: true` to make the hash sensitive to literal
  values (so `1` and `2` hash differently, but `x` and `y` still
  hash the same).
  """
  @spec hash(Macro.t(), keyword()) :: non_neg_integer()
  def hash(ast, opts \\ []), do: :erlang.phash2(canonicalize(ast, opts))

  @doc """
  True if the subtree has at least `min_nodes` AST nodes. A "node"
  is anything `Macro.prewalk` visits: tuples, atoms, literals.

  The default of 5 filters single statements (`x = y`, `foo(x)`,
  `:ok`) but admits short two-call sequences. Bump higher to focus
  on larger duplicates.
  """
  @spec meaningful?(Macro.t(), non_neg_integer()) :: boolean()
  def meaningful?(ast, min_nodes \\ 5) do
    count_nodes(ast) >= min_nodes
  end

  @doc "Count AST nodes (anything `Macro.prewalk` visits)."
  @spec count_nodes(Macro.t()) :: non_neg_integer()
  def count_nodes(ast) do
    {_ast, count} =
      Macro.prewalk(ast, 0, fn node, acc -> {node, acc + 1} end)

    count
  end

  defp normalise_node(node, false) when is_binary(node) or is_number(node), do: :_lit_
  defp normalise_node(node, true) when is_binary(node) or is_number(node), do: node

  defp normalise_node({form, _meta, args}, _preserve)
       when is_atom(form) and is_atom(args),
       # Variable: `{:x, _meta, nil}` or `{:x, _meta, Elixir.Module}` —
       # both shapes have an atom in the args slot.
       do: {:_var_, [], nil}

  defp normalise_node({form, _meta, args}, _preserve)
       when is_atom(form) and is_list(args),
       # Function call / operator / control-flow construct — preserve
       # `form`, strip metadata, recurse into args (prewalk handles that).
       do: {form, [], args}

  # Dot calls: `{{:., _, [obj, fun]}, _, args}` — preserve the call
  # shape, recurse into obj/fun/args.
  defp normalise_node({{:., _meta, dotted}, _call_meta, args}, _preserve),
    do: {{:., [], dotted}, [], args}

  # Anything else (atoms, nils, booleans, lists, 2-tuples) — preserve
  # as-is. Atoms in particular are kept verbatim because they carry
  # meaning in Elixir (status atoms, module aliases segments, function
  # names, message tags).
  defp normalise_node(other, _preserve), do: other
end
