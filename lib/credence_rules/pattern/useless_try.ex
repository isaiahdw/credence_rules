defmodule CredenceRules.Pattern.UselessTry do
  @moduledoc """
  Shape rule: `try do ... end` without a `rescue`, `catch`, or `after`
  block does nothing useful — it's a wrapper that shapes like
  exception handling but neither catches errors nor runs cleanup.

  LLMs ship these when they're translating from Java / Python "wrap
  it in try-catch" defensive habits without realizing Elixir treats
  unhandled errors at the process boundary (the supervisor's job).

  ## Bad

      try do
        do_work(input)
      end

      try do
        result = compute()
      else
        x -> process(x)
      end

  ## Good — just let it crash

      do_work(input)

  ## Good — `case` on the result if you want to branch

      case compute() do
        x -> process(x)
      end

  ## Why `else` alone isn't enough

  A `try ... else` runs only when `do` evaluates without raising — so
  it always runs when there's no `rescue`/`catch`. It's just a more
  verbose `case` with worse readability. The legitimate uses of `else`
  in `try` are paired with `rescue` or `catch`, where the `else`
  branch handles the success path.

  ## Flagged

  `try` blocks whose options keyword list contains NEITHER `:rescue`,
  `:catch`, nor `:after`. The presence of any of those three makes
  the `try` meaningful and the rule does not fire.
  """

  use CredenceRules.Rule

  alias CredenceRules.AstKeyword

  @impl true
  def priority, do: 500

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:try, meta, [kw]} = node, acc when is_list(kw) ->
          if useless?(kw),
            do: {node, [build_issue(meta) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  # Sourceror wraps the keyword keys; bare `Keyword.has_key?` returns
  # false on every Sourceror-parsed `try` and the rule fires on
  # everything. Use AstKeyword so this works regardless of parser.
  defp useless?(kw) do
    not (AstKeyword.has_key?(kw, :rescue) or
           AstKeyword.has_key?(kw, :catch) or
           AstKeyword.has_key?(kw, :after))
  end

  defp build_issue(meta) do
    %Issue{
      rule: :useless_try,
      message:
        "`try do ... end` with no `rescue` / `catch` / `after` does nothing — drop the " <>
          "`try` (let it crash; the supervisor catches the failure with a real stack " <>
          "trace) or use `case` if you wanted to branch on the result.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
