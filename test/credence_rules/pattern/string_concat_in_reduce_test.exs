defmodule CredenceRules.Pattern.StringConcatInReduceTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.StringConcatInReduce

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    StringConcatInReduce.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags Enum.reduce with `acc <> chunk`" do
      source = ~S"""
      Enum.reduce(chunks, "", fn chunk, acc -> acc <> chunk end)
      """

      assert [issue] = analyze(source)
      assert issue.rule == :string_concat_in_reduce
      assert issue.message =~ "iodata"
    end

    test "flags reversed `chunk <> acc`" do
      source = ~S"""
      Enum.reduce(chunks, "", fn chunk, acc -> chunk <> acc end)
      """

      assert [_] = analyze(source)
    end

    test "flags Enum.reduce_while" do
      source = ~S"""
      Enum.reduce_while(items, "", fn x, acc -> {:cont, acc <> to_s(x)} end)
      """

      assert [_] = analyze(source)
    end

    test "flags pipe form" do
      source = ~S"""
      chunks
      |> Enum.reduce("", fn chunk, acc -> acc <> chunk end)
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag Enum.reduce building an iodata list" do
      source = ~S"""
      Enum.reduce(chunks, [], fn chunk, acc -> [acc, chunk] end)
      """

      assert analyze(source) == []
    end

    test "does NOT flag Enum.reduce that doesn't use <>" do
      source = ~S"""
      Enum.reduce(items, 0, fn x, acc -> acc + x end)
      """

      assert analyze(source) == []
    end

    test "does NOT flag `<>` outside Enum.reduce" do
      source = ~S"""
      "foo" <> "bar"
      """

      assert analyze(source) == []
    end

    test "does NOT flag Enum.map_join (already iodata-optimised)" do
      source = ~S"""
      Enum.map_join(chunks, "", &transform/1)
      """

      assert analyze(source) == []
    end
  end
end
