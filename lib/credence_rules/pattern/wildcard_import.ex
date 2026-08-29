defmodule CredenceRules.Pattern.WildcardImport do
  @moduledoc """
  DRY rule: `import Foo` without `:only` brings every public function
  from `Foo` into local scope. Readers can no longer tell whether
  `bar(x)` is a local call, a Kernel call, or a call into `Foo` —
  every name has to be checked against the imported module's surface.

  Force the author to enumerate what they're bringing in. `:only`
  makes the import a documented contract (these names belong to Foo);
  any later code that uses a different `Foo` function has to add it
  to `:only` explicitly, which puts the name in a place reviewers can
  see.

  ## Bad

      import Logger
      # Is `debug(...)` here `Logger.debug` or a local? Reader can't tell.

      import Ecto.Query
      # Brings in `from/1`, `from/2`, `where/2`, `select/2`, … all of them.

  ## Good

      import Logger, only: [debug: 1, info: 1, warning: 1]
      import Ecto.Query, only: [from: 1, from: 2, where: 2]

  ## Allowed

  - `import Foo, only: [...]` — explicit name list
  - `import Foo, only: :functions` / `:macros` — macro/function bulk
    import is at least documented as such
  - `import Foo, except: [...]` — narrow exclusions are acceptable for
    things like macro imports where you want to mask a single name

  Imports inside a `quote` block (macros) are NOT flagged — the rule
  there is "what the macro injects," which the author of the caller
  may not control.
  """

  use CredenceRules.Rule

  @impl true
  def priority, do: 350

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, {[], 0}, fn
        # Track quote depth so we don't flag imports inside macro
        # quotation — those are part of the expanded code, not what
        # the author of the current module is bringing in.
        {:quote, _, _} = node, {acc, depth} ->
          {node, {acc, depth + 1}}

        {:import, meta, [_mod]} = node, {acc, 0} ->
          # `import Foo` — no opts.
          {node, {[build_issue(meta, :no_opts) | acc], 0}}

        {:import, meta, [_mod, opts]} = node, {acc, 0} when is_list(opts) ->
          if has_scope?(opts),
            do: {node, {acc, 0}},
            else: {node, {[build_issue(meta, :no_scope) | acc], 0}}

        node, state ->
          {node, state}
      end)

    issues
    |> elem(0)
    |> Enum.reverse()
  end

  # `:only` or `:except` makes the import a documented contract.
  defp has_scope?(opts) do
    CredenceRules.AstKeyword.has_key?(opts, :only) or
      CredenceRules.AstKeyword.has_key?(opts, :except)
  end

  defp build_issue(meta, variant) do
    detail =
      case variant do
        :no_opts -> "no options"
        :no_scope -> "no `:only` / `:except`"
      end

    %Issue{
      rule: :wildcard_import,
      message:
        "Wildcard `import` (#{detail}) brings every public function from the module " <>
          "into local scope. Readers can't tell whether `name(...)` is local, Kernel, " <>
          "or imported. Use `import Foo, only: [name: 1, other: 2]` so the surface is " <>
          "documented and reviewable.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
