defmodule CredenceRules.TestModule do
  @moduledoc """
  File-level predicate: is this an ExUnit test file?

  Test-quality rules (`no_test_without_assertion`,
  `vague_test_name`, `real_external_client_in_test`) all look
  for `test "..."` macro calls. Many Elixir libraries define
  their own `test/2` macros for DSLs (Phoenix's `test "renders
  X"` is the same shape as a controller-test macro can be);
  scanning every `test/2` call would over-fire on those.

  Gate on `use ExUnit.Case` / `use ExUnit.CaseTemplate` to limit
  the scan to actual ExUnit test modules. Both forms accept
  optional opts (`use ExUnit.Case, async: true`) so the matcher
  ignores the args list.

  Shared across the three rules to keep the gate consistent —
  one source of truth, no clause drift.
  """

  @doc """
  True if the file's AST declares a `use ExUnit.Case` or
  `use ExUnit.CaseTemplate`. Walks the AST once; stops at the
  first match.

      iex> {:ok, ast} = Code.string_to_quoted("defmodule MyTest do\\n  use ExUnit.Case\\nend")
      iex> CredenceRules.TestModule.exunit_file?(ast)
      true

      iex> {:ok, ast} = Code.string_to_quoted("defmodule MyDsl do\\n  defmacro test(name, opts), do: nil\\nend")
      iex> CredenceRules.TestModule.exunit_file?(ast)
      false
  """
  @spec exunit_file?(Macro.t()) :: boolean()
  def exunit_file?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        _node, true ->
          {[], true}

        {:use, _, [{:__aliases__, _, [:ExUnit, last]} | _]} = node, _
        when last in [:Case, :CaseTemplate] ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found?
  end
end
