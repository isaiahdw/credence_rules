defmodule CredenceRules.Pattern.GenserverHandleCallExplosionTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.GenserverHandleCallExplosion

  defp analyze(source, opts \\ []) do
    {:ok, ast} = Code.string_to_quoted(source)
    GenserverHandleCallExplosion.check(ast, [source: source] ++ opts)
  end

  defp analyze_sourceror(source) do
    {:ok, ast} = Sourceror.parse_string(source)
    GenserverHandleCallExplosion.check(ast, source: source)
  end

  defp genserver_with_handlers(count) do
    handlers =
      1..count
      |> Enum.map(fn n -> "def handle_call({:msg_#{n}, x}, _from, state), do: {:reply, x, state}" end)
      |> Enum.join("\n  ")

    "defmodule Bloat do\n  use GenServer\n  #{handlers}\nend"
  end

  describe "check/2 — flagged" do
    test "flags 8 handle_call clauses at default threshold" do
      assert [issue] = analyze(genserver_with_handlers(8))
      assert issue.rule == :genserver_handle_call_explosion
      assert issue.meta.handle_call_clauses == 8
    end

    test "flags 12 handle_call clauses with descriptive message" do
      assert [issue] = analyze(genserver_with_handlers(12))
      assert issue.message =~ "12"
    end

    test "honours custom :max_handle_call threshold" do
      assert [_] = analyze(genserver_with_handlers(4), max_handle_call: 4)
    end
  end

  describe "check/2 — not flagged" do
    test "ignores GenServer with fewer handlers" do
      assert [] = analyze(genserver_with_handlers(5))
      assert [] = analyze(genserver_with_handlers(7))
    end

    test "ignores non-GenServer modules" do
      source = ~S"""
      defmodule M do
        def handle_call(1, _, s), do: s
        def handle_call(2, _, s), do: s
        def handle_call(3, _, s), do: s
        def handle_call(4, _, s), do: s
        def handle_call(5, _, s), do: s
        def handle_call(6, _, s), do: s
        def handle_call(7, _, s), do: s
        def handle_call(8, _, s), do: s
        def handle_call(9, _, s), do: s
      end
      """

      assert [] = analyze(source)
    end

    test "ignores handle_cast / handle_info even in a GenServer" do
      source = ~S"""
      defmodule M do
        use GenServer

        def handle_cast(1, s), do: {:noreply, s}
        def handle_cast(2, s), do: {:noreply, s}
        def handle_cast(3, s), do: {:noreply, s}
        def handle_info(:tick, s), do: {:noreply, s}
        def handle_info(:tock, s), do: {:noreply, s}
        def handle_info(:tack, s), do: {:noreply, s}
        def handle_call(:get, _, s), do: {:reply, s, s}
      end
      """

      assert [] = analyze(source)
    end
  end

  describe "check/2 — per-instance GenServer exemption" do
    defp per_instance_genserver(count, start_link_body) do
      handlers =
        1..count
        |> Enum.map(fn n -> "def handle_call({:msg_#{n}, x}, _from, state), do: {:reply, x, state}" end)
        |> Enum.join("\n  ")

      "defmodule PerInstance do\n  use GenServer\n\n  #{start_link_body}\n\n  #{handlers}\nend"
    end

    test "skips per-instance GenServer below per-instance threshold (10 < 16)" do
      source =
        per_instance_genserver(
          10,
          """
          def start_link(opts) do
            id = Keyword.fetch!(opts, :id)
            GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {MyApp.Registry, id}})
          end
          """
        )

      # Singleton threshold is 8, so 10 would normally fire.
      # Per-instance threshold is 16, so 10 doesn't.
      assert [] = analyze(source)
    end

    test "flags per-instance GenServer above the per-instance threshold (16)" do
      source =
        per_instance_genserver(
          16,
          """
          def start_link(opts) do
            GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {Reg, opts[:id]}})
          end
          """
        )

      assert [issue] = analyze(source)
      assert issue.meta.handle_call_clauses == 16
    end

    test "still flags singleton (no via-tuple) at the singleton threshold" do
      source = genserver_with_handlers(9)
      assert [_] = analyze(source)
    end

    test "recognises via-tuple in a helper function (not just in start_link)" do
      source = """
      defmodule PerInstance do
        use GenServer

        def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: via_tuple(opts[:id]))

        defp via_tuple(id), do: {:via, Registry, {MyApp.Registry, id}}

        #{1..10 |> Enum.map(fn n -> "def handle_call(:msg_#{n}, _, s), do: {:reply, s, s}" end) |> Enum.join("\n  ")}
      end
      """

      assert [] = analyze(source)
    end

    test "honours custom :max_handle_call_per_instance" do
      source =
        per_instance_genserver(
          8,
          "def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {Reg, opts[:id]}})"
        )

      # With max_handle_call_per_instance=5, 8 clauses should fire.
      assert [_] = analyze(source, max_handle_call_per_instance: 5)
    end
  end

  describe "check/2 — read-bypass GenServer exemption" do
    # Helper: build a singleton GenServer that owns an ETS table,
    # exposes read APIs that hit :ets directly, and has `count`
    # write-side handle_call clauses for the writes.
    defp read_bypass_genserver(count, read_fns) do
      writes =
        1..count
        |> Enum.map(fn n -> "def handle_call({:put_#{n}, k, v}, _, state), do: {:reply, :ok, state}" end)
        |> Enum.join("\n  ")

      """
      defmodule Cache do
        use GenServer

        def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

        def init(_) do
          :ets.new(:cache, [:named_table, :public, read_concurrency: true])
          {:ok, %{}}
        end

        #{read_fns}

        #{writes}
      end
      """
    end

    test "skips ETS-owning GenServer whose reads bypass via :ets" do
      reads = """
      def get_user(id), do: :ets.lookup(:cache, id)
      def list_all, do: :ets.tab2list(:cache)
      """

      # 10 write-side handlers > singleton threshold (8) but ≤
      # read-bypass threshold (16) → no finding.
      source = read_bypass_genserver(10, reads)
      assert [] = analyze(source)
    end

    test "flags read-bypass GenServer above the read-bypass threshold (16)" do
      reads = """
      def get_user(id), do: :ets.lookup(:cache, id)
      """

      source = read_bypass_genserver(16, reads)
      assert [issue] = analyze(source)
      assert issue.meta.handle_call_clauses == 16
    end

    test "does NOT apply bypass when a read function still routes through GenServer.call" do
      reads = """
      def get_user(id), do: :ets.lookup(:cache, id)
      def list_admins, do: GenServer.call(__MODULE__, :list_admins)
      """

      # `list_admins/0` routes through the GenServer — reads aren't
      # fully bypassed. Singleton threshold applies, 10 ≥ 8 → fires.
      source = read_bypass_genserver(10, reads)
      assert [_] = analyze(source)
    end

    test "does NOT apply bypass when there's no ETS table" do
      reads = """
      def get_user(id), do: Map.get(state(), id)
      defp state, do: %{}
      """

      # No :ets.new in the body. Even if read fns skip GenServer.call,
      # they're not bypassing to a concurrent table — could be reading
      # an in-process struct in the calling process, which doesn't help
      # the bottleneck premise. Threshold stays at singleton.
      source = read_bypass_genserver(10, reads)
      assert [_] = analyze(source)
    end

    test "does NOT apply bypass when no read functions exist" do
      # Module owns ETS, has 10 write handlers, but exposes no
      # public read API. Can't claim "reads bypass" if there are no
      # reads to look at — singleton threshold applies.
      source = """
      defmodule Cache do
        use GenServer

        def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
        def init(_) do
          :ets.new(:cache, [:named_table])
          {:ok, %{}}
        end

        #{1..10 |> Enum.map(fn n -> "def handle_call({:put_#{n}, k, v}, _, s), do: {:reply, :ok, s}" end) |> Enum.join("\n  ")}
      end
      """

      assert [_] = analyze(source)
    end

    test "recognises exists?/member? as read functions" do
      reads = """
      def exists?(id), do: :ets.member(:cache, id)
      def member?(id), do: :ets.member(:cache, id)
      """

      source = read_bypass_genserver(10, reads)
      assert [] = analyze(source)
    end

    test "honours custom :max_handle_call_read_bypass" do
      reads = """
      def get_user(id), do: :ets.lookup(:cache, id)
      """

      source = read_bypass_genserver(10, reads)

      # Default (16): skipped. Lower to 5: 10 clauses ≥ 5 → fires.
      assert [] = analyze(source)
      assert [_] = analyze(source, max_handle_call_read_bypass: 5)
    end

    test "combines with per-instance: per-instance + read-bypass uses higher threshold" do
      # Both exemptions apply: via-tuple registration AND ETS reads.
      # Threshold = max(8, 16, 16) = 16. 14 < 16 → no finding.
      source = """
      defmodule SessionCache do
        use GenServer

        def start_link(opts) do
          GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {Reg, opts[:id]}})
        end

        def init(_) do
          :ets.new(:cache, [:named_table])
          {:ok, %{}}
        end

        def get_user(id), do: :ets.lookup(:cache, id)

        #{1..14 |> Enum.map(fn n -> "def handle_call({:put_#{n}, k, v}, _, s), do: {:reply, :ok, s}" end) |> Enum.join("\n  ")}
      end
      """

      assert [] = analyze(source)
    end
  end

  describe "check/2 — Sourceror-parsed (production path)" do
    test "still flags under Sourceror parse" do
      assert [_] = analyze_sourceror(genserver_with_handlers(9))
    end

    test "read-bypass exemption works under Sourceror parse" do
      source = """
      defmodule Cache do
        use GenServer

        def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

        def init(_) do
          :ets.new(:cache, [:named_table])
          {:ok, %{}}
        end

        def get_user(id), do: :ets.lookup(:cache, id)

        #{1..10 |> Enum.map(fn n -> "def handle_call({:put_#{n}, k, v}, _, s), do: {:reply, :ok, s}" end) |> Enum.join("\n  ")}
      end
      """

      assert [] = analyze_sourceror(source)
    end

    test "per-instance exemption works under Sourceror parse" do
      source = """
      defmodule PerInstance do
        use GenServer

        def start_link(opts) do
          GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {MyApp.Registry, opts[:id]}})
        end

        #{1..10 |> Enum.map(fn n -> "def handle_call(:msg_#{n}, _, s), do: {:reply, s, s}" end) |> Enum.join("\n  ")}
      end
      """

      assert [] = analyze_sourceror(source)
    end
  end
end
