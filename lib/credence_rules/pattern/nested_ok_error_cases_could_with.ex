# credence-file:repeated_case_arm_body,repeated_subtree_in_function — this
#   module is an AST pattern matcher whose check/2 + Macro.prewalk + build_issue
#   shape is the Rule contract itself, so the structural duplication is inherent
#   to the form rather than a smell
defmodule CredenceRules.Pattern.NestedOkErrorCasesCouldWith do
  @moduledoc """
  Idiom rule: nested `case` chains over `{:ok, _}` / `{:error,
  _}` are exactly the shape `with` was designed for. When every
  layer's `:error` branch is a passthrough and the `:ok` branch
  is another case of the same shape, the whole thing reads as
  one `with` chain.

  ## Bad

      case fetch_user(id) do
        {:ok, user} ->
          case authorize(user) do
            {:ok, auth} ->
              case create_session(user, auth) do
                {:ok, session} -> {:ok, session}
                {:error, reason} -> {:error, reason}
              end

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end

  Three levels of nesting, three identical error passthroughs.
  The happy path is buried inside ceremony.

  ## Good

      with {:ok, user} <- fetch_user(id),
           {:ok, auth} <- authorize(user),
           {:ok, session} <- create_session(user, auth) do
        {:ok, session}
      end

  `with` short-circuits on the first non-matching clause and
  returns the unmatched value. The default behavior IS the
  error-passthrough.

  ## Detection

  Conservative — only flags the **canonical happy-path
  nesting**:

  - Outer `case` has EXACTLY two clauses: `{:ok, _}` and
    `{:error, _}` (any order)
  - The `:error` clause body is a passthrough — returns
    `{:error, reason}` where `reason` is bound by the pattern,
    OR returns the original `:error` tuple verbatim
  - The `:ok` clause body STARTS WITH another `case` of the
    same shape (one level of nesting is enough to flag)

  Any deviation — error branch with custom logic, multiple
  patterns, intermediate calls between cases — suppresses the
  flag. The rule prefers false negatives over false positives.

  ## NOT flagged

  - Error branches with special handling (`{:error, :timeout} ->
    retry()` etc.)
  - Cases with patterns other than `{:ok, _}` / `{:error, _}`
  - Cases where the `:ok` branch does work BEFORE the nested
    case (those need to keep their structure)
  - Single-level `case` (no nesting) — `with` overhead isn't
    justified

  ## Why advisory + confidence:medium

  The detection is conservative but the rewrite to `with` isn't
  always strictly better — `case` can read clearer when the
  branches have distinct, branch-specific logic. The rule
  catches the canonical \"three identical error returns\"
  ceremony; reviewers can accept cases where the structure is
  intentional.
  """

  use CredenceRules.Rule

  @severity :medium
  @confidence :medium

  @hint """
  Replace nested `case` chains with `with`:

      # Before
      case fetch_user(id) do
        {:ok, user} ->
          case authorize(user) do
            {:ok, auth} -> {:ok, auth}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end

      # After
      with {:ok, user} <- fetch_user(id),
           {:ok, auth} <- authorize(user) do
        {:ok, auth}
      end

  `with` short-circuits on the first non-matching clause and
  returns the unmatched value. The error-passthrough is the
  default — no need to write it explicitly.

  When errors need branch-specific handling:

      with {:ok, user} <- fetch_user(id),
           {:ok, auth} <- authorize(user) do
        {:ok, auth}
      else
        {:error, :not_found} -> :user_missing
        {:error, :forbidden} -> :auth_failed
      end

  Don't force `with` when the error branches have meaningful
  per-step logic — `case` may still read cleaner.
  """

  @carve_outs [
    "Error branches with special handling (`{:error, :timeout} -> retry()`) — the rewrite to `with`'s catch-all error clause loses the per-branch behavior. Not flagged.",
    "`:ok` branch does work BEFORE the nested case (transformation, side effects). `with` chains can't intersperse non-clause statements; rewrite needs care. Not flagged.",
    "Single-level case (no nesting) — `with` overhead isn't justified. Not flagged.",
    "Cases with patterns other than `{:ok, _}` / `{:error, _}` — different shape, different rule. Not flagged."
  ]

  @impl true
  def priority, do: 493

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:case, meta, [_discriminator, [do: clauses]]} = node, acc when is_list(clauses) ->
          if nested_ok_error_chain?(clauses),
            do: {node, [build_issue(meta) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp nested_ok_error_chain?(clauses) do
    case classify_clauses(clauses) do
      {ok_body, _error_var} -> ok_body_starts_with_nested_case?(ok_body)
      :no -> false
    end
  end

  # Two-clause ok/error shape: returns the ok body so the caller
  # can recurse into it looking for a nested `case`.
  defp classify_clauses([_, _] = clauses) do
    case Enum.map(clauses, &parse_clause/1) do
      [{:ok, ok_body}, {:error, error_var, error_body}] ->
        if passthrough_error?(error_var, error_body), do: {ok_body, error_var}, else: :no

      [{:error, error_var, error_body}, {:ok, ok_body}] ->
        if passthrough_error?(error_var, error_body), do: {ok_body, error_var}, else: :no

      _ ->
        :no
    end
  end

  defp classify_clauses(_), do: :no

  # `{:ok, _} -> body` → {:ok, body}
  # `{:error, reason} -> body` → {:error, reason_var, body}
  defp parse_clause({:->, _, [[{:{}, _, [:ok, _, _]}], _body]}), do: :other
  defp parse_clause({:->, _, [[{:ok, _}], body]}), do: {:ok, body}

  defp parse_clause({:->, _, [[{:error, var}], body]}), do: {:error, var, body}

  defp parse_clause(_), do: :other

  # error body is `{:error, var}` where var matches the bound name
  defp passthrough_error?(var, {:error, var}), do: true
  # Or `{:error, _}` literal (no rebinding, just unchanged tuple)
  defp passthrough_error?(_, {:error, _}), do: true
  defp passthrough_error?(_, _), do: false

  # Ok branch starts with another case of the same shape.
  # "Starts with" means: the body IS a case, OR is a __block__
  # whose first statement is a case.
  defp ok_body_starts_with_nested_case?({:case, _, [_, [do: clauses]]}) do
    case classify_clauses(clauses) do
      {_ok_body, _error_var} -> true
      :no -> false
    end
  end

  defp ok_body_starts_with_nested_case?({:__block__, _, [first | _]}) do
    ok_body_starts_with_nested_case?(first)
  end

  defp ok_body_starts_with_nested_case?(_), do: false

  defp build_issue(meta) do
    %Issue{
      rule: :nested_ok_error_cases_could_with,
      message:
        "Nested `case` over `{:ok, _}` / `{:error, _}` chains. Each layer's " <>
          "`:error` branch is a passthrough — exactly what `with` does by " <>
          "default. Rewrite as `with {:ok, x} <- call1(), {:ok, y} <- call2(x) " <>
          "do {:ok, y} end`. Catch-all error handling goes in the `else` block " <>
          "if branch-specific behavior is needed.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
