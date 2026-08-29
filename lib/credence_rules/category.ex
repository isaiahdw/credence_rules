defmodule CredenceRules.Category do
  @moduledoc """
  Maps each rule atom to a high-level **category** used for the score
  breakdown printed by `mix credence.check`. Categories are coarse —
  the goal is to surface where a codebase's pain lives ("90% of issues
  are in `:documentation`") not to taxonomise individual rules
  precisely.

  Rules not explicitly listed fall into `:idioms` — the catch-all for
  functional-pattern misuse. Add new entries here if a rule deserves
  its own dimension. A test asserts every discovered rule resolves to
  one of the known categories, so the fallback can never silently
  hide a typo.

  Categories (ordered for the summary print):

  - `:concurrency`   — OTP role / process / supervisor / ETS / persistent term
  - `:safety`        — error handling, unsafe conversions, raise / rescue
  - `:test_quality`  — assertion strength and test-only hygiene
  - `:architecture`  — module shape, IOSP, layer / dependency boundaries
  - `:dry`           — duplicate subtrees, wildcard imports, repeated case arms
  - `:documentation` — doc strings, comments, narration
  - `:naming`        — module / function naming
  - `:idioms`        — functional patterns (default)
  """

  @category_rules %{
    concurrency: [
      :application_get_env_at_compile_time,
      :application_put_env_in_code,
      :conditional_supervisor_child,
      :ets_extract_then_enum,
      :ets_owner_lifecycle_mismatch,
      :genserver_as_kv_store,
      :genserver_handle_call_explosion,
      :genserver_receive_block,
      :genserver_self_call_deadlock,
      :genserver_with_immutable_state,
      :no_genserver_callback_missing_impl,
      :no_send_self_in_init,
      :persistent_term_abuse,
      :process_dict_in_genserver,
      :process_whereis_for_liveness,
      :sleep_in_genserver_callback,
      :task_await_in_genserver_callback,
      :task_supervisor_without_down_handling,
      :unsupervised_spawn
    ],
    safety: [
      :alternative_return_types,
      :atom_interpolation,
      :bang_function_that_doesnt_raise,
      :binary_to_term_without_safe,
      :dual_key_access,
      :empty_map_pattern_as_shape_claim,
      :mix_shell_outside_mix_task,
      :non_assertive_map_access,
      :path_expand_priv,
      :raise_without_module,
      :reraise_without_stacktrace,
      :rescue_catch_all,
      :rescue_without_reraise,
      :string_to_atom_unsafe,
      :tagged_tuple_elem_access,
      :truthy_guard_non_boolean,
      :try_rescue_with_safe_alternative,
      :unsafe_assertive_match_on_fallible_result,
      :useless_try
    ],
    test_quality: [
      :assert_enum_all,
      :assert_match_question,
      :no_test_without_assertion,
      :no_trivially_truthy_assertion,
      :process_sleep_in_test,
      :real_external_client_in_test,
      :vague_test_name
    ],
    documentation: [
      :boilerplate_doc_params,
      :credence_suppression_without_reason,
      :doc_false_on_public_function,
      :io_inspect_in_lib,
      :narrator_comment,
      :narrator_doc,
      :no_todo_or_roadmap_comment,
      :obvious_comment,
      :spec_returns_any,
      :stale_reference_comment,
      :step_comment
    ],
    naming: [
      :def_is_prefix,
      :manager_service_module_name,
      :unaliased_module_use
    ],
    dry: [
      :cross_file_duplicate_block,
      :repeated_case_arm_body,
      :repeated_subtree_in_function,
      :repeated_subtree_in_module,
      :wildcard_import
    ],
    architecture: [
      :circular_module_dependency,
      :fat_controller,
      :forbidden_module_dependency,
      :hub_module,
      :iosp_mixed_function,
      :iosp_normalizer_side_effects,
      :iosp_predicate_side_effects,
      :large_defstruct,
      :liveview_db_calls_outside_mount,
      :liveview_query_in_mount,
      :logger_call_in_mix_task,
      :module_instability,
      :module_that_re_exports_only,
      :module_with_many_use_statements,
      :no_internal_module_crossing,
      :option_branched_function,
      :oversized_message_handler_module,
      :schema_with_business_logic
    ]
  }

  @order [
    :concurrency,
    :safety,
    :test_quality,
    :architecture,
    :dry,
    :documentation,
    :naming,
    :idioms
  ]

  @lookup Map.new(
            Enum.flat_map(@category_rules, fn {category, rules} ->
              Enum.map(rules, &{&1, category})
            end)
          )

  @doc "Returns the ordered list of category atoms used for the score breakdown."
  @spec all() :: [atom()]
  def all, do: @order

  @doc """
  Returns the category atom for a rule. Rules without an explicit
  mapping fall back to `:idioms`.
  """
  @spec for_rule(atom()) :: atom()
  def for_rule(rule), do: Map.get(@lookup, rule, :idioms)

  @doc """
  Display label for a category (used in the text format summary).
  Padding-friendly: short, single-word where possible.
  """
  @spec label(atom()) :: String.t()
  def label(:concurrency), do: "Concurrency"
  def label(:safety), do: "Safety"
  def label(:test_quality), do: "Test Quality"
  def label(:architecture), do: "Architecture"
  def label(:dry), do: "DRY"
  def label(:documentation), do: "Documentation"
  def label(:naming), do: "Naming"
  def label(:idioms), do: "Idioms"
end
