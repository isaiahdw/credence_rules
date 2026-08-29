defmodule CredenceRules.Pattern.ProcessSleepInTest do
  @moduledoc """
  Test-quality rule: flags `Process.sleep/1` inside files that
  `use ExUnit.Case` (or `ExUnit.CaseTemplate`). Sleeps in tests are
  almost always a substitute for waiting on an actual condition, and
  they trade a clean test for a flaky one as soon as the host CI is
  loaded.

  ## Bad

      test "the worker eventually processes the job" do
        start_supervised!(Worker)
        Worker.enqueue(:work)
        Process.sleep(200)
        assert Worker.completed?() == true
      end

  ## Good — wait on a real signal

      test "the worker eventually processes the job" do
        start_supervised!(Worker)
        Worker.enqueue(:work)
        assert_eventually(Worker.completed?())
      end

  Use `assert_receive/2,3` for message-based work, `Mox.verify!/1` for
  expectations, `assert_eventually/2` (or your project's equivalent
  helper) for state polling, and the `:timer.tc/1` macro when you
  genuinely need to measure elapsed time.

  ## Note

  Detection is per-file: the rule only fires when the file imports
  `ExUnit.Case` or `ExUnit.CaseTemplate`. Library code that genuinely
  needs `Process.sleep` (rate-limit backoff, retry loops) is unaffected.
  """

  use CredenceRules.Rule

  @impl true
  def priority, do: 600

  @impl true
  def check(ast, _opts) do
    if exunit_file?(ast),
      do: find_sleeps(ast),
      else: []
  end

  defp exunit_file?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        {:use, _, [{:__aliases__, _, [:ExUnit, :Case]} | _]} = node, _ -> {node, true}
        {:use, _, [{:__aliases__, _, [:ExUnit, :CaseTemplate]} | _]} = node, _ -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end

  defp find_sleeps(ast) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {{:., meta, [{:__aliases__, _, [:Process]}, :sleep]}, _, [_]} = node, acc ->
          {node, [build_issue(meta) | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp build_issue(meta) do
    %Issue{
      rule: :process_sleep_in_test,
      message:
        "`Process.sleep/1` inside an ExUnit test — wait on a real signal " <>
          "(`assert_receive/2,3`, `assert_eventually/2`, `Mox.verify!/1`) " <>
          "instead. Sleeps make tests flaky on loaded CI.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
