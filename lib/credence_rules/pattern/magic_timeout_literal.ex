defmodule CredenceRules.Pattern.MagicTimeoutLiteral do
  @moduledoc """
  Maintainability rule: integer literals in timer / timeout positions
  should be module attributes (or function args), not magic numbers.

  Book *Elixir Patterns* consistently uses module attributes for
  tunable intervals: `@interval 10_000`, `@retry_after_ms 5_000`,
  `@token_ttl_ms 30_000`. The reasons compound:

  1. **Tunability.** The number is named, so its purpose is clear,
     and changes happen in one place.
  2. **Test isolation.** Tests can override the attribute via
     `Application.get_env` + `compile_env` indirection without monkey-
     patching the call site.
  3. **Operational readability.** Grepping for `@interval` finds the
     knob; grepping for `10_000` finds nothing meaningful.

  ## Detected positions

  - `Process.send_after(_, _, N)` — 3rd arg
  - `:timer.send_after(N, _)` / `:timer.send_after(N, _, _)` — 1st arg
  - `:timer.send_interval(N, _)` / `:timer.send_interval(N, _, _)` — 1st arg
  - `:timer.sleep(N)` — 1st arg
  - `GenServer.call(_, _, N)` — 3rd arg

  Only literal integers `>= @min_threshold` (default 100) are flagged.
  This avoids noise from `:infinity`, `0`, and small literal sentinels
  that are unambiguously not timers (`Process.send_after(self(), :tick, 0)`
  for "ASAP").

  ## Bad

      Process.send_after(self(), :tick, 10_000)
      :timer.send_interval(60_000, :poll)

  ## Good

      @tick_interval_ms 10_000
      @poll_interval_ms 60_000

      Process.send_after(self(), :tick, @tick_interval_ms)
      :timer.send_interval(@poll_interval_ms, :poll)
  """

  use CredenceRules.Rule

  @min_threshold 100

  @impl true
  def priority, do: 230

  @impl true
  def check(ast, opts) do
    threshold = Keyword.get(opts, :min_threshold, @min_threshold)

    {_ast, issues} =
      Macro.prewalk(ast, [], fn node, acc ->
        case classify(node) do
          {:flag, position_label, meta, value} when value >= threshold ->
            {node, [build_issue(meta, position_label, value) | acc]}

          _ ->
            {node, acc}
        end
      end)

    Enum.reverse(issues)
  end

  defp classify({{:., _, [{:__aliases__, _, [:Process]}, :send_after]}, meta, [_, _, n]})
       when is_integer(n) do
    {:flag, "Process.send_after/3", meta, n}
  end

  defp classify({{:., _, [:timer, fun]}, meta, [n | _]})
       when fun in [:send_after, :send_interval, :sleep] and is_integer(n) do
    {:flag, ":timer.#{fun}", meta, n}
  end

  defp classify({{:., _, [{:__aliases__, _, [:GenServer]}, :call]}, meta, [_, _, n]})
       when is_integer(n) do
    {:flag, "GenServer.call/3", meta, n}
  end

  defp classify(_), do: :ok

  defp build_issue(meta, position, value) do
    %Issue{
      rule: :magic_timeout_literal,
      message:
        "Magic timeout literal `#{value}` in `#{position}`. Extract to a " <>
          "named module attribute (e.g. `@tick_interval_ms #{value}`) so it's " <>
          "tunable, testable, and grep-greppable.",
      meta: %{line: Keyword.get(meta, :line), value: value}
    }
  end
end
