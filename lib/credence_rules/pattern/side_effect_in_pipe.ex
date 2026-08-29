defmodule CredenceRules.Pattern.SideEffectInPipe do
  @moduledoc """
  Shape rule: a `Logger.*` or `IO.puts`/`write`/`warn` call used as a
  **non-terminal** stage in a pipe. Those calls return `:ok`, so the
  next stage receives `:ok` instead of the data being threaded — the
  pipeline is silently broken.

  ## Bad

      record
      |> normalize()
      |> Logger.info("normalized")   # returns :ok …
      |> persist()                   # … so persist(:ok) — bug

  ## Good — `tap/1` runs the effect and passes the value through

      record
      |> normalize()
      |> tap(&Logger.info("normalized \#{inspect(&1)}"))
      |> persist()

  …or pull the effect out as its own statement so the pipe stays a
  pure data transformation:

      normalized = normalize(record)
      Logger.info("normalized")
      persist(normalized)

  A pipe should thread one value through a series of transformations;
  a stage that's there for its effect (and returns `:ok`) doesn't
  belong in the middle of one.

  ## Detection

  Flags a pipe stage that is a `Logger.{debug,info,notice,warning,warn,
  error,critical,alert,emergency,log}` or `IO.{puts,write,warn}` call
  **and is not the last stage** of its `|>` chain. `IO.inspect` is NOT
  flagged — it returns its argument unchanged, so it threads correctly
  (and `io_inspect_in_lib` already covers leftover debug output).

  The **last** stage of a pipe is never flagged: there's no downstream
  stage to starve, so `x |> build() |> Logger.info()` (the pipe's value
  is the log result) is left alone.

  ## Why advisory

  Heuristic — occasionally the `:ok` return is genuinely what the
  author wants downstream. Reviewer call. But mid-pipe `:ok` is almost
  always either a bug or a missing `tap/1`.
  """

  use CredenceRules.Rule

  @severity :low
  @confidence :high

  @logger_funs [
    :debug,
    :info,
    :notice,
    :warning,
    :warn,
    :error,
    :critical,
    :alert,
    :emergency,
    :log
  ]

  @io_funs [:puts, :write, :warn]

  @hint """
  Use `tap/1` so the effect runs but the value passes through:

      # Before
      record |> normalize() |> Logger.info("done") |> persist()

      # After
      record |> normalize() |> tap(&Logger.info("done: \#{inspect(&1)}")) |> persist()

  Or lift the effect out as its own statement and keep the pipe a pure
  data transformation.
  """

  @carve_outs [
    "The last stage of a pipe is never flagged — there's no downstream stage to starve.",
    "`IO.inspect` is not flagged — it returns its argument unchanged, so it threads correctly through a pipe.",
    "Occasionally the `:ok` return is genuinely wanted downstream — reviewer call."
  ]

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        # `inner |> stage |> _outer` — `stage` is the right operand of
        # an inner `|>` whose result feeds an outer `|>`, i.e. a
        # non-terminal stage. (Left-associativity means every stage but
        # the final one matches this shape exactly once.)
        {:|>, _, [{:|>, _, [_upstream, stage]}, _outer]} = node, acc ->
          case effect_call(stage) do
            nil -> {node, acc}
            {label, meta} -> {node, [build_issue(meta, label) | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    # Each non-terminal stage matches the pipe pattern exactly once, so
    # there are no duplicates to dedupe.
    Enum.sort_by(issues, & &1.meta.line)
  end

  # `{label, meta}` if the stage is a recognised `:ok`-returning effect
  # call, else nil.
  defp effect_call({{:., _, [{:__aliases__, _, [:Logger]}, fun]}, meta, _args}) when fun in @logger_funs,
    do: {"Logger.#{fun}", meta}

  defp effect_call({{:., _, [{:__aliases__, _, [:IO]}, fun]}, meta, _args}) when fun in @io_funs,
    do: {"IO.#{fun}", meta}

  defp effect_call(_), do: nil

  defp build_issue(meta, label) do
    %Issue{
      rule: :side_effect_in_pipe,
      message:
        "`#{label}` is a side-effecting stage in the middle of a pipe — it " <>
          "returns `:ok`, so the next stage receives `:ok`, not your data, and " <>
          "the pipeline is broken. Run the effect with `tap/1` " <>
          "(`|> tap(&#{label}(...))`) so the value passes through, or pull it " <>
          "out as its own statement.",
      meta: %{line: Keyword.get(meta, :line), call: label}
    }
  end
end
