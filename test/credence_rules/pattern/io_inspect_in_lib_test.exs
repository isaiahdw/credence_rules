defmodule CredenceRules.Pattern.IoInspectInLibTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.IoInspectInLib

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    IoInspectInLib.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags IO.inspect/1" do
      assert [issue] = analyze(~S"IO.inspect(value)")
      assert issue.rule == :io_inspect_in_lib
      assert issue.message =~ "Logger.debug"
    end

    test "flags IO.inspect/2 with label" do
      assert [_] = analyze(~S|IO.inspect(value, label: "tag")|)
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag IO.puts" do
      assert analyze(~S|IO.puts("done")|) == []
    end

    test "does NOT flag IO.write" do
      assert analyze(~S"IO.write(:stderr, msg)") == []
    end
  end
end
