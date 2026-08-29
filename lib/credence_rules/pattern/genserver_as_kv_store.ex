defmodule CredenceRules.Pattern.GenserverAsKvStore do
  @moduledoc """
  Idiomatic rule: a `use GenServer` module whose entire public API is
  `get/put/delete/...` is a key-value store implemented as a
  process — almost always the wrong tool.

  When the public API of a GenServer is just shuttling values in
  and out of its state map, the process role is "I'm a Map with a
  pid wrapper." That has costs without benefits:

  - **All reads and writes serialize through one mailbox** — a
    Map.new + `Agent`/`ETS` would parallelize reads.
  - **Crashes drop the state** — no persistence, no recovery beyond
    `init/1` re-seeding.
  - **The pid becomes a global** that everything has to look up.

  The right primitives:

  - **`ETS`** with `read_concurrency: true` — concurrent reads,
    pid-anchored ownership, near-instant writes.
  - **`:persistent_term`** for truly write-once / boot-time data.
  - **Plain state in callers** — pass the map through if it's
    request-scoped, not application-global.

  This rule is the companion to `genserver_with_immutable_state`:
  that one catches "GenServer that doesn't mutate state at all"
  (calculator-in-a-process); this one catches "GenServer whose only
  job IS to be a Map" (KV-store-in-a-process).

  ## Detection

  Flags a `use GenServer` module whose public `def`s (excluding
  OTP callbacks and lifecycle functions: `init`, `handle_*`,
  `terminate`, `code_change`, `format_status`, `start_link`,
  `start`, `child_spec`) are entirely within a small KV-style
  vocabulary:

  `get, put, delete, fetch, fetch!, has_key?, keys, values,
  update, update!, get_and_update, merge, take, drop, pop, lookup,
  insert, remove, all, list, clear, member?`

  If the public API has even one method that isn't in that
  vocabulary, the rule doesn't fire — the GenServer is doing
  something domain-specific.

  ## Bad

      defmodule Cache do
        use GenServer

        # Public API
        def get(k), do: GenServer.call(__MODULE__, {:get, k})
        def put(k, v), do: GenServer.call(__MODULE__, {:put, k, v})
        def delete(k), do: GenServer.call(__MODULE__, {:delete, k})

        # Callbacks just shuttle from state.
      end

  ## Good — use ETS

      defmodule Cache do
        @table :cache

        def init(_) do
          :ets.new(@table, [:named_table, :public, read_concurrency: true])
          # ...
        end

        def get(k), do: :ets.lookup(@table, k) |> List.first()
        def put(k, v), do: :ets.insert(@table, {k, v})
        def delete(k), do: :ets.delete(@table, k)
      end
  """

  use CredenceRules.Rule

  @kv_vocabulary MapSet.new(~w(get put delete fetch fetch! has_key? keys values
                      update update! get_and_update merge take drop pop
                      lookup insert remove all list clear member? size count)a)

  @callback_names MapSet.new(~w(init handle_call handle_cast handle_info handle_continue
                       handle_event terminate code_change format_status
                       start_link start child_spec)a)

  @impl true
  def priority, do: 460

  @impl true
  def check(ast, _opts) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:defmodule, meta, [_alias, [{:do, body}]]} = node, acc ->
          if uses_genserver?(body) and kv_only_api?(body),
            do: {node, [build_issue(meta) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp uses_genserver?(body) do
    stmts =
      case body do
        {:__block__, _, list} -> list
        single -> [single]
      end

    Enum.any?(stmts, fn
      {:use, _, [{:__aliases__, _, [:GenServer]}]} -> true
      {:use, _, [{:__aliases__, _, [:GenServer]}, _]} -> true
      _ -> false
    end)
  end

  # Returns true if all public `def`s (excluding OTP callbacks /
  # lifecycle) have names from the KV vocabulary. Requires at least
  # two such non-callback public defs (otherwise it's not really an
  # "API," it's just a single helper).
  defp kv_only_api?(body) do
    public_names = collect_public_def_names(body)

    api_names = Enum.reject(public_names, &MapSet.member?(@callback_names, &1))

    match?([_, _ | _], api_names) and
      Enum.all?(api_names, &MapSet.member?(@kv_vocabulary, &1))
  end

  defp collect_public_def_names(body) do
    {_ast, names} =
      Macro.prewalk(body, [], fn
        {:def, _, [head, _]} = node, acc ->
          # `head` is always either `{name, _, args}` or
          # `{:when, _, [inner, _guard]}` for a real def — `extract_name/1`
          # collapses both into an atom name.
          {node, [extract_name(head) | acc]}

        node, acc ->
          {node, acc}
      end)

    names
    |> Enum.reverse()
    |> Enum.reject(&is_nil/1)
  end

  # Returns the name atom for a def head, or `nil` if the AST shape is
  # unrecognized (defensive — Macro.prewalk should only hand us valid heads).
  defp extract_name({:when, _, [inner, _]}), do: extract_name(inner)
  defp extract_name({name, _, _}) when is_atom(name), do: name
  defp extract_name(_), do: nil

  defp build_issue(meta) do
    %Issue{
      rule: :genserver_as_kv_store,
      message:
        "This module `use GenServer` and its entire public API is " <>
          "get/put/delete-style key-value methods. A GenServer-wrapped Map " <>
          "serializes every read and write through one mailbox without " <>
          "giving you concurrency, persistence, or fault isolation. Use " <>
          "ETS (concurrent reads), `:persistent_term` (write-once), or " <>
          "plain state if the data is request-scoped.",
      meta: %{line: Keyword.get(meta, :line)}
    }
  end
end
