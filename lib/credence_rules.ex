defmodule CredenceRules do
  @moduledoc """
  Locally-authored Credence `Pattern.Rule` modules that target LLM failure
  modes not yet covered by the upstream
  [`credence`](https://github.com/Cinderella-Man/credence) catalog.

  ## Quick start

  Add the dep to your project:

      defp deps do
        [
          {:credence, "~> 0.5", only: [:dev, :test], runtime: false},
          {:credence_rules, git: "https://github.com/isaiahdw/credence_rules.git",
           only: [:dev, :test], runtime: false}
        ]
      end

  Run the linter:

      mix credence.check                 # report-only, scans lib/ + test/
      mix credence.check --strict        # exits 1 on boundary findings

  ## Configuration

  Optional `Application` env keys read by `mix credence.check`:

      config :credence_rules,
        # Paths excluded from the scan (typically codegen output).
        generated_paths: ["lib/my_app/generated_stuff.ex"],
        # Pre-existing modules whose names end in OOP-style suffixes
        # (Manager / Service / Helper / Handler / …) but are grandfathered
        # in. Passed to `manager_service_module_name` via rule opts.
        allowed_modules: [MyApp.Legacy.Manager]

  See `README.md` for the full rule catalog and the boundary/advisory
  taxonomy.
  """

  @pattern_prefix "Elixir.CredenceRules.Pattern."
  @cross_file_prefix "Elixir.CredenceRules.CrossFile."
  @cross_file_behaviour_module "Elixir.CredenceRules.CrossFile.Rule"

  @advisory_rules MapSet.new([
                    :anonymous_fn_capture_wrap,
                    :assert_enum_all,
                    :assert_match_question,
                    :atom_interpolation,
                    :boilerplate_doc_params,
                    :boolean_case_over_value_case,
                    :boolean_flag_argument,
                    :case_arg_could_be_function_clauses,
                    :case_destructure_should_be_function_clause,
                    :case_with_single_wildcard_arm,
                    :cond_shape_checks_should_case,
                    :cross_file_duplicate_block,
                    :def_is_prefix,
                    :doc_false_on_public_function,
                    :empty_map_pattern_as_shape_claim,
                    :enum_each_assigned,
                    :enum_into_for_map_new,
                    :fat_controller,
                    :filter_then_count,
                    :filter_then_first,
                    :flat_map_filter,
                    :genserver_handle_call_explosion,
                    :hd_or_tl_call,
                    :identity_passthrough,
                    :if_value_else_nil,
                    :io_inspect_in_lib,
                    :iosp_mixed_function,
                    :iosp_normalizer_side_effects,
                    :iosp_predicate_side_effects,
                    :large_defstruct,
                    :list_check_then_head_tail,
                    :liveview_db_calls_outside_mount,
                    :liveview_query_in_mount,
                    :logger_call_in_mix_task,
                    :hub_module,
                    :magic_timeout_literal,
                    :manager_service_module_name,
                    :map_has_key_then_get,
                    :map_into_literal,
                    :match_test_then_extract,
                    :module_instability,
                    :module_that_re_exports_only,
                    :module_with_many_use_statements,
                    :narrator_comment,
                    :narrator_doc,
                    :nested_calls_should_pipe,
                    :nested_ok_error_cases_could_with,
                    :nil_check_else_uses_value,
                    :nil_predicate_lambda,
                    :no_test_without_assertion,
                    :no_todo_or_roadmap_comment,
                    :no_trivially_truthy_assertion,
                    :obvious_comment,
                    :option_branched_function,
                    :oversized_message_handler_module,
                    :process_sleep_in_test,
                    :raise_without_module,
                    :real_external_client_in_test,
                    :redundant_boolean_if,
                    :reduce_as_map,
                    :reduce_map_put,
                    :repeated_case_arm_body,
                    :repeated_subtree_in_function,
                    :repeated_subtree_in_module,
                    :rescue_without_reraise,
                    :reraise_without_stacktrace,
                    :schema_with_business_logic,
                    :side_effect_in_pipe,
                    :sort_then_take_first,
                    :single_stage_pipe,
                    :spec_returns_any,
                    :stale_reference_comment,
                    :step_comment,
                    :tagged_tuple_elem_access,
                    :truthy_access_reused_in_body,
                    :try_rescue_with_safe_alternative,
                    :unaliased_module_use,
                    :unsafe_assertive_match_on_fallible_result,
                    :useless_try,
                    :vague_test_name,
                    :wildcard_import,
                    :with_complex_else,
                    :with_identity_do,
                    :with_identity_else
                  ])

  @doc """
  Returns the list of rule modules to register with Credence.

  Auto-discovered: every module under `CredenceRules.Pattern.*`
  that exports `check/2` is included. Drop a new file under
  `lib/credence_rules/pattern/` and it joins the run — no
  central registration list to keep in sync.

  Users can disable specific rules via Application env:

      config :credence_rules,
        disabled_rules: [:obvious_comment, :step_comment]

  …or by module reference (handy in `.iex.exs` or in test setup):

      config :credence_rules,
        disabled_rules: [CredenceRules.Pattern.ObviousComment]

  """
  @spec rules() :: [module()]
  def rules, do: discover_rules(&pattern_rule?/1)

  @doc """
  Returns the list of cross-file rule modules — every module under
  `CredenceRules.CrossFile.*` (except the `Rule` behaviour
  module itself) that exports `check/2`.

  Cross-file rules see every scanned file's AST at once. See
  `CredenceRules.CrossFile.Rule` for the callback contract.

  Disabled the same way as per-file rules via `:disabled_rules`.
  """
  @spec cross_file_rules() :: [module()]
  def cross_file_rules, do: discover_rules(&cross_file_rule?/1)

  defp discover_rules(predicate) do
    disabled = disabled_set()

    app_modules()
    |> Enum.filter(predicate)
    |> Enum.reject(&disabled?(&1, disabled))
    |> Enum.sort()
  end

  defp app_modules do
    :credence_rules |> Application.spec(:modules) |> Kernel.||([])
  end

  @doc """
  Returns the set of rule atoms classified as **advisory** (style / hygiene).

  `mix credence.check --strict` does NOT fail on these — they print with
  an `(advisory)` tag so reviewers can tell them apart from boundary
  findings. See `README.md` for the full taxonomy.
  """
  @spec advisory_rules() :: MapSet.t(atom())
  def advisory_rules, do: @advisory_rules

  @doc "True if the given rule atom is in the advisory set."
  @spec advisory?(atom()) :: boolean()
  def advisory?(rule), do: MapSet.member?(@advisory_rules, rule)

  @doc """
  Returns the rule atom for a rule module — the same atom each rule's
  `%Issue{rule: ...}` carries. Useful for looking up per-rule
  configuration keyed on the rule's atom name.

      iex> CredenceRules.rule_atom(CredenceRules.Pattern.LargeDefstruct)
      :large_defstruct

      iex> CredenceRules.rule_atom(CredenceRules.Pattern.GenServerReceiveBlock)
      :genserver_receive_block
  """
  @spec rule_atom(module()) :: atom()
  def rule_atom(module) when is_atom(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
    |> normalize_atom()
  end

  @doc """
  Returns the per-rule options configured for the given rule (module
  or atom), merging the global options from
  `Application.get_env(:credence_rules, :rule_opts, %{})` with
  any defaults the caller passes.

  Configure per-rule thresholds project-wide:

      config :credence_rules,
        rule_opts: %{
          large_defstruct: [min_clusters: 3, scan_min_fields: 15],
          genserver_handle_call_explosion: [
            max_handle_call: 12,
            max_handle_call_per_instance: 20
          ],
          forbidden_module_dependency: [graph_source: :beam]
        }

  Rules can look up their own options via `rule_opts/1`:

      defp resolve(opts) do
        defaults = [min_clusters: 2]
        Keyword.merge(defaults, opts ++ CredenceRules.rule_opts(__MODULE__))
      end

  But the canonical place to merge per-rule opts is the analyser
  (`Mix.Tasks.Credence.Check.Analyser`), which threads them into
  each rule's `check/2` call.
  """
  @spec rule_opts(module() | atom()) :: keyword()
  def rule_opts(module_or_atom) do
    atom =
      case module_or_atom do
        atom when is_atom(atom) ->
          if Code.ensure_loaded?(atom) and function_exported?(atom, :check, 2),
            do: rule_atom(atom),
            else: atom
      end

    :credence_rules
    |> Application.get_env(:rule_opts, %{})
    |> Map.get(atom, [])
  end

  defp pattern_rule?(module) when is_atom(module) do
    String.starts_with?(Atom.to_string(module), @pattern_prefix) and
      exports_check2?(module)
  end

  defp pattern_rule?(_), do: false

  defp cross_file_rule?(module) when is_atom(module) do
    name = Atom.to_string(module)

    String.starts_with?(name, @cross_file_prefix) and
      name != @cross_file_behaviour_module and
      exports_check2?(module)
  end

  defp cross_file_rule?(_), do: false

  defp exports_check2?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :check, 2)
  end

  # Resolve disabled_rules entries (atoms OR modules) to a set of
  # module atoms for filtering.
  defp disabled_set do
    :credence_rules
    |> Application.get_env(:disabled_rules, [])
    |> Enum.flat_map(&resolve_disabled/1)
    |> MapSet.new()
  end

  defp resolve_disabled(module) when is_atom(module) do
    module_str = Atom.to_string(module)

    cond do
      String.starts_with?(module_str, @pattern_prefix) ->
        [module]

      String.starts_with?(module_str, @cross_file_prefix) ->
        [module]

      # Rule atom (`:obvious_comment`) — find the matching module by
      # comparing the issue atom each rule emits.
      true ->
        case Enum.find(all_rule_modules(), fn mod -> rule_atom(mod) == module end) do
          nil -> []
          mod -> [mod]
        end
    end
  end

  defp resolve_disabled(_), do: []

  defp all_rule_modules do
    Enum.filter(app_modules(), fn m -> pattern_rule?(m) or cross_file_rule?(m) end)
  end

  defp disabled?(module, set), do: MapSet.member?(set, module)

  # The GenServer rules use modules `GenServer*` but emit atoms `:genserver_*`
  # (treating GenServer as a single word). Patch the convention here so
  # `disabled_rules: [:genserver_receive_block]` matches `GenServerReceiveBlock`.
  @genserver_overrides %{
    gen_server_receive_block: :genserver_receive_block,
    gen_server_self_call_deadlock: :genserver_self_call_deadlock,
    gen_server_with_immutable_state: :genserver_with_immutable_state,
    no_gen_server_callback_missing_impl: :no_genserver_callback_missing_impl,
    sleep_in_gen_server_callback: :sleep_in_genserver_callback,
    task_await_in_gen_server_callback: :task_await_in_genserver_callback,
    process_dict_in_gen_server: :process_dict_in_genserver
  }

  # Cross-file rules use shorter module names but emit fuller atoms so
  # output makes sense out of context (`[cross_file_duplicate_block:_]`
  # vs `[duplicate_block:_]`).
  @cross_file_overrides %{
    duplicate_block: :cross_file_duplicate_block,
    circular_dependency: :circular_module_dependency
  }

  defp normalize_atom(atom) do
    atom
    |> apply_override(@genserver_overrides)
    |> apply_override(@cross_file_overrides)
  end

  defp apply_override(atom, overrides), do: Map.get(overrides, atom, atom)
end
