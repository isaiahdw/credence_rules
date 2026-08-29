# credence-file:repeated_subtree_in_module — this module is an AST pattern
#   matcher whose check/2 + Macro.prewalk + build_issue shape is the Rule
#   contract itself, so the structural duplication is inherent to the form
#   rather than a smell
defmodule CredenceRules.Pattern.ObviousComment do
  @moduledoc """
  Comment rule: flags short verb-then-article comments that restate the
  next line of code with no technical detail.

  Conservatively defined: only short comments (≤ 60 chars) that begin
  with `<Verb> the/a/an …` and contain no digits, no perf vocabulary,
  no WHY-words. The intent is to catch noise like:

      # Fetch the user
      user = Repo.get(User, id)

      # Create the changeset
      changeset = User.changeset(user, attrs)

  …without flagging comments that genuinely explain HOW or WHY:

      # Fetch the connection from the pool, blocking up to 5s   (has digit + "blocking")
      conn = ConnectionPool.checkout!(pool, timeout: 5_000)

      # Create the changeset because validation runs in the controller
      changeset = build(...)

  ## Detection

  All of:

  1. Comment body starts with a verb from the closed list
     (`Fetch`, `Get`, `Create`, `Build`, `Update`, …) followed by
     `the` / `a` / `an`.
  2. Body length < 60 chars.
  3. No digits (`0..9`) in body.
  4. No technical-detail vocabulary (`timeout`, `blocking`, `because`,
     `since`, `O(`, `N+1`, `concurrent`, `idempotent`, `workaround`, …).
  5. Not a keeper keyword (TODO/FIXME/…) or tool pragma.
  6. Not inside a `\"""...\"""` heredoc — `#` characters inside a
     `@doc`/`@moduledoc`/`@typedoc` example block are documentation
     labels for readers, not source comments.

  Ported from
  [`ExSlop.Check.Readability.ObviousComment`](https://hex.pm/packages/ex_slop).
  """

  use CredenceRules.Rule

  @obvious_verbs ~w(
    Fetch Get Create Build Update Delete Remove Set Parse Convert Validate
    Check Process Handle Format Transform Normalize Calculate Compute Extract
    Initialize Define Assign Store Save Insert Add Return Ensure Verify
    Send Receive Open Close Read Write Load Apply Render Encode Decode
  )

  @articles ~w(the a an)

  @keeper_keywords ~w(TODO FIXME HACK NOTE SAFETY WARN BUG XXX PERF)

  @tool_keywords ~w(credo: dialyzer: sobelow: coveralls noinspection elixir-ls ExUnit)

  @technical_indicators ~w(
    timeout blocking because since avoid prevent concurrent async idempotent
    otherwise necessary compat bootstrap workaround cannot
  ) ++
                          [
                            "due to",
                            "N+1",
                            "O(",
                            "so that",
                            "so we",
                            "in order",
                            "by hand",
                            "can't",
                            "shouldn't",
                            "must not",
                            "not supported"
                          ]

  @max_length 60

  @impl true
  def priority, do: 300

  @impl true
  def check(_ast, opts) do
    source = Keyword.get(opts, :source, "")

    source
    |> CredenceRules.CommentScan.extract()
    |> Enum.flat_map(fn %{line: line_no, body: body} ->
      if obvious?(body), do: [build_issue(line_no, body)], else: []
    end)
  end

  defp obvious?(body) do
    with true <- String.length(body) < @max_length,
         true <- verb_then_article?(body),
         false <- has_digit?(body),
         false <- technical?(body),
         false <- keeper_keyword?(body),
         false <- tool_directive?(body) do
      true
    else
      _ -> false
    end
  end

  defp verb_then_article?(body) do
    case String.split(body, " ", parts: 3) do
      [verb, article | _] -> verb in @obvious_verbs and article in @articles
      _ -> false
    end
  end

  defp has_digit?(body), do: String.match?(body, ~r/[0-9]/)

  defp technical?(body) do
    Enum.any?(@technical_indicators, &String.contains?(body, &1))
  end

  defp keeper_keyword?(body), do: Enum.any?(@keeper_keywords, &String.contains?(body, &1))
  defp tool_directive?(body), do: Enum.any?(@tool_keywords, &String.contains?(body, &1))

  defp build_issue(line_no, body) do
    %Issue{
      rule: :obvious_comment,
      message:
        "Obvious comment restates what the next line does (verb + article, no technical " <>
          "detail). Delete it, or rewrite to explain WHY. Line: # #{body}",
      meta: %{line: line_no}
    }
  end
end
