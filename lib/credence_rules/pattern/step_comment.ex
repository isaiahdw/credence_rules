defmodule CredenceRules.Pattern.StepComment do
  @moduledoc """
  Comment rule: flags `# Step N: …` bookkeeping inside a single function.

  When a function needs numbered steps in comments, the steps want to
  be functions. Extracting each step into a well-named function turns
  the sequence into a self-documenting pipeline:

  ## Bad

      def process(data) do
        # Step 1: Validate the input
        validated = validate(data)

        # Step 2: Transform the data
        transformed = transform(validated)

        # Step 3: Save to database
        save(transformed)
      end

  ## Good

      def process(data) do
        data
        |> validate()
        |> transform()
        |> save()
      end

  Ported from
  [`ExSlop.Check.Readability.StepComment`](https://hex.pm/packages/ex_slop).
  """

  use CredenceRules.Rule

  @prefixes ["STEP ", "Step ", "step "]

  @impl true
  def priority, do: 300

  @impl true
  def check(_ast, opts) do
    source = Keyword.get(opts, :source, "")

    source
    |> CredenceRules.CommentScan.extract()
    |> Enum.flat_map(fn %{line: line_no, body: body} ->
      if step_comment?(body), do: [build_issue(line_no, body)], else: []
    end)
  end

  defp step_comment?(body) do
    Enum.any?(@prefixes, &String.starts_with?(body, &1))
  end

  defp build_issue(line_no, body) do
    %Issue{
      rule: :step_comment,
      message:
        ~s("Step N:" comment — extract each step into a well-named function and let the ) <>
          "pipe sequence document the flow. Line: # #{body}",
      meta: %{line: line_no}
    }
  end
end
