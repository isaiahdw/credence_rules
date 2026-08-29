defmodule CredenceRules.Pattern.ProcessWhereisForLivenessTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.ProcessWhereisForLiveness

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    ProcessWhereisForLiveness.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags `if Process.whereis(Foo), do: …`" do
      source = ~S"""
      if Process.whereis(Foo) do
        GenServer.call(Foo, :ping)
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :process_whereis_for_liveness
    end

    test "flags `unless Process.whereis(Foo), do: …`" do
      source = ~S"""
      unless Process.whereis(Foo) do
        :down
      end
      """

      assert [_] = analyze(source)
    end

    test "flags `if Process.whereis(Foo) != nil, do: …`" do
      assert [_] = analyze(~S"if Process.whereis(Foo) != nil, do: :ok")
    end

    test "flags `if Process.whereis(Foo) == nil`" do
      assert [_] = analyze(~S"if Process.whereis(Foo) == nil, do: :down")
    end

    test "flags `if is_nil(Process.whereis(Foo))`" do
      assert [_] = analyze(~S"if is_nil(Process.whereis(Foo)), do: :down")
    end

    test "flags `case Process.whereis(Foo) do nil -> … pid -> … end`" do
      source = ~S"""
      case Process.whereis(Foo) do
        nil -> :down
        pid -> :alive
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag pid = Process.whereis(Foo)" do
      # Documented limitation: assignment then use is also racy, but
      # this rule narrowly targets the if/case shapes for now.
      assert analyze(~S"pid = Process.whereis(Foo)") == []
    end

    test "does NOT flag Process.alive?" do
      assert analyze(~S"if Process.alive?(pid), do: :ok") == []
    end
  end
end
