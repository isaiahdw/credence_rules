defmodule CredenceRules.CrossFile.CircularDependencyTest do
  use ExUnit.Case, async: true

  alias CredenceRules.CrossFile.CircularDependency

  defp file(path, source), do: {path, Code.string_to_quoted!(source)}

  describe "check/2 — flagged" do
    test "flags a 2-module cycle" do
      files = [
        file("a.ex", ~S"""
        defmodule MyApp.Accounts do
          def list_admins, do: Enum.filter([], &MyApp.Users.admin?/1)
        end
        """),
        file("b.ex", ~S"""
        defmodule MyApp.Users do
          def admin?(_), do: MyApp.Accounts.admin_role()
        end
        """)
      ]

      assert [issue] = CircularDependency.check(files, [])
      assert issue.rule == :circular_module_dependency
      assert Enum.sort(issue.meta.cycle) == ["MyApp.Accounts", "MyApp.Users"]
    end

    test "flags a 3-module cycle" do
      files = [
        file("a.ex", "defmodule A do\n  def x, do: B.y()\nend\n"),
        file("b.ex", "defmodule B do\n  def y, do: C.z()\nend\n"),
        file("c.ex", "defmodule C do\n  def z, do: A.x()\nend\n")
      ]

      assert [issue] = CircularDependency.check(files, [])
      assert Enum.sort(issue.meta.cycle) == ["A", "B", "C"]
    end

    test "attaches the finding to the lexicographically-smallest module's file" do
      files = [
        file("zzz.ex", "defmodule ZebraMod do\n  def x, do: AardvarkMod.y()\nend\n"),
        file("aaa.ex", "defmodule AardvarkMod do\n  def y, do: ZebraMod.x()\nend\n")
      ]

      assert [issue] = CircularDependency.check(files, [])
      assert issue.meta.path == "aaa.ex"
    end
  end

  describe "check/2 — not flagged" do
    test "ignores a DAG" do
      files = [
        file("a.ex", "defmodule A do\n  def x, do: B.y()\nend\n"),
        file("b.ex", "defmodule B do\n  def y, do: :ok\nend\n")
      ]

      assert [] = CircularDependency.check(files, [])
    end

    test "ignores self-references" do
      files = [
        file("a.ex", "defmodule A do\n  def x, do: A.y()\n  def y, do: :ok\nend\n")
      ]

      assert [] = CircularDependency.check(files, [])
    end

    test "ignores cycles through stdlib (Enum / Repo etc.)" do
      # `Enum` isn't a project-local module so it can't participate
      # in a project cycle.
      files = [
        file("a.ex", "defmodule A do\n  def x, do: Enum.map([], & &1)\nend\n")
      ]

      assert [] = CircularDependency.check(files, [])
    end

    test "facade + grouped-alias children doesn't fabricate a cycle" do
      # Real-world shape that triggered a false-positive SCC:
      # Discovery facade delegates to + supervises its children;
      # children use `alias Discovery.{...}` for sibling access.
      # Previously this fabricated a {Discovery, child, child, ...}
      # SCC because the grouped-alias prefix `Discovery` was
      # emitted as a phantom edge from each child back to the
      # facade.
      files = [
        file("discovery.ex", ~S"""
        defmodule Discovery do
          defdelegate go, to: Discovery.Manager
          defdelegate stop, to: Discovery.Publisher

          def child_spec(_) do
            %{id: __MODULE__, start: {Discovery.Socket, :start_link, []}}
          end
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
          alias Discovery.{Socket}
          def publish(_sock), do: :ok
        end
        """),
        file("socket.ex", "defmodule Discovery.Socket do\n  def new, do: :sock\nend\n")
      ]

      assert [] = CircularDependency.check(files, [])
    end
  end

  describe "check/2 — message rendering" do
    test "names every module in a small cycle" do
      files = [
        file("a.ex", "defmodule A do\n  def x, do: B.y()\nend\n"),
        file("b.ex", "defmodule B do\n  def y, do: A.x()\nend\n")
      ]

      assert [issue] = CircularDependency.check(files, [])
      assert issue.message =~ "A ↔ B"
      refute issue.message =~ "more)"
    end

    test "truncates a large cycle, leading with the module count" do
      # Ring of 10: M0 → M1 → … → M9 → M0. Unbounded, this rendered
      # every member on one line; a real 142-module cycle came to ~7 KB.
      files =
        for i <- 0..9 do
          file("m#{i}.ex", "defmodule M#{i} do\n  def x, do: M#{rem(i + 1, 10)}.x()\nend\n")
        end

      assert [issue] = CircularDependency.check(files, [])
      assert issue.message =~ "10 modules — "
      assert issue.message =~ "(+4 more)"
      assert String.length(issue.message) < 600
    end

    test "keeps the complete cycle in meta for machine consumers" do
      files =
        for i <- 0..9 do
          file("m#{i}.ex", "defmodule M#{i} do\n  def x, do: M#{rem(i + 1, 10)}.x()\nend\n")
        end

      assert [issue] = CircularDependency.check(files, [])
      assert length(issue.meta.cycle) == 10
      assert issue.meta.cycle == Enum.sort(issue.meta.cycle)
    end
  end

  describe "check/2 — exclude_paths" do
    test "drops excluded files before graph analysis" do
      # Generated table code cycles by construction and isn't the
      # author's to restructure.
      files = [
        file("lib/generated/a.ex", "defmodule A do\n  def x, do: B.y()\nend\n"),
        file("lib/generated/b.ex", "defmodule B do\n  def y, do: A.x()\nend\n")
      ]

      assert [_] = CircularDependency.check(files, [])
      assert [] = CircularDependency.check(files, exclude_paths: ["lib/generated/"])
    end

    test "leaves non-excluded cycles alone" do
      files = [
        file("lib/generated/a.ex", "defmodule A do\n  def x, do: B.y()\nend\n"),
        file("lib/generated/b.ex", "defmodule B do\n  def y, do: A.x()\nend\n"),
        file("lib/app/c.ex", "defmodule C do\n  def x, do: D.y()\nend\n"),
        file("lib/app/d.ex", "defmodule D do\n  def y, do: C.x()\nend\n")
      ]

      assert [issue] = CircularDependency.check(files, exclude_paths: ["lib/generated/"])
      assert issue.meta.cycle == ["C", "D"]
    end
  end
end
