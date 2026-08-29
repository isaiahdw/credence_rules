# credence-file:cross_file_duplicate_block — this module is an AST pattern
#   matcher whose check/2 + Macro.prewalk + build_issue shape is the Rule
#   contract itself, so the structural duplication is inherent to the form
#   rather than a smell
defmodule CredenceRules.Pattern.FatController do
  @moduledoc """
  Architecture rule: a Phoenix controller is a thin glue layer between
  HTTP and a context. Every public function that isn't a controller
  action (an `action_name(conn, params)` shape) signals business logic
  living in the wrong place.

  LLMs ship "fat controllers" — controllers with public business-
  logic helpers exposed alongside the actions. This couples the
  HTTP layer to every concern; tests have to spin up conns to
  exercise pure logic; reuse from a LiveView or Mix task means
  copying the helpers.

  ## Bad

      defmodule MyAppWeb.UserController do
        use MyAppWeb, :controller

        def index(conn, _params) do
          render(conn, "index.html", users: list_active_users())
        end

        def show(conn, %{"id" => id}) do
          render(conn, "show.html", user: get_user!(id))
        end

        # Public helpers — exposed for reuse but tying the controller
        # to schema/Repo concerns and dragging Phoenix-shaped
        # imports into the call sites.
        def list_active_users do
          MyApp.Repo.all(from u in User, where: u.active == true)
        end

        def get_user!(id), do: MyApp.Repo.get!(User, id)
      end

  Each public non-action `def` signals business logic that should
  live in a context.

  ## Good

      defmodule MyAppWeb.UserController do
        use MyAppWeb, :controller

        alias MyApp.Accounts

        def index(conn, _params) do
          render(conn, "index.html", users: Accounts.list_active_users())
        end

        def show(conn, %{"id" => id}) do
          render(conn, "show.html", user: Accounts.get_user!(id))
        end
      end

      defmodule MyApp.Accounts do
        # all of the above, testable without a conn, reusable from
        # LiveView, mailers, mix tasks
      end

  ## Detection

  Recognises a controller module by `use ...Controller` or `use ...,
  :controller`. For each public `def`, treats it as an "action" if
  its arity is 2 (parameters look like `(conn, params)`). Any
  other public `def` is flagged as non-action.

  Action recognition is shape-based, not name-based: a public `def
  handle(conn, params)` is treated as an action even if it isn't a
  router-routable name (router-validation isn't in this rule's
  scope).

  **Private helpers (`defp`) are NOT checked.** A `defp` that calls
  `Repo` directly inside a controller is a real smell, but it's
  caught by other rules (`iosp_predicate_side_effects`,
  `iosp_mixed_function`, `forbidden_module_dependency` with the
  right edges configured). Keeping this rule focused on the public
  surface avoids overlap and double-reporting.

  ## Why advisory

  Some legitimate controllers expose small public helpers (custom
  `action/2` overrides, fallback handlers like `def fallback(conn, _),
  do: ...`). Treat findings as "does this belong in a context?" —
  not a hard wall.
  """

  use CredenceRules.Rule

  @hint """
  Move the non-action public defs into a context module:

      # Before
      defmodule MyAppWeb.UserController do
        use MyAppWeb, :controller

        def index(conn, _), do: render(conn, "index.html", users: list_active_users())
        def list_active_users, do: MyApp.Repo.all(from u in User, where: u.active)
      end

      # After
      defmodule MyAppWeb.UserController do
        use MyAppWeb, :controller

        def index(conn, _) do
          render(conn, "index.html", users: MyApp.Accounts.list_active_users())
        end
      end

      defmodule MyApp.Accounts do
        def list_active_users, do: MyApp.Repo.all(from u in User, where: u.active)
      end

  Now LiveViews, mailers, and tests can reuse `list_active_users/0`
  without spinning up a conn.
  """

  @carve_outs [
    "Custom `action/2` overrides — controllers can legitimately define a 2-arity action callback for plug behaviour; if shape matches `(conn, params)` it's accepted as an action.",
    "Fallback handlers like `def fallback(conn, _), do: ...` — currently flagged. Move to a FallbackController if it's general, otherwise accept the finding.",
    "Private helpers (`defp`) are NOT checked — covered by iosp_predicate_side_effects / forbidden_module_dependency."
  ]

  alias CredenceRules.AstKeyword

  @impl true
  def priority, do: 440

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:defmodule, meta, [_alias, kw]} = node, acc when is_list(kw) ->
          case AstKeyword.get(kw, :do) do
            nil -> {node, acc}
            body -> {node, check_module(body, meta) ++ acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp check_module(body, meta) do
    statements = top_level_statements(body)

    if Enum.any?(statements, &controller_use?/1) do
      offenders =
        statements
        |> Enum.flat_map(&public_def_name_arity/1)
        |> Enum.reject(&action_shape?/1)
        |> Enum.map(fn {name, arity} -> "#{name}/#{arity}" end)

      case offenders do
        [] -> []
        names -> [build_issue(meta, names)]
      end
    else
      []
    end
  end

  defp top_level_statements({:__block__, _, list}), do: list
  defp top_level_statements(single), do: [single]

  # `use Phoenix.Controller`, `use Phoenix.Controller, namespace: …`,
  # `use MyAppWeb, :controller`, `use SomeController` — any `use`
  # whose target alias ends in `Controller` OR whose options include
  # the `:controller` atom.
  defp controller_use?({:use, _, [{:__aliases__, _, segs}]}),
    do: ends_with_controller?(List.last(segs))

  defp controller_use?({:use, _, [{:__aliases__, _, segs}, opt]}),
    do: ends_with_controller?(List.last(segs)) or controller_atom?(opt)

  defp controller_use?(_), do: false

  defp ends_with_controller?(seg) when is_atom(seg) do
    Atom.to_string(seg) |> String.ends_with?("Controller")
  end

  defp ends_with_controller?(_), do: false

  defp controller_atom?(:controller), do: true
  defp controller_atom?({:__block__, _, [:controller]}), do: true
  defp controller_atom?(_), do: false

  defp public_def_name_arity({:def, _, [head, _kw]}) do
    case def_head(head) do
      {name, arity} -> [{name, arity}]
      _ -> []
    end
  end

  defp public_def_name_arity(_), do: []

  defp def_head({:when, _, [inner, _guard]}), do: def_head(inner)

  defp def_head({name, _meta, params}) when is_atom(name) and is_list(params),
    do: {name, length(params)}

  defp def_head({name, _meta, nil}) when is_atom(name), do: {name, 0}
  defp def_head(_), do: nil

  # An action is shape-recognised: arity 2. Phoenix controllers route
  # to `def name(conn, params)`; any other arity is non-action.
  defp action_shape?({_name, 2}), do: true
  defp action_shape?(_), do: false

  defp build_issue(meta, names) do
    {first_three, rest} = Enum.split(names, 3)
    sample = Enum.join(first_three, ", ")
    extra = if rest == [], do: "", else: " (+#{length(rest)} more)"

    %Issue{
      rule: :fat_controller,
      message:
        "Controller defines non-action public functions: #{sample}#{extra}. " <>
          "Controller actions are `def name(conn, params)` (arity 2); anything " <>
          "else is business logic in the HTTP layer. Move to a context module " <>
          "— LiveViews, mailers, and tests can reuse it without going through a conn.",
      meta: %{line: Keyword.get(meta, :line), functions: names}
    }
  end
end
