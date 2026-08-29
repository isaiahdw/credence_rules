defmodule CredenceRules.Pattern.IospPredicateSideEffectsTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.IospPredicateSideEffects

  defp analyze(source, opts \\ []) do
    {:ok, ast} = Code.string_to_quoted(source)
    IospPredicateSideEffects.check(ast, [source: source] ++ opts)
  end

  defp analyze_sourceror(source, opts \\ []) do
    {:ok, ast} = Sourceror.parse_string(source)
    IospPredicateSideEffects.check(ast, [source: source] ++ opts)
  end

  describe "check/2 — flagged predicates" do
    test "flags a predicate that calls Repo" do
      source = ~S"""
      defmodule Users do
        def active?(user) do
          Repo.exists?(from s in Subscription, where: s.user_id == ^user.id)
        end
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :iosp_predicate_side_effects
      assert issue.meta.function == :active?
    end

    test "flags a predicate that calls an HTTP client" do
      source = ~S"""
      defmodule Auth do
        def authorised?(token) do
          case Req.get("https://auth/verify", json: %{token: token}) do
            {:ok, %{status: 200}} -> true
            _ -> false
          end
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "flags a predicate that calls GenServer" do
      source = ~S"""
      defmodule Cache do
        def stale?(key) do
          case GenServer.call(__MODULE__, {:age, key}) do
            n when n > 60 -> true
            _ -> false
          end
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "flags a predicate that calls :ets (Erlang bare atom)" do
      source = ~S"""
      defmodule Cache do
        def member?(key) do
          :ets.member(:my_cache, key)
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "flags a predicate that calls :persistent_term" do
      source = ~S"""
      defmodule Feature do
        def enabled?(name) do
          :persistent_term.get({:feature, name}, false)
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "flags a predicate that calls a custom-aliased Repo" do
      # `MyApp.Repo` ends in `Repo` — matched by the trailing-segment
      # rule. Users don't have to enumerate every aliased path.
      source = ~S"""
      defmodule Users do
        alias MyApp.Repo

        def active?(user) do
          MyApp.Repo.get(User, user.id)
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "flags defp (private) predicates too" do
      source = ~S"""
      defmodule Users do
        defp loaded?(user), do: Repo.exists?(User, user.id)
      end
      """

      assert [_] = analyze(source)
    end

    test "flags multi-clause predicate when ANY clause has a side effect" do
      source = ~S"""
      defmodule Users do
        def active?(%User{} = u), do: Repo.exists?(Subscription, u.id)
        def active?(_), do: false
      end
      """

      # One clause has the side effect — should fire.
      assert [_] = analyze(source)
    end

    test "honours custom :side_effect_modules" do
      source = ~S"""
      defmodule Users do
        def active?(user), do: MyApp.Mailer.delivered?(user.email)
      end
      """

      # Default list doesn't include Mailer — no finding.
      assert [] = analyze(source)
      # Add Mailer → finding.
      assert [_] = analyze(source, side_effect_modules: ["Mailer"])
    end
  end

  describe "check/2 — not flagged" do
    test "ignores non-predicate functions that call Repo" do
      source = ~S"""
      defmodule Users do
        def list_active do
          Repo.all(from u in User, where: u.active == true)
        end
      end
      """

      assert [] = analyze(source)
    end

    test "ignores a pure predicate (no side effects)" do
      source = ~S"""
      defmodule Users do
        def adult?(user), do: user.age >= 18
      end
      """

      assert [] = analyze(source)
    end

    test "ignores predicate calling pure stdlib (Enum, Map, String)" do
      source = ~S"""
      defmodule Users do
        def has_email?(user) do
          user.email
          |> String.trim()
          |> String.length()
          |> then(&(&1 > 0))
        end
      end
      """

      assert [] = analyze(source)
    end

    test "ignores predicate calling MapSet/Map helpers" do
      source = ~S"""
      defmodule Users do
        def member?(user, ids), do: MapSet.member?(ids, user.id)
      end
      """

      assert [] = analyze(source)
    end

    test "ignores defguard (pure by construction)" do
      source = ~S"""
      defmodule Helpers do
        defguard adult?(age) when age >= 18
      end
      """

      # defguard generates a `def adult?(...)` under the hood in some
      # versions — but the AST top-level node is `:defguard`, not
      # `:def`. Our walker only matches `:def`/`:defp`, so this is
      # naturally skipped.
      assert [] = analyze(source)
    end

    test "ignores plain code" do
      assert [] = analyze("x = 1")
    end
  end

  describe "check/2 — Sourceror-parsed (production path)" do
    test "still flags Repo-calling predicate under Sourceror" do
      source = ~S"""
      defmodule Users do
        def active?(user) do
          Repo.exists?(Subscription, user.id)
        end
      end
      """

      assert [_] = analyze_sourceror(source)
    end

    test "still flags :ets bare-atom call under Sourceror" do
      source = ~S"""
      defmodule Cache do
        def member?(key) do
          :ets.member(:my_cache, key)
        end
      end
      """

      assert [_] = analyze_sourceror(source)
    end
  end

  describe "check/2 — liveness-predicate exemption" do
    test "skips simple Process.alive? predicate" do
      # Lifting this to integration would create a TOCTOU window —
      # the cached alive? is stale by the time the pure predicate
      # evaluates. See moduledoc.
      source = ~S"""
      defmodule ReadClient do
        def session_reusable?(%{exchange_mgr: mgr}) when is_pid(mgr),
          do: Process.alive?(mgr)

        def session_reusable?(_), do: false
      end
      """

      assert [] = analyze(source)
    end

    test "skips Process.alive? + companion GenServer getter (composed liveness)" do
      # Real-world shape: Process.alive?(mgr) composed
      # with a getter on the live per-instance GenServer. The getter
      # is asking the live process for its state — semantically
      # part of the same liveness check.
      source = ~S"""
      defmodule ReadClient do
        def case_session_defunct?(state) do
          case state.exchange_mgr do
            mgr when is_pid(mgr) ->
              if Process.alive?(mgr) do
                peer_silent_too_long?(state, ExchangeManager.last_peer_activity_at(mgr))
              else
                true
              end

            _ ->
              false
          end
        end
      end
      """

      assert [] = analyze(source)
    end

    test "skips :erlang.is_process_alive predicate" do
      source = ~S"""
      defmodule M do
        def reachable?(pid), do: :erlang.is_process_alive(pid)
      end
      """

      assert [] = analyze(source)
    end

    test "skips Port.info predicate" do
      source = ~S"""
      defmodule M do
        def port_open?(port), do: Port.info(port) != nil
      end
      """

      assert [] = analyze(source)
    end

    test "skips MyApp.Process.alive? (trailing segment matches)" do
      # Custom Process namespace — `Process.alive?` is recognised by
      # the trailing segment so `alias MyApp.Process, as: Proc;
      # Proc.alive?(pid)` would also exempt (alias is transparent
      # to the AST after expansion; here we use the un-aliased form).
      source = ~S"""
      defmodule M do
        def alive_check?(pid), do: MyApp.Process.alive?(pid)
      end
      """

      assert [] = analyze(source)
    end

    test "still flags a clock-shaped predicate (Repo + no liveness marker)" do
      # Clock-like (or DB-like) reads are fine to lift — the staleness
      # window is bounded. This rule should still fire on those.
      source = ~S"""
      defmodule M do
        def active?(user) do
          Repo.exists?(Subscription, user_id: user.id)
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "still flags HTTP-call predicate (no liveness marker)" do
      source = ~S"""
      defmodule Auth do
        def authorised?(token) do
          Req.get!("https://auth/verify", json: %{token: token})
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "skips predicate calling Process.info/2 (introspection)" do
      source = ~S"""
      defmodule M do
        def named?(pid) do
          case Process.info(pid, :registered_name) do
            {:registered_name, _} -> true
            _ -> false
          end
        end
      end
      """

      assert [] = analyze(source)
    end

    test "skips predicate calling Process.whereis/1" do
      source = ~S"""
      defmodule M do
        def registered?(name), do: Process.whereis(name) != nil
      end
      """

      assert [] = analyze(source)
    end
  end

  describe "check/2 — per-call introspection exemption" do
    test "flags Process.alive? AND Repo.exists? composed (bug fix)" do
      # Before the per-call fix: whole-function liveness exemption
      # silently hid the Repo.exists? call. Now the exemption is
      # per-call — Process.alive? skips but the walk continues,
      # finds Repo.exists?, flags.
      source = ~S"""
      defmodule M do
        def active?(user) do
          Process.alive?(user.pid) and Repo.exists?(Subscription, user_id: user.id)
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "flags Process.info AND GenServer.call composed (bug fix)" do
      source = ~S"""
      defmodule M do
        def named_active?(pid) do
          case Process.info(pid, :registered_name) do
            {:registered_name, _name} -> GenServer.call(pid, :is_active)
            _ -> false
          end
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "still skips a pure liveness predicate (no other side effects)" do
      # Process.alive? alone — no other side effects in the body.
      # Per-call exemption: skip Process.alive?, walk continues,
      # finds nothing else, returns false → not flagged.
      source = ~S"""
      defmodule M do
        def session_reusable?(%{pid: pid}) when is_pid(pid), do: Process.alive?(pid)
        def session_reusable?(_), do: false
      end
      """

      assert [] = analyze(source)
    end

    test "still skips a Process.info-only predicate" do
      source = ~S"""
      defmodule M do
        def named?(pid) do
          case Process.info(pid, :registered_name) do
            {:registered_name, name} when is_atom(name) -> true
            _ -> false
          end
        end
      end
      """

      assert [] = analyze(source)
    end
  end

  describe "check/2 — Mix.Tasks.* exemption" do
    test "skips predicates inside a Mix.Tasks.* module" do
      source = ~S"""
      defmodule Mix.Tasks.MyApp.Healthcheck do
        def alive?(server), do: Process.alive?(server)
        def ready?(server), do: GenServer.call(server, :ping) == :ok
      end
      """

      assert [] = analyze(source)
    end

    test "still flags predicates in normal modules" do
      source = ~S"""
      defmodule MyApp.Health do
        def ready?(server), do: GenServer.call(server, :ping) == :ok
      end
      """

      assert [_] = analyze(source)
    end
  end
end
