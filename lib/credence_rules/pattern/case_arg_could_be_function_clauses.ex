defmodule CredenceRules.Pattern.CaseArgCouldBeFunctionClauses do
  @moduledoc """
  Idiom rule: a function that immediately `case`s on one of its
  arguments — and does NOTHING else — is just function-head
  pattern matching with extra ceremony.

  ## Bad

      def handle(event) do
        case event do
          {:opened, id} -> handle_opened(id)
          {:closed, id} -> handle_closed(id)
          {:updated, id, attrs} -> handle_updated(id, attrs)
          _ -> :ignore
        end
      end

  The function does one thing: dispatch on event's shape. The
  `def handle(event) do; case event do ... end; end` wrapper is
  pure noise — Elixir gives you multi-clause function heads for
  exactly this.

  ## Good

      def handle({:opened, id}), do: handle_opened(id)
      def handle({:closed, id}), do: handle_closed(id)
      def handle({:updated, id, attrs}), do: handle_updated(id, attrs)
      def handle(_), do: :ignore

  Each shape gets its own clause. Reads as a dispatch table;
  each clause is independently inspectable; pattern matches
  show up in module docs.

  ## When `case` is still right

  This rule deliberately scopes to the **case-is-the-entire-body**
  shape. Cases where setup happens before the case, or where
  the function does work after, are kept:

      def handle(event) do
        log(:received, event)         # ← pre-case work
        case event do
          {:opened, id} -> :open
          _ -> :ignore
        end
      end

  ## Detection

  Flags `def`/`defp`/`defmacro`/`defmacrop` heads where:

  1. Function body is EXACTLY a `case` (no other statements
     before or after)
  2. The case discriminator is an argument to the function
  3. The case has 3+ clauses (avoids flagging tiny 1-2 branch
     dispatches where the case may read clearer)

  ## NOT flagged

  - Function does pre-work before the case
  - Function does post-work after the case
  - The case discriminator is NOT an arg (transformed value,
    function call, etc.)
  - Fewer than 3 clauses — small cases often read fine inline

  ## Why advisory + severity:low

  Reviewer call. Heuristic — sometimes the explicit `case` is
  the clearer shape (especially with descriptive function names
  that explain WHAT is being dispatched).
  """

  use CredenceRules.Rule

  alias CredenceRules.AstKeyword

  @severity :low
  @confidence :medium

  @hint """
  Replace the inline `case` with multi-clause function heads:

      # Before
      def handle(event) do
        case event do
          {:opened, id} -> handle_opened(id)
          {:closed, id} -> handle_closed(id)
          {:updated, id, attrs} -> handle_updated(id, attrs)
          _ -> :ignore
        end
      end

      # After
      def handle({:opened, id}), do: handle_opened(id)
      def handle({:closed, id}), do: handle_closed(id)
      def handle({:updated, id, attrs}), do: handle_updated(id, attrs)
      def handle(_), do: :ignore

  Each pattern is independently inspectable, shows up in
  module docs, and IDEs can find / jump-to each clause.

  Keep the inline `case` when:
  - The function does setup work BEFORE branching
  - The branches share local bindings created above the case
  - The function name describes the OPERATION rather than the
    dispatch (e.g., `def normalize_event(event)` reads cleaner
    with a single body than as four `def normalize_event(...)`
    heads)
  """

  @carve_outs [
    "Function does pre-work or post-work around the case — keeping the case preserves the structure. Not flagged.",
    "Case discriminator is not a function arg (a transformed value, a function call) — splitting into heads would duplicate the transform. Not flagged.",
    "Fewer than 3 clauses — small cases often read clearer inline. Not flagged.",
    "Functions whose name describes an OPERATION more than a DISPATCH — `normalize_event/1` may read clearer than four `def normalize_event(...)` heads. Reviewer call."
  ]

  @default_min_clauses 3

  @impl true
  def priority, do: 494

  @impl true
  def check(ast, opts) do
    min_clauses = Keyword.get(opts, :min_clauses, @default_min_clauses)

    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {def_kind, _meta, [head, kw]} = node, acc
        when def_kind in [:def, :defp, :defmacro, :defmacrop] and is_list(kw) ->
          case smell?(head, kw, min_clauses) do
            {:ok, name, line} -> {node, [build_issue(line, name) | acc]}
            :no -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp smell?(head, kw, min_clauses) do
    body = AstKeyword.get(kw, :do)

    with {:ok, args} <- extract_args(head),
         true <- not is_nil(body),
         {:case, case_meta, [discriminator, [do: clauses]]} <- body,
         true <- is_list(clauses),
         true <- length(clauses) >= min_clauses,
         true <- discriminator_in_args?(discriminator, args) do
      {:ok, head_name(head), Keyword.get(case_meta, :line)}
    else
      _ -> :no
    end
  end

  # `when`-guarded head: unwrap and recurse into the inner head.
  defp extract_args({:when, _, [inner, _guard]}), do: extract_args(inner)

  defp extract_args({_name, _, args}) when is_list(args), do: {:ok, args}

  defp extract_args(_), do: :no

  defp discriminator_in_args?(discriminator, args) do
    normalized = normalize(discriminator)
    Enum.any?(args, fn arg -> normalize(arg) == normalized end)
  end

  defp head_name({:when, _, [inner, _]}), do: head_name(inner)
  defp head_name({name, _, _}) when is_atom(name), do: name
  defp head_name(_), do: :unknown

  defp normalize(ast) do
    Macro.prewalk(ast, fn node ->
      Macro.update_meta(node, fn _ -> [] end)
    end)
  end

  defp build_issue(line, name) do
    %Issue{
      rule: :case_arg_could_be_function_clauses,
      message:
        "`def #{name}(arg) do; case arg do ...; end; end` — the function does " <>
          "nothing but dispatch on `arg`. Split into multi-clause function heads: " <>
          "`def #{name}(<pattern1>), do: ...; def #{name}(<pattern2>), do: ...`. " <>
          "Each pattern is independently inspectable. Keep the inline case if " <>
          "the function does pre-work before branching.",
      meta: %{line: line, function: name}
    }
  end
end
