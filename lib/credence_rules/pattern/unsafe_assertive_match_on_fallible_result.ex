defmodule CredenceRules.Pattern.UnsafeAssertiveMatchOnFallibleResult do
  @moduledoc """
  Safety rule: a top-level `{:ok, value} = fallible_call()`
  match crashes with `MatchError` when the call returns
  `{:error, _}`. Sometimes that's intentional ("if this fails
  it's a bug, let it crash"), but more often it's an LLM
  asserting a happy path without considering the error.

  ## Bad

      def import_user(attrs) do
        {:ok, user} = Repo.insert(changeset(attrs))
        {:ok, body} = Jason.decode(file_contents)
        # ...
      end

  Both `Repo.insert/1` and `Jason.decode/1` return `{:ok,
  value}` or `{:error, reason}`. The assertive `=` match
  silently treats the error case as "won't happen" — but
  validation failures, malformed JSON, and disk errors all hit
  these.

  ## Good

      def import_user(attrs) do
        case Repo.insert(changeset(attrs)) do
          {:ok, user} -> handle_user(user)
          {:error, changeset} -> {:error, changeset}
        end
      end

  Or use `with` for chained operations:

      with {:ok, body} <- Jason.decode(file_contents),
           {:ok, user} <- build_user(body) do
        {:ok, user}
      end

  ## When the assertive match IS intentional

  Several legitimate uses — the rule's carve-outs:

  - **Tests** — `assert {:ok, user} = create_user(attrs)` is
    the standard ExUnit pattern.
  - **Bang wrappers** — `def decode!(json) do {:ok, body} =
    Jason.decode(json); body end` is the canonical "raise on
    error" implementation.
  - **Startup / config code** — when crashing IS the right
    response to a config error.

  ## Detection

  Flags top-level `{:ok, _} = <call>` or `{:error, _} =
  <call>` matches when:

  - The match is a top-level statement in a function body
    (not inside `with`, `case`, or `if`)
  - The right-hand side is a CALL to a known-fallible function
    pattern (`Repo.insert/update/delete`, `Jason.decode`,
    `File.read/write`, `HTTPoison.get`, `Req.get`, etc.)
  - The enclosing function name does NOT end in `!` (bang
    wrapper convention)
  - The file is NOT a test file (ExUnit's `assert` form)

  Default fallible-call patterns are configurable via
  `:fallible_calls` opt — list of `\"Module.function\"` strings.

  ## Configuration

      config :credence_rules,
        rule_opts: %{
          unsafe_assertive_match_on_fallible_result: [
            # Add project-specific fallible APIs
            fallible_calls: [
              "MyApp.Client.fetch",
              "MyApp.Storage.persist"
            ]
          ]
        }

  ## Why advisory + medium / medium

  Real safety risk, but the carve-outs (tests, bang wrappers,
  intentional-crash sites) are common enough that strict gating
  would create noise. Reviewer call.
  """

  use CredenceRules.Rule

  alias CredenceRules.{AstKeyword, TestModule}

  @severity :medium
  @confidence :medium

  @hint """
  Replace the assertive `=` match with explicit error handling:

      # Before
      {:ok, user} = Repo.insert(changeset(attrs))

      # After
      case Repo.insert(changeset(attrs)) do
        {:ok, user} -> handle_user(user)
        {:error, changeset} -> {:error, changeset}
      end

  For chained operations:

      with {:ok, body} <- Jason.decode(file_contents),
           {:ok, user} <- build_user(body) do
        {:ok, user}
      end

  If the assertive match is INTENTIONAL ("if this fails it's
  a bug"), wrap the function in a bang convention
  (`decode!/1`) to make the contract explicit to callers.
  """

  @carve_outs [
    "Test files (`use ExUnit.Case` / `CaseTemplate`) — `assert {:ok, _} = ...` is the standard ExUnit pattern. Auto-skipped.",
    "Bang-suffix function names (`decode!/1`, `fetch!/1`) — the `!` convention announces that crashing is intentional. Auto-skipped.",
    "Startup / config code where crashing is the right response — wrap in a bang function or accept the finding."
  ]

  @default_fallible_calls [
    # Ecto
    "Repo.insert",
    "Repo.update",
    "Repo.delete",
    "Repo.insert_or_update",
    "Repo.transaction",
    # JSON
    "Jason.decode",
    "Poison.decode",
    # File
    "File.read",
    "File.write",
    "File.open",
    "File.mkdir",
    "File.mkdir_p",
    "File.rm",
    # HTTP clients
    "Req.get",
    "Req.post",
    "Req.put",
    "Req.delete",
    "Req.request",
    "HTTPoison.get",
    "HTTPoison.post",
    "HTTPoison.put",
    "HTTPoison.delete",
    "Finch.request",
    # System
    "System.cmd",
    # Code
    "Code.eval_string",
    # Map / Keyword fetches (when used as fallible)
    "Map.fetch",
    "Keyword.fetch"
  ]

  @impl true
  def priority, do: 496

  @impl true
  def check(ast, opts) do
    if TestModule.exunit_file?(ast) do
      []
    else
      fallible_set = MapSet.new(Keyword.get(opts, :fallible_calls, @default_fallible_calls))
      collect_findings(ast, fallible_set)
    end
  end

  defp collect_findings(ast, fallible_set) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {def_kind, _meta, [head, kw]} = node, acc
        when def_kind in [:def, :defp] and is_list(kw) ->
          name = head_name(head)

          if bang_function?(name) do
            {node, acc}
          else
            body = AstKeyword.get(kw, :do)

            findings =
              body
              |> top_level_statements()
              |> Enum.flat_map(&maybe_flag_statement(&1, fallible_set, name))

            {node, findings ++ acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp head_name({:when, _, [inner, _]}), do: head_name(inner)
  defp head_name({name, _, _}) when is_atom(name), do: name
  defp head_name(_), do: nil

  defp bang_function?(name) when is_atom(name) do
    name |> Atom.to_string() |> String.ends_with?("!")
  end

  defp bang_function?(_), do: false

  defp top_level_statements(nil), do: []
  defp top_level_statements({:__block__, _, stmts}) when is_list(stmts), do: stmts
  defp top_level_statements(single), do: [single]

  # Flag `{:ok, _} = <call>` or `{:error, _} = <call>` where call
  # matches the fallible pattern.
  defp maybe_flag_statement({:=, meta, [pattern, rhs]}, fallible_set, fn_name) do
    if ok_or_error_pattern?(pattern) and fallible_call?(rhs, fallible_set),
      do: [build_issue(meta, rhs, fn_name)],
      else: []
  end

  defp maybe_flag_statement(_, _, _), do: []

  defp ok_or_error_pattern?({:ok, _}), do: true
  defp ok_or_error_pattern?({:error, _}), do: true
  defp ok_or_error_pattern?(_), do: false

  defp fallible_call?({{:., _, [{:__aliases__, _, segments}, fun]}, _, _args}, fallible_set)
       when is_atom(fun) do
    module = Enum.map_join(segments, ".", &Atom.to_string/1)
    name = module <> "." <> Atom.to_string(fun)
    MapSet.member?(fallible_set, name)
  end

  defp fallible_call?(_, _), do: false

  defp build_issue(meta, rhs, fn_name) do
    call_str = Macro.to_string(rhs)

    %Issue{
      rule: :unsafe_assertive_match_on_fallible_result,
      message:
        "`{:ok, _} = #{call_str}` in `#{fn_name}` — assertive match on a fallible " <>
          "call. The call returns `{:error, _}` on failure (validation errors, malformed " <>
          "input, disk / network errors); the match will crash with `MatchError`. Use " <>
          "`case` for explicit error handling, or wrap the function as `#{fn_name}!/N` " <>
          "to make the crashing contract explicit.",
      meta: %{line: Keyword.get(meta, :line), function: fn_name}
    }
  end
end
