# credence-file:repeated_subtree_in_module — this module is an AST pattern
#   matcher whose check/2 + Macro.prewalk + build_issue shape is the Rule
#   contract itself, so the structural duplication is inherent to the form
#   rather than a smell
defmodule CredenceRules.Pattern.StaleReferenceComment do
  @moduledoc """
  Comment rule: flags backward-looking references that decay as the
  codebase evolves — PR/issue/commit numbers, version markers, "fixed
  in / regression from / previously / originally" narration.

  Comments should describe the **current** code. A comment like
  `# fixed in PR #34` was useful for the duration of one code review;
  by the time someone reads it months later, the PR has merged, the
  bug is forgotten, and the comment exists only to coast someone to a
  closed page on GitHub. The reasoning that made the comment worth
  writing belongs in the PR description or commit message; the source
  file should say what the code does now and why.

  Common offenders (and what they decay into):

  | Comment | What's wrong |
  |---|---|
  | `# fixed in PR #34` | PR closed; meaning lives in a stale URL |
  | `# regression from #46` | Issue closed; what was the regression? |
  | `# see commit abc123` | Hash is opaque; `git blame` already shows it |
  | `# previously this returned nil` | Previously? Read the current code |
  | `# used to call Foo.bar/1` | Used to: not anymore, so don't say it |
  | `# added for the OTA flow` | Couples comment to a specific caller |
  | `# introduced in v0.3` | Version markers age out; rip them |

  ## Bad

      # the bug class behind several PR #34 fixes
      defp validate_chain(...), do: ...

      # see issue #32 for full rationale
      Config.put_env(...)

      # used to filter by status; broadened in #46
      def visible?(record), do: ...

  ## Good — describe the current contract / WHY

      # Validates the full chain against trusted PAA roots. PAA list
      # is reloaded on hot-config update.
      defp validate_chain(...), do: ...

      # Splayed across calls because `Application.compile_env` pins
      # the value at compile time of the build node.
      Config.put_env(...)

  ## Detection

  Each pattern below is matched case-insensitively as a substring of a
  `#` comment line. If the comment line is allow-listed (TODO / FIXME /
  HACK / tool pragmas) it's skipped — `no_todo_or_roadmap_comment`
  owns those.

  - Explicit PR / pull request references (`PR #34`, `pull request 34`)
  - Issue / ticket references (`issue #32`, `ticket 123`)
  - `see #NN` / `see PR …` / `see issue …` / `see commit …`
  - `fixed in / for / by`, `broken in / by`, `regression from`,
    `introduced in / by`, `added for / in / when`
  - Commit-SHA references (`commit abc123`, 7+ hex chars)
  - Version markers (`v0.3`, `since v…`, `before v…`, `removed in v…`)
  - Past-tense narration:
    - `previously|originally|formerly` followed by a narrative subject
      (`we|it|this|they|i`) or a narrative past-tense verb (`returned`,
      `called`, `was`, `handled`, `sent`, `tried`, `used`, `invoked`,
      `raised`, `threw`, `set`, `cleared`, `received`, `fetched`,
      `saved`, `loaded`, `computed`, `checked`, `validated`, `matched`,
      `broke`, `deleted`, `removed`, `wrote`, `added`, `spawned`,
      `crashed`).
    - `we|it|this|they|i` followed by `used to` (e.g. *"we used to call
      Bar.baz/1"*).
    - `used to` followed by a code-action verb (`call`, `invoke`,
      `return`, `raise`, `throw`, `handle`, `do`, `be`, `fire`, `emit`,
      `set`, `clear`, `crash`, `loop`, `spawn`, `allocate`, `free`,
      `trigger`, `deadlock`, `fail`, `panic`).

    Adjectival past-participles describing domain state are NOT flagged
    — *"previously commissioned device"*, *"previously-authenticated
    message"*, *"key used to publish udp_pid"* are domain vocabulary,
    not narration about past code.

  Advisory tier — `mix credence.check --strict` does not fail on
  these. A code reviewer should still ask "is the reader served by
  this comment in six months?"
  """

  use CredenceRules.Rule

  @keeper_keywords ~w(TODO FIXME HACK NOTE SAFETY WARN BUG XXX PERF)

  @tool_keywords ~w(credo: dialyzer: sobelow: coveralls noinspection elixir-ls ExUnit)

  # Narrative subjects — pronouns that signal someone is talking about
  # past behaviour of code, not about a state of a domain object.
  @narrative_subjects ~w(we it this that they i)

  # Past-tense verbs that describe code behaviour. `previously` +
  # `returned`, or `originally` + `called`, are narration patterns.
  # `previously` + `commissioned` (a domain adjective preceding
  # `device`) is not, so domain-adjective verbs aren't in this list.
  @narrative_past_verbs ~w(
    returned called did was were handled sent tried used invoked raised
    threw defined stored set cleared received fetched saved loaded
    computed checked validated matched broke deleted removed wrote
    added spawned crashed
  )

  # Verbs that, after `used` + `to`, indicate narration about old code.
  # `used` + `to` + `call` is narration; `used` + `to` + `publish`
  # (passive description of a key's purpose) is not in this list.
  @used_to_action_verbs ~w(
    call invoke return raise throw handle do be fire emit set clear
    crash loop spawn allocate free trigger deadlock fail panic
  )

  @patterns [
    {~r/\b(pr|pull[\s\-]request)\s*#?\s*\d+\b/i, "PR/pull request reference"},
    {~r/\b(issue|ticket)\s+#?\s*\d+\b/i, "issue/ticket reference"},
    {~r/\bsee\s+(#\d+|pr\b|issue\b|ticket\b|commit\b|gh-\d+)/i, "see-reference"},
    {~r/\b(fixed|broken|regression|introduced|added|removed|reverted)\s+(in|by|from|for|when)\b/i,
     "history-trail reference"},
    {~r/\bcommit\s+[0-9a-f]{7,40}\b/i, "commit-SHA reference"},
    {~r/\b(since|before|after|removed\s+in|added\s+in|introduced\s+in)\s+v\d+(\.\d+)*/i, "version reference"},
    {Regex.compile!(
       "\\b(previously|originally|formerly)\\s+(#{Enum.join(@narrative_subjects, "|")})\\b",
       "i"
     ), "past-tense narration"},
    {Regex.compile!(
       "\\b(previously|originally|formerly)\\s+(#{Enum.join(@narrative_past_verbs, "|")})\\b",
       "i"
     ), "past-tense narration"},
    {Regex.compile!(
       "\\b(#{Enum.join(@narrative_subjects, "|")})\\s+used\\s+to\\b",
       "i"
     ), "past-tense narration"},
    {Regex.compile!(
       "\\bused\\s+to\\s+(#{Enum.join(@used_to_action_verbs, "|")})\\b",
       "i"
     ), "past-tense narration"}
  ]

  @impl true
  def priority, do: 350

  @impl true
  def check(_ast, opts) do
    source = Keyword.get(opts, :source, "")

    source
    |> CredenceRules.CommentScan.extract()
    |> Enum.flat_map(fn %{line: line_no, body: body} ->
      with false <- keeper_keyword?(body),
           false <- tool_directive?(body),
           {regex, label} when not is_nil(regex) <- find_match(body) do
        [build_issue(line_no, label, body, regex)]
      else
        _ -> []
      end
    end)
  end

  defp keeper_keyword?(body), do: Enum.any?(@keeper_keywords, &String.contains?(body, &1))
  defp tool_directive?(body), do: Enum.any?(@tool_keywords, &String.contains?(body, &1))

  defp find_match(body) do
    Enum.find(@patterns, {nil, nil}, fn {regex, _label} -> Regex.match?(regex, body) end)
  end

  defp build_issue(line_no, label, body, _regex) do
    %Issue{
      rule: :stale_reference_comment,
      message:
        "Comment contains a #{label} — decays as the codebase evolves. " <>
          "Move the reasoning into the PR description or rewrite the comment to " <>
          "describe the current code. Line: #{String.slice(body, 0, 120)}",
      meta: %{line: line_no, label: label}
    }
  end
end
