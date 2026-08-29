defmodule CredenceRules.Pattern.ManagerServiceModuleName do
  @moduledoc """
  Convention rule: discourages OOP-style "service / manager / helper /
  utility / common / shared" module-name suffixes.

  Idiomatic Elixir modules are **nouns describing what they produce or
  represent** (`User`, `Cache`, `Repo`, `Auction.Bid`), or **verbs
  describing what they do** (`Encode`, `Render`, `Resize`). Suffixes
  like `Manager`, `Service`, `Helper(s)`, `Util(s)`, `Handler`,
  `Common`, `Shared`, and generic `Controller` (outside Phoenix's
  `MyAppWeb.FooController` convention) usually mean "I had behavior
  to put somewhere, so I invented a class to hold it" — the OOP
  service-layer mental model leaking into Elixir.

  `Common` and `Shared` are particularly suspect: they're the
  default landing spot for "code two things use" that should
  usually have its own concept name (`Encoder`, `Tokenizer`,
  `Policy`) — naming the abstraction by what it is, not by who
  uses it.

  **Behaviour modules are exempt.** A module that declares
  `@callback` / `@macrocallback` is a behaviour — a named seam other
  modules implement (`MyApp.Interaction.CommandHandler`,
  `MyApp.EventHandler`). The `Handler` suffix there names a real
  contract, not a service object, so the rule skips it.

  This rule fires on *new* code, not existing modules. Configure
  `allowed_modules:` with the current names you want grandfathered:

      CredenceRules.Pattern.ManagerServiceModuleName.check(ast,
        allowed_modules: [
          MyApp.Legacy.Manager,
          MyApp.Discovery.Manager,
          # ...
        ])

  Or relax the suffix list:

      CredenceRules.Pattern.ManagerServiceModuleName.check(ast,
        forbidden_suffixes: ["Helpers", "Utils"])

  ## Bad

      defmodule MyApp.UserManager do
        def create_user(attrs), do: ...
      end

  ## Good

      defmodule MyApp.Accounts do            # context module
        def create_user(attrs), do: ...
      end

      defmodule MyApp.User do                # struct module
        defstruct [:id, :email]
      end
  """

  use CredenceRules.Rule

  alias CredenceRules.AstKeyword

  @default_forbidden_suffixes ~w(Manager Service Helper Helpers Util Utils Handler Common Shared)

  @impl true
  def priority, do: 280

  @impl true
  def check(ast, opts) do
    forbidden =
      opts
      |> Keyword.get(:forbidden_suffixes, @default_forbidden_suffixes)
      |> MapSet.new()

    allowed =
      opts
      |> Keyword.get(:allowed_modules, [])
      |> Enum.map(&Module.split/1)
      |> Enum.map(&Enum.join(&1, "."))
      |> MapSet.new()

    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:defmodule, meta, [{:__aliases__, _, parts}, do_block]} = node, acc
        when is_list(parts) ->
          full = Enum.map_join(parts, ".", &Atom.to_string/1)
          last = parts |> List.last() |> Atom.to_string()

          matched_suffix =
            Enum.find(forbidden, fn s -> String.ends_with?(last, s) end)

          cond do
            MapSet.member?(allowed, full) -> {node, acc}
            behaviour_module?(do_block) -> {node, acc}
            matched_suffix -> {node, [build_issue(meta, full, matched_suffix) | acc]}
            true -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  # A module that declares `@callback` / `@macrocallback` IS a behaviour
  # — a named seam other modules implement (`CommandHandler`,
  # `EventHandler`), not OOP service-layer naming. The suffix is doing
  # legitimate work, so it's exempt.
  defp behaviour_module?(do_block) when is_list(do_block) do
    case AstKeyword.get(do_block, :do) do
      nil -> false
      body -> defines_callback?(body)
    end
  end

  defp behaviour_module?(_), do: false

  defp defines_callback?(body) do
    {_ast, found?} =
      Macro.prewalk(body, false, fn
        _node, true -> {[], true}
        {:@, _, [{attr, _, _}]} = node, false when attr in [:callback, :macrocallback] -> {node, true}
        node, false -> {node, false}
      end)

    found?
  end

  defp build_issue(meta, full, suffix) do
    %Issue{
      rule: :manager_service_module_name,
      message:
        "Module `#{full}` ends in `#{suffix}` — OOP service-layer naming. " <>
          "Idiomatic Elixir module names describe what they *are* (a noun: " <>
          "`User`, `Cache`) or *do* (a verb: `Encode`, `Render`), not " <>
          "what they manage. Consider renaming or, if intentional, add to " <>
          "the rule's `allowed_modules:` list.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
