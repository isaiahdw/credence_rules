defmodule CredenceRules.Pattern.QueryInEnumMapTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.QueryInEnumMap

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    QueryInEnumMap.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags Enum.map with anonymous fn calling Repo.get" do
      source = ~S"""
      Enum.map(user_ids, fn id -> Repo.get(User, id) end)
      """

      assert [issue] = analyze(source)
      assert issue.rule == :query_in_enum_map
      assert issue.message =~ "N+1"
    end

    test "flags Enum.each with Repo.update" do
      source = ~S"""
      Enum.each(orders, fn o ->
        Repo.update(Order.changeset(o, %{status: :paid}))
      end)
      """

      assert [_] = analyze(source)
    end

    test "flags pipe form Enum.map" do
      source = ~S"""
      user_ids |> Enum.map(fn id -> Repo.get(User, id) end)
      """

      assert [_] = analyze(source)
    end

    test "flags Enum.flat_map" do
      source = ~S"""
      Enum.flat_map(parents, fn p -> Repo.all(Child, parent_id: p.id) end)
      """

      assert [_] = analyze(source)
    end

    test "flags namespaced Repo (MyApp.Repo.get)" do
      assert [_] =
               analyze(~S|Enum.map(ids, fn id -> MyApp.Repo.get(User, id) end)|)
    end

    test "flags captured-form (&Repo.get(User, &1))" do
      assert [_] = analyze(~S|Enum.map(ids, &Repo.get(User, &1))|)
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag Enum.map without Repo call" do
      assert analyze(~S|Enum.map(users, & &1.email)|) == []
    end

    test "does NOT flag Repo.all (single batched query, no Enum)" do
      assert analyze(~S|Repo.all(from u in User, where: u.id in ^ids)|) == []
    end

    test "does NOT flag a function unrelated to Enum" do
      assert analyze(~S|MyMod.process(ids, fn id -> Repo.get(User, id) end)|) == []
    end
  end
end
