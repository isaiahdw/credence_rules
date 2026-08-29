defmodule CredenceRules.Pattern.LiveviewQueryInMount do
  @moduledoc """
  Architecture / performance rule: a Phoenix LiveView's `mount/3` is
  called **twice** — once for the initial HTTP render and once when
  the WebSocket reconnects. A `Repo.*` (or other expensive) call
  inside `mount/3` without a `connected?(socket)` guard runs both
  times, doubling the query load on every page view.

  This is one of the most common Phoenix performance bugs LLMs ship:
  they write LiveView the way they'd write a controller (load data
  up front, render), missing the LiveView lifecycle.

  ## Bad

      defmodule MyAppWeb.UserLive do
        use Phoenix.LiveView

        def mount(_params, _session, socket) do
          users = MyApp.Accounts.list_users()    # runs twice per page
          {:ok, assign(socket, users: users)}
        end
      end

  Each page view fires `list_users/0` twice — once for the SSR pass
  (where the user sees the initial HTML), once again immediately
  after when the LiveView WebSocket connects.

  ## Good — gate with `connected?/1`

      def mount(_params, _session, socket) do
        users =
          if connected?(socket),
            do: MyApp.Accounts.list_users(),
            else: []

        {:ok, assign(socket, users: users)}
      end

  ## Good — load in handle_params

  If the data depends on URL params, do it in `handle_params/3` —
  that fires once per route transition, on the connected socket only.

      def mount(_params, _session, socket), do: {:ok, socket}

      def handle_params(_params, _uri, socket) do
        {:noreply, assign(socket, users: MyApp.Accounts.list_users())}
      end

  ## Detection — path-sensitive

  Flags a `mount/3` (or `mount/4` for `use Phoenix.LiveComponent`)
  inside a LiveView/LiveComponent module that calls into a
  data-loading namespace **on a path that isn't dominated by
  `connected?(socket)`**.

  These shapes are recognised as "dominated by `connected?`":

  - `if connected?(socket), do: Repo.all(...), else: ...` — the
    `do:` branch is dominated; loader is suppressed.
  - `if connected?(socket) do; Repo.all(...); end` — same.
  - `if not connected?(socket), do: ..., else: Repo.all(...)` —
    the `else:` branch is dominated.
  - `unless connected?(socket), do: ..., else: Repo.all(...)` —
    inverted; `else:` is dominated.
  - `case connected?(socket) do; true -> Repo.all(...); …; end` —
    the `true ->` arm is dominated.
  - `connected?(socket) && Repo.all(...)` (or `and`) — RHS is
    dominated.

  These shapes are NOT dominated (loader still flagged):

  - `Repo.all(...)` at the top level of mount before any
    `connected?` check — the loader always runs.
  - `Repo.all(...)` in the `else:` arm of `if connected?(...)`.
  - `Repo.all(...)` in a `case` clause that doesn't pattern-match
    `true` against a `connected?(...)` scrutinee.

  The walker is intentionally conservative: shapes it can't
  classify are treated as "not dominated" and the loader is
  flagged. This is a behaviour change from the older "any
  `connected?` anywhere in the body suppresses everything"
  semantics — that was too coarse and missed the real bug case
  where the loader runs at the top level before the gate.

  Default trigger calls (configurable via `:loader_modules`):

  - `Repo.*` — Ecto.Repo callables
  - `Ecto.Query.*`, `from/1,2`
  - `HTTPoison.*`, `Req.*`, `Finch.*`, `Tesla.*`
  - `Oban.insert/1,2` (job enqueue side effect)

  ## Why advisory

  Some LiveViews legitimately want the data on the initial render
  (better LCP, SEO). In those cases pair the load with
  `temporary_assigns` or accept the double-query cost knowingly.
  The rule's intent is to surface the bug-shaped case for review.
  """

  use CredenceRules.Rule

  alias CredenceRules.AstKeyword

  @default_loaders ~w(Repo HTTPoison Req Finch Tesla Oban)

  @impl true
  def priority, do: 450

  @impl true
  def check(ast, opts) do
    loaders = Keyword.get(opts, :loader_modules, @default_loaders)

    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [_alias, kw]} = node, acc when is_list(kw) ->
          case AstKeyword.get(kw, :do) do
            nil ->
              {node, acc}

            body ->
              if liveview_module?(body),
                do: {node, scan_mounts(body, loaders) ++ acc},
                else: {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp top_level_statements({:__block__, _, list}), do: list
  defp top_level_statements(single), do: [single]

  defp liveview_module?(body) do
    body
    |> top_level_statements()
    |> Enum.any?(&liveview_use?/1)
  end

  # `use Phoenix.LiveView`, `use Phoenix.LiveComponent`, `use MyAppWeb,
  # :live_view`, `use MyAppWeb, :live_component`.
  defp liveview_use?({:use, _, [{:__aliases__, _, segs}]}) do
    last = List.last(segs)
    last == :LiveView or last == :LiveComponent
  end

  defp liveview_use?({:use, _, [{:__aliases__, _, segs}, opt]}) do
    last = List.last(segs)
    last == :LiveView or last == :LiveComponent or live_atom?(opt)
  end

  defp liveview_use?(_), do: false

  defp live_atom?(:live_view), do: true
  defp live_atom?(:live_component), do: true
  defp live_atom?({:__block__, _, [atom]}), do: live_atom?(atom)
  defp live_atom?(_), do: false

  defp scan_mounts(body, loaders) do
    body
    |> top_level_statements()
    |> Enum.flat_map(fn
      {:def, meta, [head, kw]} = _node when is_list(kw) ->
        with {:ok, name, arity} <- def_head(head),
             true <- mount_function?(name, arity),
             {:ok, def_body} <- {:ok, AstKeyword.get(kw, :do)},
             [_ | _] = offenders <- unguarded_loader_calls(def_body, loaders) do
          [build_issue(meta, offenders)]
        else
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp def_head({:when, _, [inner, _guard]}), do: def_head(inner)

  defp def_head({name, _meta, params}) when is_atom(name) and is_list(params),
    do: {:ok, name, length(params)}

  defp def_head(_), do: :error

  defp mount_function?(:mount, arity) when arity in [3, 4], do: true
  defp mount_function?(_, _), do: false

  # Path-sensitive: returns the loader calls that are NOT dominated
  # by a `connected?(_)` check. A loader inside the `do:` arm of
  # `if connected?(socket), do: …, else: …` is dominated and skipped;
  # a loader at the top level of `mount` (or in the wrong branch) is
  # flagged.
  #
  # Older versions of this rule suppressed any loader as soon as a
  # `connected?` appeared *anywhere* in the body — too coarse, since
  # the loader could be on a path the check never gated. The current
  # walker tracks the dominance context as it descends `if` / `unless`
  # / `case` arms.
  defp unguarded_loader_calls(body, loaders) do
    body
    |> walk_for_loaders(loaders, _under_connected? = false, [])
    |> Enum.uniq()
    |> Enum.reverse()
  end

  defp walk_for_loaders(node, loaders, under_connected?, acc)

  # `if cond do … else … end` and `if cond, do: …, else: …`
  defp walk_for_loaders({:if, _, [cond_ast, branches]}, loaders, under_connected?, acc) do
    acc = walk_for_loaders(cond_ast, loaders, under_connected?, acc)

    do_branch = branch(branches, :do)
    else_branch = branch(branches, :else)

    do_under = under_connected? or implies_connected_true?(cond_ast)
    else_under = under_connected? or implies_connected_false?(cond_ast)

    acc = walk_for_loaders(do_branch, loaders, do_under, acc)
    walk_for_loaders(else_branch, loaders, else_under, acc)
  end

  # `unless cond do … else … end` — inverted dominance.
  defp walk_for_loaders({:unless, _, [cond_ast, branches]}, loaders, under_connected?, acc) do
    acc = walk_for_loaders(cond_ast, loaders, under_connected?, acc)

    do_branch = branch(branches, :do)
    else_branch = branch(branches, :else)

    # `unless connected?(...)` → else branch is dominated, do branch is "when not connected".
    do_under = under_connected? or implies_connected_false?(cond_ast)
    else_under = under_connected? or implies_connected_true?(cond_ast)

    acc = walk_for_loaders(do_branch, loaders, do_under, acc)
    walk_for_loaders(else_branch, loaders, else_under, acc)
  end

  # `case connected?(...) do; true -> …; false -> … end` — only the
  # `true ->` arm is dominated.
  defp walk_for_loaders(
         {:case, _, [scrutinee, [{:do, clauses}]]},
         loaders,
         under_connected?,
         acc
       ) do
    acc = walk_for_loaders(scrutinee, loaders, under_connected?, acc)
    scrutinee_is_connected? = implies_connected_true?(scrutinee)

    Enum.reduce(clauses, acc, fn
      {:->, _, [[pattern], body]}, inner_acc ->
        arm_under = under_connected? or (scrutinee_is_connected? and matches_true?(pattern))
        walk_for_loaders(body, loaders, arm_under, inner_acc)

      _other, inner_acc ->
        inner_acc
    end)
  end

  # `connected?(...) && expr` / `connected?(...) and expr` — RHS dominated.
  defp walk_for_loaders({op, _, [lhs, rhs]}, loaders, under_connected?, acc)
       when op in [:&&, :and] do
    acc = walk_for_loaders(lhs, loaders, under_connected?, acc)
    rhs_under = under_connected? or implies_connected_true?(lhs)
    walk_for_loaders(rhs, loaders, rhs_under, acc)
  end

  # Loader call — flag if not dominated.
  defp walk_for_loaders(
         {{:., _, [{:__aliases__, _, segs}, fun]}, _, args},
         loaders,
         under_connected?,
         acc
       )
       when is_atom(fun) and is_list(args) do
    acc =
      if loader_match?(segs, loaders) and not under_connected? do
        ["#{Enum.map_join(segs, ".", &Atom.to_string/1)}.#{fun}" | acc]
      else
        acc
      end

    # Recurse into the call args too (a loader might be nested in
    # another expression).
    walk_children(args, loaders, under_connected?, acc)
  end

  # Generic 3-tuple AST node — recurse into args.
  defp walk_for_loaders({_form, _meta, args}, loaders, under_connected?, acc)
       when is_list(args) do
    walk_children(args, loaders, under_connected?, acc)
  end

  # 2-tuple (keyword pair or struct shape) — recurse both halves.
  defp walk_for_loaders({left, right}, loaders, under_connected?, acc) do
    acc = walk_for_loaders(left, loaders, under_connected?, acc)
    walk_for_loaders(right, loaders, under_connected?, acc)
  end

  # List — recurse each element.
  defp walk_for_loaders(list, loaders, under_connected?, acc) when is_list(list) do
    walk_children(list, loaders, under_connected?, acc)
  end

  # Leaf — nothing to do.
  defp walk_for_loaders(_, _loaders, _under_connected?, acc), do: acc

  defp walk_children(children, loaders, under_connected?, acc) do
    Enum.reduce(children, acc, fn child, inner_acc ->
      walk_for_loaders(child, loaders, under_connected?, inner_acc)
    end)
  end

  defp branch(branches, key) when is_list(branches) do
    Keyword.get(branches, key)
  end

  defp branch(_, _), do: nil

  # Recognise common shapes meaning "this side runs only when connected".
  defp implies_connected_true?({:connected?, _, args}) when is_list(args), do: true

  defp implies_connected_true?({:and, _, [lhs, rhs]}),
    do: implies_connected_true?(lhs) or implies_connected_true?(rhs)

  defp implies_connected_true?({:&&, _, [lhs, rhs]}),
    do: implies_connected_true?(lhs) or implies_connected_true?(rhs)

  defp implies_connected_true?(_), do: false

  defp implies_connected_false?({:not, _, [inner]}), do: implies_connected_true?(inner)
  defp implies_connected_false?({:!, _, [inner]}), do: implies_connected_true?(inner)
  defp implies_connected_false?(_), do: false

  defp matches_true?(true), do: true
  defp matches_true?({:__block__, _, [true]}), do: true
  defp matches_true?(_), do: false

  # A call's module path matches a loader if ANY segment in the path
  # equals one of the loader names. `MyApp.Repo` matches `Repo`;
  # `Req` matches `Req` directly; `HTTPoison.get` matches `HTTPoison`.
  defp loader_match?(segs, loaders) do
    seg_strings = Enum.map(segs, &Atom.to_string/1)
    Enum.any?(loaders, fn loader -> loader in seg_strings end)
  end

  defp build_issue(meta, calls) do
    sample = calls |> Enum.take(3) |> Enum.join(", ")

    %Issue{
      rule: :liveview_query_in_mount,
      message:
        "`mount/3` calls #{sample} without a `connected?(socket)` guard. `mount/3` " <>
          "fires twice (HTTP render + WebSocket connect) so each call runs twice " <>
          "per page view. Gate with `if connected?(socket), do: …, else: …` or " <>
          "move the load into `handle_params/3` which runs once per route on the " <>
          "connected socket.",
      meta: %{line: Keyword.get(meta, :line), calls: calls}
    }
  end
end
