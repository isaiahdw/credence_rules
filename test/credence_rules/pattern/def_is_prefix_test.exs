defmodule CredenceRules.Pattern.DefIsPrefixTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.DefIsPrefix

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    DefIsPrefix.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags `def is_valid?`" do
      assert [issue] = analyze(~S"def is_valid?(x), do: x > 0")
      assert issue.rule == :def_is_prefix
      assert issue.message =~ "valid?"
      assert issue.message =~ "defguard"
    end

    test "flags `def is_valid` (no question mark)" do
      assert [issue] = analyze(~S"def is_valid(x), do: x > 0")
      # The suggestion adds a trailing question mark.
      assert issue.message =~ "valid?"
    end

    test "flags `defp` as well" do
      assert [_] = analyze(~S"defp is_internal?(x), do: x > 0")
    end

    test "flags inside a defmodule" do
      source = ~S"""
      defmodule Foo do
        def is_thing?(x), do: x
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag defguard" do
      assert analyze(~S"defguard is_valid(x) when x > 0") == []
    end

    test "does NOT flag a function not starting with `is_`" do
      assert analyze(~S"def valid?(x), do: x > 0") == []
    end

    test "does NOT flag the stdlib-style allowlist (defensive)" do
      # If someone defines `def is_list` etc., that's overshadowing
      # builtins and probably an error in its own right — but this
      # rule's allowlist exempts the names so it doesn't double-fire
      # with whatever other rule catches that.
      assert analyze(~S"def is_list(x), do: x") == []
    end
  end
end
