defmodule CredenceRules.CrossFile.ModuleGraphTest do
  use ExUnit.Case, async: true

  alias CredenceRules.CrossFile.ModuleGraph

  defp file(path, source) do
    {path, Code.string_to_quoted!(source)}
  end

  describe "build/1" do
    test "builds a forward + reverse edge map" do
      files = [
        file("a.ex", ~S"""
        defmodule MyApp.A do
          def go, do: MyApp.B.do_b()
        end
        """),
        file("b.ex", ~S"""
        defmodule MyApp.B do
          def do_b, do: MyApp.C.do_c()
        end
        """),
        file("c.ex", ~S"""
        defmodule MyApp.C do
          def do_c, do: :ok
        end
        """)
      ]

      graph = ModuleGraph.build(files)

      assert ModuleGraph.fan_out(graph, "MyApp.A") == ["MyApp.B"]
      assert ModuleGraph.fan_out(graph, "MyApp.B") == ["MyApp.C"]
      assert ModuleGraph.fan_out(graph, "MyApp.C") == []
      assert ModuleGraph.fan_in(graph, "MyApp.B") == ["MyApp.A"]
      assert ModuleGraph.fan_in(graph, "MyApp.C") == ["MyApp.B"]
    end

    test "filters out non-project modules (Enum, Repo, etc.)" do
      files = [
        file("a.ex", ~S"""
        defmodule MyApp.A do
          def go(list), do: Enum.map(list, &MyApp.B.do_b/1)
        end
        """),
        file("b.ex", "defmodule MyApp.B do\n  def do_b(_), do: :ok\nend\n")
      ]

      graph = ModuleGraph.build(files)
      assert ModuleGraph.fan_out(graph, "MyApp.A") == ["MyApp.B"]
    end

    test "filters out self-references" do
      files = [
        file("a.ex", ~S"""
        defmodule MyApp.A do
          def go, do: MyApp.A.helper()
          def helper, do: :ok
        end
        """)
      ]

      graph = ModuleGraph.build(files)
      assert ModuleGraph.fan_out(graph, "MyApp.A") == []
    end

    test "skips files with no defmodule" do
      files = [
        file("script.ex", "IO.puts(\"hello\")")
      ]

      graph = ModuleGraph.build(files)
      assert graph.modules == MapSet.new()
    end
  end

  describe "strongly_connected_components/1" do
    test "detects a 2-module cycle" do
      files = [
        file("a.ex", "defmodule A do\n  def x, do: B.y()\nend\n"),
        file("b.ex", "defmodule B do\n  def y, do: A.x()\nend\n")
      ]

      graph = ModuleGraph.build(files)
      sccs = ModuleGraph.strongly_connected_components(graph)

      multi_sccs = Enum.filter(sccs, &(length(&1) >= 2))
      assert length(multi_sccs) == 1
      assert Enum.sort(hd(multi_sccs)) == ["A", "B"]
    end

    test "detects a 3-module cycle" do
      files = [
        file("a.ex", "defmodule A do\n  def x, do: B.y()\nend\n"),
        file("b.ex", "defmodule B do\n  def y, do: C.z()\nend\n"),
        file("c.ex", "defmodule C do\n  def z, do: A.x()\nend\n")
      ]

      graph = ModuleGraph.build(files)

      multi_sccs =
        graph
        |> ModuleGraph.strongly_connected_components()
        |> Enum.filter(&(length(&1) >= 2))

      assert length(multi_sccs) == 1
      assert Enum.sort(hd(multi_sccs)) == ["A", "B", "C"]
    end

    test "doesn't detect a cycle in a DAG" do
      files = [
        file("a.ex", "defmodule A do\n  def x, do: B.y()\nend\n"),
        file("b.ex", "defmodule B do\n  def y, do: :ok\nend\n")
      ]

      graph = ModuleGraph.build(files)

      assert [] =
               graph
               |> ModuleGraph.strongly_connected_components()
               |> Enum.filter(&(length(&1) >= 2))
    end
  end

  describe "grouped-alias expansion" do
    test "alias Parent.{A, B} expands to children, not the prefix" do
      # The bug: `alias My.Parent.{A, B}` parses as the call
      # `My.Parent.{}(A, B)`. Naively walking emits THREE refs —
      # the prefix My.Parent plus unqualified A and B. When
      # My.Parent is a real project module (a facade), the
      # phantom prefix edge fabricates a circular dependency.
      files = [
        file("parent.ex", "defmodule My.Parent do\nend\n"),
        file("child.ex", "defmodule My.Child do\n  alias My.Parent.{A, B}\nend\n"),
        file("a.ex", "defmodule My.Parent.A do\nend\n"),
        file("b.ex", "defmodule My.Parent.B do\nend\n")
      ]

      graph = ModuleGraph.build(files)
      fan_out = ModuleGraph.fan_out(graph, "My.Child")

      refute "My.Parent" in fan_out,
             "grouped-alias prefix leaked as a phantom edge: #{inspect(fan_out)}"

      assert "My.Parent.A" in fan_out
      assert "My.Parent.B" in fan_out
    end

    test "non-grouped alias still emits the full module" do
      files = [
        file("child.ex", "defmodule My.Child do\n  alias My.Parent.A\nend\n"),
        file("a.ex", "defmodule My.Parent.A do\nend\n")
      ]

      graph = ModuleGraph.build(files)
      assert ModuleGraph.fan_out(graph, "My.Child") == ["My.Parent.A"]
    end

    test "grouped require / import / use forms also expand correctly" do
      # `require Foo.{A, B}`, `import Foo.{A, B}`, `use Foo.{A, B}`
      # all share the same AST shape — the directive doesn't
      # appear inside `:{}`. Catching one catches all.
      files = [
        file("foo.ex", "defmodule My.Foo do\nend\n"),
        file("c.ex", "defmodule My.C do\n  require My.Foo.{A, B}\nend\n"),
        file("a.ex", "defmodule My.Foo.A do\nend\n"),
        file("b.ex", "defmodule My.Foo.B do\nend\n")
      ]

      graph = ModuleGraph.build(files)
      fan_out = ModuleGraph.fan_out(graph, "My.C")

      refute "My.Foo" in fan_out
      assert "My.Foo.A" in fan_out
      assert "My.Foo.B" in fan_out
    end

    test "facade + grouped-alias children no longer fabricates an SCC" do
      # Real-world shape: Discovery facade
      # delegates to Manager / Publisher; children use grouped
      # alias to reference siblings. Previously this fabricated
      # a {Discovery, Manager, Publisher} SCC.
      files = [
        file("discovery.ex", ~S"""
        defmodule Discovery do
          defdelegate go, to: Discovery.Manager
          defdelegate stop, to: Discovery.Publisher
        end
        """),
        file("manager.ex", ~S"""
        defmodule Discovery.Manager do
          alias Discovery.{Publisher, Socket}
          def go, do: Publisher.publish(Socket.new())
        end
        """),
        file("publisher.ex", ~S"""
        defmodule Discovery.Publisher do
          alias Discovery.{Manager, Socket}
          def publish(sock), do: Manager.notify(sock)
        end
        """),
        file("socket.ex", "defmodule Discovery.Socket do\n  def new, do: :sock\nend\n")
      ]

      graph = ModuleGraph.build(files)

      sccs =
        graph
        |> ModuleGraph.strongly_connected_components()
        |> Enum.filter(&(length(&1) >= 2))

      # Manager <-> Publisher IS a real cycle (each aliases +
      # calls the other). Discovery (facade) is NOT in the cycle —
      # children only reference siblings, not the parent prefix.
      assert length(sccs) == 1
      [scc] = sccs
      assert Enum.sort(scc) == ["Discovery.Manager", "Discovery.Publisher"]
      refute "Discovery" in scc, "facade should not be in the SCC"
    end

    test "real cycles still detected after the fix" do
      # Regression guard: the prune-prefix fix shouldn't break
      # detection of actual A <-> B cycles.
      files = [
        file("a.ex", "defmodule A do\n  alias B\n  def x, do: B.y()\nend\n"),
        file("b.ex", "defmodule B do\n  alias A\n  def y, do: A.x()\nend\n")
      ]

      graph = ModuleGraph.build(files)

      sccs =
        graph
        |> ModuleGraph.strongly_connected_components()
        |> Enum.filter(&(length(&1) >= 2))

      assert [scc] = sccs
      assert Enum.sort(scc) == ["A", "B"]
    end
  end
end
