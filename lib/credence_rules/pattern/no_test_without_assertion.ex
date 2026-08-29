defmodule CredenceRules.Pattern.NoTestWithoutAssertion do
  @moduledoc """
  Idiomatic rule: flags `test "..." do ... end` blocks with no assertion.

  A test block that runs to completion without calling any assertion macro
  is a fixture, not a test — it proves only that the code under exercise
  doesn't crash. Coverage tools count it; failures don't surface.

  Assertion-free tests are an LLM failure mode in particular: models
  generate the `test` skeleton plus the setup-and-call body and then
  forget to write what's actually being checked.

  ## Detected macros

  Out of the box: `assert`, `assert_*`, `refute`, `refute_*`,
  `assert_receive`, `refute_receive`, `assert_raise`, `assert_called`,
  `catch_exit`, `catch_throw`, `catch_error`.

  Custom assertion macros (e.g. `assert_response_ok/1`) can be added via
  the `:extra_assertion_macros` option:

      CredenceRules.Pattern.NoTestWithoutAssertion.check(ast,
        extra_assertion_macros: [:assert_response_ok, :assert_event])

  ## Bad

      test "creates a user" do
        Accounts.create_user(%{email: "a@b.c"})
      end

  ## Good

      test "creates a user" do
        assert {:ok, %User{email: "a@b.c"}} = Accounts.create_user(%{email: "a@b.c"})
      end

  ## Allow-list

  - `test "..."` blocks that do nothing but `:ok` (intentional placeholders)
    can be silenced with a `@tag :pending` and an `IO.warn` body — this
    rule does not currently special-case those; if it becomes noisy,
    extend the rule with a `pending_tags` option.
  """

  use CredenceRules.Rule

  @assertion_macros MapSet.new([
                      :assert,
                      :assert_in_delta,
                      :assert_raise,
                      :assert_receive,
                      :assert_received,
                      :assert_called,
                      :assert_called_with,
                      :refute,
                      :refute_in_delta,
                      :refute_receive,
                      :refute_received,
                      :catch_exit,
                      :catch_throw,
                      :catch_error
                    ])

  @impl true
  def priority, do: 350

  @impl true
  def check(ast, opts) do
    extras = opts |> Keyword.get(:extra_assertion_macros, []) |> MapSet.new()
    macros = MapSet.union(@assertion_macros, extras)

    # Gate: only scan files whose modules `use ExUnit.Case` or `use
    # ExUnit.CaseTemplate`. Non-ExUnit DSLs that happen to define a
    # `test/2` macro (Phoenix.LiveViewTest, custom test-runner DSLs,
    # behaviour declarations) shouldn't be flagged.
    if exunit_file?(ast) do
      collect_issues(ast, macros)
    else
      []
    end
  end

  defp exunit_file?(ast), do: CredenceRules.TestModule.exunit_file?(ast)

  defp collect_issues(ast, macros) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:test, meta, [title | _rest]} = node, acc when is_binary(title) ->
          if has_assertion?(node, macros) do
            {node, acc}
          else
            {node, [build_issue(meta, title) | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp has_assertion?(test_block_ast, macros) do
    test_block_ast
    |> Macro.prewalk(false, fn
      _node, true ->
        {[], true}

      {name, _meta, args} = node, false when is_atom(name) ->
        cond do
          MapSet.member?(macros, name) ->
            {node, true}

          # `assert_*` and `refute_*` families — match by prefix so custom
          # ExUnit.Case helpers (e.g. `assert_redirected_to/2`) count too.
          is_list(args) and assertion_prefix?(name) ->
            {node, true}

          true ->
            {node, false}
        end

      node, found ->
        {node, found}
    end)
    |> elem(1)
  end

  defp assertion_prefix?(name) do
    s = Atom.to_string(name)
    String.starts_with?(s, "assert_") or String.starts_with?(s, "refute_")
  end

  defp build_issue(meta, title) do
    %Issue{
      rule: :no_test_without_assertion,
      message:
        "Test #{inspect(title)} has no assertion — it proves only that the code under " <>
          "exercise doesn't crash. Add an `assert`, `refute`, `assert_raise`, or similar.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
