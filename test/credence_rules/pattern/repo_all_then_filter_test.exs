defmodule CredenceRules.Pattern.RepoAllThenFilterTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.RepoAllThenFilter

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    RepoAllThenFilter.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags Repo.all |> Enum.filter" do
      source = ~S"""
      Repo.all(User) |> Enum.filter(& &1.active)
      """

      assert [issue] = analyze(source)
      assert issue.rule == :repo_all_then_filter
      assert issue.message =~ "predicate"
    end

    test "flags Repo.all |> Enum.reject" do
      source = ~S"""
      Repo.all(User) |> Enum.reject(& &1.archived)
      """

      assert [_] = analyze(source)
    end

    test "flags Repo.all |> Enum.find" do
      source = ~S"""
      Repo.all(User) |> Enum.find(& &1.email == email)
      """

      assert [_] = analyze(source)
    end

    test "flags MyApp.Repo.all |> Enum.filter" do
      source = ~S"""
      MyApp.Repo.all(User) |> Enum.filter(& &1.active)
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag Repo.all alone" do
      assert analyze(~S"Repo.all(User)") == []
    end

    test "does NOT flag Repo.all |> Enum.map" do
      # Enum.map is a projection, not a predicate filter — pushdown
      # doesn't apply.
      source = ~S"""
      Repo.all(User) |> Enum.map(&serialize/1)
      """

      assert analyze(source) == []
    end

    test "does NOT flag Repo.one |> Enum.filter" do
      # Repo.one returns a single struct, not a list — Enum.filter
      # wouldn't make sense.
      source = ~S"""
      Repo.one(User) |> Enum.filter(& &1)
      """

      assert analyze(source) == []
    end

    test "does NOT flag pre-filtered query" do
      source = ~S"""
      from(u in User, where: u.active) |> Repo.all() |> Enum.map(&serialize/1)
      """

      assert analyze(source) == []
    end
  end
end
