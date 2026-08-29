defmodule CredenceRules.Pattern.ModuleWithManyUseStatements do
  @moduledoc """
  SRP rule: a `defmodule` with four or more `use Foo` statements is
  the LLM "kitchen sink" tell — pull in everything and hope something
  sticks.

  `use` is heavyweight: it imports, aliases, and injects code at
  compile time. Stacking them blurs what's actually defined locally
  vs. what came from where. The same module ends up being a Phoenix
  controller, an Ecto schema, a behaviour callback target, AND a
  custom mixin all at once.

  ## Bad

      defmodule MyApp.User do
        use Ecto.Schema
        use MyApp.AuditableSchema
        use Pow.Ecto.Schema
        use PowEmailConfirmation.Ecto.Schema
        use PowResetPassword.Ecto.Schema
      end

  Six `use`s, six possible callback contracts, six possible
  conflicting `__schema__/1` injections.

  ## Good — narrow the surface

  Pick the one that defines the module's role, inline the rest as
  explicit `import` / `alias` / `defdelegate`, or split into multiple
  modules composed at the seam.

  ## Detection

  Counts top-level `use Foo` / `use Foo, opts` calls in the
  `defmodule` body. Threshold defaults to 4, configurable via
  `:max_uses` opt.

  Phoenix's canonical scaffold (`use Phoenix.LiveView`, `use
  Phoenix.Component`, `use MyAppWeb, :live_view`) regularly has 2-3
  `use`s by design. The default threshold of 4 sits above the
  Phoenix baseline.

  ## Why advisory

  Some libraries are designed for stacking (Pow's individual
  extensions are the standard example). Treat findings as "is each
  `use` pulling its weight?" — not a hard cap.
  """

  use CredenceRules.Rule

  alias CredenceRules.AstKeyword

  @default_max 4

  @impl true
  def priority, do: 420

  @impl true
  def check(ast, opts) do
    max_uses = Keyword.get(opts, :max_uses, @default_max)

    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:defmodule, meta, [_alias, kw]} = node, acc when is_list(kw) ->
          case AstKeyword.get(kw, :do) do
            nil ->
              {node, acc}

            body ->
              count = count_use_statements(body)

              if count >= max_uses,
                do: {node, [build_issue(meta, count, max_uses) | acc]},
                else: {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp count_use_statements(body) do
    statements =
      case body do
        {:__block__, _, list} -> list
        single -> [single]
      end

    Enum.count(statements, &use_statement?/1)
  end

  defp use_statement?({:use, _, _}), do: true
  defp use_statement?(_), do: false

  defp build_issue(meta, count, threshold) do
    %Issue{
      rule: :module_with_many_use_statements,
      message:
        "Module has #{count} `use` statements (threshold #{threshold}). Stacking " <>
          "`use`s blurs which behaviours, imports, and aliases are coming from " <>
          "where — and any of them can inject conflicting compile-time code. Pick " <>
          "the one `use` that defines the module's role; replace the rest with " <>
          "explicit `import` / `alias` / `defdelegate`, or split the module.",
      meta: %{line: Keyword.get(meta, :line), uses: count}
    }
  end
end
