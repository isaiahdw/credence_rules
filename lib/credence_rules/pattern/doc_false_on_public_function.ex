defmodule CredenceRules.Pattern.DocFalseOnPublicFunction do
  @moduledoc """
  Readability rule: multiple `@doc false` on public `def`s inside one
  module is cargo-culted hiding — typically copy-pasted from Phoenix
  generators or LLM output that's trying to "make the API look private
  without committing to `defp`."

  A single `@doc false` on a deliberately-internal public function is
  fine (that's what it's for). But sprayed across 3+ public functions
  it usually means *those functions should be `defp`* or *those
  functions should actually be documented*.

  ## Bad

      defmodule MyAppWeb.UserController do
        @doc false
        def index(conn, _params), do: ...

        @doc false
        def show(conn, %{"id" => id}), do: ...

        @doc false
        def create(conn, %{"user" => params}), do: ...
      end

  ## Good

      defmodule MyAppWeb.UserController do
        def index(conn, _params), do: ...
        def show(conn, %{"id" => id}), do: ...
      end

  ## Detection

  Fires once per `@doc false` `def` (after threshold) in the module.
  OTP callbacks (`init`, `handle_call`, `handle_cast`, `handle_info`,
  `handle_continue`, `terminate`, `code_change`, `format_status`,
  `child_spec`, `start_link`) and dunder functions (`__using__`,
  `__before_compile__`, `__after_compile__`, …) are exempt — those
  defs SHOULD carry `@doc false`.

  Threshold defaults to 2 hits per module. Override via opts:
  `min_count: 3`.

  Ported from
  [`ExSlop.Check.Readability.DocFalseOnPublicFunction`](https://hex.pm/packages/ex_slop).
  """

  use CredenceRules.Rule

  @default_min_count 2

  @otp_callbacks ~w(child_spec start_link init terminate code_change
    handle_call handle_cast handle_info handle_continue format_status)a

  @dunder_functions ~w(__using__ __before_compile__ __after_compile__
    __changeset__ __struct__ __schema__ __fields__ __resource__)a

  @impl true
  def priority, do: 250

  @impl true
  def check(ast, opts) do
    min_count = Keyword.get(opts, :min_count, @default_min_count)

    {_ast, {hits, _pending}} =
      Macro.prewalk(ast, {[], false}, fn node, acc -> walk(node, acc) end)

    if length(hits) >= min_count do
      hits |> Enum.reverse() |> Enum.map(fn {meta, name} -> build_issue(meta, name) end)
    else
      []
    end
  end

  # @doc false → arm the "next public def is suspicious" flag
  defp walk({:@, _, [{:doc, _, [false]}]} = node, {hits, _}), do: {node, {hits, true}}

  # @impl true on a def → it's an OTP callback or behaviour impl;
  # disarm. The `@doc false` is legit there.
  defp walk({:@, _, [{:impl, _, [true]}]} = node, {hits, _}), do: {node, {hits, false}}

  defp walk({:@, _, [{:impl, _, [{:__block__, _, [true]}]}]} = node, {hits, _}),
    do: {node, {hits, false}}

  # Public def while armed → record (unless the name is exempt).
  defp walk({:def, meta, [head | _]} = node, {hits, true}) do
    case def_name(head) do
      nil ->
        {node, {hits, false}}

      name ->
        if exempt?(name),
          do: {node, {hits, false}},
          else: {node, {[{meta, name} | hits], false}}
    end
  end

  # Private def disarms (defp + @doc false is uncommon but harmless).
  defp walk({:defp, _, _} = node, {hits, _}), do: {node, {hits, false}}

  # Any other @doc or @moduledoc disarms (we only care about consecutive
  # `@doc false` → `def` pairs).
  defp walk({:@, _, [{attr, _, _}]} = node, {hits, _}) when attr in [:doc, :moduledoc],
    do: {node, {hits, false}}

  defp walk(node, acc), do: {node, acc}

  # `:when` is itself an atom, so the guarded-head clause must come
  # first — otherwise `{name, _, _}` matches it and returns `:when`.
  defp def_name({:when, _, [inner | _]}), do: def_name(inner)
  defp def_name({name, _, _}) when is_atom(name), do: name
  defp def_name(_), do: nil

  defp exempt?(name), do: name in @otp_callbacks or name in @dunder_functions

  defp build_issue(meta, name) do
    %Issue{
      rule: :doc_false_on_public_function,
      message:
        "`@doc false` on public `def #{name}/_` — at least #{@default_min_count} public " <>
          "functions in this module are hidden this way. Make these `defp` if they're " <>
          "internal, or write a real `@doc` if they're public API.",
      meta: %{line: Keyword.get(meta, :line), name: name}
    }
  end
end
