defmodule CredenceRulesTest do
  # `async: false` because we mutate :credence_rules Application
  # env in some tests (disabled_rules). Each test restores the original
  # value on exit to keep the rest of the suite unaffected.
  use ExUnit.Case, async: false

  describe "rules/0" do
    test "discovers every module under CredenceRules.Pattern.*" do
      modules = CredenceRules.rules()

      # Sanity-check the count matches the number of files on disk — the
      # whole point of auto-discovery is that this stays in sync without
      # a central registration list.
      file_count =
        Path.join([__DIR__, "..", "lib", "credence_rules", "pattern", "*.ex"])
        |> Path.wildcard()
        |> length()

      assert length(modules) == file_count
      assert file_count > 0
    end

    test "every discovered module exports check/2" do
      for mod <- CredenceRules.rules() do
        assert function_exported?(mod, :check, 2),
               "#{inspect(mod)} is returned by rules/0 but does not export check/2"
      end
    end

    test "every discovered module lives under CredenceRules.Pattern.*" do
      for mod <- CredenceRules.rules() do
        assert String.starts_with?(Atom.to_string(mod), "Elixir.CredenceRules.Pattern."),
               "#{inspect(mod)} is not under the Pattern namespace"
      end
    end

    test "returns modules sorted" do
      modules = CredenceRules.rules()
      assert modules == Enum.sort(modules)
    end

    test "is callable from a fresh BEAM (no compile-time state required)" do
      # Spot-check a known rule is present.
      assert CredenceRules.Pattern.NarratorComment in CredenceRules.rules()
    end
  end

  describe "rules/0 with :disabled_rules config" do
    setup do
      original = Application.get_env(:credence_rules, :disabled_rules)
      on_exit(fn -> reset_disabled(original) end)
      :ok
    end

    test "filters by module reference" do
      Application.put_env(:credence_rules, :disabled_rules, [
        CredenceRules.Pattern.ObviousComment
      ])

      refute CredenceRules.Pattern.ObviousComment in CredenceRules.rules()
      assert CredenceRules.Pattern.NarratorComment in CredenceRules.rules()
    end

    test "filters by rule atom" do
      Application.put_env(:credence_rules, :disabled_rules, [:obvious_comment])

      refute CredenceRules.Pattern.ObviousComment in CredenceRules.rules()
    end

    test "filters multiple rules at once (mixed forms)" do
      Application.put_env(:credence_rules, :disabled_rules, [
        :obvious_comment,
        CredenceRules.Pattern.StepComment
      ])

      remaining = CredenceRules.rules()
      refute CredenceRules.Pattern.ObviousComment in remaining
      refute CredenceRules.Pattern.StepComment in remaining
    end

    test "filters GenServer-named rules by their snake_case atom (with patched convention)" do
      # The module is `GenserverAsKvStore` and emits `:genserver_as_kv_store`.
      # The module is `GenServerReceiveBlock` (camel-cased "Server") but emits
      # `:genserver_receive_block`. The override map should resolve both.
      Application.put_env(:credence_rules, :disabled_rules, [
        :genserver_receive_block,
        :genserver_as_kv_store
      ])

      remaining = CredenceRules.rules()
      refute CredenceRules.Pattern.GenServerReceiveBlock in remaining
      refute CredenceRules.Pattern.GenserverAsKvStore in remaining
    end

    test "ignores unknown atoms instead of raising" do
      Application.put_env(:credence_rules, :disabled_rules, [:nonexistent_rule_xyz])

      # No crash; full list still returned.
      assert is_list(CredenceRules.rules())
      assert length(CredenceRules.rules()) > 0
    end

    test "empty disabled list is the default" do
      Application.delete_env(:credence_rules, :disabled_rules)
      assert length(CredenceRules.rules()) > 0
    end
  end

  describe "advisory_rules/0" do
    test "is a MapSet of atoms" do
      set = CredenceRules.advisory_rules()
      assert is_struct(set, MapSet)

      for atom <- set do
        assert is_atom(atom), "#{inspect(atom)} is not an atom"
      end
    end

    test "every advisory atom corresponds to a real rule module" do
      # Derive each rule's expected atom from its module name (using the
      # same convention `disabled_rules` uses for atom→module resolution)
      # and assert that every advisory atom maps to a real, discovered
      # rule. Catches stale entries: a rule got renamed/deleted but the
      # advisory set still references its old atom.
      per_file_atoms = Enum.map(CredenceRules.rules(), &module_to_rule_atom/1)
      cross_file_atoms = Enum.map(CredenceRules.cross_file_rules(), &module_to_rule_atom/1)
      expected_atoms = MapSet.new(per_file_atoms ++ cross_file_atoms)

      stale = MapSet.difference(CredenceRules.advisory_rules(), expected_atoms)

      assert MapSet.size(stale) == 0,
             "advisory_rules/0 references atoms with no live rule: #{inspect(MapSet.to_list(stale))}"
    end
  end

  describe "advisory?/1" do
    test "returns true for known advisory atoms" do
      assert CredenceRules.advisory?(:narrator_comment)
      assert CredenceRules.advisory?(:obvious_comment)
    end

    test "returns false for boundary atoms" do
      refute CredenceRules.advisory?(:rescue_catch_all)
      refute CredenceRules.advisory?(:genserver_as_kv_store)
    end

    test "returns false for unknown atoms" do
      refute CredenceRules.advisory?(:nonexistent)
    end
  end

  # Mirror the atom-resolution convention used by the rules/0 disabled-rules
  # filter — `Macro.underscore` on the last module segment, with the
  # GenServer overrides patched. If those drift, this test breaks loudly.
  @genserver_overrides %{
    gen_server_receive_block: :genserver_receive_block,
    gen_server_self_call_deadlock: :genserver_self_call_deadlock,
    gen_server_with_immutable_state: :genserver_with_immutable_state,
    no_gen_server_callback_missing_impl: :no_genserver_callback_missing_impl,
    sleep_in_gen_server_callback: :sleep_in_genserver_callback,
    task_await_in_gen_server_callback: :task_await_in_genserver_callback,
    process_dict_in_gen_server: :process_dict_in_genserver
  }

  @cross_file_overrides %{
    duplicate_block: :cross_file_duplicate_block,
    circular_dependency: :circular_module_dependency
  }

  defp module_to_rule_atom(module) do
    base =
      module
      |> Module.split()
      |> List.last()
      |> Macro.underscore()
      |> String.to_atom()

    base
    |> (fn a -> Map.get(@genserver_overrides, a, a) end).()
    |> (fn a -> Map.get(@cross_file_overrides, a, a) end).()
  end

  defp reset_disabled(nil), do: Application.delete_env(:credence_rules, :disabled_rules)
  defp reset_disabled(value), do: Application.put_env(:credence_rules, :disabled_rules, value)
end
