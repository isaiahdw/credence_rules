defmodule CredenceRules.Pattern.EtsExtractThenEnumTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.EtsExtractThenEnum

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    EtsExtractThenEnum.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags :ets.tab2list/1 |> Enum.filter" do
      assert [issue] =
               analyze(~S":ets.tab2list(:users) |> Enum.filter(fn _ -> true end)")

      assert issue.rule == :ets_extract_then_enum
      assert issue.message =~ ":ets.select"
    end

    test "flags pipe with Enum.map" do
      assert [_] = analyze(~S":ets.tab2list(:users) |> Enum.map(&elem(&1, 1))")
    end

    test "flags pipe with Enum.sort_by" do
      assert [_] = analyze(~S":ets.tab2list(:items) |> Enum.sort_by(& &1.id)")
    end

    test "flags pipe with Enum.reduce" do
      assert [_] = analyze(~S":ets.tab2list(:t) |> Enum.reduce(0, fn _, acc -> acc + 1 end)")
    end

    test "flags chained pipe" do
      source = ~S"""
      :ets.tab2list(:users)
      |> Enum.filter(&active?/1)
      |> Enum.map(&elem(&1, 1))
      """

      # Both `Enum.filter` and `Enum.map` are downstream of tab2list, but
      # only the first pipe gets the immediate tab2list LHS — the second
      # has Enum.filter() LHS. So we flag once.
      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag :ets.select" do
      assert analyze(~S":ets.select(:users, [{{:_, %{a: true}}, [], [:_]}])") == []
    end

    test "does NOT flag :ets.tab2list followed by length() (cheap)" do
      assert analyze(~S":ets.tab2list(:t) |> length()") == []
    end

    test "does NOT flag tab2list piped to a non-Enum function" do
      assert analyze(~S":ets.tab2list(:t) |> IO.inspect()") == []
    end

    test "does NOT flag :ets.match followed by Enum.map" do
      # `match` already filtered; Enum.map on its result is fine.
      assert analyze(~S":ets.match(:t, :_) |> Enum.map(&hd/1)") == []
    end
  end
end
