# credence-file:repeated_case_arm_body,repeated_subtree_in_module — this module
#   is an AST pattern matcher whose check/2 + Macro.prewalk + build_issue shape
#   is the Rule contract itself, so the structural duplication is inherent to
#   the form rather than a smell
defmodule CredenceRules.Pattern.AlternativeReturnTypes do
  @moduledoc """
  Design rule: a function should return a single, consistent shape.

  When a function mixes "tagged" returns (`{:ok, x}`/`{:error, e}`)
  with "naked" returns (`x`/`nil`/struct), every call site has to
  pattern-match on both possibilities — and almost always gets one of
  them wrong. This is the
  [alternative return types](https://hexdocs.pm/elixir/main/design-anti-patterns.html#alternative-return-types)
  anti-pattern in the official Elixir design-anti-pattern doc.

  LLMs introduce this by:

  - adding a `raise: true` / `raw: true` opt that flips the shape
    (`{:ok, x}` ↔ `x`)
  - "helpfully" un-wrapping the tuple before returning when the value
    is known good (`{:ok, x} = result; x` for some callers, full tuple
    for others)

  The fix is to **pick one shape** for the function and split into
  two functions if you need both — typically `foo/N` returning
  `{:ok, _} | {:error, _}` and `foo!/N` returning the value (raising
  on the error path).

  ## Detection

  Collects every return-position expression in the function body
  (last expression, all arm RHSs in `case`/`with`/`if`/`cond`/`try`).
  Classifies each as:

  - **tagged success** — `{:ok, _}` 2-tuple literal
  - **naked value** — anything else that isn't an `{:ok, _}` /
    `{:error, _}` /  bare `:ok` / `:error` atom

  The function is flagged if **both** classes appear among its
  returns. The normal `{:ok, _} | {:error, _}` and `:ok | :error`
  patterns are NOT flagged (both tagged).

  ## Limitations

  - Function-call returns (`foo(x)`) can't be classified without
    types — they're treated as opaque and don't push the function
    into either bucket.
  - Multi-clause functions are scanned per-clause; mixed returns
    across clauses also flag.
  - Nested branches contribute their leaf returns, but if the leaf is
    a recursive call back into the same function, it's opaque.

  ## Bad

      def fetch(id, opts \\\\ []) do
        case do_fetch(id) do
          {:ok, x} ->
            if opts[:raw], do: x, else: {:ok, x}    # mixed!
          err ->
            err
        end
      end

  ## Good — split into two functions

      def fetch(id), do: do_fetch(id)
      def fetch!(id) do
        case do_fetch(id) do
          {:ok, x} -> x
          {:error, e} -> raise "fetch failed: " <> inspect(e)
        end
      end
  """

  use CredenceRules.Rule

  @impl true
  def priority, do: 250

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {kind, meta, [head, [{:do, body}]]} = node, acc when kind in [:def, :defp] ->
          case classify_function_returns(body) do
            :mixed -> {node, [build_issue(meta, head) | acc]}
            _ -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    issues
    |> Enum.uniq_by(& &1.meta.line)
    |> Enum.sort_by(& &1.meta.line)
  end

  # Walks the function body and collects every "return-position"
  # expression. Classifies as `:tagged`, `:naked`, or `:opaque`, then
  # decides whether the mix is anti-pattern-worthy.
  defp classify_function_returns(body) do
    tags = collect_return_tags(body)

    if :tagged in tags and :naked in tags, do: :mixed, else: :consistent
  end

  # Returns a list of return-class atoms (`:tagged`, `:naked`, `:opaque`)
  # — one per return-position expression in the body.
  defp collect_return_tags(body) do
    body
    |> tail_expressions()
    |> Enum.map(&classify_expr/1)
    |> Enum.reject(&(&1 == :opaque))
  end

  # Tail expressions: the value(s) that the function ultimately produces.
  # For a block, that's the last expression. For a case/with/if/cond, it's
  # the RHS of each branch.
  defp tail_expressions({:__block__, _, stmts}) when stmts != [],
    do: stmts |> List.last() |> tail_expressions()

  defp tail_expressions({:case, _, [_subject, [{:do, arms}]]}),
    do: Enum.flat_map(arms, fn {:->, _, [_pat, rhs]} -> tail_expressions(rhs) end)

  defp tail_expressions({:cond, _, [[{:do, arms}]]}),
    do: Enum.flat_map(arms, fn {:->, _, [_cond, rhs]} -> tail_expressions(rhs) end)

  defp tail_expressions({:if, _, [_cond, branches]}) when is_list(branches),
    do: if_branches(branches)

  defp tail_expressions({:unless, _, [_cond, branches]}) when is_list(branches),
    do: if_branches(branches)

  defp tail_expressions({:with, _, args}) when is_list(args) do
    case List.last(args) do
      [{:do, do_body} | rest] ->
        do_returns = tail_expressions(do_body)

        else_returns =
          case Keyword.get(rest, :else, []) do
            arms when is_list(arms) ->
              Enum.flat_map(arms, fn
                {:->, _, [_pat, rhs]} -> tail_expressions(rhs)
                _ -> []
              end)

            _ ->
              []
          end

        do_returns ++ else_returns

      _ ->
        []
    end
  end

  defp tail_expressions({:try, _, [clauses]}) when is_list(clauses) do
    do_returns = clauses |> Keyword.get(:do) |> tail_expressions()

    rescue_returns =
      case Keyword.get(clauses, :rescue, []) do
        arms when is_list(arms) ->
          Enum.flat_map(arms, fn
            {:->, _, [_pat, rhs]} -> tail_expressions(rhs)
            _ -> []
          end)

        _ ->
          []
      end

    do_returns ++ rescue_returns
  end

  defp tail_expressions(other), do: [other]

  # Helper: distinguish "no branch" from "branch is literally nil". Without
  # an `else`, the implicit value of the absent branch is `nil` — and that's
  # a real return-position value the rule should see.
  defp if_branches(branches) do
    do_branches =
      if Keyword.has_key?(branches, :do),
        do: [Keyword.get(branches, :do)],
        else: []

    else_branches =
      if Keyword.has_key?(branches, :else),
        do: [Keyword.get(branches, :else)],
        else: [nil]

    Enum.flat_map(do_branches ++ else_branches, &tail_expressions/1)
  end

  # Any 2-element tuple `{atom, _}` where atom is a non-nil tag —
  # `{:ok, x}`, `{:error, e}`, `{:noreply, state}`, `{:reply, _, _}`, etc.
  defp classify_expr({atom, _value}) when is_atom(atom) and not is_nil(atom),
    do: :tagged

  # 3+-element tagged tuples: `{:ok, x, y}` / `{:noreply, state, _}` /
  # `{:stop, reason, reply, state}` etc. parse via the `:{}` AST node.
  defp classify_expr({:{}, _, [head | _]}) when is_atom(head) and not is_nil(head),
    do: :tagged

  # Bare atoms used as control / status sentinels — `:ok`, `:error`,
  # `:ignore` (GenServer init), `:stop`, `:cont`, `:halt`, custom
  # success atoms. Exclude `true`/`false` (boolean returns are a
  # different smell — boolean obsession, not return-shape) and `nil`
  # (handled above as :naked because it's the silent-failure case).
  defp classify_expr(atom) when is_atom(atom) and atom not in [nil, true, false],
    do: :tagged

  # Bare nil — counts as naked (since it's the silent-failure case the
  # rule warns about).
  defp classify_expr(nil), do: :naked
  # Struct literal: `%Foo{…}` → `{:%, _, [alias, map]}`. Naked.
  defp classify_expr({:%, _, [_alias, _map]}), do: :naked
  # Map literal: `%{…}` → `{:%{}, _, [...]}`. Naked.
  defp classify_expr({:%{}, _, _}), do: :naked
  # Bare variables (and 0-arity local calls — they're ambiguous in AST):
  # `{name, _, ctx}` where ctx is an atom (a variable context). Opaque —
  # we can't tell what shape it'll have without types.
  defp classify_expr({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: :opaque
  # Function calls: `foo(...)` → `{foo, _, [arg1, ...]}`. Opaque.
  defp classify_expr({fun, _, args}) when is_atom(fun) and is_list(args), do: :opaque
  # Remote calls: `Foo.bar(args)` → `{{:., _, _}, _, _}`. Opaque.
  defp classify_expr({{:., _, _}, _, _}), do: :opaque
  # Anything else literal (numbers, strings, lists, structs, other atoms) is naked.
  defp classify_expr(_), do: :naked

  defp build_issue(meta, head) do
    name_arity =
      case head do
        {:when, _, [{name, _, args}, _]} when is_atom(name) and is_list(args) ->
          "#{name}/#{length(args)}"

        {name, _, args} when is_atom(name) and is_list(args) ->
          "#{name}/#{length(args)}"

        # 0-arity def: `def foo, do: body` parses with `args = nil`.
        {name, _, nil} when is_atom(name) ->
          "#{name}/0"

        _ ->
          "function"
      end

    %Issue{
      rule: :alternative_return_types,
      message:
        "`#{name_arity}` mixes tagged-tuple returns (`{:ok, _}`/`{:error, _}`) " <>
          "with naked-value returns. Callers have to pattern-match both " <>
          "shapes, and one of them always gets forgotten. Split into " <>
          "`foo/N` (returns `{:ok, _} | {:error, _}`) and `foo!/N` (returns " <>
          "the value, raises on the error path).",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
