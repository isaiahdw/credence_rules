defmodule CredenceRules.Pattern.UnaliasedModuleUse do
  @moduledoc """
  Readability rule: a fully-qualified module name used **3+ times in
  one function body** without an `alias` is noise. LLMs tend to paste
  the full module name into every call rather than aggregate aliases at
  the top of the module.

  Unlike a "no fully-qualified names anywhere" rule, this only fires on
  dense use *within a single function* — one or two qualified calls is
  fine, but five `Credo.Code.prewalk` calls in one function body wants
  `alias Credo.Code`.

  ## Bad

      def run(source_file) do
        Credo.Code.prewalk(source_file, &walk/2, ctx)
        Credo.Code.remove_metadata(pattern)
        Credo.Code.remove_metadata(body)
      end

  ## Good

      alias Credo.Code

      def run(source_file) do
        Code.prewalk(source_file, &walk/2, ctx)
        Code.remove_metadata(pattern)
        Code.remove_metadata(body)
      end

  ## Detection

  - Counts dot calls of the shape `Mod.Sub.func(...)` per function body.
  - Single-segment modules (e.g. `Enum`, `String`) are skipped — they
    can't usefully be aliased shorter.
  - Module names that already appear in an `alias` declaration anywhere
    in the file are skipped (we don't want to fight existing aliases).
  - Threshold defaults to 3; override via `min_count: N` opt.

  Ported from
  [`ExSlop.Check.Readability.UnaliasedModuleUse`](https://hex.pm/packages/ex_slop).
  """

  use CredenceRules.Rule

  @default_min_count 3

  @impl true
  def priority, do: 200

  @impl true
  def check(ast, opts) do
    min_count = Keyword.get(opts, :min_count, @default_min_count)
    aliased = collect_aliased(ast)

    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {op, _, _} = node, acc when op in [:def, :defp] ->
          {node, collect_dense_uses(node, aliased, min_count) ++ acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp collect_aliased(ast) do
    {_ast, set} =
      Macro.prewalk(ast, MapSet.new(), fn
        {:alias, _, [{:__aliases__, _, parts} | _]} = node, acc when is_list(parts) ->
          {node, MapSet.put(acc, name_of(parts))}

        node, acc ->
          {node, acc}
      end)

    set
  end

  # For each fun body, count fully-qualified Mod.Sub.func references
  # and emit one issue per module that exceeds the threshold (locating
  # at the first use site).
  defp collect_dense_uses(fun_ast, aliased, min_count) do
    {_, counts} = Macro.prewalk(fun_ast, %{}, &count_qualified_call/2)

    counts
    |> Enum.filter(fn {name, %{count: count}} ->
      count >= min_count and not MapSet.member?(aliased, name)
    end)
    |> Enum.map(fn {name, %{count: count, line: line}} -> build_issue(name, count, line) end)
  end

  # Skip the inside of `alias` declarations — they have a real
  # __aliases__ but aren't a "use" of the module.
  defp count_qualified_call({:alias, _, _}, acc), do: {nil, acc}

  # Skip module attributes — the @type body etc. references types,
  # not call sites.
  defp count_qualified_call({:@, _, _}, acc), do: {nil, acc}

  defp count_qualified_call(
         {:., meta, [{:__aliases__, _, [_, _ | _] = parts}, fun]} = node,
         acc
       )
       when is_atom(fun) do
    if Enum.all?(parts, &is_atom/1) do
      name = name_of(parts)
      line = Keyword.get(meta, :line)

      acc =
        Map.update(acc, name, %{count: 1, line: line}, fn existing ->
          %{existing | count: existing.count + 1}
        end)

      {node, acc}
    else
      {node, acc}
    end
  end

  defp count_qualified_call(node, acc), do: {node, acc}

  defp name_of(parts), do: Enum.map_join(parts, ".", &Atom.to_string/1)

  defp build_issue(name, count, line) do
    %Issue{
      rule: :unaliased_module_use,
      message:
        "`#{name}` used #{count}× in one function body — add `alias #{name}` at the top of " <>
          "the module and use the short name. Long fully-qualified names buried inline are " <>
          "an LLM tell: experienced authors aggregate aliases.",
      meta: %{line: line, name: name, count: count}
    }
  end
end
