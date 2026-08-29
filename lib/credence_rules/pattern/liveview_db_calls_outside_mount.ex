defmodule CredenceRules.Pattern.LiveviewDbCallsOutsideMount do
  @moduledoc """
  Architecture rule: a Phoenix LiveView (or LiveComponent) module
  shouldn't call `Repo.*`, HTTP clients, or `Mailer` modules
  **directly** from any callback or helper function. Direct
  data-access calls in the view layer skip the context boundary —
  the same anti-pattern as `fat_controller`, but for LiveView.

  Companion to `liveview_query_in_mount`, which targets the
  specific `mount/3` double-fire performance bug. This rule
  targets the broader SRP concern: data loading belongs in a
  context (`MyApp.Accounts.list_users/0`), not inlined into a
  `handle_event/3` clause or a private LiveView helper.

  ## Bad

      defmodule MyAppWeb.UserLive do
        use Phoenix.LiveView

        def handle_event("delete", %{"id" => id}, socket) do
          # Repo call inlined into the view layer — skips Accounts context.
          user = Repo.get!(User, id)
          Repo.delete!(user)
          {:noreply, socket}
        end

        def handle_info({:user_updated, id}, socket) do
          # HTTP client called from the view — should be a context fn.
          {:ok, profile} = Req.get!("https://profiles/" <> id)
          {:noreply, assign(socket, profile: profile)}
        end
      end

  ## Good — delegate to a context

      defmodule MyAppWeb.UserLive do
        use Phoenix.LiveView

        def handle_event("delete", %{"id" => id}, socket) do
          :ok = MyApp.Accounts.delete_user(id)
          {:noreply, socket}
        end

        def handle_info({:user_updated, id}, socket) do
          {:ok, profile} = MyApp.Profiles.fetch(id)
          {:noreply, assign(socket, profile: profile)}
        end
      end

  ## Detection

  Inside a LiveView/LiveComponent module (detected via
  `use Phoenix.LiveView`, `use Phoenix.LiveComponent`, or the
  `use MyAppWeb, :live_view` / `:live_component` shape), any
  `def` / `defp` body that contains a call to a configured loader
  module is flagged. Defaults match `liveview_query_in_mount`:

  - `Repo`
  - `HTTPoison`, `Req`, `Finch`, `Tesla`
  - `Oban`

  Override via `:loader_modules`. Match is by trailing alias
  segment (so `MyApp.Repo` matches `Repo`).

  ## Why this is separate from `liveview_query_in_mount`

  - `liveview_query_in_mount` exists because `mount/3` fires
    **twice** — it's a performance-bug rule, gated on the
    `connected?(socket)` exemption.
  - This rule is about **SRP** — LiveView shouldn't talk to the
    persistence layer directly anywhere. No `connected?` exemption
    applies: a `Repo.delete!` inside `handle_event/3` is fine
    *performance-wise* (only fires when the event triggers) but
    skips the context boundary regardless.

  Both rules can fire on the same line (mount with a Repo call
  without connected?). They report different concerns; both reads
  are useful.

  ## Why advisory

  Some LiveViews legitimately own a small bit of state with no
  context wrapper (admin tools, internal dashboards). Treat
  findings as "should this load go through a context?" — not a
  hard cap.
  """

  use CredenceRules.Rule

  alias CredenceRules.AstKeyword

  @default_loaders ~w(Repo HTTPoison Req Finch Tesla Oban)

  @impl true
  def priority, do: 451

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
                do: {node, scan_functions(body, loaders) ++ acc},
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

  # Scan every def/defp in the module body. `mount/3` itself is
  # skipped — `liveview_query_in_mount` covers it (with the
  # `connected?` exemption). The other LiveView callbacks
  # (handle_event, handle_info, handle_params, render) and any
  # private helpers in the module are in scope.
  defp scan_functions(body, loaders) do
    body
    |> top_level_statements()
    |> Enum.flat_map(fn
      {def_kind, _meta, [head, kw]} = _node
      when def_kind in [:def, :defp] and is_list(kw) ->
        case def_info(head, kw) do
          {:ok, name, arity, def_body} ->
            if skip_function?(name, arity) do
              []
            else
              flag_if_loader_call(def_body, name, arity, loaders)
            end

          :error ->
            []
        end

      _ ->
        []
    end)
  end

  defp def_info({:when, _, [inner, _guard]}, kw), do: def_info(inner, kw)

  defp def_info({name, _meta, params}, kw)
       when is_atom(name) and is_list(params) do
    {:ok, name, length(params), AstKeyword.get(kw, :do)}
  end

  # `defp foo, do: …` (no parens, no args) AST'd with `params = nil`.
  defp def_info({name, _meta, nil}, kw) when is_atom(name) do
    {:ok, name, 0, AstKeyword.get(kw, :do)}
  end

  defp def_info(_, _), do: :error

  # mount/3 and mount/4 belong to `liveview_query_in_mount`.
  defp skip_function?(:mount, arity) when arity in [3, 4], do: true
  defp skip_function?(_, _), do: false

  defp flag_if_loader_call(nil, _name, _arity, _loaders), do: []

  defp flag_if_loader_call(body, name, arity, loaders) do
    case find_loader_calls(body, loaders) do
      [] -> []
      calls -> [build_issue(name, arity, calls, body)]
    end
  end

  defp find_loader_calls(body, loaders) do
    {_ast, calls} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, segs}, fun]}, _, args} = node, acc
        when is_atom(fun) and is_list(args) ->
          if loader_match?(segs, loaders),
            do: {node, [{segs, fun} | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    calls
    |> Enum.uniq()
    |> Enum.map(fn {segs, fun} ->
      "#{Enum.map_join(segs, ".", &Atom.to_string/1)}.#{fun}"
    end)
  end

  defp loader_match?(segs, loaders) do
    seg_strings = Enum.map(segs, &Atom.to_string/1)
    Enum.any?(loaders, fn loader -> loader in seg_strings end)
  end

  defp build_issue(name, arity, calls, body) do
    sample = calls |> Enum.take(3) |> Enum.join(", ")

    %Issue{
      rule: :liveview_db_calls_outside_mount,
      message:
        "LiveView function `#{name}/#{arity}` calls #{sample} directly. Data " <>
          "access belongs in a context module — delegate via a context fn " <>
          "(`MyApp.Accounts.list_users/0`) so the LiveView stays a view-layer " <>
          "concern. `mount/3` is exempt (see `liveview_query_in_mount`).",
      meta: %{
        line: body_line(body),
        function: name,
        arity: arity,
        calls: calls
      }
    }
  end

  # First metadata line we can find in the body — close enough to
  # point a reviewer at the right neighbourhood.
  defp body_line(body) do
    {_ast, lines} =
      Macro.prewalk(body, [], fn
        {_form, meta, _args} = node, acc when is_list(meta) ->
          case Keyword.get(meta, :line) do
            nil -> {node, acc}
            line -> {node, [line | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    case lines do
      [] -> nil
      _ -> Enum.min(lines)
    end
  end
end
