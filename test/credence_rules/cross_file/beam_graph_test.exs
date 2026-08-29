defmodule CredenceRules.CrossFile.BeamGraphTest do
  use ExUnit.Case, async: true

  alias CredenceRules.CrossFile.{BeamGraph, ModuleGraph}

  describe "build/0" do
    test "returns a populated ModuleGraph from our own compiled beams" do
      assert {:ok, %ModuleGraph{} = graph} = BeamGraph.build()

      # We're inside this project — every rule module should appear.
      assert MapSet.size(graph.modules) > 50

      # Sanity: our own modules appear as nodes.
      assert MapSet.member?(graph.modules, "CredenceRules.CrossFile.BeamGraph")
      assert MapSet.member?(graph.modules, "CredenceRules.CrossFile.ModuleGraph")
    end

    test "GraphSource depends on BeamGraph (function call → import → edge)" do
      assert {:ok, graph} = BeamGraph.build()

      deps = ModuleGraph.fan_out(graph, "CredenceRules.CrossFile.GraphSource")

      # `GraphSource.resolve/2` calls `BeamGraph.build/0` — that's
      # a real function call so it appears in the BEAM imports
      # chunk. (Struct-only references like `%ModuleGraph{...}`
      # don't appear in imports — they're a known BEAM-source
      # limitation vs. AST source.)
      assert "CredenceRules.CrossFile.BeamGraph" in deps
    end

    test "filters out non-project modules (Enum, MapSet, etc.)" do
      assert {:ok, graph} = BeamGraph.build()

      refute MapSet.member?(graph.modules, "Enum")
      refute MapSet.member?(graph.modules, "MapSet")
      refute MapSet.member?(graph.modules, "Kernel")

      # No edge points to stdlib either — they'd have been filtered
      # at build time.
      for {_source, targets} <- graph.forward do
        refute MapSet.member?(targets, "Enum")
        refute MapSet.member?(targets, "MapSet")
      end
    end

    test "reverse graph mirrors forward edges" do
      assert {:ok, graph} = BeamGraph.build()

      # If A → B in forward, then A ∈ fan_in(B) in reverse.
      Enum.each(graph.forward, fn {source, targets} ->
        Enum.each(targets, fn target ->
          fan_in = ModuleGraph.fan_in(graph, target)
          assert source in fan_in, "expected #{source} in fan_in(#{target}), got #{inspect(fan_in)}"
        end)
      end)
    end

    test "module_to_file points at actual .beam files" do
      assert {:ok, graph} = BeamGraph.build()

      for {_module, path} <- graph.module_to_file do
        assert String.ends_with?(path, ".beam")
        assert File.exists?(path)
      end
    end
  end

  describe "imports_for/1 — fallback for compiled-but-not-loaded modules" do
    test "returns {:ok, modules} for a loaded module" do
      # Our own module — definitely loaded.
      assert {:ok, modules} = BeamGraph.imports_for("CredenceRules.CrossFile.BeamGraph")
      assert is_list(modules)
      # BeamGraph imports a bunch of stdlib + Mix modules.
      assert "Enum" in modules or :code in Enum.map(modules, &String.to_atom/1)
    end

    test "returns {:error, :not_compiled} for a module with no BEAM on disk" do
      # All three fallback paths miss: atom doesn't exist,
      # compile_path doesn't contain it, no ebin on the code path
      # has it. Returns :not_compiled cleanly (no crash on
      # ArgumentError from String.to_existing_atom).
      assert {:error, :not_compiled} =
               BeamGraph.imports_for("Synthetic.Truly.Does.Not.Exist.#{System.unique_integer([:positive])}")
    end

    @tag :tmp_dir
    test "code_path fallback finds a real .beam when atom isn't loaded",
         %{tmp_dir: tmp_dir} do
      # The actual reproduction shape from the review: a module
      # with a .beam on disk but whose atom has never been touched
      # in this VM. We copy a real .beam (BeamGraph's own) to a
      # fresh filename whose atom is guaranteed-unloaded, add the
      # tmp dir to the code path, and verify imports_for finds it.
      {_module, source_beam, _} =
        :code.get_object_code(CredenceRules.CrossFile.BeamGraph)

      unique = System.unique_integer([:positive])
      new_name = "Synthetic.Fresh.NeverTouched#{unique}"
      new_filename = "Elixir." <> new_name <> ".beam"
      File.write!(Path.join(tmp_dir, new_filename), source_beam)

      true = :code.add_path(String.to_charlist(tmp_dir))

      try do
        # Sanity: the new module's atom is NOT in the table.
        atom_loaded? =
          try do
            String.to_existing_atom("Elixir." <> new_name)
            true
          rescue
            ArgumentError -> false
          end

        refute atom_loaded?

        # imports_for SHOULD resolve via the code-path fallback —
        # NOT return {:error, :not_compiled}. The BEAM is BeamGraph's
        # own bytes (we can't compile a fresh module to disk from a
        # test), so the imports list is whatever BeamGraph imports;
        # the invariant we test is {:ok, _list}, not the contents.
        assert {:ok, modules} = BeamGraph.imports_for(new_name)
        assert is_list(modules)
      after
        :code.del_path(String.to_charlist(tmp_dir))
      end
    end
  end
end
