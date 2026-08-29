defmodule CredenceRules.Pattern.RescueCatchAllTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.RescueCatchAll

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    RescueCatchAll.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags `rescue _ -> …`" do
      source = ~S"""
      try do
        Jason.decode!(bin)
      rescue
        _ -> %{}
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :rescue_catch_all
      assert issue.message =~ "rescue _"
    end

    test "flags `rescue _e -> …`" do
      source = ~S"""
      try do
        Jason.decode!(bin)
      rescue
        _e -> %{}
      end
      """

      assert [_] = analyze(source)
    end

    test "flags bare-var rescue whose body drops the binding" do
      # Bound, then discarded — the exception is gone just as completely
      # as with `rescue _`.
      source = ~S"""
      try do
        Jason.decode!(bin)
      rescue
        e -> %{}
      end
      """

      assert [issue] = analyze(source)
      assert issue.message =~ "rescue e"
    end

    test "flags a rescue that returns a constant error tuple" do
      # `{:error, :decode_failed}` looks like propagation but discards
      # which exception fired.
      source = ~S"""
      try do
        Jason.decode!(bin)
      rescue
        error -> {:error, :decode_failed}
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag `rescue e in DecodeError -> …`" do
      source = ~S"""
      try do
        Jason.decode!(bin)
      rescue
        e in Jason.DecodeError -> {:error, e}
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag `rescue e in [A, B] -> …`" do
      source = ~S"""
      try do
        do_thing()
      rescue
        e in [ArgumentError, ArithmeticError] -> {:error, e}
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag try without rescue" do
      source = ~S"""
      try do
        do_thing()
      after
        :cleanup
      end
      """

      assert analyze(source) == []
    end
  end

  describe "check/2 — converting the exception to a value is not swallowing" do
    test "does NOT flag a body that carries the bound error forward" do
      source = ~S"""
      try do
        establish.(attempt)
      rescue
        error -> {:error, {:establish_raised, error}}
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag `rescue e -> {:error, e}`" do
      source = ~S"""
      try do
        Jason.decode!(bin)
      rescue
        e -> {:error, e}
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag a reraising arm" do
      source = ~S"""
      try do
        do_thing()
      rescue
        error -> reraise error, __STACKTRACE__
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag when the error is used deeper in the body" do
      source = ~S"""
      try do
        do_thing()
      rescue
        error ->
          Logger.error("failed", reason: Exception.message(error))
          {:error, error}
      end
      """

      assert analyze(source) == []
    end

    test "DOES still flag an underscored name even if it appears in the body" do
      # `_error` declares the value unused; referencing it anyway is a
      # mistake, not propagation.
      source = ~S"""
      try do
        do_thing()
      rescue
        _error -> {:error, :failed}
      end
      """

      assert [_] = analyze(source)
    end
  end
end
