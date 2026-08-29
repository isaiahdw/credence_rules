defmodule CredenceRules.Pattern.NestedCallsShouldPipe do
  @moduledoc """
  Composability rule: three or more function calls nested through the
  **first argument** thread one value inside-out. A pipe reads the same
  steps top-to-bottom.

  ## Bad

      Enum.map(Enum.filter(Enum.uniq(list), &active?/1), & &1.name)

  You read it inside-out: `uniq`, then `filter`, then `map`.

  ## Good

      list
      |> Enum.uniq()
      |> Enum.filter(&active?/1)
      |> Enum.map(& &1.name)

  Each transformation is visible in execution order, and adding or
  removing a step is a one-line edit.

  ## Detection

  Flags a call whose first argument is a call whose first argument is a
  call — a chain of ≥ `:min_pipe_depth` (default 3) calls threaded
  through the **first** argument position, which is exactly what `|>`
  rewrites. Two kinds of call count: local calls (`foo(...)`) and
  remote calls on a module alias (`Mod.fun(...)`).

  Only the outermost call of a chain is reported (the inner links are
  part of the same finding).

  ## NOT flagged

  - **Two-deep nesting** (`foo(bar(x))`) — reads fine; the pipe earns
    its keep at three stages.
  - **Operators and control-flow** — `a + b + c`, `if/case/with/for`,
    `&` captures, comprehensions, and data constructors (`%{}`, `{}`,
    `<<>>`) aren't function-call chains and aren't pipeable.
  - **Definition forms** — `def`, `defmodule`, `defstruct`, `use`, …
  - **Non-first-arg threading** — `g(other, h(x))`. The value is the
    *second* argument, so `|>` can't thread it without `then/2`; that's
    a different (and weaker) rewrite, so it's left alone.

  ## Why advisory

  Heuristic and partly taste — some three-deep nestings read fine, and
  a `Map.new(Enum.map(...))` may be clearer than its pipe to some
  readers. Reviewer call. Pairs with `single_stage_pipe` (don't pipe a
  lone call) as the other half of "use pipes for what they're for".
  """

  use CredenceRules.Rule

  @severity :low
  @confidence :medium

  @default_min_depth 3

  # Atom-form nodes that are NOT function calls we'd thread through a
  # pipe: operators, control-flow / special forms, data constructors,
  # and definition / directive macros. A local call whose head is one
  # of these is left alone.
  @non_pipeable MapSet.new([
                  # operators
                  :+,
                  :-,
                  :*,
                  :/,
                  :==,
                  :!=,
                  :===,
                  :!==,
                  :<,
                  :>,
                  :<=,
                  :>=,
                  :&&,
                  :||,
                  :!,
                  :and,
                  :or,
                  :not,
                  :<>,
                  :++,
                  :--,
                  :in,
                  :..,
                  :..//,
                  :|>,
                  :|,
                  :=,
                  :=~,
                  :"::",
                  :&,
                  :@,
                  :^,
                  :<<<,
                  :>>>,
                  :&&&,
                  :|||,
                  :"^^^",
                  # control-flow / special forms
                  :if,
                  :unless,
                  :case,
                  :cond,
                  :with,
                  :for,
                  :fn,
                  :try,
                  :receive,
                  :when,
                  :->,
                  :__block__,
                  :__aliases__,
                  :%{},
                  :%,
                  :{},
                  :<<>>,
                  :.,
                  :quote,
                  :unquote,
                  :unquote_splicing,
                  :super,
                  :__MODULE__,
                  # definition / directive macros
                  :def,
                  :defp,
                  :defmodule,
                  :defmacro,
                  :defmacrop,
                  :defstruct,
                  :defdelegate,
                  :defguard,
                  :defguardp,
                  :defexception,
                  :defimpl,
                  :defprotocol,
                  :defoverridable,
                  :use,
                  :import,
                  :alias,
                  :require
                ])

  @hint """
  Rewrite the inside-out nesting as a top-to-bottom pipe:

      # Before
      Enum.map(Enum.filter(Enum.uniq(list), &active?/1), & &1.name)

      # After
      list
      |> Enum.uniq()
      |> Enum.filter(&active?/1)
      |> Enum.map(& &1.name)

  Each step reads in execution order. Keep the nested form only when a
  middle step doesn't thread the value as its first argument (a pipe
  would need `then/2`), or when the nesting genuinely reads clearer.
  """

  @carve_outs [
    "Two-deep nesting (`foo(bar(x))`) — a pipe earns its keep at three stages, not two.",
    "Non-first-arg threading (`g(other, h(x))`) — the value isn't the first argument, so `|>` can't thread it without `then/2`.",
    "Operators, control-flow, captures, and data constructors aren't call chains.",
    "Some three-deep nestings read clearly as-is — reviewer call."
  ]

  @impl true
  def check(ast, opts) do
    min_depth = Keyword.get(opts, :min_pipe_depth, @default_min_depth)

    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        # `@name value` parses as `@(name(value))` — the attribute *name*
        # looks like a call wrapping its value. Strip that phantom layer
        # (descend straight into the value) so a 2-deep attribute value
        # isn't miscounted as a 3-deep chain.
        {:@, _, [{attr, _, [val]}]}, acc when is_atom(attr) ->
          {val, acc}

        node, acc ->
          if pipeable_call?(node) and chain_depth(node) >= min_depth do
            # Prune the chain's subtree so inner links of the SAME chain
            # aren't reported again.
            {[], [build_issue(node) | acc]}
          else
            {node, acc}
          end
      end)

    Enum.reverse(issues)
  end

  # Length of the first-argument call chain rooted at `node`.
  defp chain_depth(node) do
    if pipeable_call?(node) do
      case first_arg(node) do
        {:ok, arg} -> 1 + chain_depth(arg)
        :none -> 1
      end
    else
      0
    end
  end

  # `Mod.fun(args)` — remote call on a module alias.
  defp pipeable_call?({{:., _, [{:__aliases__, _, _}, fun]}, _, args})
       when is_atom(fun) and is_list(args),
       do: true

  # `foo(args)` — local call that isn't an operator / special form / def
  # / sigil.
  defp pipeable_call?({name, _, args}) when is_atom(name) and is_list(args),
    do: not MapSet.member?(@non_pipeable, name) and not sigil?(name)

  defp pipeable_call?(_), do: false

  defp sigil?(name), do: name |> Atom.to_string() |> String.starts_with?("sigil_")

  defp first_arg({{:., _, _}, _, [a | _]}), do: {:ok, a}
  defp first_arg({name, _, [a | _]}) when is_atom(name), do: {:ok, a}
  defp first_arg(_), do: :none

  defp build_issue(node) do
    %Issue{
      rule: :nested_calls_should_pipe,
      message:
        "#{label(node)} nests 3+ calls through the first argument — read " <>
          "inside-out. A pipe reads top-to-bottom in execution order: " <>
          "`x |> inner() |> … |> outer()`. (Keep the nesting if a step doesn't " <>
          "thread the value as its first argument.)",
      meta: %{line: call_line(node)}
    }
  end

  defp label({{:., _, [{:__aliases__, _, segs}, fun]}, _, _}),
    do: "`#{Enum.map_join(segs, ".", &Atom.to_string/1)}.#{fun}(...)`"

  defp label({name, _, _}) when is_atom(name), do: "`#{name}(...)`"
  defp label(_), do: "This call"

  defp call_line({{:., meta, _}, _, _}), do: Keyword.get(meta, :line)
  defp call_line({_name, meta, _}), do: Keyword.get(meta, :line)
end
