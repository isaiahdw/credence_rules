defmodule CredenceRules.Pattern.ReraiseWithoutStacktrace do
  @moduledoc """
  Safety rule: `reraise/2,3` exists to re-throw an exception while
  **preserving its original stack trace**. Passing `[]` or `nil` for
  the stacktrace argument silently drops the very thing `reraise`
  exists to keep.

  ## Bad

      try do
        do_work()
      rescue
        e ->
          Logger.error(...)
          reraise e, []
      end

  ## Good

      try do
        do_work()
      rescue
        e ->
          Logger.error(...)
          reraise e, __STACKTRACE__
      end

  ## Detection

  Fires on `reraise(_, [])` and `reraise(_, nil)`. The correct call is
  `reraise(e, __STACKTRACE__)` (or the 3-arg `reraise(kind, reason, stacktrace)`
  form when re-throwing from a `catch`). `__STACKTRACE__` is only valid
  inside a `rescue`/`catch` clause — the compiler already guarantees
  that, so this rule trusts the context and only checks the second arg.
  """

  use CredenceRules.Rule

  @impl true
  def priority, do: 700

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn node, acc ->
        case match_bad_reraise(node) do
          {:ok, meta, kind} -> {node, [build_issue(meta, kind) | acc]}
          :error -> {node, acc}
        end
      end)

    Enum.reverse(issues)
  end

  # reraise(_, []) — 2-arg form with empty list
  defp match_bad_reraise({:reraise, meta, [_e, []]}), do: {:ok, meta, :empty_list}

  defp match_bad_reraise({:reraise, meta, [_e, {:__block__, _, [[]]}]}),
    do: {:ok, meta, :empty_list}

  # reraise(_, nil) — 2-arg form with nil
  defp match_bad_reraise({:reraise, meta, [_e, nil]}), do: {:ok, meta, :nil_arg}

  defp match_bad_reraise({:reraise, meta, [_e, {:__block__, _, [nil]}]}),
    do: {:ok, meta, :nil_arg}

  # reraise(kind, reason, []) — 3-arg form with empty list
  defp match_bad_reraise({:reraise, meta, [_kind, _reason, []]}), do: {:ok, meta, :empty_list}

  defp match_bad_reraise({:reraise, meta, [_kind, _reason, {:__block__, _, [[]]}]}),
    do: {:ok, meta, :empty_list}

  # reraise(kind, reason, nil)
  defp match_bad_reraise({:reraise, meta, [_kind, _reason, nil]}), do: {:ok, meta, :nil_arg}

  defp match_bad_reraise({:reraise, meta, [_kind, _reason, {:__block__, _, [nil]}]}),
    do: {:ok, meta, :nil_arg}

  defp match_bad_reraise(_), do: :error

  defp build_issue(meta, kind) do
    arg = if kind == :empty_list, do: "`[]`", else: "`nil`"

    %Issue{
      rule: :reraise_without_stacktrace,
      message:
        "`reraise(..., #{arg})` drops the stack trace — the whole point of `reraise` is to " <>
          "preserve it. Use `__STACKTRACE__` instead (valid inside any `rescue`/`catch` clause).",
      meta: %{line: Keyword.get(meta, :line), kind: kind}
    }
  end
end
