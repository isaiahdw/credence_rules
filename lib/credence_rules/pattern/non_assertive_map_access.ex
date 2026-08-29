defmodule CredenceRules.Pattern.NonAssertiveMapAccess do
  @moduledoc """
  Idiomatic rule: `map[:atom_key]` with a literal atom key silently
  returns `nil` when the key is missing — usually a bug.

  Elixir gives you two ways to read a map's value:

  - `map.atom_key` — assertive. Raises `KeyError` if missing.
  - `map[:atom_key]` — non-assertive. Returns `nil` if missing.

  The official Elixir
  [anti-pattern doc](https://hexdocs.pm/elixir/main/code-anti-patterns.html#non-assertive-map-access)
  recommends `map.key` for **required** fields and reserves `map[:key]`
  for genuinely optional fields where `nil` is a valid sentinel.

  In practice, LLM-generated code reaches for `map[:key]` uniformly
  because:

  - it works on any `Access`-implementing container (so the LLM
    doesn't have to think about whether the value is a map or a Keyword)
  - the failure mode is silent — tests that don't assert on the return
    value pass even when the key is wrong

  ## Bad

      def email(user) do
        user[:email]      # if :email is required, this hides typos
      end

  ## Good

      def email(user) do
        user.email        # raises if :email is missing — bug surfaces immediately
      end

      # Or, if email really is optional:
      def email(user) do
        Map.get(user, :email)     # explicit "may be missing"
      end

  ## Limitations

  - Variable keys (`map[k]` where `k` is a variable) are NOT flagged —
    the LLM-typo failure mode requires a literal key.
  - **Conventionally keyword-list-named variables are skipped** —
    `opts`, `options`, `config`, `params`, `attrs`, `args`, and any
    var ending in `_opts` / `_options` / `_config` / `_params` /
    `_args`. These are almost always `Keyword` not `Map`, and
    `kw[:atom]` is the idiomatic access. To override, use
    `Keyword.fetch!/2` explicitly.
  """

  use CredenceRules.Rule

  @keyword_list_var_names ~w(opts options config params attrs args)

  @keyword_list_var_suffixes ~w(_opts _options _config _params _attrs _args)

  @impl true
  def priority, do: 310

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        # `m[:atom]` parses as `{{:., meta, [Access, :get]}, meta, [m_ast, key]}`
        # with `from_brackets: true` in the inner meta. The `Access` reference
        # is a bare atom, NOT a `{:__aliases__, _, [:Access]}` node — that
        # distinguishes it from an explicit `Access.get(...)` call.
        {{:., inner_meta, [Access, :get]}, outer_meta, [container, key]} = node, acc ->
          cond do
            not from_brackets?(inner_meta) and not from_brackets?(outer_meta) ->
              # Explicit `Access.get(m, :k)` call — author opted in. Don't flag.
              {node, acc}

            keyword_list_receiver?(container) ->
              # `opts[:k]`, `config[:host]`, etc. — keyword list by convention.
              {node, acc}

            is_atom(key) and not is_nil(key) and not is_boolean(key) ->
              # `m[:atom_key]` with a literal atom (excluding nil/true/false
              # which would be weird key choices but legal).
              {node, [build_issue(outer_meta, key) | acc]}

            true ->
              # `m[var]` or `m["string"]` — different shape; don't flag.
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp from_brackets?(meta), do: Keyword.get(meta, :from_brackets) == true

  # `{var_name, _, ctx}` where `var_name` is a known keyword-list var.
  defp keyword_list_receiver?({name, _, ctx}) when is_atom(name) and is_atom(ctx) do
    str = Atom.to_string(name)

    str in @keyword_list_var_names or
      Enum.any?(@keyword_list_var_suffixes, &String.ends_with?(str, &1))
  end

  defp keyword_list_receiver?(_), do: false

  defp build_issue(meta, key) do
    %Issue{
      rule: :non_assertive_map_access,
      message:
        "`m[#{inspect(key)}]` (bracket access) silently returns `nil` if " <>
          "the key is missing — typo-friendly. Use `m.#{key}` for required " <>
          "fields (raises `KeyError` on miss), or `Map.get(m, #{inspect(key)})` " <>
          "if the field is genuinely optional and `nil` is a valid sentinel.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
