defmodule CredenceRules.Pattern.RescueCatchAll do
  @moduledoc """
  Safety rule: `rescue _` or `rescue _name -> …` matches every exception,
  including ones that the code wasn't designed to handle (OOM, KeyError
  on a typo, atom-table exhaustion, programmer bugs).

  Catch-all rescue is a classic "borrowed from other languages" pattern:
  Python's `except Exception`, Ruby's `rescue`, Java's `catch (Exception
  e)`. In those ecosystems the broad catch is sometimes idiomatic; in
  Erlang/Elixir, **let it crash** plus supervisor restart is the
  primary error-handling strategy. A bare rescue silently swallows the
  signals supervisors are watching for.

  When you really do want to handle a specific failure mode, name the
  exception type:

      rescue
        e in [ArgumentError, ArithmeticError] -> {:error, e}

  ## Detected forms

  - `rescue _ -> …`
  - `rescue _e -> …` (any variable starting with `_`)
  - `rescue e -> …` where the body never mentions `e`

  Forms that pin to a type list are not flagged.

  ## Converting an exception to a value is not swallowing it

  A bare-var rescue whose body *uses* the bound variable is not
  flagged:

      rescue
        error -> {:error, {:establish_raised, error}}

  Nothing is hidden there — the failure still reaches the caller, as
  data instead of an exception. That's the standard shape at a process
  or API boundary, where raising would leave the parent holding only
  `{:DOWN, …, reason}` with no idea what happened. Flagging it taught
  readers to skim a rule whose real subject is the *discarding* case:

      rescue _ -> :ok           # flagged — the exception is gone
      rescue error -> :ok       # flagged — bound, then dropped

  `reraise error, __STACKTRACE__` counts as using it, so re-raising
  arms stay clear too.

  ## Bad

      try do
        Jason.decode!(input)
      rescue
        _ -> %{}        # also swallows KeyError, OOM, etc.
      end

  ## Good

      try do
        Jason.decode!(input)
      rescue
        e in Jason.DecodeError -> {:error, e}
      end

  ## Allowlist

  Parser-style modules that legitimately want to reject anything they
  can't make sense of can suppress with a reasoned
  `# credence:rescue_catch_all — <why>` comment (see
  `CredenceRules.Suppression`), or refactor to use `with` +
  `{:error, _}` style and skip the rescue.
  """

  use CredenceRules.Rule

  alias CredenceRules.AstKeyword

  @impl true
  def priority, do: 360

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        # Skip ExUnit case modules — property tests and "verify no
        # unexpected crash" tests legitimately rescue every exception
        # to make assertions about input tolerance.
        #
        # Use AstKeyword.get/2 so the exemption fires under both
        # Code.string_to_quoted/1 (tests) and Sourceror.parse_string/1
        # (production), since Sourceror wraps the `:do` key.
        {:defmodule, _meta, [_alias, kw]} = node, acc when is_list(kw) ->
          case AstKeyword.get(kw, :do) do
            nil ->
              {node, acc}

            body ->
              if exunit_case?(body),
                do: {[], acc},
                else: {node, acc}
          end

        {:try, _meta, [clauses]} = node, acc when is_list(clauses) ->
          {node, scan_clauses(clauses) ++ acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp exunit_case?(body) do
    stmts =
      case body do
        {:__block__, _, list} -> list
        single -> [single]
      end

    Enum.any?(stmts, fn
      {:use, _, [{:__aliases__, _, [:ExUnit, :Case]}]} -> true
      {:use, _, [{:__aliases__, _, [:ExUnit, :Case]}, _]} -> true
      {:use, _, [{:__aliases__, _, [:ExUnit, :CaseTemplate]}]} -> true
      {:use, _, [{:__aliases__, _, [:ExUnit, :CaseTemplate]}, _]} -> true
      _ -> false
    end)
  end

  defp scan_clauses(clauses) do
    case AstKeyword.get(clauses, :rescue) do
      nil -> []
      arms when is_list(arms) -> Enum.flat_map(arms, &scan_arm/1)
    end
  end

  # An arm parses as `{:->, meta, [[pattern], body]}`.
  defp scan_arm({:->, meta, [[pattern], body]}) do
    case bound_name(pattern) do
      nil ->
        []

      name ->
        if discards?(name, body), do: [build_issue(meta, pattern)], else: []
    end
  end

  defp scan_arm(_), do: []

  # The variable a catch-all rescue binds, or nil when the arm isn't a
  # catch-all.
  #
  # `e in ExceptionType` / `e in [A, B]` pins the type, so it's not a
  # catch-all — checked first. Everything else of the shape
  # `{name, _, ctx}` with both atoms is a plain variable (`_`, `_var`,
  # `e`), and those match every exception.
  defp bound_name({:in, _meta, _args}), do: nil
  defp bound_name({name, _meta, ctx}) when is_atom(name) and is_atom(ctx), do: name
  defp bound_name(_pattern), do: nil

  # The rule's subject is the exception going missing, which happens two
  # ways: an underscored name declares up front that the value is
  # unused, and a bound name the body never mentions is dropped just as
  # completely.
  #
  # A body that *does* mention it — `{:error, {:raised, error}}`,
  # `reraise error, __STACKTRACE__` — propagates the failure as data
  # instead of as an exception. Nothing is swallowed, so it isn't this
  # rule's concern.
  defp discards?(name, body), do: underscored?(name) or not references?(body, name)

  defp underscored?(name), do: name |> Atom.to_string() |> String.starts_with?("_")

  defp references?(body, name) do
    {_ast, found?} =
      Macro.prewalk(body, false, fn
        {^name, _meta, ctx} = node, _acc when is_atom(ctx) -> {node, true}
        node, acc -> {node, acc}
      end)

    found?
  end

  defp build_issue(meta, pattern) do
    label =
      case pattern do
        {:_, _, _} -> "rescue _"
        {name, _, _} -> "rescue #{name}"
      end

    %Issue{
      rule: :rescue_catch_all,
      message:
        "`#{label}` matches every exception — OOMs, KeyErrors from typos, " <>
          "and programmer bugs are silently swallowed alongside the failure " <>
          "you meant to handle. Constrain with `e in [SomeError, OtherError]`, " <>
          "or remove the rescue and let the supervisor restart.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
