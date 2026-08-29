# credence-file:repeated_subtree_in_module — this module is an AST pattern
#   matcher whose check/2 + Macro.prewalk + build_issue shape is the Rule
#   contract itself, so the structural duplication is inherent to the form
#   rather than a smell
defmodule CredenceRules.Pattern.NarratorDoc do
  @moduledoc """
  Doc rule: flags `@moduledoc` / `@doc` strings whose first line is the
  shape *"This <noun> <verb> …"* — narrator docs that restate the name.

  The module name already says it's a module; the function name already
  says it's a function. Docs should add information the name doesn't —
  constraints, return contracts, side effects, examples, the WHY.

  ## Bad

      @moduledoc \"""
      This module provides functionality for handling user authentication.
      \"""
      defmodule MyApp.Auth do

      @doc \"""
      This function creates a new user.
      \"""
      def create_user(attrs)

  ## Good

      @moduledoc \"""
      Wraps Bcrypt and session token generation.
      Rate-limits login attempts per IP via a sliding window.
      \"""

      @doc \"""
      Passwords must be at least 12 characters. Returns
      `{:error, :weak_password}` for common dictionary words.
      \"""

  ## Detection

  All three on the first line of the docstring:

  1. Begins with `This ` or `The ` (case-insensitive).
  2. Contains one of `module`, `function`, `struct`, `schema`, `plug`,
     `controller`, `component`, `channel`, `socket`, `worker`, `server`,
     `supervisor`, `task`, `behaviour`, `macro`, `context`, `view`,
     `endpoint`, `router`, `live view`.
  3. Contains one of `provides`, `handles`, `manages`, `implements`,
     `represents`, `serves as`, `acts as`, `holds`, `stores`, `wraps`,
     `encapsulates`, `exposes`, `is responsible for`, `is used to`,
     `is used for`.

  `@doc false` is skipped (it's a deliberate hide, not narration).

  Ported from
  [`ExSlop.Check.Readability.NarratorDoc`](https://hex.pm/packages/ex_slop).
  """

  use CredenceRules.Rule

  @prefixes ["this ", "the "]

  @nouns ~w(
    module function struct schema plug controller view component
    channel socket endpoint router context worker server supervisor
    task behaviour macro
  ) ++ ["live view"]

  @verbs ~w(
    provides provide handles handle manages manage implements implement
    represents represent holds hold stores store wraps wrap encapsulates
    encapsulate exposes expose creates create returns return builds build
    computes compute generates generate parses parse validates validate
    converts convert formats format
  ) ++
           [
             "is responsible for",
             "is used to",
             "is used for",
             "serves as",
             "serve as",
             "acts as",
             "act as"
           ]

  @impl true
  def priority, do: 300

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:@, _, [{:moduledoc, meta, [docstring]}]} = node, acc when is_binary(docstring) ->
          if narrator?(docstring),
            do: {node, [build_issue(meta, :moduledoc, docstring) | acc]},
            else: {node, acc}

        {:@, _, [{:doc, meta, [docstring]}]} = node, acc when is_binary(docstring) ->
          if narrator?(docstring),
            do: {node, [build_issue(meta, :doc, docstring) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp narrator?(docstring) do
    first_line =
      docstring
      |> String.trim_leading()
      |> String.split("\n", parts: 2)
      |> hd()
      |> String.downcase()

    has_prefix?(first_line) and has_noun?(first_line) and has_verb?(first_line)
  end

  defp has_prefix?(line), do: Enum.any?(@prefixes, &String.starts_with?(line, &1))
  defp has_noun?(line), do: Enum.any?(@nouns, &String.contains?(line, &1))
  defp has_verb?(line), do: Enum.any?(@verbs, &String.contains?(line, &1))

  defp build_issue(meta, tag, docstring) do
    snippet =
      docstring
      |> String.trim_leading()
      |> String.split("\n", parts: 2)
      |> hd()
      |> String.slice(0, 80)

    %Issue{
      rule: :narrator_doc,
      message:
        ~s(`@#{tag}` opens with "This <noun> <verb> …" — restates the name. Document ) <>
          "constraints / return contract / WHY instead, or remove the doc. First line: " <>
          "#{snippet}",
      meta: %{line: Keyword.get(meta, :line), tag: tag}
    }
  end
end
