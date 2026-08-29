defmodule CredenceRules.Pattern.BangFunctionThatDoesntRaise do
  @moduledoc """
  Convention rule: a function defined as `def foo!(...)` must be able to
  raise on failure.

  The `!` suffix in Elixir is a contract: "this function raises when it
  cannot return a normal value." Callers rely on it to skip the
  `{:ok, _} | {:error, _}` wrapping that `foo/N` would impose. A `foo!`
  whose body never raises, never propagates from another bang call, and
  never returns `nil` on failure (which would itself be a bug — bangs
  shouldn't return nil either) silently breaks the convention and every
  caller that trusts it.

  ## Detection

  A `def foo!(...)` body is flagged when *none* of the following appear
  anywhere inside it:

  - an explicit `raise ...` / `reraise ...`
  - a call to another bang function (`Map.fetch!`, `Repo.get!`, ...)
  - a `throw ...`
  - a `:erlang.error/1,2` / `:erlang.throw/1` / `:erlang.exit/1` call

  ## Bad

      def fetch!(key) do
        Map.get(map, key)               # returns nil, doesn't raise
      end

      def parse!(input) do
        case Jason.decode(input) do
          {:ok, v} -> v
          {:error, _} -> nil            # bang functions shouldn't return nil
        end
      end

  ## Good

      def fetch!(key), do: Map.fetch!(map, key)

      def parse!(input) do
        case Jason.decode(input) do
          {:ok, v} -> v
          {:error, e} -> raise ArgumentError, "invalid input: " <> inspect(e)
        end
      end
  """

  use CredenceRules.Rule

  @impl true
  def priority, do: 420

  @impl true
  def check(ast, _opts) do
    # Walk every `def!/defp!` clause and accumulate them by {name, arity}.
    # The contract "this function raises on failure" is module-wide: if
    # *any* clause raises, the bang contract is satisfied — even if the
    # specific clause we just looked at returns `:ok`. So we group first,
    # then decide.
    {_ast, clauses_by_name} =
      Macro.prewalk(ast, %{}, fn
        {def_kind, meta, [head, [{:do, body}]]} = node, acc
        when def_kind in [:def, :defp] ->
          case bang_def_name_arity(head) do
            {name, arity} ->
              key = {name, arity}
              entry = %{meta: meta, raises?: can_raise?(body)}
              {node, Map.update(acc, key, [entry], &[entry | &1])}

            :other ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    clauses_by_name
    |> Enum.flat_map(fn {{name, arity}, clauses} ->
      if Enum.any?(clauses, & &1.raises?) do
        []
      else
        # No clause raises. One finding at the FIRST clause's line so
        # the report points at the function head readers will look at.
        first = clauses |> Enum.reverse() |> List.first()
        [build_issue(first.meta, name, arity)]
      end
    end)
    |> Enum.sort_by(& &1.meta.line)
  end

  # Returns `{name, arity}` for a bang def head, `:other` otherwise.
  # Handles both shapes:
  #   - `def foo!(args)`              → `{name, _, args}`
  #   - `def foo!(args) when guard`   → `{:when, _, [{name, _, args}, _guard]}`
  defp bang_def_name_arity({:when, _, [{name, _, args}, _guard]}),
    do: classify_bang(name, args)

  defp bang_def_name_arity({name, _, args}), do: classify_bang(name, args)
  defp bang_def_name_arity(_), do: :other

  defp classify_bang(name, args) when is_atom(name) and is_list(args) do
    name_str = Atom.to_string(name)

    # Require at least one char before the `!` — the macro-y `def !(x)`
    # case isn't a bang convention violation, it's a custom operator.
    if String.ends_with?(name_str, "!") and String.length(name_str) > 1,
      do: {name, length(args)},
      else: :other
  end

  defp classify_bang(_, _), do: :other

  # True if any subtree of `body` can raise an exception.
  defp can_raise?(body) do
    body
    |> Macro.prewalk(false, fn
      _node, true ->
        {[], true}

      {:raise, _, _} = node, _ ->
        {node, true}

      {:reraise, _, _} = node, _ ->
        {node, true}

      {:throw, _, _} = node, _ ->
        {node, true}

      # Remote calls: Foo.bar!(...), Map.fetch!(...), :erlang.error(...).
      # Combined into one clause because Macro.prewalk only matches the
      # first arm — split arms for "bang suffix" and ":erlang.error" had
      # the more general one masking the specific one.
      {{:., _, [mod, fun]}, _meta, _args} = node, _ when is_atom(fun) ->
        raises? =
          String.ends_with?(Atom.to_string(fun), "!") or
            (mod == :erlang and fun in [:error, :exit, :throw])

        {node, raises?}

      # Local bang calls: foo!(...)
      {fun, _meta, args} = node, _ when is_atom(fun) and is_list(args) ->
        if String.ends_with?(Atom.to_string(fun), "!"),
          do: {node, true},
          else: {node, false}

      node, found ->
        {node, found}
    end)
    |> elem(1)
  end

  defp build_issue(meta, name, arity) do
    %Issue{
      rule: :bang_function_that_doesnt_raise,
      message:
        "`#{name}/#{arity}` has the `!` suffix but its body never raises, " <>
          "re-raises, or delegates to another bang call. Either make it " <>
          "raise on failure or drop the `!` (and return `{:ok, _} | {:error, _}`).",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
