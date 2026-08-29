defmodule CredenceRules.Pattern.OptionBranchedFunction do
  @moduledoc """
  SRP rule: a function whose `opts` argument is doing manual dispatch
  via `case opts[:mode]` (or equivalent keyword lookup) is two or
  three functions in a trench coat. The opts-as-dispatcher pattern is
  a "configurable function" shape LLMs default to because it sounds
  flexible — but it pushes the branching cost onto every reader of
  every call site.

  Each branch is a distinct semantic; promote each to its own
  function and let the caller pick by name.

  ## Bad

      def go(input, opts \\ []) do
        case Keyword.get(opts, :mode) do
          :fast -> do_fast(input)
          :safe -> do_safe(input)
          :paranoid -> do_paranoid(input)
        end
      end

      # callers
      go(input, mode: :fast)
      go(input, mode: :safe)

  Every call site has a magic atom; every reader of `go/2` has to
  hold the case branches in their head.

  ## Good

      def go_fast(input), do: ...
      def go_safe(input), do: ...
      def go_paranoid(input), do: ...

      # callers
      go_fast(input)
      go_safe(input)

  Each mode is now a named function with its own typespec, docs, and
  call-graph.

  ## Detection

  Flags a `def` / `defp` when ALL of:

  1. It declares an `opts` parameter (a parameter named `opts`,
     `options`, or `config`, possibly with a default `\\ []` or
     `\\ %{}`).
  2. Its body's top-level expression is a `case` whose subject is a
     `Keyword.get(opts, key)` / `opts[key]` / `Keyword.fetch!(opts,
     key)` lookup against that opts parameter.
  3. The `case` has 3+ non-wildcard clauses (2-arm dispatch isn't
     usually worth splitting; 3+ is a real fan-out).

  ## Why advisory

  Some legitimate uses exist (genuinely-orthogonal flags like
  `debug:` or `verbose:` aren't dispatch). The rule targets the
  "mode" / "strategy" pattern specifically.
  """

  use CredenceRules.Rule

  @hint """
  Split into one function per mode. Callers pick by name:

      # Before — runtime dispatch on an opt
      def go(opts) do
        case Keyword.get(opts, :mode) do
          :fast -> fast_path()
          :safe -> safe_path()
          :debug -> debug_path()
        end
      end

      # After — one named function per mode
      def go_fast, do: fast_path()
      def go_safe, do: safe_path()
      def go_debug, do: debug_path()

  Each variant gets its own docstring, typespec, and call-graph
  entry. Callers self-document at the call site.
  """

  @carve_outs [
    "When the modes ARE the same operation parameterised by a single knob (`format: :json | :csv | :xml` on a serializer), keep the dispatch — it's coherent variation, not dispatch by name.",
    "Behaviour-callback dispatch (`init/1` of a Supervisor branching on opts[:strategy]) — convention, not a smell.",
    "Confidence is :medium — heuristic. Reviewer: does this `case` represent unrelated code paths (split it) or one operation with a parameter (leave it)?"
  ]

  alias CredenceRules.AstKeyword

  @opts_param_names ~w(opts options config)a
  @min_clauses 3

  @impl true
  def priority, do: 430

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {kind, meta, [head, kw]} = node, acc when kind in [:def, :defp] and is_list(kw) ->
          case AstKeyword.get(kw, :do) do
            nil ->
              {node, acc}

            body ->
              with {:ok, opts_name} <- opts_param(head),
                   {:ok, clause_count} <- dispatch_case?(body, opts_name) do
                {node, [build_issue(meta, opts_name, clause_count) | acc]}
              else
                _ -> {node, acc}
              end
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  # Find an `opts`/`options`/`config` parameter in the head.
  defp opts_param({:when, _, [inner, _guard]}), do: opts_param(inner)

  defp opts_param({_name, _meta, params}) when is_list(params) do
    params
    |> Enum.map(&unwrap_default_param/1)
    |> Enum.find_value(:error, fn
      {name, _, ctx} when name in @opts_param_names and is_atom(ctx) -> {:ok, name}
      _ -> nil
    end)
  end

  defp opts_param(_), do: :error

  # `\\` default-arg wraps: `{:\\, _, [param, _default]}`.
  defp unwrap_default_param({:\\, _, [inner, _default]}), do: inner
  defp unwrap_default_param(other), do: other

  # Body is a `case Keyword.get(opts, key)` (etc.) with 3+ clauses.
  defp dispatch_case?({:__block__, _, [single]}, opts_name), do: dispatch_case?(single, opts_name)

  defp dispatch_case?({:case, _, [subject, kw]}, opts_name) when is_list(kw) do
    with true <- keyword_lookup_on?(subject, opts_name),
         clauses when is_list(clauses) <- AstKeyword.get(kw, :do),
         count when count >= @min_clauses <- count_non_wildcard_clauses(clauses) do
      {:ok, count}
    else
      _ -> :error
    end
  end

  defp dispatch_case?(_, _), do: :error

  # `Keyword.get(opts, key)` — 2 or 3 args.
  defp keyword_lookup_on?(
         {{:., _, [{:__aliases__, _, [:Keyword]}, fun]}, _, [{name, _, ctx} | _rest]},
         name
       )
       when fun in [:get, :fetch, :fetch!] and is_atom(ctx),
       do: true

  # `opts[:key]` — `Access.get/2` macro expands to this shape.
  defp keyword_lookup_on?(
         {{:., _, [Access, :get]}, _, [{name, _, ctx}, _key]},
         name
       )
       when is_atom(ctx),
       do: true

  # Sourceror-parsed `opts[:key]` shape (different sugar).
  defp keyword_lookup_on?(
         {{:., _, [{name, _, ctx}, _key_or_call]}, _meta, _},
         name
       )
       when is_atom(ctx),
       do: true

  defp keyword_lookup_on?(_, _), do: false

  defp count_non_wildcard_clauses(clauses) do
    Enum.count(clauses, fn
      {:->, _, [[{:_, _, ctx}], _body]} when is_atom(ctx) -> false
      {:->, _, [[_pat], _body]} -> true
      _ -> false
    end)
  end

  defp build_issue(meta, opts_name, clause_count) do
    %Issue{
      rule: :option_branched_function,
      message:
        "Function uses `case Keyword.get(#{opts_name}, …)` with #{clause_count} branches " <>
          "for dispatch. The `#{opts_name}` argument is doing dispatch by atom — split " <>
          "into one function per mode (e.g. `go_fast/1`, `go_safe/1`) and let callers " <>
          "pick by name. Each branch gets its own docs, typespec, and call-graph.",
      meta: %{line: Keyword.get(meta, :line), opts_param: opts_name, clauses: clause_count}
    }
  end
end
