defmodule CredenceRules.CategoryTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Category

  describe "for_rule/1" do
    test "returns the mapped category for a known rule" do
      assert Category.for_rule(:unsupervised_spawn) == :concurrency
      assert Category.for_rule(:rescue_catch_all) == :safety
      assert Category.for_rule(:assert_enum_all) == :test_quality
      assert Category.for_rule(:obvious_comment) == :documentation
      assert Category.for_rule(:manager_service_module_name) == :naming
    end

    test "unmapped rules fall back to :idioms" do
      assert Category.for_rule(:flat_map_filter) == :idioms
      assert Category.for_rule(:totally_made_up_rule_xyz) == :idioms
    end
  end

  describe "all/0" do
    test "lists categories in display order" do
      assert Category.all() == [
               :concurrency,
               :safety,
               :test_quality,
               :architecture,
               :dry,
               :documentation,
               :naming,
               :idioms
             ]
    end
  end

  describe "label/1" do
    test "returns a display label for each category" do
      for category <- Category.all() do
        assert is_binary(Category.label(category))
      end
    end
  end

  describe "coverage" do
    test "every live rule resolves to a category from Category.all/0" do
      known = MapSet.new(Category.all())

      for module <- CredenceRules.rules() do
        atom = module_to_rule_atom(module)
        category = Category.for_rule(atom)

        assert MapSet.member?(known, category),
               "#{inspect(atom)} resolves to unknown category #{inspect(category)}"
      end
    end
  end

  # Mirror the rules/0 atom convention.
  @genserver_overrides %{
    gen_server_receive_block: :genserver_receive_block,
    gen_server_self_call_deadlock: :genserver_self_call_deadlock,
    gen_server_with_immutable_state: :genserver_with_immutable_state,
    no_gen_server_callback_missing_impl: :no_genserver_callback_missing_impl,
    sleep_in_gen_server_callback: :sleep_in_genserver_callback,
    task_await_in_gen_server_callback: :task_await_in_genserver_callback,
    process_dict_in_gen_server: :process_dict_in_genserver
  }

  defp module_to_rule_atom(module) do
    base =
      module
      |> Module.split()
      |> List.last()
      |> Macro.underscore()
      |> String.to_atom()

    Map.get(@genserver_overrides, base, base)
  end
end
