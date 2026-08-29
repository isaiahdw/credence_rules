defmodule CredenceRules.Pattern.NoTriviallyTruthyAssertion do
  @moduledoc """
  Idiomatic rule: flags `assert`/`refute` calls whose argument is statically
  truthy (or falsy) — the macro will pass regardless of the system under
  test.

  ## Detected shapes

  | Pattern                            | Why it's trivial                                    |
  |------------------------------------|-----------------------------------------------------|
  | `assert true`                      | Literal — passes unconditionally                    |
  | `assert :ok`                       | Atom — any non-nil/false atom is truthy             |
  | `assert 1` / `assert "x"`          | Truthy literal                                      |
  | `assert _ = expr`                  | Pin-free `_` matches anything                       |
  | `assert _name = expr`              | Variable pattern matches anything                   |
  | `refute false` / `refute nil`      | Literal falsy value                                 |

  These show up most often as scaffolding ("I'll fill it in later") that
  never gets filled in. LLMs generate them when asked to "add a test for
  X" without a clear assertion target.

  ## Bad

      test "creates a user" do
        assert _ = Accounts.create_user(params)
        assert :ok
      end

  ## Good

      test "creates a user" do
        assert {:ok, %User{}} = Accounts.create_user(params)
      end
  """

  use CredenceRules.Rule

  # Atoms that always pass `assert` because they're truthy. Most ExUnit
  # tests treat `assert :ok` as a stand-in for "the call succeeded" —
  # but `:ok` literally cannot fail.
  @truthy_atoms MapSet.new([:ok, :error, :pending, :todo])

  @impl true
  def priority, do: 360

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:assert, meta, [arg]} = node, acc ->
          case trivial_truthy_form(arg) do
            nil -> {node, acc}
            shape -> {node, [build_issue(:assert, meta, shape) | acc]}
          end

        {:refute, meta, [arg]} = node, acc ->
          case trivial_falsy_form(arg) do
            nil -> {node, acc}
            shape -> {node, [build_issue(:refute, meta, shape) | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  # --- Truthy classifier ---

  defp trivial_truthy_form(true), do: "literal `true`"

  defp trivial_truthy_form(arg) when is_atom(arg) and arg not in [nil, false] do
    if MapSet.member?(@truthy_atoms, arg),
      do: "atom literal `#{inspect(arg)}`",
      else: nil
  end

  defp trivial_truthy_form(arg) when is_integer(arg) and arg != 0,
    do: "non-zero integer literal `#{arg}`"

  defp trivial_truthy_form(arg) when is_binary(arg) and arg != "",
    do: "non-empty string literal"

  # `assert _ = expr`  or  `assert _name = expr`
  defp trivial_truthy_form({:=, _, [{var, _, ctx}, _rhs]})
       when is_atom(var) and is_atom(ctx) do
    if underscore_or_plain_var?(var),
      do: "pattern `#{var}` matches anything",
      else: nil
  end

  defp trivial_truthy_form(_), do: nil

  defp underscore_or_plain_var?(:_), do: true

  defp underscore_or_plain_var?(name) do
    # `assert _result = ...` is the classic placeholder; a leading
    # underscore signals "I don't intend to use this binding" and
    # makes the assertion meaningless. Plain variables (no leading _)
    # are also unconditional matches, but they're frequently used in
    # tests that destructure-then-assert-fields later — too noisy to
    # flag without examining the rest of the test body, so we restrict
    # to the leading-underscore form.
    name |> Atom.to_string() |> String.starts_with?("_")
  end

  # --- Falsy classifier (for `refute`) ---

  defp trivial_falsy_form(false), do: "literal `false`"
  defp trivial_falsy_form(nil), do: "literal `nil`"
  defp trivial_falsy_form(_), do: nil

  defp build_issue(macro, meta, shape) do
    %Issue{
      rule: :no_trivially_truthy_assertion,
      message:
        "`#{macro}` argument is trivially truthy/falsy: #{shape}. " <>
          "This passes regardless of the system under test — replace with " <>
          "a pattern match (`assert {:ok, _} = ...`) or a value check.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
