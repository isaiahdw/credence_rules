defmodule CredenceRules.CrossFile.HubModuleTest do
  use ExUnit.Case, async: true

  alias CredenceRules.CrossFile.HubModule

  defp file(path, source), do: {path, Code.string_to_quoted!(source)}

  describe "check/2 — flagged" do
    test "flags a module with fan-in above threshold" do
      # 6 modules depend on Hub; threshold lowered to 5 so it fires.
      files = [
        file("hub.ex", "defmodule Hub do\n  def shared, do: :ok\nend\n")
        | for n <- ~w(A B C D E F) do
            file(
              "#{String.downcase(n)}.ex",
              "defmodule #{n} do\n  def go, do: Hub.shared()\nend\n"
            )
          end
      ]

      # max_vocab_loc: 0 disables the tiny-module exemption so this
      # test isolates fan-in detection.
      assert [issue] = HubModule.check(files, max_fan_in: 5, max_vocab_loc: 0)
      assert issue.rule == :hub_module
      assert issue.meta.fan_in == 6
    end

    test "flags multiple hubs when multiple exceed threshold" do
      files =
        [
          file("hub1.ex", "defmodule Hub1 do\n  def x, do: :ok\nend\n"),
          file("hub2.ex", "defmodule Hub2 do\n  def x, do: :ok\nend\n")
        ] ++
          for n <- ~w(A B C D E F) do
            file(
              "#{String.downcase(n)}.ex",
              "defmodule #{n} do\n  def go do\n  Hub1.x()\n  Hub2.x()\n  end\nend\n"
            )
          end

      issues = HubModule.check(files, max_fan_in: 5, max_vocab_loc: 0)
      assert length(issues) == 2
    end
  end

  describe "check/2 — not flagged" do
    test "ignores modules below threshold" do
      files = [
        file("hub.ex", "defmodule Hub do\n  def shared, do: :ok\nend\n")
        | for n <- ~w(A B C) do
            file(
              "#{String.downcase(n)}.ex",
              "defmodule #{n} do\n  def go, do: Hub.shared()\nend\n"
            )
          end
      ]

      # fan_in=3, default threshold=15 → no fire.
      assert [] = HubModule.check(files, [])
    end

    test "ignores leaf modules with no dependents" do
      files = [
        file("a.ex", "defmodule A do\n  def go, do: :ok\nend\n")
      ]

      assert [] = HubModule.check(files, [])
    end

    test "honours :exclude_modules opt (atom form)" do
      files = [
        file("hub.ex", "defmodule Hub do\n  def shared, do: :ok\nend\n")
        | for n <- ~w(A B C D E F) do
            file(
              "#{String.downcase(n)}.ex",
              "defmodule #{n} do\n  def go, do: Hub.shared()\nend\n"
            )
          end
      ]

      # Without exclusion: fires (max_vocab_loc: 0 isolates exclusion).
      assert [_] = HubModule.check(files, max_fan_in: 5, max_vocab_loc: 0)
      # With exclusion: skipped.
      assert [] = HubModule.check(files, max_fan_in: 5, max_vocab_loc: 0, exclude_modules: [Hub])
    end

    test ":exclude_modules accepts string form too" do
      files = [
        file("hub.ex", "defmodule Hub do\n  def shared, do: :ok\nend\n")
        | for n <- ~w(A B C D E F) do
            file(
              "#{String.downcase(n)}.ex",
              "defmodule #{n} do\n  def go, do: Hub.shared()\nend\n"
            )
          end
      ]

      assert [] = HubModule.check(files, max_fan_in: 5, max_vocab_loc: 0, exclude_modules: ["Hub"])
    end

    test "ignores a tiny stable-vocabulary module despite high fan-in" do
      # `NodeId` is a small value type — high fan-in by design, no
      # accumulated logic. Auto-exempt under the default vocab-loc gate.
      nodeid =
        file(
          "node_id.ex",
          "defmodule NodeId do\n  defstruct [:value]\n  def parse(s), do: %__MODULE__{value: s}\nend\n"
        )

      deps =
        for n <- ~w(A B C D E F),
            do:
              file("#{String.downcase(n)}.ex", "defmodule #{n} do\n  def go, do: NodeId.parse(\"x\")\nend\n")

      assert [] = HubModule.check([nodeid | deps], max_fan_in: 5)
    end

    test "flags a large hub above :max_vocab_loc" do
      body = Enum.map_join(1..30, "\n", fn i -> "  def f#{i}(x), do: x" end)
      hub = file("hub.ex", "defmodule Hub do\n#{body}\nend\n")

      deps =
        for n <- ~w(A B C D E F),
            do: file("#{String.downcase(n)}.ex", "defmodule #{n} do\n  def go, do: Hub.f1(1)\nend\n")

      files = [hub | deps]

      # ~30 LOC > vocab threshold of 10 → flagged; raise the threshold → exempt.
      assert [_] = HubModule.check(files, max_fan_in: 5, max_vocab_loc: 10)
      assert [] = HubModule.check(files, max_fan_in: 5, max_vocab_loc: 200)
    end
  end

  describe "check/2 — exclude_paths" do
    test "excluded dependants stop counting toward fan-in" do
      # Generated modules referencing a shared struct inflate its fan-in
      # without saying anything about the module's design.
      files = [
        file("hub.ex", "defmodule Hub do\n  def shared, do: :ok\nend\n")
        | for n <- ~w(A B C D E F) do
            file(
              "lib/generated/#{String.downcase(n)}.ex",
              "defmodule #{n} do\n  def go, do: Hub.shared()\nend\n"
            )
          end
      ]

      assert [_] = HubModule.check(files, max_fan_in: 5, max_vocab_loc: 0)

      assert [] =
               HubModule.check(files,
                 max_fan_in: 5,
                 max_vocab_loc: 0,
                 exclude_paths: ["lib/generated/"]
               )
    end
  end
end
