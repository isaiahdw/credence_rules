defmodule CredenceRules.Pattern.StringConcatInReduce do
  @moduledoc """
  Performance rule: `acc <> str` inside `Enum.reduce` is quadratic.

  Binary concatenation with `<>` in BEAM allocates a fresh binary
  each time: the result of `acc <> str` is a new binary copying
  `byte_size(acc) + byte_size(str)` bytes. Doing this inside
  `Enum.reduce` makes the total work `O(n²)` in the size of the
  accumulated string.

  The idiomatic alternative is **iodata** — a nested list of
  binaries / chars / iodata — built with `[acc, str]` (or
  `[str | acc]` if order doesn't matter) and flattened once at the
  end via `IO.iodata_to_binary/1` (or written directly to
  `:gen_tcp` / `File.write/2`, which accept iodata natively).

  ## Bad

      Enum.reduce(chunks, "", fn chunk, acc -> acc <> chunk end)
      # Each iteration allocates a binary; O(n²) total.

  ## Good

      chunks
      |> Enum.reduce([], fn chunk, acc -> [chunk | acc] end)
      |> Enum.reverse()
      |> IO.iodata_to_binary()

      # Or, if you don't actually need a flat binary, pass the iodata
      # directly to whatever consumes it:
      :gen_tcp.send(socket, Enum.reduce(chunks, [], fn c, acc -> [acc, c] end))

  ## Detection

  Flags `Enum.reduce(_, _, fn _, acc -> body end)` where:

  - The accumulator parameter (second arrow-pattern arg) is named
    `acc` (or any var)
  - The lambda body uses `<>` with that accumulator as one operand

  The initial accumulator value isn't required to be `""` — the
  quadratic concern applies whenever the accumulator's binary value
  grows monotonically. Pattern-matching the accumulator name
  prevents false positives on `<>` uses that aren't in the
  accumulator path.

  Also flags `Enum.reduce_while` similarly. Does NOT flag
  `Enum.map_join/2,3` — that's already iodata-optimised internally.
  """

  use CredenceRules.Rule

  @reduce_funs MapSet.new([:reduce, :reduce_while])

  @impl true
  def priority, do: 350

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:Enum]}, fun]}, meta, args} = node, acc
        when is_atom(fun) and is_list(args) ->
          if MapSet.member?(@reduce_funs, fun) and reduce_fn_concats?(args),
            do: {node, [build_issue(meta) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    issues
    |> Enum.uniq_by(& &1.meta.line)
    |> Enum.sort_by(& &1.meta.line)
  end

  # Look for the lambda arg (last arg of Enum.reduce) and inspect it:
  # `fn item, acc -> body end`. We want to know whether body uses
  # `<>` with `acc` as an operand.
  defp reduce_fn_concats?(args) do
    Enum.any?(args, &lambda_concats_accumulator?/1)
  end

  defp lambda_concats_accumulator?({:fn, _, [{:->, _, [[_item, {acc_name, _, ctx}], body]}]})
       when is_atom(acc_name) and is_atom(ctx) do
    body_uses_concat_on?(body, acc_name)
  end

  defp lambda_concats_accumulator?(_), do: false

  # Walks `body` looking for `<>` (`Kernel.<>`) where one side is a
  # variable reference matching `acc_name`.
  defp body_uses_concat_on?(body, acc_name) do
    {_ast, found?} =
      Macro.prewalk(body, false, fn
        _node, true ->
          {[], true}

        # `Kernel.<>` parses as the operator `<>` with two args.
        {:<>, _, [lhs, rhs]} = node, _ ->
          {node, var_matches?(lhs, acc_name) or var_matches?(rhs, acc_name)}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp var_matches?({name, _, ctx}, name) when is_atom(name) and is_atom(ctx), do: true
  defp var_matches?(_, _), do: false

  defp build_issue(meta) do
    %Issue{
      rule: :string_concat_in_reduce,
      message:
        "`acc <> _` inside `Enum.reduce` is O(n²) in the accumulated " <>
          "binary size — each iteration allocates a fresh binary. Build " <>
          "iodata instead: `Enum.reduce(enum, [], fn x, acc -> [acc, x] end) " <>
          "|> IO.iodata_to_binary()`. Or pass iodata directly to sinks that " <>
          "accept it (`:gen_tcp.send`, `File.write`).",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
