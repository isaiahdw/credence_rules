defmodule CredenceRules.Pattern.HdOrTlCall do
  @moduledoc """
  Style rule: `hd/1` and `tl/1` are remnants of the imperative
  "get-the-first-element / get-the-rest-of-the-list" mental model.
  Pattern matching expresses the same thing more clearly *and* fails
  predictably on an empty list (instead of raising a generic
  `ArgumentError`).

  ## Bad

      first = hd(list)
      rest = tl(list)

      def process(list) do
        Logger.info("got \#{hd(list)}")
        do_work(tl(list))
      end

  ## Good — pattern match on the function head

      def process([first | rest]) do
        Logger.info("got \#{first}")
        do_work(rest)
      end

  ## Good — pattern match in the body

      [first | rest] = list

  ## Why

  `hd([])` raises `** (ArgumentError) errors were found at the given
  arguments: ...` — which is the same generic error every other `hd/1`
  in the program produces. Pattern matching gives you a `MatchError`
  with the function name and the actual value that failed.

  ## Notes

  - `List.first/1,2` and `List.last/1,2` (which return `nil` / a
    default on empty) are fine — this rule only flags `hd/1` and
    `tl/1`.
  - Guard-friendly siblings (`is_list`, `length`, `match?`) are
    unrelated and not flagged.
  """

  use CredenceRules.Rule

  @impl true
  def priority, do: 350

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:hd, meta, [_arg]} = node, acc ->
          {node, [build_issue(meta, :hd) | acc]}

        {:tl, meta, [_arg]} = node, acc ->
          {node, [build_issue(meta, :tl) | acc]}

        # Fully-qualified Kernel form
        {{:., _, [{:__aliases__, _, [:Kernel]}, :hd]}, meta, [_arg]} = node, acc ->
          {node, [build_issue(meta, :hd) | acc]}

        {{:., _, [{:__aliases__, _, [:Kernel]}, :tl]}, meta, [_arg]} = node, acc ->
          {node, [build_issue(meta, :tl) | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp build_issue(meta, fun) do
    %Issue{
      rule: :hd_or_tl_call,
      message:
        "`#{fun}/1` raises a generic `ArgumentError` on an empty list. Pattern match " <>
          "with `[head | rest]` instead — function-head or `=` — for a clearer match " <>
          "site and an actionable `MatchError` on empty input.",
      meta: %{line: Keyword.get(meta, :line), fun: fun}
    }
  end
end
