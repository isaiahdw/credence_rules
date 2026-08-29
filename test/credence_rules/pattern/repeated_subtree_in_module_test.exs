defmodule CredenceRules.Pattern.RepeatedSubtreeInModuleTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.RepeatedSubtreeInModule

  defp analyze(source, opts \\ []) do
    {:ok, ast} = Code.string_to_quoted(source)
    RepeatedSubtreeInModule.check(ast, [source: source] ++ opts)
  end

  defp analyze_sourceror(source, opts \\ []) do
    {:ok, ast} = Sourceror.parse_string(source)
    RepeatedSubtreeInModule.check(ast, [source: source] ++ opts)
  end

  describe "check/2 — flagged" do
    test "flags duplicated pipeline across two functions" do
      # Threshold is 16 nodes; atoms are preserved in canonical form,
      # so a divergent atom (`:owner` vs `:admin`) between the two
      # pipelines would prevent the match. Same-shape pipelines that
      # differ only in their input vars.
      source = ~S"""
      defmodule Users do
        def actives(users) do
          users
          |> Enum.filter(& &1.active)
          |> Enum.map(& &1.name)
          |> Enum.uniq()
          |> Enum.sort()
        end

        def pending(users) do
          users
          |> Enum.filter(& &1.active)
          |> Enum.map(& &1.name)
          |> Enum.uniq()
          |> Enum.sort()
        end
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :repeated_subtree_in_module
      assert issue.meta.functions == 2
    end

    test "reports function count when duplicate spans three functions" do
      source = ~S"""
      defmodule M do
        def a(x) do
          x
          |> Enum.filter(&match?({:ok, _}, &1))
          |> Enum.map(&elem(&1, 1))
        end

        def b(x) do
          x
          |> Enum.filter(&match?({:ok, _}, &1))
          |> Enum.map(&elem(&1, 1))
        end

        def c(x) do
          x
          |> Enum.filter(&match?({:ok, _}, &1))
          |> Enum.map(&elem(&1, 1))
        end
      end
      """

      assert [issue] = analyze(source)
      assert issue.meta.functions == 3
    end
  end

  describe "check/2 — not flagged" do
    test "ignores duplicates within one function (other rule's domain)" do
      source = ~S"""
      defmodule M do
        def go(a, b) do
          x = a
              |> Enum.filter(&active?/1)
              |> Enum.map(& &1.name)
              |> Enum.sort()

          y = b
              |> Enum.filter(&active?/1)
              |> Enum.map(& &1.name)
              |> Enum.sort()

          {x, y}
        end
      end
      """

      assert [] = analyze(source)
    end

    test "ignores when functions have completely different bodies" do
      source = ~S"""
      defmodule M do
        def go(x), do: Enum.map(x, &to_string/1)
        def stop(_), do: :ok
      end
      """

      assert [] = analyze(source)
    end

    test "ignores duplicates below size threshold" do
      source = ~S"""
      defmodule M do
        def a(x), do: foo(x)
        def b(x), do: foo(x)
      end
      """

      assert [] = analyze(source)
    end

    # The variant calls differ by their tag atom (`:rcac` / `:icac`),
    # so the whole-call subtrees don't cluster — only the structurally
    # identical keyword lists do. Each list assembles the same shape
    # from variant-specific values; the call site is the boundary, not
    # a missing helper. The keyword list is pure data, so it's dropped.
    @builder_calls ~S"""
    defmodule Generator do
      def rcac(serial, dn, now, after_ts, pubkey, exts) do
        build_and_sign(:rcac, [
          serial: serial,
          issuer: dn,
          subject: dn,
          not_before: now,
          not_after: after_ts,
          public_key: pubkey,
          extensions: exts
        ])
      end

      def icac(serial, dn, now, after_ts, pubkey, exts) do
        build_and_sign(:icac, [
          serial: serial,
          issuer: dn,
          subject: dn,
          not_before: now,
          not_after: after_ts,
          public_key: pubkey,
          extensions: exts
        ])
      end
    end
    """

    test "ignores identical keyword-list arg shapes to a builder call" do
      assert [] = analyze_sourceror(@builder_calls)
    end

    test "flag_pure_data_duplicates: true reports the keyword-list shape" do
      assert [_] = analyze_sourceror(@builder_calls, flag_pure_data_duplicates: true)
    end

    # Two socket-failure branches share the log shape but have opposite
    # policies (`{:stop, reason}` aborts startup; `{:noreply,
    # :ipv6_only}` degrades gracefully). The shared part is a log line,
    # not a missing helper.
    @logging_branches ~S"""
    defmodule Transport.Udp do
      def open(opts) do
        case :gen_udp.open(0, opts) do
          {:ok, socket} ->
            {:ok, socket}

          {:error, reason} ->
            Logger.error("[Transport.Udp] socket open failed: #{inspect(reason)} opts=#{inspect(opts)}")
            {:stop, reason}
        end
      end

      def open_v4_fallback(opts) do
        case :gen_udp.open(0, opts) do
          {:ok, socket} ->
            {:ok, socket}

          {:error, reason} ->
            Logger.error("[Transport.Udp] socket open failed: #{inspect(reason)} opts=#{inspect(opts)}")
            {:noreply, :ipv6_only}
        end
      end
    end
    """

    test "ignores a Logger error-log shape shared across failure branches" do
      assert [] = analyze(@logging_branches)
    end

    test "flag_logging_idioms: true reports the log shape" do
      assert [_] = analyze(@logging_branches, flag_logging_idioms: true)
    end

    test "still flags the log shape when it also calls a project module" do
      # The shared subtree now includes a non-formatting project call
      # (`Audit.record/1`), so it's a real operation-plus-log, not a
      # pure logging idiom.
      source = ~S"""
      defmodule Transport.Udp do
        def open(opts) do
          reason = compute(opts)
          Audit.record(reason)
          Logger.error("[Transport.Udp] socket open failed: #{inspect(reason)} opts=#{inspect(opts)}")
        end

        def open_v4_fallback(opts) do
          reason = compute(opts)
          Audit.record(reason)
          Logger.error("[Transport.Udp] socket open failed: #{inspect(reason)} opts=#{inspect(opts)}")
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "ignores a repeated Mix.shell() CLI-output shape" do
      source = ~S"""
      defmodule Mix.Tasks.Sync do
        def report_a(result) do
          Mix.shell().info("synced #{inspect(result.count)} records to #{inspect(result.target)}")
        end

        def report_b(result) do
          Mix.shell().info("synced #{inspect(result.count)} records to #{inspect(result.target)}")
        end
      end
      """

      assert [] = analyze(source)
    end
  end

  describe "check/2 — Sourceror-parsed (production path)" do
    test "still flags cross-function duplicates under Sourceror parse" do
      source = ~S"""
      defmodule Users do
        def actives(users) do
          users
          |> Enum.filter(& &1.active)
          |> Enum.map(& &1.name)
          |> Enum.uniq()
          |> Enum.sort()
        end

        def pending(users) do
          users
          |> Enum.filter(& &1.active)
          |> Enum.map(& &1.name)
          |> Enum.uniq()
          |> Enum.sort()
        end
      end
      """

      assert [_] = analyze_sourceror(source)
    end
  end
end
