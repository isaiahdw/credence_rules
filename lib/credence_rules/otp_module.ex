defmodule CredenceRules.OtpModule do
  @moduledoc """
  Shared OTP-shape predicates for the concurrency / boundary rules.

  Several rules only apply *inside* a process module — `Process.sleep`
  in a callback, `:persistent_term.put` instead of state, an
  `async_nolink` with no `:DOWN` handling. Each used to carry its own
  copy of "does this module body `use GenServer`?"; this is the one
  implementation.

  Operates on the **module body** (the `do` block of a `defmodule`),
  not the whole file — callers extract that first.
  """

  # `use GenServer` and `use GenStage` both make the module a process
  # owner with the same state-ownership expectations.
  @process_owners [:GenServer, :GenStage]

  @doc """
  True if the module body contains a `use GenServer` / `use GenStage`
  statement (with or without options).

  Checks top-level statements only — a `use` nested inside a macro or a
  conditional isn't a straightforward process module.
  """
  @spec uses_genserver?(Macro.t()) :: boolean()
  def uses_genserver?(module_body) do
    module_body
    |> statements()
    |> Enum.any?(&process_use?/1)
  end

  defp statements({:__block__, _, list}) when is_list(list), do: list
  defp statements(single), do: [single]

  defp process_use?({:use, _, [{:__aliases__, _, [mod]} | _]}) when mod in @process_owners,
    do: true

  defp process_use?(_), do: false
end
