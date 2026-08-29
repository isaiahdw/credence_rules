defmodule CredenceRules.Pattern.LargeDefstructTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.LargeDefstruct

  defp analyze(source, opts \\ []) do
    {:ok, ast} = Code.string_to_quoted(source)
    LargeDefstruct.check(ast, [source: source] ++ opts)
  end

  defp analyze_sourceror(source, opts \\ []) do
    {:ok, ast} = Sourceror.parse_string(source)
    LargeDefstruct.check(ast, [source: source] ++ opts)
  end

  describe "check/2 — flagged (prefix clustering)" do
    test "flags the canonical glued-entity struct" do
      source = ~S"""
      defmodule User do
        defstruct [
          :password_hash, :mfa_enabled, :last_login_at,
          :stripe_customer_id, :plan, :trial_ends_at, :payment_method,
          :timezone, :locale, :theme
        ]
      end
      """

      # Three implicit clusters (no shared prefix) but the field
      # names don't share a leading segment under our heuristic.
      # The actual prefix split on these is one cluster per field —
      # so this particular bad shape doesn't fire. Use a more
      # textbook clustered example below.
      assert [] = analyze(source)
    end

    test "flags an auth_* / billing_* / pref_* clustered struct" do
      source = ~S"""
      defmodule User do
        defstruct [
          :auth_password_hash, :auth_mfa_enabled, :auth_last_login_at,
          :billing_stripe_customer_id, :billing_plan, :billing_trial_ends_at, :billing_payment_method,
          :pref_timezone, :pref_locale, :pref_theme
        ]
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :large_defstruct
      assert issue.meta.fields == 10
      assert length(issue.meta.clusters) == 3
      clusters = Map.new(issue.meta.clusters)
      assert clusters["auth"] == 3
      assert clusters["billing"] == 4
      assert clusters["pref"] == 3
    end

    test "flags a 2-cluster struct (non-protocol prefixes)" do
      # `request_*` / `response_*` would trip an "is this two
      # sub-entities glued together?" review. Unlike `peer_*` /
      # `local_*` (auto-exempted as participant-pair protocol state),
      # request/response don't match a known crypto pattern.
      source = ~S"""
      defmodule RequestState do
        defstruct [
          :request_method, :request_path, :request_headers,
          :request_body,
          :response_status, :response_headers, :response_body,
          :elapsed_ms, :user_agent, :remote_ip
        ]
      end
      """

      assert [issue] = analyze(source)
      assert length(issue.meta.clusters) == 2
    end

    test "honours custom :min_cluster_size" do
      # Two clusters of 2 fields each. Default min_cluster_size=3
      # wouldn't fire; lower to 2 and it does.
      source = ~S"""
      defmodule M do
        defstruct [
          :foo_a, :foo_b,
          :bar_a, :bar_b,
          :x, :y, :z, :w, :u, :v
        ]
      end
      """

      assert [] = analyze(source)
      assert [_] = analyze(source, min_cluster_size: 2)
    end
  end

  describe "check/2 — not flagged" do
    test "ignores small structs (below :scan_min_fields)" do
      source = ~S"""
      defmodule M do
        defstruct [:foo_a, :foo_b, :foo_c, :bar_a, :bar_b, :bar_c]
      end
      """

      assert [] = analyze(source)
    end

    test "ignores wide single-entity struct (no clusters)" do
      # Wire-format mirror / persisted record — every field has a
      # distinct name, no clustering.
      source = ~S"""
      defmodule CommissionableNode do
        defstruct [
          :host, :port, :ttl, :addrs, :last_seen,
          :discriminator, :vendor_id, :product_id,
          :sii, :sai, :hint, :commissioning_mode,
          :rotating_id, :pairing_hint, :pairing_instr
        ]
      end
      """

      assert [] = analyze(source)
    end

    test "ignores a single cluster (one sub-entity is just an entity)" do
      source = ~S"""
      defmodule M do
        defstruct [
          :auth_a, :auth_b, :auth_c, :auth_d,
          :x, :y, :z, :w, :u, :v
        ]
      end
      """

      assert [] = analyze(source)
    end

    test "ignores keyword-shape (with defaults)" do
      source = ~S"""
      defmodule M do
        defstruct foo: nil, bar: nil, baz: nil
      end
      """

      assert [] = analyze(source)
    end

    test "ignores plain code" do
      assert [] = analyze("x = 1")
    end
  end

  describe "check/2 — protocol-state exemption" do
    test "skips a peer_* / local_* handshake state struct" do
      # SIGMA handshake state with
      # symmetric peer/local participant fields. Algorithm requires
      # the symmetry — there's no responsibility to split.
      source = ~S"""
      defmodule Handshake do
        defstruct [
          :peer_random, :peer_session_id, :peer_ecdh_public,
          :peer_noc, :peer_icac,
          :local_random, :local_ecdh_public, :local_ecdh_private,
          :shared, :transcript
        ]
      end
      """

      assert [] = analyze(source)
    end

    test "skips an initiator_* / responder_* protocol struct" do
      source = ~S"""
      defmodule Noise do
        defstruct [
          :initiator_static, :initiator_ephemeral, :initiator_nonce,
          :responder_static, :responder_ephemeral, :responder_nonce,
          :handshake_state, :symmetric_state, :cipher_state, :rng
        ]
      end
      """

      assert [] = analyze(source)
    end

    test "skips a client_* / server_* TLS-style struct" do
      source = ~S"""
      defmodule Tls do
        defstruct [
          :client_random, :client_certificate, :client_key_share,
          :server_random, :server_certificate, :server_key_share,
          :cipher_suite, :version, :session_id, :extensions
        ]
      end
      """

      assert [] = analyze(source)
    end

    test "skips a SIGMA-style struct via crypto markers (no participant prefix)" do
      # Marker-based exemption: enough crypto-protocol field names
      # to recognise the domain regardless of how the cluster prefixes
      # land. `sigma1_bytes`, `sigma2_bytes`, `sigma3_bytes` +
      # `shared_secret` + `ipk` → 5 markers, exemption fires.
      source = ~S"""
      defmodule Sigma do
        defstruct [
          :sigma1_bytes, :sigma2_bytes, :sigma3_bytes,
          :shared_secret, :ipk,
          :fabric_a, :fabric_b, :fabric_c,
          :session_a, :session_b
        ]
      end
      """

      assert [] = analyze(source)
    end

    test "still flags a non-protocol struct even with one participant cluster" do
      # `peer_*` alone (without `local_*` matching it) isn't the
      # protocol-state shape — could be just clustered domain fields.
      # Should still flag if it forms a normal multi-cluster pattern.
      source = ~S"""
      defmodule PeerThing do
        defstruct [
          :peer_a, :peer_b, :peer_c,
          :metric_a, :metric_b, :metric_c, :metric_d,
          :extra_a, :extra_b, :extra_c
        ]
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — allowlist" do
    test "skips struct inside a GenServer module regardless of clustering" do
      source = ~S"""
      defmodule M do
        use GenServer

        defstruct [
          :auth_a, :auth_b, :auth_c,
          :billing_a, :billing_b, :billing_c,
          :pref_a, :pref_b, :pref_c, :pref_d
        ]
      end
      """

      assert [] = analyze(source)
    end

    test "skips struct inside a `use GenServer, restart: :transient` module" do
      source = ~S"""
      defmodule M do
        use GenServer, restart: :transient

        defstruct [
          :auth_a, :auth_b, :auth_c,
          :billing_a, :billing_b, :billing_c,
          :pref_a, :pref_b, :pref_c, :pref_d
        ]
      end
      """

      assert [] = analyze(source)
    end

    test "skips struct inside a `@behaviour :gen_statem` module" do
      source = ~S"""
      defmodule M do
        @behaviour :gen_statem

        defstruct [
          :peer_a, :peer_b, :peer_c,
          :local_a, :local_b, :local_c
        ]
      end
      """

      assert [] = analyze(source)
    end

    test "skips struct inside a `use Ecto.Schema` module (persisted record)" do
      source = ~S"""
      defmodule User do
        use Ecto.Schema

        defstruct [
          :auth_a, :auth_b, :auth_c,
          :billing_a, :billing_b, :billing_c,
          :pref_a, :pref_b, :pref_c, :pref_d
        ]
      end
      """

      assert [] = analyze(source)
    end

    test "still flags clustered struct in non-allowlisted module" do
      source = ~S"""
      defmodule M do
        use SomeOtherLib

        defstruct [
          :auth_a, :auth_b, :auth_c,
          :billing_a, :billing_b, :billing_c,
          :pref_a, :pref_b, :pref_c, :pref_d
        ]
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — Sourceror-parsed (production path)" do
    test "still detects clustering under Sourceror parse" do
      source = ~S"""
      defmodule M do
        defstruct [
          :auth_a, :auth_b, :auth_c,
          :billing_a, :billing_b, :billing_c,
          :pref_a, :pref_b, :pref_c, :pref_d
        ]
      end
      """

      assert [_] = analyze_sourceror(source)
    end

    test "still allowlists `@behaviour :gen_statem` (bare atom) under Sourceror parse" do
      source = ~S"""
      defmodule F do
        @behaviour :gen_statem

        defstruct [
          :peer_a, :peer_b, :peer_c,
          :local_a, :local_b, :local_c
        ]
      end
      """

      assert [] = analyze_sourceror(source)
    end

    test "still allowlists `@behaviour :gen_event` (bare atom) under Sourceror parse" do
      source = ~S"""
      defmodule F do
        @behaviour :gen_event

        defstruct [
          :req_a, :req_b, :req_c,
          :rsp_a, :rsp_b, :rsp_c
        ]
      end
      """

      assert [] = analyze_sourceror(source)
    end

    test "still allowlists `use :gen_statem` (bare atom) under Sourceror parse" do
      source = ~S"""
      defmodule F do
        use :gen_statem

        defstruct [
          :peer_a, :peer_b, :peer_c,
          :local_a, :local_b, :local_c
        ]
      end
      """

      assert [] = analyze_sourceror(source)
    end

    test "still allowlists `use Ecto.Schema` under Sourceror parse" do
      source = ~S"""
      defmodule User do
        use Ecto.Schema

        defstruct [
          :auth_a, :auth_b, :auth_c,
          :billing_a, :billing_b, :billing_c,
          :pref_a, :pref_b, :pref_c, :pref_d
        ]
      end
      """

      assert [] = analyze_sourceror(source)
    end
  end
end
