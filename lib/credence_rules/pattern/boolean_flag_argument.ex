defmodule CredenceRules.Pattern.BooleanFlagArgument do
  @moduledoc """
  Design rule: a function with a **boolean flag parameter** — a default
  argument whose default is `true` or `false` — usually does two
  things bolted together behind a switch.

  Two problems. At the call site the flag is unreadable —
  `render(doc, true)` tells you nothing about what `true` selects. And
  the function itself branches on the flag internally, so it can't be
  composed cleanly: callers can't pipe through one behaviour without
  dragging the other along.

  ## Bad

      def render(doc, compact \\\\ false) do
        if compact, do: render_compact(doc), else: render_full(doc)
      end

      # call sites — what does `true` mean here?
      render(doc, true)
      render(doc, false)

  ## Good — split into intention-named functions

      def render(doc), do: render_full(doc)
      def render_compact(doc), do: ...

      # call sites read themselves
      render(doc)
      render_compact(doc)

  Each function is focused, names its behaviour, and threads cleanly
  through a pipe.

  ## Detection

  Flags a `def` / `defp` / `defmacro` / `defmacrop` head with a
  default-valued parameter (`arg \\\\ default`) whose default is the
  boolean literal `true` or `false`. The default makes the boolean's
  *intent as a switch* unambiguous, which keeps the rule precise — a
  plain boolean parameter with no default can't be told apart from a
  function that legitimately takes a boolean value.

  ## NOT flagged

  - Non-boolean defaults (`opts \\\\ []`, `timeout \\\\ 5_000`,
    `value \\\\ nil`) — those are ordinary optional arguments.
  - Boolean parameters with no default — undecidable from the head.

  ## Why advisory

  Occasionally a boolean default is a genuine data value (a struct
  field's default carried through a constructor) rather than a
  behaviour switch. Reviewer call.
  """

  use CredenceRules.Rule

  @severity :low
  @confidence :medium

  @hint """
  Replace the boolean flag with two intention-named functions:

      # Before
      def fetch(id, preload \\\\ false) do
        if preload, do: fetch_with_assocs(id), else: fetch_bare(id)
      end

      # After
      def fetch(id), do: fetch_bare(id)
      def fetch_with_preload(id), do: fetch_with_assocs(id)

  Each names its behaviour, reads at the call site without a bare
  `true`/`false`, and composes in a pipe.

  Keep the boolean only when it's genuine *data* the function stores or
  forwards (not a switch on behaviour).
  """

  @carve_outs [
    "A boolean default that's stored/forwarded as data (a struct field default carried through a constructor) rather than switching behaviour — reviewer call.",
    "Boolean parameters with no default aren't flagged — they can't be distinguished from a function that legitimately takes a boolean value."
  ]

  @def_kinds [:def, :defp, :defmacro, :defmacrop]

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {kind, meta, [head | _]} = node, acc when kind in @def_kinds ->
          case flag_param(head) do
            nil -> {node, acc}
            {name, flag} -> {node, [build_issue(meta, name, flag) | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  # First default-valued parameter whose default is a boolean literal,
  # as `{function_name, flag_param_name}`.
  defp flag_param({:when, _, [inner | _]}), do: flag_param(inner)

  defp flag_param({name, _, args}) when is_atom(name) and is_list(args) do
    Enum.find_value(args, fn
      {:\\, _, [{param, _, ctx}, default]} when is_atom(param) and is_atom(ctx) ->
        if boolean_literal?(default), do: {name, param}

      _ ->
        nil
    end)
  end

  defp flag_param(_), do: nil

  # `true` / `false` — bare, or wrapped in Sourceror's `__block__`
  # trivia node.
  defp boolean_literal?(default) when is_boolean(default), do: true
  defp boolean_literal?({:__block__, _, [b]}) when is_boolean(b), do: true
  defp boolean_literal?(_), do: false

  defp build_issue(meta, fun, param) do
    %Issue{
      rule: :boolean_flag_argument,
      message:
        "`#{fun}` takes a boolean flag parameter `#{param} \\\\ true/false`. A " <>
          "boolean argument usually means the function does two things — and " <>
          "`#{fun}(x, true)` is unreadable at the call site. Split into two " <>
          "intention-named functions (e.g. `#{fun}/n` and a `#{fun}_<variant>`), " <>
          "each focused and composable.",
      meta: %{line: Keyword.get(meta, :line), function: fun, flag: param}
    }
  end
end
