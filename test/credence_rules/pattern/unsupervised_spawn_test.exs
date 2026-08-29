defmodule CredenceRules.Pattern.UnsupervisedSpawnTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.UnsupervisedSpawn

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    UnsupervisedSpawn.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags spawn/1" do
      source = ~S"""
      spawn(fn -> work() end)
      """

      assert [issue] = analyze(source)
      assert issue.rule == :unsupervised_spawn
      assert issue.message =~ "spawn/1"
    end

    test "flags spawn_link/1" do
      source = ~S"""
      spawn_link(fn -> work() end)
      """

      assert [issue] = analyze(source)
      assert issue.message =~ "spawn_link/1"
    end

    test "flags spawn_monitor/1" do
      source = ~S"""
      spawn_monitor(fn -> work() end)
      """

      assert [_] = analyze(source)
    end

    test "flags multiple raw spawns in one block" do
      source = ~S"""
      def f do
        spawn(&work/0)
        spawn_link(&work/0)
        spawn_monitor(&work/0)
      end
      """

      assert length(analyze(source)) == 3
    end

    test "flags Task.start/1 (fire-and-forget, no link)" do
      source = ~S"""
      Task.start(fn -> work() end)
      """

      assert [issue] = analyze(source)
      assert issue.message =~ "Task.start/1"
    end

    test "flags Task.start_link/1 (linked but no supervisor strategy)" do
      source = ~S"""
      Task.start_link(fn -> work() end)
      """

      assert [issue] = analyze(source)
      assert issue.message =~ "Task.start_link/1"
    end
  end

  describe "check/2 — not flagged (Task.async is supervised by caller)" do
    test "does NOT flag Task.async" do
      source = ~S"""
      Task.async(fn -> work() end) |> Task.await(:infinity)
      """

      assert analyze(source) == []
    end

    test "does NOT flag Task.async_stream" do
      source = ~S"""
      Task.async_stream(items, &work/1) |> Stream.run()
      """

      assert analyze(source) == []
    end

    test "does NOT flag Task.Supervisor.* forms" do
      source = ~S"""
      Task.Supervisor.start_child(MySup, fn -> work() end)
      Task.Supervisor.async_nolink(MySup, fn -> work() end)
      """

      assert analyze(source) == []
    end

    test "does NOT flag arbitrary user functions named spawn" do
      source = ~S"""
      MyAdapter.spawn(fn -> work() end)
      """

      assert analyze(source) == []
    end

    test "does NOT flag {Task, fn} in a children list (supervised pattern)" do
      # `{Task, fn}` is the supervised form — the supervisor resolves it
      # to a supervised `start_link`. There's no literal `Task.start_link`
      # call in user code, so the rule shouldn't fire.
      source = ~S"""
      children = [
        {Task, fn -> work() end}
      ]
      """

      assert analyze(source) == []
    end

    test "does NOT flag spawn/spawn_link in a `use ExUnit.Case` module" do
      # Tests routinely spawn raw helper processes for race-condition
      # setup. The supervision concern doesn't apply — tests own their
      # process lifetimes.
      source = ~S"""
      defmodule MyApp.WorkerTest do
        use ExUnit.Case

        test "races" do
          pid = spawn(fn -> :timer.sleep(100) end)
          spawn_link(fn -> handle(pid) end)
          assert Process.alive?(pid)
        end
      end
      """

      assert analyze(source) == []
    end

    test "DOES still flag bare spawn outside an ExUnit module" do
      # Same `spawn` call, but in a regular module — flagged.
      source = ~S"""
      defmodule MyApp.Worker do
        def f do
          spawn(fn -> work() end)
        end
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — definition heads are not calls" do
    test "does NOT flag a function DEFINITION named spawn" do
      # A definition head is structurally identical to a call in the
      # AST. `spawn` is the natural name for a "start an external
      # process" behaviour callback, and there'd be no way to suppress
      # it at the definition short of suppressing the whole file.
      source = ~S"""
      defmodule MyApp.Host do
        @impl Host
        def spawn(state, exe, args), do: ask(state, {:spawn, exe, args})
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag a guarded definition named spawn" do
      source = ~S"""
      defmodule MyApp.Host do
        def spawn(state, exe, args) when is_list(args), do: ask(state, exe)
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag defp / defdelegate named spawn" do
      source = ~S"""
      defmodule MyApp.Host do
        defp spawn(a), do: a
        defdelegate spawn(a, b), to: MyApp.Backend
      end
      """

      assert analyze(source) == []
    end

    test "DOES flag a real spawn call inside a def named spawn" do
      # Skipping the head must not skip the body.
      source = ~S"""
      defmodule MyApp.Host do
        def spawn(exe), do: spawn(fn -> run(exe) end)
      end
      """

      assert [issue] = analyze(source)
      assert issue.message =~ "spawn/1"
    end
  end

  describe "check/2 — spawn_monitor with observed death" do
    test "does NOT flag spawn_monitor when a receive handles {:DOWN, …}" do
      # Same "death is observed" property that exempts Task.async.
      source = ~S"""
      defmodule MyApp.Worker do
        def run do
          {pid, ref} = spawn_monitor(fn -> work() end)

          receive do
            {:DOWN, ^ref, :process, ^pid, reason} -> {:error, reason}
          end
        end
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag spawn_monitor when handle_info/2 handles {:DOWN, …}" do
      source = ~S"""
      defmodule MyApp.Server do
        def kick(state), do: {:noreply, spawn_monitor(fn -> work() end)}

        def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
          {:noreply, state}
        end
      end
      """

      assert analyze(source) == []
    end

    test "DOES flag spawn_monitor when the module never handles {:DOWN, …}" do
      source = ~S"""
      defmodule MyApp.Worker do
        def run, do: spawn_monitor(fn -> work() end)
      end
      """

      assert [issue] = analyze(source)
      assert issue.message =~ "spawn_monitor/1"
    end

    test "DOES flag bare spawn even when the module handles {:DOWN, …}" do
      # A monitor is what {:DOWN, …} observes; bare spawn has none.
      source = ~S"""
      defmodule MyApp.Worker do
        def run, do: spawn(fn -> work() end)

        def handle_info({:DOWN, _r, :process, _p, _reason}, s), do: {:noreply, s}
      end
      """

      assert [issue] = analyze(source)
      assert issue.message =~ "spawn/1"
    end

    test "scopes the {:DOWN, …} exemption to the enclosing module" do
      # A sibling module handling :DOWN must not clear this one.
      source = ~S"""
      defmodule MyApp.Watcher do
        def handle_info({:DOWN, _r, :process, _p, _reason}, s), do: {:noreply, s}
      end

      defmodule MyApp.Worker do
        def run, do: spawn_monitor(fn -> work() end)
      end
      """

      assert [issue] = analyze(source)
      assert issue.message =~ "spawn_monitor/1"
    end
  end

  describe "check/2 — start_link/N is the supervisor contract" do
    test "does NOT flag Task.start_link inside start_link/1" do
      # `{MyModule, opts}` in a children list resolves to exactly this.
      source = ~S"""
      defmodule MyApp.Runner do
        def start_link(opts), do: Task.start_link(__MODULE__, :run, [opts])
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag spawn_link inside start_link/1" do
      source = ~S"""
      defmodule MyApp.Runner do
        def start_link(args), do: {:ok, spawn_link(fn -> run(args) end)}
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag spawn_link inside a guarded start_link/1" do
      source = ~S"""
      defmodule MyApp.Runner do
        def start_link(args) when is_list(args) do
          {:ok, spawn_link(fn -> run(args) end)}
        end
      end
      """

      assert analyze(source) == []
    end

    test "DOES flag bare spawn inside start_link/1" do
      # The link is what makes the process supervisor-owned; without
      # one the supervisor never learns it died.
      source = ~S"""
      defmodule MyApp.Runner do
        def start_link(args), do: {:ok, spawn(fn -> run(args) end)}
      end
      """

      assert [issue] = analyze(source)
      assert issue.message =~ "spawn/1"
    end

    test "DOES flag Task.start inside start_link/1" do
      # Task.start is fire-and-forget with no link at all.
      source = ~S"""
      defmodule MyApp.Runner do
        def start_link(opts), do: Task.start(fn -> run(opts) end)
      end
      """

      assert [issue] = analyze(source)
      assert issue.message =~ "Task.start/1"
    end

    test "DOES still flag Task.start_link in a differently-named function" do
      source = ~S"""
      defmodule MyApp.Runner do
        def go(opts), do: Task.start_link(fn -> run(opts) end)
      end
      """

      assert [issue] = analyze(source)
      assert issue.message =~ "Task.start_link/1"
    end
  end
end
