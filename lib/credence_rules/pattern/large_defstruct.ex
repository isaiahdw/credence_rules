# credence-file:repeated_case_arm_body — this module is an AST pattern matcher
#   whose check/2 + Macro.prewalk + build_issue shape is the Rule contract
#   itself, so the structural duplication is inherent to the form rather than a
#   smell
defmodule CredenceRules.Pattern.LargeDefstruct do
  @moduledoc """
  SRP rule: a `defstruct` that conflates multiple sub-entities under
  one struct. The smell isn't *width* — it's the field set forming
  two or three clusters of related names that belong to different
  responsibilities, lifetimes, or invariants.

  ## Bad

      defstruct [
        # auth (3)
        :password_hash, :mfa_enabled, :last_login_at,
        # billing (4)
        :stripe_customer_id, :plan, :trial_ends_at, :payment_method,
        # preferences (3)
        :timezone, :locale, :theme
      ]

  Three sub-entities under one struct. Each has a different lifetime
  (auth state vs. subscription vs. UX prefs) and different invariants.
  Splitting into `Auth`/`Billing`/`Prefs` makes the seams visible and
  lets each piece be changed without re-reading the others.

  ## Good — split by concern

      defstruct [:auth, :profile, :billing, :prefs]

      defmodule Auth do
        defstruct [:password_hash, :mfa_enabled, :last_login_at]
      end

      # ...

  ## Detection — prefix clustering

  Group the struct's field names by their first underscore-delimited
  segment. If `min_clusters` or more groups each have at least
  `min_cluster_size` fields, the struct is flagged — those groups
  signal sub-entities. Otherwise it's one entity with many distinct
  attributes (a wire-format mirror, a persisted record, a cache
  entry, parser state) and the rule stays silent.

  This is a much better proxy than field count: wide-but-single-entity
  structs (whose field names are heterogeneous) cluster as
  many-groups-of-one, so they don't trip the rule. Glued-entity
  structs (whose field names share `auth_*`, `billing_*` prefixes)
  cluster naturally.

  Defaults:

  - `:min_cluster_size` — fields per cluster needed to call it a
    sub-entity. Default 3. Below this and the cluster is just two
    related fields, not a sub-entity.
  - `:min_clusters` — number of qualifying clusters needed. Default
    2. One cluster of related fields is just an entity with related
    fields.
  - `:scan_min_fields` — only run clustering on structs with at
    least this many fields. Default 10. No point clustering a
    4-field struct.

  ## State-machine + schema allowlist

  Structs inside modules that declare one of:

  - `use GenServer` / `use GenStage`
  - `use :gen_statem` / `@behaviour :gen_statem`
  - `@behaviour GenServer` / `@behaviour :gen_event`
  - `use Ecto.Schema`

  …are skipped regardless of the clustering result. State-machine
  state has one lifetime; schema fields are defined by the data
  contract (the table/spec), so any "clusters" they form are
  representational, not a smell. The clustering heuristic complements
  the allowlist; it doesn't replace it.

  ## Protocol-state exemption

  Two-party cryptographic handshake structs are *supposed* to have
  a `peer_*` / `local_*` (or `initiator_*` / `responder_*`,
  `client_*` / `server_*`) cluster pair — the local/peer symmetry IS
  the algorithm. SIGMA, Noise, TLS handshakes, Diffie-Hellman
  exchanges all share this exact shape because the protocol has two
  participants. There's no "responsibility" to split.

  The rule auto-detects this in two cheap ways; either one trips
  the exemption:

  1. **Symmetric participant clusters**. The two largest clusters
     are paired members of `peer`/`local`, `initiator`/`responder`,
     or `client`/`server`.
  2. **Crypto-handshake field markers**. 3+ fields match a
     crypto-protocol name pattern (`*_random`, `*_ecdh_*`,
     `*_nonce`, `shared_secret`, `ipk`, `sigma*_bytes`,
     `handshake_*`, `transcript_*`, `*_keyshare`). These names are
     domain-specific to crypto protocols and don't naturally appear
     in business-logic structs.

  ## Why advisory

  Even clean clustering matches can be intentional beyond the
  documented exemptions. Treat findings as "is the clustering
  intentional, or did sub-entities accumulate by accident?" — not a
  hard cap.
  """

  use CredenceRules.Rule

  alias CredenceRules.AstKeyword

  @hint """
  Split by cluster. Each cluster becomes its own struct; the
  outer struct holds them as fields:

      # Before — auth_*, billing_*, pref_* glued together
      defmodule User do
        defstruct [
          :auth_password_hash, :auth_mfa_enabled, :auth_last_login_at,
          :billing_stripe_id, :billing_plan, :billing_trial_ends_at,
          :pref_timezone, :pref_locale, :pref_theme
        ]
      end

      # After — one struct per sub-entity, composed at the boundary
      defmodule User do
        defstruct [:auth, :billing, :prefs]
      end

      defmodule User.Auth do
        defstruct [:password_hash, :mfa_enabled, :last_login_at]
      end

      defmodule User.Billing do
        defstruct [:stripe_id, :plan, :trial_ends_at]
      end

      defmodule User.Prefs do
        defstruct [:timezone, :locale, :theme]
      end

  Or own each lifetime separately as its own module + changeset.
  """

  @carve_outs [
    "State-machine state (use GenServer / GenStage / :gen_statem / @behaviour :gen_statem|GenServer|:gen_event) — one process, one logical entity. Auto-skipped.",
    "Ecto schemas (use Ecto.Schema) — fields are defined by the table contract. Auto-skipped.",
    "Two-party crypto protocol state (peer_*/local_*, initiator_*/responder_*, client_*/server_*) or struct with 3+ crypto field markers (*_random, sigma*_bytes, shared_secret, etc.). The symmetry IS the algorithm. Auto-skipped.",
    "Wire-format mirrors / persisted records / parser state with many heterogeneous fields — no clustering, won't trip the rule."
  ]

  @default_min_cluster_size 3
  @default_min_clusters 2
  @default_scan_min_fields 10

  @impl true
  def priority, do: 420

  @impl true
  def check(ast, opts) do
    min_cluster_size = Keyword.get(opts, :min_cluster_size, @default_min_cluster_size)
    min_clusters = Keyword.get(opts, :min_clusters, @default_min_clusters)
    scan_min_fields = Keyword.get(opts, :scan_min_fields, @default_scan_min_fields)

    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [_alias, kw]} = node, acc when is_list(kw) ->
          case AstKeyword.get(kw, :do) do
            nil ->
              {node, acc}

            body ->
              {node, scan_module(body, min_cluster_size, min_clusters, scan_min_fields) ++ acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  defp scan_module(body, min_cluster_size, min_clusters, scan_min_fields) do
    if allowlisted_module?(body) do
      []
    else
      collect_defstruct_issues(body, min_cluster_size, min_clusters, scan_min_fields)
    end
  end

  defp top_level_statements({:__block__, _, list}), do: list
  defp top_level_statements(single), do: [single]

  defp allowlisted_module?(body) do
    body
    |> top_level_statements()
    |> Enum.any?(&allowlist_declaration?/1)
  end

  # `use GenServer / GenStage / :gen_statem / :gen_event / Ecto.Schema`,
  # `@behaviour GenServer / :gen_statem / :gen_event`.
  defp allowlist_declaration?({:use, _, [arg]}), do: allowlist_arg?(arg)
  defp allowlist_declaration?({:use, _, [arg, _opts]}), do: allowlist_arg?(arg)

  defp allowlist_declaration?({:@, _, [{:behaviour, _, [arg]}]}), do: allowlist_arg?(arg)

  defp allowlist_declaration?(_), do: false

  defp allowlist_arg?(arg) do
    case unwrap_block(arg) do
      {:__aliases__, _, [last]} when last in [:GenServer, :GenStage] -> true
      {:__aliases__, _, [:Ecto, :Schema]} -> true
      :gen_statem -> true
      :gen_event -> true
      _ -> false
    end
  end

  defp unwrap_block({:__block__, _, [inner]}), do: inner
  defp unwrap_block(other), do: other

  defp collect_defstruct_issues(body, min_cluster_size, min_clusters, scan_min_fields) do
    body
    |> top_level_statements()
    |> Enum.flat_map(fn
      {:defstruct, meta, [arg]} ->
        case extract_field_names(arg) do
          fields when length(fields) >= scan_min_fields ->
            check_struct(fields, meta, min_cluster_size, min_clusters)

          _ ->
            []
        end

      _ ->
        []
    end)
  end

  defp check_struct(fields, meta, min_cluster_size, min_clusters) do
    cluster_summary = cluster_fields(fields, min_cluster_size)

    cond do
      length(cluster_summary) < min_clusters -> []
      protocol_state?(fields, cluster_summary) -> []
      true -> [build_issue(meta, length(fields), cluster_summary, min_cluster_size)]
    end
  end

  # Two-party crypto handshake state — `peer_*` / `local_*` (or other
  # participant-pair) clusters, OR crypto-marker fields present.
  defp protocol_state?(fields, clusters) do
    symmetric_participant_clusters?(clusters) or crypto_markers?(fields)
  end

  @participant_pairs [
    {"peer", "local"},
    {"initiator", "responder"},
    {"client", "server"}
  ]

  defp symmetric_participant_clusters?([{a, _}, {b, _} | _]) do
    Enum.any?(@participant_pairs, fn {x, y} ->
      (a == x and b == y) or (a == y and b == x)
    end)
  end

  defp symmetric_participant_clusters?(_), do: false

  @crypto_field_patterns [
    ~r/_random$/,
    ~r/_ecdh_/,
    ~r/_nonce$/,
    ~r/^shared_secret$/,
    ~r/^ipk$/,
    ~r/^sigma[0-9]*_bytes$/,
    ~r/^handshake_/,
    ~r/^transcript_/,
    ~r/_keyshare$/
  ]

  defp crypto_markers?(fields) do
    matching =
      Enum.count(fields, fn field ->
        name = Atom.to_string(field)
        Enum.any?(@crypto_field_patterns, &Regex.match?(&1, name))
      end)

    matching >= 3
  end

  # Extract field name atoms from a defstruct argument. Handles:
  #   defstruct [:a, :b]
  #   defstruct a: 1, b: 2
  #   defstruct [:a, b: 1]
  # Sourceror wraps the list and every atom; unwrap as we go.
  defp extract_field_names({:__block__, _, [inner]}), do: extract_field_names(inner)

  defp extract_field_names(fields) when is_list(fields) do
    Enum.flat_map(fields, &field_name/1)
  end

  defp extract_field_names(_), do: []

  defp field_name({:__block__, _, [inner]}), do: field_name(inner)
  defp field_name(atom) when is_atom(atom), do: [atom]
  defp field_name({key, _default}) when is_atom(key), do: [key]
  defp field_name({{:__block__, _, [key]}, _default}) when is_atom(key), do: [key]
  defp field_name(_), do: []

  # Group field atoms by first underscore-delimited segment. Return
  # `[{prefix, count}, …]` for clusters meeting min_cluster_size,
  # sorted by descending count for stable reporting.
  defp cluster_fields(fields, min_cluster_size) do
    fields
    |> Enum.group_by(&prefix/1)
    |> Enum.flat_map(fn {prefix, group} ->
      if length(group) >= min_cluster_size, do: [{prefix, length(group)}], else: []
    end)
    |> Enum.sort_by(fn {_p, count} -> -count end)
  end

  defp prefix(atom) when is_atom(atom) do
    atom
    |> Atom.to_string()
    |> String.split("_", parts: 2)
    |> hd()
  end

  defp build_issue(meta, total_fields, clusters, min_cluster_size) do
    summary = Enum.map_join(clusters, ", ", fn {prefix, count} -> "#{prefix}_* (#{count})" end)

    %Issue{
      rule: :large_defstruct,
      message:
        "`defstruct` with #{total_fields} fields forms #{length(clusters)} naming " <>
          "clusters of ≥ #{min_cluster_size} fields each: #{summary}. The clusters " <>
          "signal sub-entities glued under one struct — split by responsibility " <>
          "(`#{leading_prefix(clusters)}` could be its own struct) and compose at " <>
          "the boundary, or accept the clustering if it's intentional for the " <>
          "algorithm (handshake state, protocol frame).",
      meta: %{
        line: Keyword.get(meta, :line),
        fields: total_fields,
        clusters: clusters
      }
    }
  end

  defp leading_prefix([{prefix, _} | _]), do: prefix
  defp leading_prefix(_), do: "?"
end
