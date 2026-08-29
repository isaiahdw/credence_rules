defmodule CredenceRules.AstKeyword do
  @moduledoc """
  Lookups for keyword lists that appear **inside an AST** — as opposed
  to keyword-list metadata attached to AST nodes.

  Sourceror wraps every literal — including keyword keys — in a
  `{:__block__, meta, [literal]}` node to preserve trivia. So a source
  fragment like `try do ... rescue _ -> :ok end` parses to:

      {:try, _, [
        [
          {{:__block__, _meta, [:do]},     do_body},
          {{:__block__, _meta, [:rescue]}, rescue_clauses}
        ]
      ]}

  `Keyword.has_key?(kw, :rescue)` on that list returns `false` because
  the key is `{:__block__, _, [:rescue]}`, not `:rescue`. The check
  task uses `Sourceror.parse_string/1` (per `Credence.Pattern.analyze/2`),
  so any rule that uses bare-atom keyword lookups on AST nodes silently
  misclassifies every match.

  These helpers unwrap Sourceror's block wrapper before comparing, so
  rules work whether the AST came from `Code.string_to_quoted/1` (bare
  atoms — what tests use) or `Sourceror.parse_string/1` (wrapped keys
  — what production uses).

  Use these for keyword lists **in the AST** (the body of a `try`,
  `with`, `if`, `case`, `defdelegate` options, etc.). Do NOT use them
  for the `meta` keyword list attached to AST nodes — that's always
  bare-atom-keyed regardless of parser.
  """

  @type ast_kw :: [{atom() | {:__block__, keyword(), [atom()]}, term()}]

  @doc """
  Returns true if `kw` contains an entry whose key — unwrapped from
  any Sourceror block wrapper — equals `key`.
  """
  @spec has_key?(ast_kw(), atom()) :: boolean()
  def has_key?(kw, key) when is_list(kw) and is_atom(key) do
    Enum.any?(kw, &match_key?(&1, key))
  end

  @doc """
  Returns the value of the first entry whose key matches `key`, or
  `default` if no such entry exists.
  """
  def get(kw, key, default \\ nil) when is_list(kw) and is_atom(key) do
    case Enum.find(kw, &match_key?(&1, key)) do
      {_k, v} -> v
      nil -> default
    end
  end

  defp match_key?({{:__block__, _, [k]}, _v}, key) when is_atom(k), do: k == key
  defp match_key?({k, _v}, key) when is_atom(k), do: k == key
  defp match_key?(_, _), do: false
end
