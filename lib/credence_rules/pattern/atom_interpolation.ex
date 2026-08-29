defmodule CredenceRules.Pattern.AtomInterpolation do
  @moduledoc ~S"""
  Advisory rule: `:"prefix_#{value}"` mints a new atom for every
  distinct interpolated value.

  Atoms are never garbage-collected, so interpolating an *unbounded*
  source into an atom literal grows the atom table until the node
  dies. That's the same hazard `string_to_atom_unsafe` covers — but
  it needs different advice, because **there is no interpolation
  sugar for `binary_to_existing_atom`**. Rewriting `:"meta_#{key}"`
  as `:erlang.binary_to_existing_atom("meta_#{key}", :utf8)` is
  measurably worse to read, and wrong whenever the atom is
  legitimately new. The fix is to check where the interpolated values
  come from, not to swap the function.

  Most uses of this sugar are fine: process names derived from a
  supervision tree, keys iterated from a module attribute, test
  fixtures. It reports at `:low` so it reads as "confirm this source
  is bounded", not "this is a bug".

  ## Bad

      # `type` arrives off the wire — unbounded atom minting.
      def key(type), do: :"handler_#{type}"

  ## Good

      # Bounded by a compile-time list.
      @types [:read, :write]
      def key(type) when type in @types, do: :"handler_#{type}"

      # Or resolve against atoms that already exist.
      def key(type), do: String.to_existing_atom("handler_#{type}")

  ## Relationship to `string_to_atom_unsafe`

  Elixir lowers `:"a_#{b}"` to `:erlang.binary_to_atom(<<…>>, :utf8)`,
  which is exactly the call `string_to_atom_unsafe` matches — the two
  are indistinguishable by function name alone. This module owns the
  discriminator (`interpolated_binary?/1`); `string_to_atom_unsafe`
  calls it and skips what it matches. Keeping one owner is what stops
  the two rules from drifting into double-reporting the same site, or
  both skipping it.
  """

  use CredenceRules.Rule

  @severity :low
  @confidence :high

  @hint """
  Confirm the interpolated values come from a bounded set — a module
  attribute, a literal list, an `in` guard, or a value already
  validated against one. If the source is untrusted (params, wire
  payload, filenames), build the string first and resolve it with
  `String.to_existing_atom/1` against a known allowlist.
  """

  @carve_outs [
    "Process / supervision-tree names derived from a caller-supplied module name",
    "Keys iterated from a compile-time module attribute or literal list",
    "Test fixtures generating per-case names"
  ]

  @impl true
  def priority, do: 200

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {{:., _, [:erlang, :binary_to_atom]}, meta, [arg | _]} = node, acc ->
          if interpolated_binary?(arg),
            do: {node, [build_issue(meta) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  @doc ~S"""
  True if `node` is the binary literal Elixir builds for an
  interpolated atom — `:"a_#{b}"` quotes its first argument as a
  `{:<<>>, _, segments}` whose interpolated segments carry
  `from_interpolation: true`.

  A hand-written `:erlang.binary_to_atom(var, :utf8)` never looks like
  this, which is what makes the two shapes separable.

  Used by `CredenceRules.Pattern.StringToAtomUnsafe` to skip the
  sites this rule reports.

      iex> alias CredenceRules.Pattern.AtomInterpolation
      iex> {{:., _, _}, _, [arg | _]} = Code.string_to_quoted!(~S|:"a_#{b}"|)
      iex> AtomInterpolation.interpolated_binary?(arg)
      true

      iex> alias CredenceRules.Pattern.AtomInterpolation
      iex> AtomInterpolation.interpolated_binary?(Code.string_to_quoted!("var"))
      false
  """
  @spec interpolated_binary?(Macro.t()) :: boolean()
  def interpolated_binary?({:<<>>, _meta, segments}) when is_list(segments) do
    Enum.any?(segments, &interpolated_segment?/1)
  end

  def interpolated_binary?(_node), do: false

  # `"a_#{b}"` segments quote as
  # `{:"::", _, [{{:., _, [Kernel, :to_string]}, [from_interpolation: true, …], _}, _]}`.
  # Both parse paths (Code.string_to_quoted and Sourceror) carry the flag.
  defp interpolated_segment?({:"::", _meta, [{_call, meta, _args} | _]}) when is_list(meta),
    do: Keyword.get(meta, :from_interpolation, false)

  defp interpolated_segment?(_segment), do: false

  defp build_issue(meta) do
    %Issue{
      rule: :atom_interpolation,
      message:
        "`:\"…\#{}\"` mints a new atom per distinct value, and atoms are " <>
          "never garbage-collected. Confirm the interpolated values come " <>
          "from a bounded set (a module attribute, a literal list, an `in` " <>
          "guard). If the source is untrusted, resolve the string with " <>
          "`String.to_existing_atom/1` instead.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
