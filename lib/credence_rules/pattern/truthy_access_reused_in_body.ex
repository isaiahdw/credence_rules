# credence-file:iosp_mixed_function — this module is an AST pattern matcher
#   whose check/2 + Macro.prewalk + build_issue shape is the Rule contract
#   itself, so the structural duplication is inherent to the form rather than a
#   smell
defmodule CredenceRules.Pattern.TruthyAccessReusedInBody do
  @moduledoc """
  Idiom rule: an `if` that gates on a value, then the body
  re-reads the same value. The author wanted to bind the value
  once and branch on it — `if` makes them write the expression
  twice.

  ## Bad

      defp close_sockets(state) do
        if state.socket6, do: :socket.close(state.socket6)
        if state.socket4, do: :socket.close(state.socket4)
      end

      if cfg[:url], do: register(cfg[:url])

      if Map.get(user, :email), do: send_email(Map.get(user, :email))

      if conn.assigns.current_user do
        audit(conn.assigns.current_user)
      end

  Each of these gates on an access expression (`state.socket6`,
  `cfg[:url]`, `Map.get(user, :email)`, `conn.assigns.current_user`)
  and then reuses that exact expression in the body. The value
  is computed twice; the intent is "if non-nil/non-false, use it."

  ## Good — bind once, branch once

  Two common shapes, pick what fits:

  **Repeated operation → helper with pattern-matched clauses:**

      defp close_sockets(state) do
        close_socket(state.socket6)
        close_socket(state.socket4)
      end

      defp close_socket(nil), do: nil
      defp close_socket(false), do: nil
      defp close_socket(socket), do: :socket.close(socket)

  **One-off branching → local `case`:**

      case user.email do
        nil -> log("no email")
        false -> log("no email")
        email -> send_email(email)
      end

  ## False-preservation

  `if` treats both `nil` AND `false` as falsey. A naive rewrite to
  `case` that only handles `nil` changes semantics when the value
  is ever `false`:

      # WRONG (semantics change)
      case user.email do
        nil -> log("no email")
        email -> send(email)   # send(false) if value is `false`
      end

      # RIGHT
      case user.email do
        nil -> log("no email")
        false -> log("no email")
        email -> send(email)
      end

  If you can prove the value is never `false` (struct field
  declared as `String.t() | nil`, etc.), drop the `false` clause.

  ## Detection

  Flags `if <access_expr>, do: <body>` (with or without `else`)
  when ALL of:

  - `access_expr` is a **field-access shape**:
    - `x.y` and chained `x.y.z` (zero-arity dot calls)
    - `Map.get(x, :y)` / `Map.get(x, :y, default)` (exact `Map` module)
    - `Keyword.get(x, :y)` / `Keyword.get(x, :y, default)` (exact `Keyword`)
    - `x[:y]` bracket access (`Access.get/2`)
  - The same `access_expr` appears **structurally** in `body`
    (line numbers / meta stripped before compare) in a position
    that ISN'T string interpolation — i.e., the value is *operated
    on*, not merely displayed.
  - The accessed field name does NOT end in `?` — boolean fields
    (`user.admin?`, `feature.enabled?`, `opts[:debug?]`) are
    auto-skipped; pattern-matching them usually makes code worse.

  ## What's NOT flagged

  - `if <bare_var>, do: ...` — too broad; rule scoped to field access.
  - `if condition, do: action` where `action` doesn't reuse the
    condition — pure boolean test, no smell.
  - `if Enum.empty?(list), do: ...` — predicate function, not field access.
  - `if x > 0, do: ...` — comparison, not field access.
  - `if get_socket(state), do: :socket.close(get_socket(state))` —
    arbitrary function calls aren't flagged. You can't tell if the
    function is a cheap accessor, a predicate, or an expensive call
    intentionally repeated. Use a local binding (`socket = get_socket(state)`)
    if that's a real concern; separate rule territory.
  - `if plan.device_address, do: log("addr=\#{plan.device_address}")` —
    the value is only **interpolated into a string** (displayed), not
    operated on. There's nothing to extract into a helper and a 3-way
    `case` for a log line reads worse than the `if`. Reuses that occur
    solely inside `\#{...}` don't count.

  ## Why advisory

  Heuristic. Some flagged cases are fine as-is (one-off uses where
  helper extraction would be overkill, or contexts where the
  original `if` reads more clearly). Reviewer call.
  """

  use CredenceRules.Rule

  alias CredenceRules.AstKeyword

  @severity :low
  @confidence :medium

  @hint """
  You gated on a value, then re-read the same value. Bind or
  branch on the value once.

      # Repeated operation: helper with pattern-matched clauses
      defp close_sockets(state) do
        close_socket(state.socket6)
        close_socket(state.socket4)
      end

      defp close_socket(nil), do: nil
      defp close_socket(false), do: nil
      defp close_socket(socket), do: :socket.close(socket)

      # One-off branching: local `case`
      case user.email do
        nil -> log("no email")
        false -> log("no email")
        email -> send_email(email)
      end

  `if` treats BOTH `nil` and `false` as falsey — preserve both
  clauses unless the value provably can't be `false` (typespecs
  declare it nilable but not boolean).
  """

  @carve_outs [
    "Body that doesn't reuse the gated value (`if state.flag, do: log(\"set\")`) — pure boolean test, not flagged.",
    "Field names ending in `?` (`user.admin?`, `feature.enabled?`, `opts[:debug?]`) — likely boolean fields where pattern-matching makes code worse. Auto-skipped.",
    "Bare variables (`if user, do: ...`) — too broad for a heuristic rule. Scoped to field-access shapes only.",
    "Arbitrary function calls in the condition (`if get_socket(s), do: use(get_socket(s))`) — same smell, different concern. Use a local binding (`socket = get_socket(s)`); separate rule territory.",
    "Value only interpolated into a string (`if plan.device_address, do: log(\"addr=\#{plan.device_address}\")`) — it's displayed, not operated on. No helper to extract; a case for a log line reads worse. Reuses solely inside \#{...} are auto-skipped.",
    "One-off uses where extracting a helper is overkill — accept the finding if the `if` reads more clearly than a `case`."
  ]

  @impl true
  def priority, do: 483

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        # `if cond, do: body` and `if cond, do: body, else: else_body`
        {:if, meta, [cond, kw]} = node, acc when is_list(kw) ->
          case AstKeyword.get(kw, :do) do
            nil ->
              {node, acc}

            body ->
              if flag?(cond, body),
                do: {node, [build_issue(meta, cond) | acc]},
                else: {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp flag?(cond, body) do
    access_expr?(cond) and
      not boolean_field?(cond) and
      reused_outside_interpolation?(body, cond)
  end

  # `x.y` — zero-arity dot call (covers chained `x.y.z` because the
  # target can be another dot call recursively).
  defp access_expr?({{:., _, [_target, field]}, _, []}) when is_atom(field), do: true

  # `Map.get(x, :y)` and `Map.get(x, :y, default)`
  defp access_expr?({{:., _, [{:__aliases__, _, [:Map]}, :get]}, _, args})
       when is_list(args) and length(args) in 2..3,
       do: true

  # `Keyword.get(x, :y)` and `Keyword.get(x, :y, default)`
  defp access_expr?({{:., _, [{:__aliases__, _, [:Keyword]}, :get]}, _, args})
       when is_list(args) and length(args) in 2..3,
       do: true

  # `x[:y]` — Access.get/2. Elixir parses this as a bare `Access` atom,
  # not an `__aliases__` node.
  defp access_expr?({{:., _, [Access, :get]}, _, args}) when is_list(args), do: true

  defp access_expr?(_), do: false

  # Skip boolean-looking fields. `?` suffix is a strong Elixir signal
  # that the value is intentionally boolean — pattern-matching on it
  # usually reads worse than the `if`.
  defp boolean_field?({{:., _, [_target, field]}, _, []}) when is_atom(field) do
    ends_with_question?(field)
  end

  defp boolean_field?({{:., _, [{:__aliases__, _, [mod]}, :get]}, _, [_target, key | _]})
       when mod in [:Map, :Keyword] do
    key_ends_with_question?(key)
  end

  defp boolean_field?({{:., _, [Access, :get]}, _, [_target, key]}) do
    key_ends_with_question?(key)
  end

  defp boolean_field?(_), do: false

  defp ends_with_question?(atom) when is_atom(atom) do
    atom |> Atom.to_string() |> String.ends_with?("?")
  end

  defp key_ends_with_question?(atom) when is_atom(atom), do: ends_with_question?(atom)

  # Sourceror wraps bare atom keys in `{:__block__, _, [:atom]}`.
  defp key_ends_with_question?({:__block__, _, [atom]}) when is_atom(atom),
    do: ends_with_question?(atom)

  defp key_ends_with_question?(_), do: false

  # True if `expr` appears in `body` somewhere that ISN'T a string
  # interpolation. A value that's only interpolated into a string —
  # `if x, do: log("…#{x}…")` — is being *displayed*, not operated on:
  # there's no operation to extract into a helper and no `case` that
  # reads better, so the `if` is already the clearest shape. The
  # canonical smell reuses the value as an *operand*
  # (`:socket.close(state.socket6)`), which a pattern-matched helper or
  # `case` cleans up.
  #
  # Interpolation is marked by `from_interpolation: true` on the
  # `Kernel.to_string/1` wrapper the parser inserts — set by both
  # `Code.string_to_quoted/1` and Sourceror. Pruning that subtree means
  # reuses inside `#{...}` don't count.
  #
  # Structural equivalence strips metadata from every node (line
  # numbers / context vary between identical expressions at different
  # source positions) before comparing.
  defp reused_outside_interpolation?(body, expr) do
    normalized_expr = normalize(expr)

    {_, found} =
      Macro.prewalk(body, false, fn
        _node, true ->
          {[], true}

        {_form, meta, _args} = node, acc when is_list(meta) ->
          cond do
            Keyword.get(meta, :from_interpolation, false) -> {[], acc}
            normalize(node) == normalized_expr -> {node, true}
            true -> {node, acc}
          end

        node, acc ->
          if normalize(node) == normalized_expr,
            do: {node, true},
            else: {node, acc}
      end)

    found
  end

  # `Macro.update_meta/2` only touches the top-level node. Recursive
  # strip via `Macro.prewalk/2` clears meta on every nested node so
  # the same expression at different lines compares equal.
  defp normalize(ast) do
    Macro.prewalk(ast, fn node ->
      Macro.update_meta(node, fn _ -> [] end)
    end)
  end

  defp build_issue(meta, expr) do
    %Issue{
      rule: :truthy_access_reused_in_body,
      message:
        "`if #{Macro.to_string(expr)}` gates on a value, then the body re-reads " <>
          "the same value. Bind it once with a pattern-matched helper or local " <>
          "`case`. Preserve BOTH `nil` and `false` clauses to match `if`'s falsey " <>
          "semantics, unless the value provably can't be `false`.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
