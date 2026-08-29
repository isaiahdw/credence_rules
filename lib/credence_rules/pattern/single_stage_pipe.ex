defmodule CredenceRules.Pattern.SingleStagePipe do
  @moduledoc """
  Style rule: `x |> foo()` with no further pipe stages is a pipe in
  costume. It reads as "data flow" but it's just `foo(x)` with extra
  characters — and the extra characters trick readers into looking for
  the pipeline that isn't there.

  Pipes earn their keep when they chain multiple transformations.
  Reserve them for that.

  ## Bad

      result = string |> String.trim()
      result = list |> Enum.sort()
      user.name |> String.upcase()

  ## Good

      result = String.trim(string)
      result = Enum.sort(list)
      String.upcase(user.name)

  ## Good — multi-stage pipelines still earn their keep

      string |> String.trim() |> String.downcase() |> String.split(" ")

  ## Detection

  Fires on a `|>` node where ALL of the following hold:

  - Its LHS is not itself a `|>` (so this is the *first* stage of a
    chain), AND
  - It's not nested inside another `|>` (so this is the *last* stage
    of a chain too), AND
  - Its LHS is a **bare value** — a variable, a literal, or a single
    field access (`user.name`).

  The third condition is the key one. `f(x) |> g(y)` is two distinct
  transformations chained via a pipe — exactly the shape pipes are
  meant for — and the rule does **not** fire on it, even though there
  are only two stages. The smell is "wrapping a single function call
  in pipe ceremony," which only applies when the LHS is something so
  simple that `foo(lhs)` would read identically.

  Examples that are NOT flagged:

      :crypto.hash(:sha256, key) |> binary_part(0, 20)    # two ops
      f(x) |> g(y)                                        # two ops
      Module.function() |> Enum.each(...)                 # 0-arity remote
      DateTime.utc_now() |> DateTime.to_iso8601()         # 0-arity remote
      %{a: 1} |> Map.put(:b, 2)                           # builder
      a |> b() |> c()                                     # multi-stage
  """

  use CredenceRules.Rule

  @hint """
  Replace `x |> foo()` with `foo(x)`. Mechanical rewrite:

      # Before
      result = string |> String.trim()
      list |> Enum.sort()

      # After
      result = String.trim(string)
      Enum.sort(list)

  If the pipe is at the start of a longer chain (e.g.
  `string |> String.trim() |> String.downcase()`), no change
  needed — the chain earns the pipe ceremony.
  """

  @carve_outs [
    "Multi-stage pipelines: `string |> String.trim() |> String.downcase()` — the rule won't fire on these (LHS is itself a pipe call result), but they're the canonical good shape if you find yourself questioning a flagged single-stage.",
    "Function-call LHS: `f(x) |> g(y)` — already two distinct ops chained, not flagged.",
    "0-arity remote calls: `DateTime.utc_now() |> DateTime.to_iso8601()` — also not flagged; LHS is a function call."
  ]

  @impl true
  def priority, do: 350

  @impl true
  def check(ast, _opts) do
    {_ast, {issues, _depth}} =
      Macro.traverse(
        ast,
        {[], 0},
        fn node, {acc, depth} -> {node, enter(node, acc, depth)} end,
        fn node, {acc, depth} -> {node, leave(node, acc, depth)} end
      )

    Enum.reverse(issues)
  end

  defp enter({:|>, meta, [lhs, _rhs]}, acc, 0) do
    # Top-level pipe (we are not inside another pipe).
    # - Multi-stage chain: skip (LHS is itself a pipe).
    # - LHS is a real expression (function call, builder map): skip —
    #   `f(x) |> g(y)` is a two-stage transformation, not a single-stage
    #   misuse.
    # - LHS is a bare value (variable / literal / field access): fire.
    new_acc =
      cond do
        pipe?(lhs) -> acc
        bare_value?(lhs) -> [build_issue(meta) | acc]
        true -> acc
      end

    {new_acc, 1}
  end

  defp enter({:|>, _, _}, acc, depth), do: {acc, depth + 1}
  defp enter(_node, acc, depth), do: {acc, depth}

  defp leave({:|>, _, _}, acc, depth), do: {acc, depth - 1}
  defp leave(_node, acc, depth), do: {acc, depth}

  defp pipe?({:|>, _, _}), do: true
  defp pipe?(_), do: false

  # Bare variable: `{name, _meta, ctx}` where both are atoms and `ctx`
  # is the variable context (nil or a module). Function-call nodes
  # share this shape but with `args` as a list, not an atom.
  defp bare_value?({name, _meta, ctx}) when is_atom(name) and is_atom(ctx), do: true

  # `Module.function()` — 0-arity remote call. Shares the same shape as
  # field access (`{{:., _, [obj, name]}, _, []}`) but the LHS of the
  # dot is `{:__aliases__, _, _}`. That's a real transformation, not a
  # bare value; clause order matters — this must come before the
  # field-access clause below.
  defp bare_value?({{:., _, [{:__aliases__, _, _}, _]}, _, []}), do: false

  # Field access — `user.name` parses to `{{:., _, [obj, field]}, _, []}`.
  # `obj` is value-shaped (variable, nested field access), not an alias.
  defp bare_value?({{:., _, [_obj, field]}, _, []}) when is_atom(field), do: true

  # Literals — strings, numbers, atoms, lists, booleans.
  defp bare_value?(v) when is_binary(v) or is_number(v) or is_atom(v) or is_list(v), do: true

  # Sourceror wraps literals in `{:__block__, _, [literal]}` — unwrap.
  defp bare_value?({:__block__, _, [inner]}), do: bare_value?(inner)

  # Anything else (function call, tuple constructor, map literal, struct,
  # binary, range, etc.) is treated as a real expression — not a bare
  # value — so a one-stage pipe over it doesn't fire.
  defp bare_value?(_), do: false

  defp build_issue(meta) do
    %Issue{
      rule: :single_stage_pipe,
      message:
        "Single-stage pipe — `x |> foo()` is `foo(x)` with extra characters. Pipes earn " <>
          "their keep when they chain multiple transformations; reserve them for that.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
