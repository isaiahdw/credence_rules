defmodule CredenceRules.Pattern.CaseDestructureShouldBeFunctionClause do
  @moduledoc """
  Idiom rule: a function whose whole body is a two-arm `case` that
  destructures one input and falls through to a simple error — the LLM
  habit of writing pattern-matching as a `case` instead of using
  function-head clauses.

  ## Bad

      defp read_rr_header(packet, off) do
        case packet do
          <<_::binary-size(off), type::16, class_raw::16, ttl::32, rdlength::16, _::binary>> ->
            {:ok, %{type: type, class_raw: class_raw, ttl: ttl, rdlength: rdlength}, off + 10}

          _ ->
            {:error, :truncated}
        end
      end

  ## Good — the valid shape lives in the head, the fallback in a clause

      defp read_rr_header(
             <<_::binary-size(off), type::16, class_raw::16, ttl::32, rdlength::16, _::binary>>,
             off
           ) do
        {:ok, %{type: type, class_raw: class_raw, ttl: ttl, rdlength: rdlength}, off + 10}
      end

      defp read_rr_header(_packet, _off), do: {:error, :truncated}

  Binary parsers read best when the valid wire shape is expressed in
  the function head and a fallback clause handles truncation.

  ## Detection

  Flags a `def` / `defp` / `defmacro` / `defmacrop` whose body is
  **exactly** a `case` (no statements before or after) where ALL of:

  1. The `case` has **exactly two** arms.
  2. One arm's pattern is a **destructuring pattern** — a binary
     (`<<…>>`), tuple, map, struct, or list pattern that **binds at
     least one variable** (extracts data). A bare value match
     (`:ok`, a literal) is not destructuring.
  3. The other arm is the wildcard `_` (no guard).
  4. The fallback (wildcard) body is a **simple value** — `{:error,
     reason}`, `nil`, `false`, `:error`, `[]` — with no calls or
     side effects (see `CredenceRules.AstClassify.pure_data?/1`).
  5. The `case` subject is a **plain variable** (a parameter), not a
     function call or a transformed expression.
  6. Neither arm carries a `when` guard.

  ## Relationship to the sibling rules

  - `case_arg_could_be_function_clauses` handles the **3+ clause**
    dispatch table; it deliberately skips two-arm cases.
  - `case_with_single_wildcard_arm` handles the degenerate **one-arm**
    `_ ->` case.

  This rule fills the middle: the two-arm destructure-plus-fallback
  shape, where function clauses are a clear win even though the
  3-clause rule bows out.

  ## NOT flagged

  - 3+ semantic branches (that's `case_arg_could_be_function_clauses`).
  - Subject is a function call or transformed value — splitting heads
    would duplicate the transform.
  - Fallback arm does real work (logs, calls a function, branches).
  - A `when` guard on either arm — moving a complex guard to the head
    can read worse.
  - Pre-work before the case or post-work after it — the `case` isn't
    the whole body, so clauses would scatter the surrounding code.
  - A two-arm value dispatch (`:ok -> …; _ -> …`) — no destructuring,
    nothing to extract into the head.

  ## Why advisory

  Heuristic and a reviewer call: occasionally the explicit `case`
  reads clearer (a descriptive function name, an awkward head). The
  rule targets the narrow, high-confidence parser shape.
  """

  use CredenceRules.Rule

  alias CredenceRules.{AstClassify, AstKeyword}

  @severity :low
  @confidence :medium

  @hint """
  Lift the destructuring pattern into the function head and let a
  fallback clause handle the miss:

      # Before
      defp read_rdata(packet, off, len) do
        case packet do
          <<_::binary-size(off), rdata::binary-size(len), _::binary>> -> {:ok, rdata}
          _ -> {:error, :truncated}
        end
      end

      # After
      defp read_rdata(<<_::binary-size(off), rdata::binary-size(len), _::binary>>, off, len) do
        {:ok, rdata}
      end

      defp read_rdata(_packet, _off, _len), do: {:error, :truncated}

  The valid binary shape is now visible in the head; the fallback
  clause is the truncation case.
  """

  @carve_outs [
    "Subject is a function call or transformed value, not a parameter — splitting into heads would duplicate the transform. Not flagged.",
    "Fallback arm does real work (logging, a function call, branching) — it's not a simple miss. Not flagged.",
    "Either arm has a `when` guard — a complex guard can read worse in the head. Not flagged.",
    "Pre-work before the case or post-work after it — the case isn't the whole body. Not flagged.",
    "3+ branches are `case_arg_could_be_function_clauses`' domain; a single `_ ->` arm is `case_with_single_wildcard_arm`'."
  ]

  @def_kinds [:def, :defp, :defmacro, :defmacrop]

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {kind, _meta, [head, kw]} = node, acc when kind in @def_kinds and is_list(kw) ->
          case smell?(head, kw) do
            {:ok, name, line} -> {node, [build_issue(line, name) | acc]}
            :no -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp smell?(head, kw) do
    with {:ok, _args} <- extract_args(head),
         {:case, case_meta, [subject, case_kw]} <- sole_case(AstKeyword.get(kw, :do)),
         true <- is_list(case_kw),
         true <- variable?(subject),
         clauses when is_list(clauses) <- AstKeyword.get(case_kw, :do),
         [_, _] <- clauses,
         :ok <- destructure_with_fallback?(clauses) do
      {:ok, head_name(head), Keyword.get(case_meta, :line)}
    else
      _ -> :no
    end
  end

  # The case must be the ENTIRE body — directly, or as the sole
  # statement of a block (Sourceror sometimes wraps a single
  # expression). A block with other statements means surrounding work,
  # so it isn't a clean head-pattern rewrite.
  defp sole_case({:case, _, _} = node), do: node
  defp sole_case({:__block__, _, [single]}), do: sole_case(single)
  defp sole_case(_), do: nil

  defp extract_args({:when, _, [inner, _guard]}), do: extract_args(inner)
  defp extract_args({_name, _, args}) when is_list(args), do: {:ok, args}
  defp extract_args(_), do: :no

  # A plain variable node `{name, _meta, context_atom}` — a parameter
  # (the case is the whole body, so it can't be a local binding).
  defp variable?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: true
  defp variable?(_), do: false

  # One arm destructures and binds data; the other is a bare wildcard
  # with a simple fallback value. No guards on either.
  defp destructure_with_fallback?(clauses) do
    with [{p1, b1}, {p2, b2}] <- Enum.map(clauses, &arm/1),
         false <- p1 == :guarded or p2 == :guarded,
         {:ok, _destructure, fallback_body} <- pair(p1, b1, p2, b2),
         true <- AstClassify.pure_data?(fallback_body) do
      :ok
    else
      _ -> :no
    end
  end

  # `{pattern, body}` for a clause, or `{:guarded, nil}` if it carries
  # a `when` guard (which we decline to move into the head).
  defp arm({:->, _, [[{:when, _, _}], _body]}), do: {:guarded, nil}
  defp arm({:->, _, [[pattern], body]}), do: {pattern, body}
  defp arm(_), do: {:other, nil}

  # Return `{:ok, destructure_pattern, fallback_body}` when exactly one
  # arm is the wildcard and the other is a destructuring pattern.
  defp pair(p1, b1, p2, b2) do
    cond do
      wildcard?(p1) and destructuring?(p2) -> {:ok, p2, b1}
      wildcard?(p2) and destructuring?(p1) -> {:ok, p1, b2}
      true -> :no
    end
  end

  defp wildcard?({:_, _, ctx}) when is_atom(ctx), do: true
  defp wildcard?(_), do: false

  # A structural pattern that binds at least one variable — it extracts
  # data, so the shape belongs in the head.
  defp destructuring?(pattern), do: structural?(pattern) and binds_var?(pattern)

  defp structural?({:<<>>, _, _}), do: true
  defp structural?({:%{}, _, _}), do: true
  defp structural?({:%, _, _}), do: true
  defp structural?({:{}, _, _}), do: true
  defp structural?({:|, _, _}), do: true
  defp structural?({_left, _right}), do: true
  defp structural?(list) when is_list(list) and list != [], do: true
  defp structural?({:=, _, [left, right]}), do: structural?(left) or structural?(right)
  defp structural?(_), do: false

  defp binds_var?(pattern) do
    {_ast, bound?} =
      Macro.prewalk(pattern, false, fn
        _node, true -> {[], true}
        {name, _, ctx} = node, false when is_atom(name) and is_atom(ctx) -> {node, name != :_}
        node, false -> {node, false}
      end)

    bound?
  end

  defp head_name({:when, _, [inner, _]}), do: head_name(inner)
  defp head_name({name, _, _}) when is_atom(name), do: name
  defp head_name(_), do: :unknown

  defp build_issue(line, name) do
    %Issue{
      rule: :case_destructure_should_be_function_clause,
      message:
        "`#{name}/n` is a two-arm `case` that only destructures a simple input " <>
          "with a wildcard fallback. Prefer function-head pattern matching with a " <>
          "fallback clause: put the destructuring pattern in the head and handle " <>
          "the miss in `def #{name}(_, …), do: <fallback>`.",
      meta: %{line: line, function: name}
    }
  end
end
