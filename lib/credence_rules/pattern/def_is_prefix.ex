defmodule CredenceRules.Pattern.DefIsPrefix do
  @moduledoc """
  Convention rule: the `is_` prefix on a function name is reserved for
  guards.

  Elixir's standard library uses the `is_` prefix exclusively for
  guard-safe predicates: `is_atom/1`, `is_binary/1`, `is_list/1`,
  `is_map_key/2`, etc. These are defined via `defguard/1` (or as BIFs)
  so they can appear in `when` clauses and `case`/`with`/`cond` guards.

  A `def is_foo?` (or worse, `def is_foo`) is a function that *looks
  like* a guard but can't be used as one. Callers reading the code
  will reach for `when is_foo?(x)` and discover at compile time that
  it doesn't compile.

  Naming conventions:

  - **Boolean-returning regular functions:** `foo?/1` (`valid?/1`,
    `expired?/1`, `member?/2`)
  - **Boolean-returning guards:** `defguard is_foo(x) when …`
  - **Predicate over a value:** `Foo.valid?/1`, not `Foo.is_valid/1`

  ## Bad

      def is_valid_time?(cert), do: cert.not_after > now()

      # Caller can't write:
      def handle(cert) when is_valid_time?(cert), do: ...  # CompileError

  ## Good

      def valid_time?(cert), do: cert.not_after > now()
      # Or, if you want guard usability:
      defguard is_valid_time(cert) when cert.not_after > now()
  """

  use CredenceRules.Rule

  @impl true
  def priority, do: 260

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {kind, _meta, [head, _body]} = node, acc when kind in [:def, :defp] ->
          case extract_name_meta(head) do
            {name, name_meta} ->
              str = Atom.to_string(name)

              if String.starts_with?(str, "is_") and str not in ~w(is_list is_map is_binary) do
                {node, [build_issue(name_meta, str) | acc]}
              else
                {node, acc}
              end

            :no ->
              {node, acc}
          end

        # `defguard` is fine — it's the legitimate is_*/1 namespace.
        {:defguard, _, _} = node, acc ->
          {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp extract_name_meta({:when, _, [inner, _]}), do: extract_name_meta(inner)

  defp extract_name_meta({name, meta, args}) when is_atom(name) and is_list(args),
    do: {name, meta}

  defp extract_name_meta(_), do: :no

  defp build_issue(meta, name) do
    suggested = String.replace_prefix(name, "is_", "") |> trailing_question_mark()

    %Issue{
      rule: :def_is_prefix,
      message:
        "`def #{name}` looks like a guard but isn't — the `is_` prefix is " <>
          "reserved for `defguard`-defined predicates that work in `when` " <>
          "clauses. Rename to `#{suggested}` (regular `?`-suffix predicate) " <>
          "or convert to `defguard #{name}(x) when …` if it should be guard-usable.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end

  defp trailing_question_mark(name) do
    if String.ends_with?(name, "?"), do: name, else: name <> "?"
  end
end
