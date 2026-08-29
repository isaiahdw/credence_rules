defmodule CredenceRules.Pattern.TryRescueWithSafeAlternative do
  @moduledoc """
  Safety rule: a `try/rescue` whose body is a single call to a function
  that ships a non-raising sibling (`String.to_integer/1` →
  `Integer.parse/1`, `Jason.decode!/1` → `Jason.decode/1`, `Map.fetch!/2`
  → `Map.fetch/2`, etc.) is an "I don't know Elixir's API" tell.

  Using the safe alternative makes the failure case visible in the
  return type and removes the cost of building / unwinding an exception.

  ## Bad

      try do
        String.to_integer(value)
      rescue
        _ -> nil
      end

  ## Good

      case Integer.parse(value) do
        {int, ""} -> int
        _ -> nil
      end

  ## Recognised pairs

  | Raising                  | Safe alternative              |
  |--------------------------|-------------------------------|
  | `String.to_integer/1`    | `Integer.parse/1`             |
  | `String.to_float/1`      | `Float.parse/1`               |
  | `String.to_atom/1`       | `String.to_existing_atom/1`   |
  | `Jason.decode!/1,2`      | `Jason.decode/1,2`            |
  | `JSON.decode!/1`         | `JSON.decode/1`               |
  | `Map.fetch!/2`           | `Map.fetch/2`                 |
  | `Keyword.fetch!/2`       | `Keyword.fetch/2`             |
  | `Enum.fetch!/2`          | `Enum.fetch/2` or `Enum.at/2` |
  | `File.read!/1`           | `File.read/1`                 |
  | `File.write!/2,3`        | `File.write/2,3`              |

  Ported from
  [`ExSlop.Check.Refactor.TryRescueWithSafeAlternative`](https://hex.pm/packages/ex_slop).
  """

  use CredenceRules.Rule

  alias CredenceRules.AstKeyword

  @raising %{
    {:String, :to_integer, 1} => "Integer.parse/1",
    {:String, :to_float, 1} => "Float.parse/1",
    {:String, :to_atom, 1} => "String.to_existing_atom/1",
    {:Jason, :decode!, 1} => "Jason.decode/1",
    {:Jason, :decode!, 2} => "Jason.decode/2",
    {:JSON, :decode!, 1} => "JSON.decode/1",
    {:Map, :fetch!, 2} => "Map.fetch/2",
    {:Keyword, :fetch!, 2} => "Keyword.fetch/2",
    {:Enum, :fetch!, 2} => "Enum.fetch/2 (or Enum.at/2)",
    {:File, :read!, 1} => "File.read/1",
    {:File, :write!, 2} => "File.write/2",
    {:File, :write!, 3} => "File.write/3"
  }

  @impl true
  def priority, do: 600

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:try, meta, [kw]} = node, acc when is_list(kw) ->
          if AstKeyword.has_key?(kw, :rescue) do
            case find_raising(AstKeyword.get(kw, :do)) do
              {raising, safe} -> {node, [build_issue(meta, raising, safe) | acc]}
              nil -> {node, acc}
            end
          else
            {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp find_raising(nil), do: nil
  defp find_raising({:__block__, _, [single]}), do: find_raising(single)
  defp find_raising({:__block__, _, exprs}), do: find_raising(List.last(exprs))
  defp find_raising({:=, _, [_lhs, rhs]}), do: find_raising(rhs)

  defp find_raising({{:., _, [{:__aliases__, _, [mod]}, fun]}, _, args})
       when is_list(args) and is_atom(mod) and is_atom(fun) do
    case Map.fetch(@raising, {mod, fun, length(args)}) do
      {:ok, safe} -> {"#{mod}.#{fun}/#{length(args)}", safe}
      :error -> nil
    end
  end

  defp find_raising(_), do: nil

  defp build_issue(meta, raising, safe) do
    %Issue{
      rule: :try_rescue_with_safe_alternative,
      message: "`try/rescue` around `#{raising}` — use `#{safe}` instead.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
