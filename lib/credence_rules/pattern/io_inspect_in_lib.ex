defmodule CredenceRules.Pattern.IoInspectInLib do
  @moduledoc """
  Hygiene rule: `IO.inspect/1,2` in `lib/` code is almost always a
  debugging artifact that was meant to be removed.

  In tests and scripts, `IO.inspect` is fine — its purpose is to peek
  at a value while staying out of the way of `|>`-chains. In a library
  module that ships to other applications, `IO.inspect`:

  - dumps to the host's stdout/stderr unpredictably,
  - bypasses the host's `Logger` configuration (log levels, metadata,
    structured backends),
  - and (with `:label`) embeds debug context that's wrong for whichever
    caller eventually hits it.

  Use `Logger.debug` (with structured metadata) when you actually want
  observability; delete `IO.inspect` otherwise.

  ## Bad

      def parse(bin) do
        IO.inspect(bin, label: "incoming")
        decode(bin)
      end

  ## Good

      require Logger

      def parse(bin) do
        Logger.debug("decoding payload", bytes: byte_size(bin))
        decode(bin)
      end

  ## Allowlist

  Mix tasks and dev-only modules (e.g. `lib/mix/tasks/*`) are also
  flagged today — pass an `:allowed_modules` opt, or suppress with a
  reason if a CLI tool genuinely wants to print inspected output to
  the user:

      # credence:io_inspect_in_lib — CLI task, inspected output is the
      #   deliverable rather than leftover debugging
      IO.inspect(report)
  """

  use CredenceRules.Rule

  @impl true
  def priority, do: 290

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, [:IO]}, :inspect]}, meta, args} = node, acc
        when is_list(args) ->
          {node, [build_issue(meta, length(args)) | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp build_issue(meta, arity) do
    %Issue{
      rule: :io_inspect_in_lib,
      message:
        "`IO.inspect/#{arity}` in library code is almost always a leftover " <>
          "debugging call. Use `Logger.debug` (with structured metadata) if " <>
          "you want observability, or remove the call if the data wasn't " <>
          "actually meant to be exposed.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
