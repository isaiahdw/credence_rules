defmodule CredenceRules.CrossFile.ModuleInstabilityTest do
  use ExUnit.Case, async: true

  alias CredenceRules.CrossFile.ModuleInstability

  defp file(path, source), do: {path, Code.string_to_quoted!(source)}

  defp leaves(names) do
    for n <- names do
      file("#{String.downcase(n)}.ex", "defmodule #{n} do\n  def go(x \\\\ nil), do: x\nend\n")
    end
  end

  defp ops(names) do
    names
    |> Enum.map(fn n -> "  def #{String.downcase(n)}_op(x), do: #{n}.go(x)" end)
    |> Enum.join("\n")
  end

  defp filler(n) do
    Enum.map_join(1..n, "\n", fn i -> "    _x#{i} = #{i}" end)
  end

  describe "check/2 — flagged (≥ 2 smell signals)" do
    test "broad interface + large body (shallow god)" do
      names = ~w(A B C D E F)
      mod = file("god.ex", "defmodule God do\n#{ops(names)}\n  def extra do\n#{filler(40)}\n  end\nend\n")

      assert [issue] = ModuleInstability.check([mod | leaves(names)], min_loc: 20)
      assert issue.rule == :module_instability
      assert :broad_interface in issue.meta.signals
      assert :large_shallow in issue.meta.signals
    end

    test "broad interface + callback explosion (god GenServer)" do
      names = ~w(A B C D E F)

      callbacks =
        Enum.map_join(1..10, "\n", fn i -> "  def handle_call(:c#{i}, _, s), do: {:reply, :ok, s}" end)

      mod = file("srv.ex", "defmodule GodServer do\n  use GenServer\n#{ops(names)}\n#{callbacks}\nend\n")

      assert [issue] = ModuleInstability.check([mod | leaves(names)], [])
      assert :broad_interface in issue.meta.signals
      assert :callback_explosion in issue.meta.signals
    end

    test "dependency cycle + broad interface" do
      x =
        file(
          "x.ex",
          "defmodule X do\n  def a, do: A.go()\n  def b, do: B.go()\n  def c, do: C.go()\n  def d, do: D.go()\n  def y, do: Y.go()\nend\n"
        )

      y = file("y.ex", "defmodule Y do\n  def go, do: X.a()\nend\n")

      assert [issue] = ModuleInstability.check([x, y | leaves(~w(A B C D))], [])
      assert issue.meta.path == "x.ex"
      assert :cycle in issue.meta.signals
      assert :broad_interface in issue.meta.signals
    end

    test "raw metric when role_aware is disabled" do
      names = ~w(A B C D E F)
      files = [thin_coordinator() | leaves(names)]

      assert [] = ModuleInstability.check(files, [])
      assert [_] = ModuleInstability.check(files, role_aware: false)
    end
  end

  describe "check/2 — not flagged" do
    test "deep module: narrow interface over a large, multi-dependency body" do
      names = ~w(A B C D E F)

      deep =
        file(
          "deep.ex",
          "defmodule Proto do\n  def run do\n    A.go()\n    B.go()\n    C.go()\n    D.go()\n    E.go()\n    F.go()\n#{filler(40)}\n  end\nend\n"
        )

      assert [] = ModuleInstability.check([deep | leaves(names)], min_loc: 20)
    end

    test "focused gen_statem: narrow interface, few callbacks" do
      names = ~w(A B C D E F)

      sm =
        file(
          "sm.ex",
          "defmodule Proto do\n  @behaviour :gen_statem\n  def start_link(x), do: x\n  def handle_event(:a, _, _, _), do: A.go() && B.go() && C.go()\n  def handle_event(:b, _, _, _), do: D.go() && E.go() && F.go()\nend\n"
        )

      assert [] = ModuleInstability.check([sm | leaves(names)], [])
    end

    test "broad interface alone is one signal (not enough)" do
      names = ~w(A B C D E F)
      mod = file("plain.ex", "defmodule Plain do\n#{ops(names)}\nend\n")

      assert [] = ModuleInstability.check([mod | leaves(names)], [])
    end

    test "thin coordinator scores zero signals" do
      assert [] = ModuleInstability.check([thin_coordinator() | leaves(~w(A B C D E F))], [])
    end

    test "use Application / use Supervisor / Mix.Tasks.* are exempt" do
      names = ~w(A B C D E F)
      pad = Enum.map_join(1..40, "\n", fn i -> "  def f#{i}(x), do: x" end)
      app = file("app.ex", "defmodule MyApp.Application do\n  use Application\n#{ops(names)}\n#{pad}\nend\n")
      sup = file("sup.ex", "defmodule MyApp.Sup do\n  use Supervisor\n#{ops(names)}\n#{pad}\nend\n")
      task = file("task.ex", "defmodule Mix.Tasks.MyApp.Run do\n#{ops(names)}\n#{pad}\nend\n")

      for owner <- [app, sup, task] do
        assert [] = ModuleInstability.check([owner | leaves(names)], min_loc: 20)
      end
    end

    test "low fan-out" do
      files = [
        file("a.ex", "defmodule A do\n  def go, do: B.x()\nend\n"),
        file("b.ex", "defmodule B do\n  def x, do: :ok\nend\n")
      ]

      assert [] = ModuleInstability.check(files, [])
    end

    test "stable module (low instability)" do
      files = [
        file("core.ex", "defmodule Core do\n  def shared, do: :ok\nend\n")
        | for n <- ~w(A B C D E F) do
            file("#{String.downcase(n)}.ex", "defmodule #{n} do\n  def go, do: Core.shared()\nend\n")
          end
      ]

      assert [] = ModuleInstability.check(files, [])
    end

    test "honours :exclude_modules and :min_signals" do
      names = ~w(A B C D E F)
      mod = file("god.ex", "defmodule God do\n#{ops(names)}\n  def extra do\n#{filler(40)}\n  end\nend\n")
      files = [mod | leaves(names)]

      assert [_] = ModuleInstability.check(files, min_loc: 20)
      assert [] = ModuleInstability.check(files, min_loc: 20, exclude_modules: [God])
      # broad_interface + large_shallow = 2; require 3 → spared.
      assert [] = ModuleInstability.check(files, min_loc: 20, min_signals: 3)
    end
  end

  describe "check/2 — exclude_paths" do
    test "excluded files are dropped before scoring" do
      names = ~w(A B C D E F)

      callbacks =
        Enum.map_join(1..10, "\n", fn i ->
          "  def handle_call(:c#{i}, _, s), do: {:reply, :ok, s}"
        end)

      mod =
        file(
          "lib/generated/srv.ex",
          "defmodule GodServer do\n  use GenServer\n#{ops(names)}\n#{callbacks}\nend\n"
        )

      files = [mod | leaves(names)]

      assert [_] = ModuleInstability.check(files, [])
      assert [] = ModuleInstability.check(files, exclude_paths: ["lib/generated/"])
    end
  end

  defp thin_coordinator do
    file(
      "hub.ex",
      "defmodule Hub do\n  def run do\n    A.go()\n    B.go()\n    C.go()\n    D.go()\n    E.go()\n    F.go()\n  end\nend\n"
    )
  end
end
