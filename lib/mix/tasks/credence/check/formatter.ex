defmodule Mix.Tasks.Credence.Check.Formatter do
  @moduledoc """
  Dispatch shim — picks the right formatter module for the requested
  output format and delegates to `render/2`.

  Supported formats: `:text` (default), `:github`, `:ai`.

  Each formatter exports `render(report, opts)` and returns the full
  stdout payload as a single string. The Mix task is responsible for
  printing it; formatters are pure.
  """

  alias CredenceRules.Score
  alias Mix.Tasks.Credence.Check.Formatter.{Ai, Github, Text}

  @type issue :: %{path: String.t(), rule: atom(), message: String.t(), line: pos_integer() | nil}

  @type report :: %{
          issues: [issue],
          score: Score.t(),
          files: [String.t()],
          strict?: boolean()
        }

  @formats [:text, :github, :ai]
  # User-facing aliases that map to a canonical format. `:json` is an
  # alias for `:ai` so non-AI consumers wanting structured output find
  # what they expect.
  @aliases %{json: :ai}

  @doc "Returns the list of supported format atoms (canonical names)."
  @spec supported() :: [atom()]
  def supported, do: @formats

  @doc """
  Parse a format string (from CLI or config) into one of the
  supported atoms. Returns `{:ok, format}` or `{:error, reason}` with
  a user-facing reason. Aliases (e.g. `"json"` → `:ai`) are resolved
  here so callers always see a canonical format atom.
  """
  @spec parse(String.t() | atom() | nil) :: {:ok, atom()} | {:error, String.t()}
  def parse(nil), do: {:ok, :text}
  def parse(format) when format in @formats, do: {:ok, format}
  def parse(format) when is_atom(format) and is_map_key(@aliases, format), do: {:ok, @aliases[format]}

  def parse(format) when is_binary(format) do
    cond do
      atom = Enum.find(@formats, &(Atom.to_string(&1) == format)) ->
        {:ok, atom}

      alias_atom = find_alias_atom(format) ->
        {:ok, @aliases[alias_atom]}

      true ->
        unknown_format_error("unknown", format)
    end
  end

  def parse(other), do: unknown_format_error("invalid", other)

  defp unknown_format_error(kind, format),
    do: {:error, "#{kind} format #{inspect(format)} — expected one of: #{format_list()}"}

  defp find_alias_atom(format) do
    Enum.find_value(@aliases, fn {alias_atom, _canonical} ->
      if Atom.to_string(alias_atom) == format, do: alias_atom
    end)
  end

  @doc "Render the report using the requested format."
  @spec render(atom(), report()) :: String.t()
  def render(:text, report), do: Text.render(report)
  def render(:github, report), do: Github.render(report)
  def render(:ai, report), do: Ai.render(report)

  defp format_list do
    alias_strings = Enum.map(@aliases, fn {alias_atom, _} -> Atom.to_string(alias_atom) end)

    (Enum.map(@formats, &Atom.to_string/1) ++ alias_strings)
    |> Enum.sort()
    |> Enum.join(", ")
  end
end
