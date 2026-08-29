defmodule CredenceRules.Pattern.RaiseWithoutModule do
  @moduledoc """
  Error-shape rule: `raise "some string"` becomes a `RuntimeError`. That
  makes the failure ungreppable — every distinct failure-class in the
  codebase looks identical to `rescue RuntimeError -> _` and to a
  `try` catcher upstream.

  Pick an exception module. Either an existing one (`ArgumentError`,
  `KeyError`, `File.Error`) or a domain-specific one defined in your
  app (`MyApp.NotAuthorizedError`).

  ## Bad

      raise "user not found"

      raise "expected an integer, got \#{inspect(value)}"

  ## Good — pick a stdlib exception that fits

      raise ArgumentError, "expected an integer, got \#{inspect(value)}"

  ## Good — define a domain exception

      defmodule MyApp.UserNotFoundError do
        defexception [:user_id]

        @impl true
        def message(%{user_id: id}), do: "user \#{id} not found"
      end

      raise MyApp.UserNotFoundError, user_id: id

  ## Detection

  Fires when `raise/1` is called with a binary literal or a string
  interpolation as the only argument. Does not fire on:

  - `raise SomeError` (module-only form — uses the exception's
    `:default_message`)
  - `raise SomeError, "message"` (module + message form)
  - `raise SomeError, key: value` (module + opts form)
  - `raise variable` (re-raising a captured exception)
  - `raise build_exception(...)` (building an exception by call)
  """

  use CredenceRules.Rule

  @impl true
  def priority, do: 500

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:raise, meta, [arg]} = node, acc ->
          if string_message?(arg),
            do: {node, [build_issue(meta, arg) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  # Plain binary literal: `raise "..."`
  defp string_message?(arg) when is_binary(arg), do: true

  # Interpolated string: `raise "user #{id} not found"`
  defp string_message?({:<<>>, _, _}), do: true

  # Concatenation: `raise "user " <> id <> " not found"`
  defp string_message?({:<>, _, _}), do: true

  defp string_message?(_), do: false

  defp build_issue(meta, arg) do
    snippet =
      case arg do
        s when is_binary(s) -> "\"#{String.slice(s, 0, 60)}\""
        _ -> "<interpolated string>"
      end

    %Issue{
      rule: :raise_without_module,
      message:
        "`raise #{snippet}` becomes a generic `RuntimeError` — pick an exception module " <>
          "(`ArgumentError`, `KeyError`, …, or a `defexception` in your app) so callers can " <>
          "rescue / pattern-match on the failure class.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
