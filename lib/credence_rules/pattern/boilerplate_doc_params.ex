# credence-file:repeated_subtree_in_module — this module is an AST pattern
#   matcher whose check/2 + Macro.prewalk + build_issue shape is the Rule
#   contract itself, so the structural duplication is inherent to the form
#   rather than a smell
defmodule CredenceRules.Pattern.BoilerplateDocParams do
  @moduledoc """
  Doc rule: flags `@doc` strings with a `## Parameters` / `## Args`
  section that lists conventional Phoenix arg names (`conn`, `params`,
  `socket`, `assigns`) alongside stock descriptions that merely restate
  the signature.

  ## Bad

      @doc \"""
      Renders the index page.

      ## Parameters

      - conn: The connection struct
      - params: A map of parameters
      \"""
      def index(conn, params)

  ## Good — document constraints, not names

      @doc \"""
      Renders the index page.

      ## Parameters

      - params: Must include `"page"` (integer >= 1) and optionally
        `"per_page"` (default 20, max 100).
      \"""

  ## Also good — no `## Parameters` section at all

      @doc \"""
      Renders the index page, paginated.
      \"""

  Ported from
  [`ExSlop.Check.Readability.BoilerplateDocParams`](https://hex.pm/packages/ex_slop).
  """

  use CredenceRules.Rule

  @section_headings ["## Parameters", "## Params", "## Arguments", "## Args"]

  @boilerplate_params ~w(conn params socket assigns)

  @boilerplate_descriptions ["connection", "map of param", "socket", "assigns"]

  @impl true
  def priority, do: 250

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{:doc, meta, [docstring]}]} = node, acc when is_binary(docstring) ->
          if boilerplate_params?(docstring),
            do: {node, [build_issue(meta) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp boilerplate_params?(docstring) do
    has_section_heading?(docstring) and has_boilerplate_entry?(docstring)
  end

  defp has_section_heading?(docstring) do
    Enum.any?(@section_headings, &String.contains?(docstring, &1))
  end

  defp has_boilerplate_entry?(docstring) do
    docstring
    |> String.split("\n")
    |> Enum.any?(&boilerplate_line?/1)
  end

  defp boilerplate_line?(line) do
    trimmed = String.trim(line)

    if String.starts_with?(trimmed, "-") do
      content =
        trimmed
        |> String.trim_leading("-")
        |> String.trim()

      param_match =
        Enum.any?(@boilerplate_params, fn param ->
          String.starts_with?(content, param) or
            String.starts_with?(content, "`#{param}`")
        end)

      lowered = String.downcase(content)
      desc_match = Enum.any?(@boilerplate_descriptions, &String.contains?(lowered, &1))

      param_match and desc_match
    else
      false
    end
  end

  defp build_issue(meta) do
    %Issue{
      rule: :boilerplate_doc_params,
      message:
        "`@doc` has a `## Parameters` section that restates the signature " <>
          "(`conn`/`params`/`socket`/`assigns` with stock descriptions). Document " <>
          "constraints (allowed shapes, required keys, value ranges) — or remove " <>
          "the section.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
