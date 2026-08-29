defmodule CredenceRules.CommentScan do
  @moduledoc """
  Real-source-comment extraction for the comment-style rules.

  Previously, the comment rules (`obvious_comment`, `narrator_comment`,
  `step_comment`, `stale_reference_comment`, `no_todo_or_roadmap_comment`)
  each split the source on `\\n` and grep'd for `#`-prefixed lines.
  That false-positived on `@moduledoc` examples — a docstring's
  `## Bad` block typically demonstrates the *exact* anti-pattern the
  rule catches, so the rule fired on its own documentation. The
  self-scan output was full of "obvious_comment in
  obvious_comment.ex" entries that no one could act on.

  This helper uses `Code.string_to_quoted_with_comments/2` (Elixir
  1.13+), which returns *only* real source comments — anything
  inside `\"\"\"…\"\"\"` triple-quoted strings is treated as the
  string content it actually is.

  Each entry is `%{line: integer, body: String.t()}` — `body` is
  the comment with the leading `#` and any whitespace stripped.

  Falls back to a regex-based scan if `Code.string_to_quoted_with_comments`
  fails (syntax-broken file). Better to over-flag than to silently
  miss real comments in a file that's otherwise scannable.
  """

  @doc """
  Extract real source comments from a source string. Returns
  `[%{line: integer, body: String.t()}]` ordered by line.
  """
  @spec extract(String.t()) :: [%{line: pos_integer(), body: String.t()}]
  def extract(source) when is_binary(source) do
    case Code.string_to_quoted_with_comments(source) do
      {:ok, _ast, comments} ->
        Enum.map(comments, fn %{line: line, text: text} ->
          %{line: line, body: strip_hash(text)}
        end)

      {:error, _} ->
        fallback_scan(source)
    end
  end

  defp strip_hash("#" <> rest), do: String.trim_leading(rest)
  defp strip_hash(other), do: other

  # Syntax-broken file: best effort. Splits on `\n` and pulls
  # `#`-prefixed lines. Will false-positive on `#` inside a string,
  # but a syntax-broken file is already in a degraded state.
  defp fallback_scan(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, line_no} ->
      case String.trim_leading(line) do
        "#" <> rest -> [%{line: line_no, body: String.trim_leading(rest)}]
        _ -> []
      end
    end)
  end
end
