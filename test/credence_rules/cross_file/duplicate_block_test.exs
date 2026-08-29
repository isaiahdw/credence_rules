defmodule CredenceRules.CrossFile.DuplicateBlockTest do
  use ExUnit.Case, async: true

  alias CredenceRules.CrossFile.DuplicateBlock

  defp file(path, source), do: {path, Code.string_to_quoted!(source)}

  describe "check/2 — flagged" do
    test "flags a duplicate pipeline in two files" do
      # References MyApp.Source (a non-stdlib module), so it's a real
      # cross-file duplicate, not a stdlib-only language idiom.
      pipeline = """
      MyApp.Source.stream(x)
      |> Enum.filter(& &1.active)
      |> Enum.map(& &1.name)
      |> Enum.uniq()
      |> Enum.sort()
      """

      files = [
        file("a.ex", "defmodule A do\n  def go(x), do: " <> pipeline <> "end\n"),
        file("b.ex", "defmodule B do\n  def go(x), do: " <> pipeline <> "end\n")
      ]

      assert [issue] = DuplicateBlock.check(files, [])
      assert issue.rule == :cross_file_duplicate_block
      assert issue.meta.occurrences == 2
      assert Enum.sort(issue.meta.files) == ["a.ex", "b.ex"]
    end

    test "flags a duplicate across three files" do
      block = """
      with {:ok, a} <- Steps.one(x),
           {:ok, b} <- Steps.two(a),
           {:ok, c} <- Steps.three(b) do
        {:ok, c}
      end
      """

      files = [
        file("a.ex", "defmodule A do\n  def go(x), do: " <> block <> "end\n"),
        file("b.ex", "defmodule B do\n  def go(x), do: " <> block <> "end\n"),
        file("c.ex", "defmodule C do\n  def go(x), do: " <> block <> "end\n")
      ]

      assert [issue] = DuplicateBlock.check(files, [])
      assert issue.meta.occurrences == 3
      assert Enum.sort(issue.meta.files) == ["a.ex", "b.ex", "c.ex"]
    end

    test "attaches finding to lexicographically-smallest path" do
      pipeline = """
      MyApp.Source.stream(x)
      |> Enum.filter(& &1.active)
      |> Enum.map(& &1.name)
      |> Enum.uniq()
      |> Enum.sort()
      """

      files = [
        file("zzz.ex", "defmodule Z do\n  def go(x), do: " <> pipeline <> "end\n"),
        file("aaa.ex", "defmodule A do\n  def go(x), do: " <> pipeline <> "end\n")
      ]

      assert [issue] = DuplicateBlock.check(files, [])
      assert issue.meta.path == "aaa.ex"
    end
  end

  describe "check/2 — not flagged" do
    test "ignores duplicates within one file (other rules handle that)" do
      pipeline = """
      MyApp.Source.stream(x)
      |> Enum.filter(& &1.active)
      |> Enum.map(& &1.name)
      |> Enum.uniq()
      |> Enum.sort()
      """

      files = [
        file(
          "a.ex",
          "defmodule A do\n  def go(x), do: " <>
            pipeline <> "  def go2(x), do: " <> pipeline <> "end\n"
        )
      ]

      assert [] = DuplicateBlock.check(files, [])
    end

    test "ignores small duplicates (below threshold)" do
      files = [
        file("a.ex", "defmodule A do\n  def go(x), do: foo(x)\nend\n"),
        file("b.ex", "defmodule B do\n  def go(x), do: foo(x)\nend\n")
      ]

      assert [] = DuplicateBlock.check(files, [])
    end

    test "ignores when files have no shared structure" do
      files = [
        file("a.ex", "defmodule A do\n  def go, do: :first\nend\n"),
        file("b.ex", "defmodule B do\n  def go, do: :second\nend\n")
      ]

      assert [] = DuplicateBlock.check(files, [])
    end
  end

  describe "language idioms" do
    test "ignores a stdlib-only optional-lookup idiom across files" do
      block = """
      case Map.get(opts, :timeout) do
        nil -> Application.get_env(:app, :default_timeout)
        value -> value
      end
      """

      files = [
        file("a.ex", "defmodule A do\n  def t(opts), do: " <> block <> "end\n"),
        file("b.ex", "defmodule B do\n  def t(opts), do: " <> block <> "end\n")
      ]

      assert [] = DuplicateBlock.check(files, [])
    end

    test "ignores a Logger error-log idiom across files" do
      block = """
      case run(x) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("[M] failed: \#{inspect(reason)}")
      end
      """

      files = [
        file("a.ex", "defmodule A do\n  def t(x), do: " <> block <> "end\n"),
        file("b.ex", "defmodule B do\n  def t(x), do: " <> block <> "end\n")
      ]

      assert [] = DuplicateBlock.check(files, [])
    end

    test "flags the same idiom once it calls a project module" do
      block = """
      case Map.get(opts, :store) do
        nil -> MyApp.Store.default()
        value -> value
      end
      """

      files = [
        file("a.ex", "defmodule A do\n  def t(opts), do: " <> block <> "end\n"),
        file("b.ex", "defmodule B do\n  def t(opts), do: " <> block <> "end\n")
      ]

      assert [_] = DuplicateBlock.check(files, [])
    end

    test "flag_language_idioms: true reports stdlib-only duplicates" do
      block = """
      case Map.get(opts, :timeout) do
        nil -> Application.get_env(:app, :default_timeout)
        value -> value
      end
      """

      files = [
        file("a.ex", "defmodule A do\n  def t(opts), do: " <> block <> "end\n"),
        file("b.ex", "defmodule B do\n  def t(opts), do: " <> block <> "end\n")
      ]

      assert [_] = DuplicateBlock.check(files, flag_language_idioms: true)
    end

    test "extra_stdlib_modules treats a project namespace as stdlib" do
      block = """
      case Map.get(opts, :store) do
        nil -> MyApp.Store.default()
        value -> value
      end
      """

      files = [
        file("a.ex", "defmodule A do\n  def t(opts), do: " <> block <> "end\n"),
        file("b.ex", "defmodule B do\n  def t(opts), do: " <> block <> "end\n")
      ]

      assert [] = DuplicateBlock.check(files, extra_stdlib_modules: [:MyApp])
    end
  end

  describe "facade / behaviour mirrors" do
    # The behaviour's @callback and the facade's @spec share the inner
    # `name(args) :: ret` signature. It references project types, so it
    # survives the language-idiom filter — the mirror filter is what
    # drops it.
    @behaviour_file """
    defmodule MyApp.Thread.Adapter do
      @callback start_link(MyApp.Thread.Config.t()) ::
                  {:ok, MyApp.Thread.Session.t()} | {:error, term()}
    end
    """

    @facade_file """
    defmodule MyApp.Thread do
      @spec start_link(MyApp.Thread.Config.t()) ::
              {:ok, MyApp.Thread.Session.t()} | {:error, term()}
      def start_link(config), do: adapter().start_link(config)

      defp adapter, do: Application.get_env(:my_app, :thread_adapter, Default)
    end
    """

    test "ignores a @callback / @spec signature mirror across files" do
      files = [
        file("lib/my_app/thread/adapter.ex", @behaviour_file),
        file("lib/my_app/thread.ex", @facade_file)
      ]

      assert [] = DuplicateBlock.check(files, [])
    end

    test "flag_interface_mirrors: true reports the mirror" do
      files = [
        file("lib/my_app/thread/adapter.ex", @behaviour_file),
        file("lib/my_app/thread.ex", @facade_file)
      ]

      assert [_] = DuplicateBlock.check(files, flag_interface_mirrors: true)
    end

    test "ignores a duplicated @spec referencing project types" do
      spec = """
      @spec encode(MyApp.Tlv.Tag.t(), MyApp.Tlv.Value.t(), keyword()) ::
              {:ok, binary()} | {:error, MyApp.Tlv.Error.t()}
      """

      # Different impls so only the identical @spec clusters (not the
      # whole def), isolating the type-declaration drop.
      files = [
        file("a.ex", "defmodule A do\n  #{spec}  def encode(t, v, o), do: encode_a(t, v, o)\nend\n"),
        file("b.ex", "defmodule B do\n  #{spec}  def encode(t, v, o), do: encode_b(t, v, o)\nend\n")
      ]

      assert [] = DuplicateBlock.check(files, [])
      assert [_] = DuplicateBlock.check(files, flag_interface_mirrors: true)
    end

    test "still flags real shared logic that merely lives near a spec" do
      # Not a mirror: the cluster is a project-logic pipeline, not a
      # type signature or a delegation.
      block = """
      MyApp.Thread.Registry.lookup(id)
      |> MyApp.Thread.Session.touch()
      |> MyApp.Thread.Session.persist()
      |> MyApp.Thread.Telemetry.record(:touched)
      """

      files = [
        file("a.ex", "defmodule A do\n  def go(id), do: #{block}end\n"),
        file("b.ex", "defmodule B do\n  def go(id), do: #{block}end\n")
      ]

      assert [_] = DuplicateBlock.check(files, [])
    end
  end

  describe "subsumption" do
    test "reports only the largest enclosing cluster, not nested sub-clusters" do
      # A big duplicated block contains smaller duplicated sub-blocks
      # at every level. Only the outer one should report.
      block = """
      case MyApp.Source.load(x) do
        {:ok, v} ->
          v
          |> Enum.filter(& &1.active)
          |> Enum.map(& &1.name)
          |> Enum.uniq()
          |> Enum.sort()

        {:error, _} ->
          []
      end
      """

      files = [
        file("a.ex", "defmodule A do\n  def go(x), do: " <> block <> "end\n"),
        file("b.ex", "defmodule B do\n  def go(x), do: " <> block <> "end\n")
      ]

      # Should be exactly one finding even though the inner pipeline
      # also duplicates between the two files.
      assert [_] = DuplicateBlock.check(files, [])
    end
  end
end
