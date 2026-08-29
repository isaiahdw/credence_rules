# credence-file:repeated_subtree_in_module — this module is an AST pattern
#   matcher whose check/2 + Macro.prewalk + build_issue shape is the Rule
#   contract itself, so the structural duplication is inherent to the form
#   rather than a smell
defmodule CredenceRules.Pattern.NarratorComment do
  @moduledoc """
  Comment rule: flags inline narration in first-person plural ("we") or
  with "Let's" / "Here we" — a hallmark of LLM-generated code that
  describes what the next line does instead of why it does it.

  These comments either restate the code (in which case delete them) or
  document the author's stream of thought (in which case rewrite as
  WHY-comments).

  ## Bad

      # Here we fetch the user from the database
      user = Repo.get!(User, id)

      # Now we validate the input
      changeset = User.changeset(user, attrs)

      # Let's create a new changeset
      changeset = change(user)

  ## Good

      # No comment — the code is self-explanatory:
      user = Repo.get!(User, id)

      # Or, a comment that explains WHY (not flagged):
      # Bypass validation for admin imports; pre-validated upstream.
      Repo.insert!(changeset, skip_validations: true)

  ## Skipped (intentionally not flagged)

  - Lines containing TODO / FIXME / HACK / NOTE / SAFETY / WARN / BUG /
    XXX / PERF — `no_todo_or_roadmap_comment` owns those.
  - Tool pragmas (`# credo:`, `# dialyzer:`, `# sobelow:`, etc.).
  - Comments that contain an explanation indicator (`because`, `since`,
    `due to`, `avoid`, `prevent`, `otherwise`, `so that`, …) — these
    are WHY-comments doing exactly what we want.

  Ported from
  [`ExSlop.Check.Readability.NarratorComment`](https://hex.pm/packages/ex_slop).
  """

  use CredenceRules.Rule

  @narrator_starts [
    "Here we",
    "Now we",
    "Let's",
    "Lets",
    "Next we",
    "Next, we",
    "Finally we",
    "Finally, we",
    "First we",
    "First, we",
    "Then we",
    "Then, we"
  ]

  @keeper_keywords ~w(TODO FIXME HACK NOTE SAFETY WARN BUG XXX PERF)

  @tool_keywords ~w(credo: dialyzer: sobelow: coveralls noinspection elixir-ls ExUnit)

  @explanation_indicators ~w(
    because since avoid prevent otherwise ensure necessary workaround compat bootstrap
  ) ++
                            [
                              "due to",
                              "in order",
                              "so that",
                              "so we",
                              "in case",
                              "need to handle",
                              "not supported",
                              "cannot",
                              "can't",
                              "shouldn't",
                              "must not"
                            ]

  @max_length 80

  @impl true
  def priority, do: 350

  @impl true
  def check(_ast, opts) do
    source = Keyword.get(opts, :source, "")

    source
    |> CredenceRules.CommentScan.extract()
    |> Enum.flat_map(fn %{line: line_no, body: body} ->
      if narrator?(body), do: [build_issue(line_no, body)], else: []
    end)
  end

  defp narrator?(body) do
    with true <- String.length(body) <= @max_length,
         true <- narrator_start?(body),
         false <- keeper_keyword?(body),
         false <- tool_directive?(body),
         false <- explanation?(body) do
      true
    else
      _ -> false
    end
  end

  defp narrator_start?(body), do: Enum.any?(@narrator_starts, &String.starts_with?(body, &1))
  defp keeper_keyword?(body), do: Enum.any?(@keeper_keywords, &String.contains?(body, &1))
  defp tool_directive?(body), do: Enum.any?(@tool_keywords, &String.contains?(body, &1))
  defp explanation?(body), do: Enum.any?(@explanation_indicators, &String.contains?(body, &1))

  defp build_issue(line_no, body) do
    %Issue{
      rule: :narrator_comment,
      message:
        "Narrator comment (\"Here we…\" / \"Now we…\" / \"Let's…\") restates what the next " <>
          "line does. Delete it, or rewrite to explain WHY (because / since / avoid / …). " <>
          "Line: # #{body}",
      meta: %{line: line_no, body: body}
    }
  end
end
