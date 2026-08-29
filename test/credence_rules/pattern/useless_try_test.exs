defmodule CredenceRules.Pattern.UselessTryTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.UselessTry

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    UselessTry.check(ast, source: source)
  end

  # Production parses via Sourceror, which wraps keyword keys in
  # `{:__block__, _, [:rescue]}`. The check task runs against this
  # AST, not `Code.string_to_quoted/1`'s — so a rule that "passes"
  # the `Code`-parsed tests can still misfire on every file in CI.
  defp analyze_sourceror(source) do
    {:ok, ast} = Sourceror.parse_string(source)
    UselessTry.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags `try do ... end` with no rescue/catch/after" do
      source = ~S"""
      try do
        do_work()
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :useless_try
    end

    test "flags `try do ... else ... end` (else without rescue/catch)" do
      source = ~S"""
      try do
        compute()
      else
        x -> process(x)
      end
      """

      assert [_] = analyze(source)
    end

    test "reports the line of the try" do
      source = ~S"""
      def go(input) do
        x = preprocess(input)
        try do
          do_work(x)
        end
      end
      """

      assert [issue] = analyze(source)
      assert issue.meta.line == 3
    end

    test "flags each useless try in a function" do
      source = ~S"""
      def go(a, b) do
        try do
          do_work(a)
        end

        try do
          do_work(b)
        end
      end
      """

      assert length(analyze(source)) == 2
    end
  end

  describe "check/2 — not flagged" do
    test "ignores try with rescue" do
      source = ~S"""
      try do
        do_work()
      rescue
        e -> {:error, e}
      end
      """

      assert [] = analyze(source)
    end

    test "ignores try with catch" do
      source = ~S"""
      try do
        throw(:halt)
      catch
        :halt -> :ok
      end
      """

      assert [] = analyze(source)
    end

    test "ignores try with after" do
      source = ~S"""
      try do
        File.read!(path)
      after
        File.rm(path)
      end
      """

      assert [] = analyze(source)
    end

    test "ignores try with rescue + else" do
      source = ~S"""
      try do
        compute()
      rescue
        e -> {:error, e}
      else
        x -> {:ok, x}
      end
      """

      assert [] = analyze(source)
    end

    test "ignores try with rescue + after + else (legit combo)" do
      source = ~S"""
      try do
        compute()
      rescue
        e -> {:error, e}
      else
        x -> {:ok, x}
      after
        cleanup()
      end
      """

      assert [] = analyze(source)
    end

    test "ignores try with catch + after" do
      source = ~S"""
      try do
        throw(:halt)
      catch
        :halt -> :ok
      after
        cleanup()
      end
      """

      assert [] = analyze(source)
    end

    test "ignores plain code" do
      assert [] = analyze("do_work()")
    end
  end

  # Regression: Sourceror wraps keyword keys, so `Keyword.has_key?(kw,
  # :rescue)` on the production-parsed AST returns false even when
  # rescue is present. Every try/rescue used to fire as useless.
  describe "check/2 — Sourceror-parsed (production path)" do
    test "ignores try / rescue under Sourceror parse" do
      source = ~S"""
      try do
        do_work()
      rescue
        _ -> :error
      end
      """

      assert [] = analyze_sourceror(source)
    end

    test "ignores try / catch :exit / catch :error under Sourceror parse" do
      source = ~S"""
      try do
        do_work()
      catch
        :exit, _ -> :exit
        :error, _ -> :error
      end
      """

      assert [] = analyze_sourceror(source)
    end

    test "ignores try / catch kind, reason under Sourceror parse" do
      source = ~S"""
      try do
        do_work()
      catch
        kind, reason -> {kind, reason}
      end
      """

      assert [] = analyze_sourceror(source)
    end

    test "ignores try / after under Sourceror parse" do
      source = ~S"""
      try do
        File.read!(path)
      after
        File.rm(path)
      end
      """

      assert [] = analyze_sourceror(source)
    end

    test "still flags genuinely useless try under Sourceror parse" do
      source = ~S"""
      try do
        do_work()
      end
      """

      assert [_] = analyze_sourceror(source)
    end
  end
end
