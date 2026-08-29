defmodule CredenceRules.Pattern.NoTodoOrRoadmapComment do
  @moduledoc """
  Comment rule: flags **forward-looking** work markers — TODO / FIXME /
  HACK / "Phase N" / "follow-up" / "we'll add … later" — that turn
  source files into informal project trackers.

  Companion rules:

  - Backward-looking history (`# fixed in PR #34`, `# previously …`,
    version markers, commit SHAs) is owned by
    `CredenceRules.Pattern.StaleReferenceComment`.
  - Inline narration ("Here we…" / "Now we…" / "Let's…") is owned by
    `CredenceRules.Pattern.NarratorComment`.

  ## Detected forms (case-insensitive)

  - `# TODO[: …]`, `# FIXME[: …]`, `# HACK[: …]`, `# XXX[: …]`
  - `# Phase N` / `# Phase N:` / `# (Phase N)` — roadmap markers that
    rot fast and are invisible to issue trackers
  - `# follow-up` / `# followup` / `# follow up`
  - `# we'll add … later` — narrative commentary that documents intent
    rather than code

  ## Why a linter (and not just code review)?

  These markers degrade silently. A `# TODO` from two years ago might
  describe a feature that shipped, was reverted, or never mattered —
  the comment outlives whichever was true. Source files are not the
  authoritative tracker; the issue tracker is. A lint rule forces the
  author to either (a) do the work now, (b) open an issue and link to
  it without leaving a comment, or (c) suppress the rule with explicit
  justification.

  ## Bad

      # TODO: handle the rate limit case (Phase 2)
      def request(req), do: do_request(req)

      # we'll add retry logic later
      def fetch(id), do: HTTPClient.get(id)

  ## Good

      def request(req), do: do_request(req)        # fix it, ship it, or
                                                   # open an issue and stay quiet

  ## Note on parse strategy

  Comments are not part of the Elixir AST `Code.string_to_quoted/2`
  returns by default. This rule reads the raw `:source` from `opts`
  (always set by `CredenceRules.Pattern.analyze/2`) and scans
  line-by-line. Strings that *contain* `TODO`-like substrings inside
  code (e.g. a `"# TODO"` documentation example) are skipped via a
  simple `String.starts_with?(trimmed, "#")` filter.
  """

  use CredenceRules.Rule

  @patterns [
    {~r/^\s*todo\b/i, "TODO"},
    {~r/^\s*fixme\b/i, "FIXME"},
    {~r/^\s*hack\b/i, "HACK"},
    {~r/^\s*xxx\b/i, "XXX"},
    {~r/^\s*\(?phase\s+\d/i, "Phase N"},
    {~r/^\s*follow[\s\-]?up\b/i, "follow-up"},
    {~r/^\s*we['']ll\s+add\b.+\blater\b/i, "future-work narration"}
  ]

  @impl true
  def priority, do: 700

  @impl true
  def check(_ast, opts) do
    source = Keyword.get(opts, :source, "")

    source
    |> CredenceRules.CommentScan.extract()
    |> Enum.flat_map(fn %{line: line_no, body: body} ->
      # First matching pattern wins — we report one issue per line,
      # not one per matching pattern. A line like `# TODO Phase 2`
      # would otherwise fire twice.
      case Enum.find_value(@patterns, fn {regex, label} ->
             if Regex.match?(regex, body), do: label, else: nil
           end) do
        nil -> []
        label -> [build_issue(line_no, label, body)]
      end
    end)
  end

  defp build_issue(line_no, label, body) do
    %Issue{
      rule: :no_todo_or_roadmap_comment,
      message:
        "Source comment contains a #{label} marker — open an issue (and link " <>
          "to it from the PR, not the source) or do the work now. " <>
          "Line: # #{body}",
      meta: %{line: line_no}
    }
  end
end
