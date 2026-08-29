defmodule CredenceRules.Pattern.WithComplexElse do
  @moduledoc """
  Idiomatic rule (advisory): a `with` block whose `else` has many
  arms is doing too many unrelated things in one chain.

  Per Elixir's [code anti-patterns doc](https://hexdocs.pm/elixir/code-anti-patterns.html#complex-else-clauses-in-with)
  and Saša Jurić's writing on the topic: when an `else` block grows
  to four or more arms handling heterogeneous error shapes from
  different services, the `with` chain has become a poorly-shaped
  `case`. Each `<-` is matching against a different success shape;
  the `else` is then re-matching each possible failure shape; the
  result is a function whose error handling is spread between the
  arrows and the else block in a way readers can't trace.

  The fix is to *factor* — pull each error-prone step into its own
  function that returns a normalized result, then chain those at the
  caller.

  ## Detection

  Flags `with ... else <arms> end` where the `else` block has 4 or
  more `->` arms. The threshold is configurable via
  `:else_arm_threshold` (default 4).

  3-arm `else` blocks (e.g. `:ok` + one specific retryable error +
  generic error) are NOT flagged at the default threshold — those
  often represent legitimate fine-grained error handling at a
  single boundary.

  ## Bad

      with {:ok, user} <- fetch_user(id),
           {:ok, perms} <- fetch_perms(user),
           {:ok, audit} <- log_access(user, perms),
           {:ok, _} <- track_metric(:access) do
        {:ok, perms}
      else
        {:error, :user_not_found} -> {:error, :not_found}
        {:error, :no_permissions} -> {:error, :forbidden}
        {:error, :audit_failed} -> {:error, :internal}
        {:error, :metrics_down} -> {:ok, perms}            # mixed shapes!
        :error -> {:error, :unknown}
      end

  ## Good

      def authorized_perms(id) do
        with {:ok, user} <- to_user(id),
             {:ok, perms} <- to_perms(user) do
          _ = audit_and_track(user, perms)   # side effect; failure swallowed
          {:ok, perms}
        end
      end

      defp to_user(id) do
        case fetch_user(id) do
          {:ok, user} -> {:ok, user}
          {:error, :user_not_found} -> {:error, :not_found}
        end
      end

      # …each step normalizes its own errors.

  ## Why advisory, not boundary

  Some 3-4 arm `else` blocks are legitimate — e.g. catching a
  specific network-transient error class separately from generic
  failures. The threshold is a heuristic, not a correctness
  boundary. Treat findings as "have a second look at whether this
  `with` is doing too much," not as a hard error.
  """

  use CredenceRules.Rule

  alias CredenceRules.AstKeyword

  @default_threshold 4

  @impl true
  def priority, do: 240

  @impl true
  def check(ast, opts) do
    threshold = Keyword.get(opts, :else_arm_threshold, @default_threshold)

    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:with, meta, args} = node, acc when is_list(args) ->
          case else_arms(args) do
            arms when length(arms) >= threshold ->
              {node, [build_issue(meta, length(arms), threshold) | acc]}

            _ ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  # `with` args end with a keyword list: `[do: body]` or
  # `[do: body, else: arms]`. Returns the `else:` arms list (the
  # `{:->, _, _}` triples) or [] if there's no else.
  defp else_arms(args) do
    with kw when is_list(kw) <- List.last(args),
         arms when is_list(arms) <- AstKeyword.get(kw, :else) do
      Enum.filter(arms, fn
        {:->, _, _} -> true
        _ -> false
      end)
    else
      _ -> []
    end
  end

  defp build_issue(meta, arm_count, threshold) do
    %Issue{
      rule: :with_complex_else,
      message:
        "`with ... else` has #{arm_count} arms (threshold #{threshold}). " <>
          "When the `else` grows this large, the `with` chain is usually " <>
          "doing too many unrelated things — factor each error-prone step " <>
          "into its own function that returns a normalized result, then " <>
          "chain those at the caller.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
