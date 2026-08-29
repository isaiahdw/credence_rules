defmodule CredenceRules.Pattern.ModuleThatReExportsOnly do
  @moduledoc """
  SRP rule: a module whose every public function is a one-line
  delegation to another module exists solely to flatten a namespace.
  Either inline the calls at the call sites, or use `defdelegate` so
  the intent is documented.

  ## Bad

      defmodule MyApp.Users do
        def fetch(id), do: MyApp.Users.Storage.fetch(id)
        def create(attrs), do: MyApp.Users.Storage.create(attrs)
        def update(user, attrs), do: MyApp.Users.Storage.update(user, attrs)
        def delete(user), do: MyApp.Users.Storage.delete(user)
      end

  Every `def` adds a layer with no behaviour — and no `defdelegate`
  to make the layer's purpose explicit. Readers debugging an error
  hop through this module to land in `Storage` anyway.

  ## Good — `defdelegate`

      defmodule MyApp.Users do
        defdelegate fetch(id), to: MyApp.Users.Storage
        defdelegate create(attrs), to: MyApp.Users.Storage
        defdelegate update(user, attrs), to: MyApp.Users.Storage
        defdelegate delete(user), to: MyApp.Users.Storage
      end

  `defdelegate` documents "this is a passthrough" in the code,
  generates the same compiled output, and lets readers know not to
  search for behaviour at this layer.

  ## Better — drop the wrapper

  If the wrapper has no other purpose, callers can use
  `MyApp.Users.Storage` directly. If you want a stable boundary for
  swapping the impl, that's the use case `defdelegate` documents
  explicitly.

  ## Detection

  Flags a module when:

  1. It has at least `:min_defs` (default 3) public `def`s, AND
  2. Every public `def` body is a single function call to a remote
     module (e.g. `OtherMod.fun(args)` or `OtherMod.fun(args, opts)`),
     AND
  3. Each delegate call's args are exactly the same as the
     delegating function's parameters in the same order.

  `defdelegate` doesn't count as a public `def`, so a module that's
  half-delegate-half-real-def doesn't fire. The check only catches
  the "all manual delegation" shape.

  ## Why advisory

  Some legitimate facade modules do exist (boundary contracts for
  inter-bounded-context calls, swappable adapter façades). Treat
  findings as "is this layer earning its keep?" — not a hard rule.
  """

  use CredenceRules.Rule

  @hint """
  Either use `defdelegate` to make the passthrough explicit, or
  drop the wrapper entirely.

      # Before — manual passthrough
      defmodule MyApp.Users do
        def fetch(id), do: MyApp.Users.Storage.fetch(id)
        def create(attrs), do: MyApp.Users.Storage.create(attrs)
        def update(u, a), do: MyApp.Users.Storage.update(u, a)
      end

      # After (option A) — defdelegate documents the passthrough
      defmodule MyApp.Users do
        defdelegate fetch(id), to: MyApp.Users.Storage
        defdelegate create(attrs), to: MyApp.Users.Storage
        defdelegate update(u, a), to: MyApp.Users.Storage
      end

      # After (option B) — drop the wrapper, callers use Storage directly
      # (delete MyApp.Users entirely; rg + sed callers)

  `defdelegate` compiles to the same code but tells readers "this
  is a passthrough" — they won't search for behaviour at this layer.
  """

  @carve_outs [
    "Facades delegating to MULTIPLE collaborators (storage + mailer + notifier) — coordination layer, not a re-export. Rule's single-target check auto-skips these.",
    "Boundary contracts where the wrapper exists to make a context's public API discoverable (Phoenix's `MyApp.Accounts` is often this) — acceptable, accept the finding as a reviewer hint."
  ]

  alias CredenceRules.AstKeyword

  @default_min_defs 3

  @impl true
  def priority, do: 430

  @impl true
  def check(ast, opts) do
    min_defs = Keyword.get(opts, :min_defs, @default_min_defs)

    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:defmodule, meta, [_alias, kw]} = node, acc when is_list(kw) ->
          case AstKeyword.get(kw, :do) do
            nil -> {node, acc}
            body -> {node, check_module(body, meta, min_defs) ++ acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp check_module(body, meta, min_defs) do
    public_defs = collect_public_defs(body)

    cond do
      length(public_defs) < min_defs ->
        []

      not Enum.all?(public_defs, &passthrough?/1) ->
        []

      # Verify all delegate to the SAME target module. Facades that
      # delegate to multiple collaborators (boundary contracts that
      # compose several adapters) are NOT what this rule targets —
      # those legitimately need a layer to coordinate.
      single_target?(public_defs) ->
        [first | _] = public_defs
        target = passthrough_target(first)
        [build_issue(meta, length(public_defs), target)]

      true ->
        []
    end
  end

  defp single_target?(public_defs) do
    targets =
      public_defs
      |> Enum.map(&passthrough_target/1)
      |> Enum.uniq()

    match?([_], targets)
  end

  defp passthrough_target({_node, _head, body}) do
    case remote_call(body) do
      {segs, _fun, _args} -> Enum.map_join(segs, ".", &Atom.to_string/1)
      _ -> nil
    end
  end

  defp collect_public_defs(body) do
    statements =
      case body do
        {:__block__, _, list} -> list
        single -> [single]
      end

    Enum.flat_map(statements, fn
      {:def, _, [head, kw]} = node when is_list(kw) ->
        case AstKeyword.get(kw, :do) do
          nil -> []
          body -> [{node, head, body}]
        end

      _ ->
        []
    end)
  end

  # A `def name(p1, p2) do OtherMod.f(p1, p2) end` is a passthrough.
  # The remote call's args must mirror the def's params in order.
  defp passthrough?({_node, head, body}) do
    with {name, params} <- def_signature(head),
         {_remote_mod, _remote_fun, args} <- remote_call(body),
         true <- args_match_params?(args, params) do
      _ = name
      true
    else
      _ -> false
    end
  end

  defp def_signature({:when, _, [inner, _guard]}), do: def_signature(inner)

  defp def_signature({name, _meta, params}) when is_atom(name) and is_list(params) do
    {name, params}
  end

  defp def_signature({name, _meta, nil}) when is_atom(name), do: {name, []}
  defp def_signature(_), do: nil

  # `OtherMod.fun(args)` parses as `{{:., _, [{:__aliases__, _, _segs}, fun]}, _, args}`.
  # Sourceror may wrap; the actual call shape is the same.
  defp remote_call({:__block__, _, [inner]}), do: remote_call(inner)

  defp remote_call({{:., _, [{:__aliases__, _, segs}, fun]}, _, args})
       when is_atom(fun) and is_list(args) do
    {segs, fun, args}
  end

  defp remote_call(_), do: nil

  defp args_match_params?(args, params) when length(args) == length(params) do
    Enum.zip(args, params)
    |> Enum.all?(fn {arg, param} -> same_var?(arg, param) end)
  end

  defp args_match_params?(_, _), do: false

  # Sourceror-block-wrapped variable in arg position.
  defp same_var?({:__block__, _, [inner]}, param), do: same_var?(inner, param)

  defp same_var?({name, _, ctx_a}, {name, _, ctx_b})
       when is_atom(name) and is_atom(ctx_a) and is_atom(ctx_b),
       do: true

  defp same_var?(_, _), do: false

  defp build_issue(meta, def_count, target) do
    %Issue{
      rule: :module_that_re_exports_only,
      message:
        "Module has #{def_count} public `def`s, all one-line passthroughs to " <>
          "`#{target}`. The wrapper layer adds no behaviour. Use `defdelegate` so " <>
          "the passthrough is explicit, or drop the wrapper and let callers " <>
          "reach `#{target}` directly.",
      meta: %{line: Keyword.get(meta, :line), defs: def_count, target: target}
    }
  end
end
