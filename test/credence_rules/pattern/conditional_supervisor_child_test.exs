defmodule CredenceRules.Pattern.ConditionalSupervisorChildTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.ConditionalSupervisorChild

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    ConditionalSupervisorChild.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags Supervisor.init with `if` inside children list" do
      source = ~S"""
      Supervisor.init(
        [
          Worker,
          if(Config.feature_enabled?(), do: OptionalWorker)
        ],
        strategy: :one_for_one
      )
      """

      assert [issue] = analyze(source)
      assert issue.rule == :conditional_supervisor_child
    end

    test "flags Supervisor.init with Enum.reject(&is_nil/1) cleanup" do
      source = ~S"""
      Supervisor.init(
        [Worker, maybe_optional()] |> Enum.reject(&is_nil/1),
        strategy: :one_for_one
      )
      """

      assert [_] = analyze(source)
    end

    test "flags Supervisor.start_link with case in children" do
      source = ~S"""
      Supervisor.start_link(
        [
          Worker,
          case mode() do
            :on -> Optional
            :off -> nil
          end
        ],
        strategy: :one_for_one
      )
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag a flat children list" do
      source = ~S"""
      Supervisor.init([Worker, OptionalWorker], strategy: :one_for_one)
      """

      assert analyze(source) == []
    end

    test "does NOT flag conditionals outside Supervisor.init/start_link" do
      source = ~S"""
      children = if Config.enabled?, do: [A], else: [B]
      """

      assert analyze(source) == []
    end
  end
end
