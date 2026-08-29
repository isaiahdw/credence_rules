defmodule CredenceRules.Pattern.BinaryToTermWithoutSafe do
  @moduledoc """
  Safety rule: `:erlang.binary_to_term/1,2` without the `:safe` option is
  a remote-code-execution risk on untrusted input.

  An attacker who controls the input bytes can craft a term that creates
  arbitrary atoms (atom-table exhaustion → permanent VM degradation),
  references arbitrary funs (with side effects on deserialization), or
  forges PIDs/refs to spoof intra-cluster messages. The `:safe` option
  rejects the dangerous shapes.

  This rule catches both:

  - `:erlang.binary_to_term(bin)` — no opts at all
  - `:erlang.binary_to_term(bin, opts)` — opts list lacks `:safe`

  Aliased `Erlang.binary_to_term/1` and Elixir's `binary_to_term` (none
  exists at present) would be picked up too if added.

  ## Bad

      :erlang.binary_to_term(payload)
      :erlang.binary_to_term(payload, [:used])

  ## Good

      :erlang.binary_to_term(payload, [:safe])
  """

  use CredenceRules.Rule

  @impl true
  def priority, do: 480

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {{:., _, [:erlang, :binary_to_term]}, meta, args} = node, acc ->
          if safe_opts?(args),
            do: {node, acc},
            else: {node, [build_issue(meta, args) | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp safe_opts?([_bin]), do: false
  defp safe_opts?([_bin, opts]) when is_list(opts), do: :safe in opts
  # Non-literal opts list: can't statically verify — be conservative and
  # treat as unsafe so the rule flags the call site for review.
  defp safe_opts?([_bin, _opts]), do: false
  defp safe_opts?(_), do: false

  defp build_issue(meta, args) do
    %Issue{
      rule: :binary_to_term_without_safe,
      message:
        "`:erlang.binary_to_term/#{length(args)}` without `[:safe]` opts is " <>
          "an RCE / atom-table-exhaustion risk on untrusted input. Pass " <>
          "`[:safe]` (or extend the existing opts list) unless the input " <>
          "is known-trusted (e.g. from your own ETS table).",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
