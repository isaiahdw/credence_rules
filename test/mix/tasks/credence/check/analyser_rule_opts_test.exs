defmodule Mix.Tasks.Credence.Check.Analyser.RuleOptsTest do
  # async: false — mutates Application env, which is per-VM-global.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Credence.Check.Analyser

  setup do
    original = Application.get_env(:credence_rules, :rule_opts)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:credence_rules, :rule_opts)
        opts -> Application.put_env(:credence_rules, :rule_opts, opts)
      end
    end)
  end

  describe "Application env :rule_opts plumbing" do
    test "default tuning fires — large_defstruct at min_clusters=2 default" do
      # Default min_clusters is 2 → an auth_*/billing_*/pref_* shape
      # (3 clusters) fires at the default.
      source = ~S"""
      defmodule User do
        defstruct [
          :auth_a, :auth_b, :auth_c,
          :billing_a, :billing_b, :billing_c,
          :pref_a, :pref_b, :pref_c, :pref_d
        ]
      end
      """

      issues = Analyser.analyse_source(source)
      assert Enum.any?(issues, &(&1.rule == :large_defstruct))
    end

    test ":rule_opts threshold raise suppresses the default finding" do
      # Same struct, but raise min_clusters to 4 — only 3 clusters
      # appear, so it should now be suppressed.
      Application.put_env(:credence_rules, :rule_opts, %{
        large_defstruct: [min_clusters: 4]
      })

      source = ~S"""
      defmodule User do
        defstruct [
          :auth_a, :auth_b, :auth_c,
          :billing_a, :billing_b, :billing_c,
          :pref_a, :pref_b, :pref_c, :pref_d
        ]
      end
      """

      issues = Analyser.analyse_source(source)
      refute Enum.any?(issues, &(&1.rule == :large_defstruct))
    end

    test ":rule_opts threshold lower fires on a previously-clean struct" do
      # Below default scan_min_fields (10). Lower the threshold so
      # smaller structs are eligible, then drop min_clusters too.
      Application.put_env(:credence_rules, :rule_opts, %{
        large_defstruct: [scan_min_fields: 4, min_cluster_size: 2, min_clusters: 2]
      })

      source = ~S"""
      defmodule Tight do
        defstruct [:auth_a, :auth_b, :billing_a, :billing_b]
      end
      """

      issues = Analyser.analyse_source(source)
      assert Enum.any?(issues, &(&1.rule == :large_defstruct))
    end

    test "per-rule opts isolate to that rule (other rules unchanged)" do
      # Set a config for large_defstruct; check that an unrelated
      # rule (e.g. iosp_predicate_side_effects) still fires on its
      # own input.
      Application.put_env(:credence_rules, :rule_opts, %{
        large_defstruct: [scan_min_fields: 99]
      })

      source = ~S"""
      defmodule M do
        def active?(user), do: Repo.exists?(Subscription, user.id)
      end
      """

      issues = Analyser.analyse_source(source)
      assert Enum.any?(issues, &(&1.rule == :iosp_predicate_side_effects))
    end
  end

  describe "CredenceRules.rule_atom/1" do
    test "maps standard rule modules to atoms via underscore" do
      assert CredenceRules.rule_atom(CredenceRules.Pattern.LargeDefstruct) ==
               :large_defstruct
    end

    test "applies GenServer override (GenServer → genserver_*)" do
      assert CredenceRules.rule_atom(CredenceRules.Pattern.NoGenServerCallbackMissingImpl) ==
               :no_genserver_callback_missing_impl
    end

    test "applies cross-file override" do
      assert CredenceRules.rule_atom(CredenceRules.CrossFile.DuplicateBlock) ==
               :cross_file_duplicate_block
    end
  end

  describe "CredenceRules.rule_opts/1" do
    test "returns [] when no rule_opts configured" do
      assert CredenceRules.rule_opts(CredenceRules.Pattern.LargeDefstruct) == []
    end

    test "returns the configured opts for the rule's atom" do
      Application.put_env(:credence_rules, :rule_opts, %{
        large_defstruct: [min_clusters: 5]
      })

      assert CredenceRules.rule_opts(CredenceRules.Pattern.LargeDefstruct) ==
               [min_clusters: 5]
    end

    test "accepts a rule atom directly" do
      Application.put_env(:credence_rules, :rule_opts, %{
        large_defstruct: [min_clusters: 5]
      })

      assert CredenceRules.rule_opts(:large_defstruct) == [min_clusters: 5]
    end
  end
end
