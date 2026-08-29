defmodule CredenceRules.CrossFile.ModuleSource do
  @moduledoc """
  Per-module source metrics for the cross-file coupling rules, keyed by
  the same dotted module-name strings `ModuleGraph` uses.

  The graph knows a module's fan-in / fan-out; these rules also want to
  know how *big* the module is — a high-fan-in vocabulary type and a
  high-fan-in god-module look identical in the graph but differ on the
  page. One place computes that from the source AST.
  """

  alias CredenceRules.AstKeyword
  alias CredenceRules.CrossFile.ModuleGraph

  @doc """
  Map of `module-name => approximate LOC` for every file's defining
  module. LOC is the line span of the module body (max line − min line
  across its metadata) — close enough to flag "tiny" vs "substantial"
  without the source text.
  """
  @spec loc_by_module([{Path.t(), Macro.t()}]) :: %{String.t() => non_neg_integer()}
  def loc_by_module(files) do
    Enum.reduce(files, %{}, fn {_path, ast}, acc ->
      case defining_module(ast) do
        {name, body} -> Map.put(acc, name, line_span(body))
        nil -> acc
      end
    end)
  end

  @doc """
  The first `defmodule` in a file as `{module_name_string, body_ast}`,
  or `nil`. Handles both bare-atom (`Code.string_to_quoted`) and
  Sourceror keyword shapes for the `do` block.
  """
  @spec defining_module(Macro.t()) :: {String.t(), Macro.t()} | nil
  def defining_module({:defmodule, _, [alias_node, kw]}) when is_list(kw) do
    case {ModuleGraph.module_name(alias_node), AstKeyword.get(kw, :do)} do
      {name, body} when is_binary(name) -> {name, body}
      _ -> nil
    end
  end

  def defining_module({:__block__, _, statements}) do
    Enum.find_value(statements, &defining_module/1)
  end

  def defining_module(_), do: nil

  @doc "Line span of an AST: `max(line) - min(line) + 1`, or 0 if unknown."
  @spec line_span(Macro.t()) :: non_neg_integer()
  def line_span(ast) do
    {_ast, lines} =
      Macro.prewalk(ast, [], fn
        {_form, meta, _args} = node, acc when is_list(meta) ->
          case Keyword.get(meta, :line) do
            nil -> {node, acc}
            line -> {node, [line | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    case lines do
      [] -> 0
      lines -> Enum.max(lines) - Enum.min(lines) + 1
    end
  end
end
