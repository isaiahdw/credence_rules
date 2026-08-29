defmodule CredenceRules.Pattern.StringToAtomUnsafe do
  @moduledoc """
  Safety rule: `String.to_atom/1` and `:erlang.binary_to_atom/1,2`
  silently grow the atom table.

  Atoms are not garbage-collected. Every distinct atom occupies a slot
  in the global atom table (default capacity ~1M). Once exhausted, the
  BEAM crashes the entire node — there's no way to free atoms. Any
  code path that turns *untrusted input* into atoms via `to_atom` is
  a DoS vector.

  The fix is `String.to_existing_atom/1` (or
  `:erlang.binary_to_existing_atom/1,2`) which raises `ArgumentError`
  if the atom doesn't already exist. Trusted, bounded inputs (a
  whitelist of rule names, a fixed enum) are safe with `to_atom` — but
  the rule fires uniformly so call sites have to be reviewed.

  ## Bad

      # `name` comes from a JSON payload — attacker controls the
      # atom-table-growth rate.
      type = String.to_atom(payload["type"])

  ## Good

      # The atom exists if and only if your code already mentions it
      # somewhere — bounded by your own surface area.
      type = String.to_existing_atom(payload["type"])

  ## Atom-literal interpolation is a different rule

  Elixir lowers `:"a_\#{b}"` to `:erlang.binary_to_atom(<<…>>, :utf8)`
  — the exact call this rule matches. Those sites are reported by
  `atom_interpolation` instead, because the advice below does not fit
  them: there is no interpolation sugar for `binary_to_existing_atom`,
  so "use the existing-atom variant" is not an actionable fix. This
  rule defers to
  `CredenceRules.Pattern.AtomInterpolation.interpolated_binary?/1`
  so each site is reported exactly once.

  What stays here: `String.to_atom/1`, `:erlang.list_to_atom/1`, and
  `binary_to_atom` on a non-literal first argument — where swapping in
  the existing-atom variant is the right fix as written.

  ## Allowlist

  When you legitimately need to mint new atoms from a bounded source
  (e.g. test-rule discovery, codegen), suppress with a reason:

      # credence:string_to_atom_unsafe — bounded: keys come from the
      #   compile-time @rule_names list, not from user input
      type = String.to_atom(name)
  """

  use CredenceRules.Rule

  alias CredenceRules.Pattern.AtomInterpolation

  @impl true
  def priority, do: 470

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        # String.to_atom/1
        {{:., _, [{:__aliases__, _, [:String]}, :to_atom]}, meta, [_]} = node, acc ->
          {node, [build_issue(meta, "String.to_atom/1", "String.to_existing_atom/1") | acc]}

        # :erlang.binary_to_atom/1,2 — but `:"a_#{b}"` lowers to exactly
        # this call, and belongs to `atom_interpolation` instead.
        {{:., _, [:erlang, :binary_to_atom]}, meta, [arg | _] = args} = node, acc
        when is_list(args) and length(args) in [1, 2] ->
          if AtomInterpolation.interpolated_binary?(arg) do
            {node, acc}
          else
            {node,
             [
               build_issue(
                 meta,
                 ":erlang.binary_to_atom/#{length(args)}",
                 ":erlang.binary_to_existing_atom"
               )
               | acc
             ]}
          end

        # :erlang.list_to_atom/1
        {{:., _, [:erlang, :list_to_atom]}, meta, [_]} = node, acc ->
          {node, [build_issue(meta, ":erlang.list_to_atom/1", ":erlang.list_to_existing_atom") | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp build_issue(meta, name, replacement) do
    %Issue{
      rule: :string_to_atom_unsafe,
      message:
        "`#{name}` grows the atom table without bound — DoS risk on " <>
          "untrusted input. Use `#{replacement}` to require the atom to " <>
          "already exist, or suppress with a comment if the input set is " <>
          "demonstrably bounded.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
