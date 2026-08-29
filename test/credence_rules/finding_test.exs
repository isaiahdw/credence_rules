defmodule CredenceRules.FindingTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Finding

  describe "severity_for/1" do
    test "concurrency / safety default to :high" do
      assert Finding.severity_for(:rescue_catch_all) == :high
      assert Finding.severity_for(:no_send_self_in_init) == :high
    end

    test "advisory rules in concurrency cap at :medium" do
      # genserver_handle_call_explosion is concurrency (:high
      # category default) but advisory — should cap at :medium so
      # default `--strict` doesn't break backward compat.
      assert CredenceRules.advisory?(:genserver_handle_call_explosion)
      assert Finding.severity_for(:genserver_handle_call_explosion) == :medium
    end

    test "architecture / dry / idioms / test_quality default to :medium" do
      # Non-heuristic structural rules in these categories — e.g.
      # circular_module_dependency, wildcard_import — stay :medium.
      assert Finding.severity_for(:circular_module_dependency) == :medium
      assert Finding.severity_for(:wildcard_import) == :medium
      assert Finding.severity_for(:assert_enum_all) == :medium
    end

    test "documentation / naming default to :low" do
      # obvious_comment is heuristic AND documentation — both routes
      # cap at :low.
      assert Finding.severity_for(:obvious_comment) == :low
      # manager_service_module_name is heuristic AND naming — same.
      assert Finding.severity_for(:manager_service_module_name) == :low
      # def_is_prefix is :naming but NOT heuristic — :low by category.
      assert Finding.severity_for(:def_is_prefix) == :low
    end

    test "heuristic rules cap at :low regardless of category" do
      # large_defstruct is :architecture (:medium by category) but
      # heuristic — capped at :low.
      assert Finding.severity_for(:large_defstruct) == :low
      # repeated_subtree_in_module is :dry (:medium) but heuristic.
      assert Finding.severity_for(:repeated_subtree_in_module) == :low
      # vague_test_name is :test_quality (:medium) but heuristic.
      assert Finding.severity_for(:vague_test_name) == :low
      # fat_controller is :architecture (:medium) but heuristic AND
      # advisory — :low cap wins.
      assert Finding.severity_for(:fat_controller) == :low
    end

    test "unknown rule falls back through :idioms → :medium" do
      assert Finding.severity_for(:not_a_real_rule) == :medium
    end
  end

  describe "confidence_for/1" do
    test "structural rules default to :high" do
      assert Finding.confidence_for(:rescue_catch_all) == :high
      assert Finding.confidence_for(:no_send_self_in_init) == :high
    end

    test "heuristic rules return :medium" do
      assert Finding.confidence_for(:iosp_mixed_function) == :medium
      assert Finding.confidence_for(:repeated_subtree_in_module) == :medium
      assert Finding.confidence_for(:large_defstruct) == :medium
    end

    test "name-only rules return :low" do
      assert Finding.confidence_for(:vague_test_name) == :low
      assert Finding.confidence_for(:manager_service_module_name) == :low
    end
  end

  describe "gte?/2" do
    test "comparison across levels" do
      assert Finding.gte?(:high, :low)
      assert Finding.gte?(:high, :medium)
      assert Finding.gte?(:high, :high)
      assert Finding.gte?(:medium, :low)
      assert Finding.gte?(:medium, :medium)
      refute Finding.gte?(:medium, :high)
      refute Finding.gte?(:low, :medium)
      refute Finding.gte?(:low, :high)
    end
  end

  describe "strict_fail?/3" do
    test "fires when severity AND confidence both >= thresholds" do
      finding = %{rule: :r, severity: :high, confidence: :high}
      assert Finding.strict_fail?(finding, :high, :high)
      assert Finding.strict_fail?(finding, :medium, :medium)
      assert Finding.strict_fail?(finding, :low, :low)
    end

    test "doesn't fire when severity is below threshold" do
      finding = %{rule: :r, severity: :medium, confidence: :high}
      refute Finding.strict_fail?(finding, :high, :high)
      assert Finding.strict_fail?(finding, :medium, :high)
    end

    test "doesn't fire when confidence is below threshold" do
      finding = %{rule: :r, severity: :high, confidence: :medium}
      refute Finding.strict_fail?(finding, :high, :high)
      assert Finding.strict_fail?(finding, :high, :medium)
    end

    test "falls back to rule's category default when severity missing" do
      # rescue_catch_all is in :safety → severity:high default
      assert Finding.strict_fail?(%{rule: :rescue_catch_all}, :high, :high)

      # obvious_comment is heuristic → caps at :low
      refute Finding.strict_fail?(%{rule: :obvious_comment}, :high, :high)

      # fat_controller is architecture + heuristic → severity caps
      # at :low, confidence caps at :medium → doesn't trip the
      # :medium/:medium gate, only fires at :low/:medium and below.
      refute Finding.strict_fail?(%{rule: :fat_controller}, :high, :high)
      refute Finding.strict_fail?(%{rule: :fat_controller}, :medium, :medium)
      assert Finding.strict_fail?(%{rule: :fat_controller}, :low, :medium)

      # circular_module_dependency is architecture, NOT heuristic, NOT
      # advisory — keeps :medium category default and trips :medium gate.
      assert Finding.strict_fail?(
               %{rule: :circular_module_dependency},
               :medium,
               :high
             )
    end

    test "synthetic crash finding with explicit :high trips the gate" do
      # :analyse_crashed isn't in any category map. The synthetic
      # finding carries explicit severity:high + confidence:high so
      # it trips regardless of the rule atom being categorisable.
      crash = %{rule: :analyse_crashed, severity: :high, confidence: :high}
      assert Finding.strict_fail?(crash, :high, :high)

      cross_crash = %{
        rule: :cross_file_rule_crashed,
        severity: :high,
        confidence: :high
      }

      assert Finding.strict_fail?(cross_crash, :high, :high)
    end

    test "unknown rule with no explicit severity falls back to :medium/:high" do
      # Unknown rule atoms fall to :idioms (default category) →
      # severity:medium, confidence:high.
      mystery = %{rule: :not_a_real_rule}
      refute Finding.strict_fail?(mystery, :high, :high)
      assert Finding.strict_fail?(mystery, :medium, :high)
    end
  end

  describe "parse_level/1" do
    test "parses strings" do
      assert {:ok, :high} = Finding.parse_level("high")
      assert {:ok, :medium} = Finding.parse_level("medium")
      assert {:ok, :low} = Finding.parse_level("low")
    end

    test "accepts atoms" do
      assert {:ok, :high} = Finding.parse_level(:high)
      assert {:ok, :medium} = Finding.parse_level(:medium)
    end

    test "rejects garbage and nil" do
      assert :error = Finding.parse_level("HIGH")
      assert :error = Finding.parse_level("nope")
      assert :error = Finding.parse_level(nil)
      assert :error = Finding.parse_level(:nope)
    end
  end

  describe "fingerprint/1" do
    test "is stable across calls" do
      issue = %{rule: :large_defstruct, path: "lib/foo.ex", message: "abc"}
      assert Finding.fingerprint(issue) == Finding.fingerprint(issue)
    end

    test "differs when rule differs" do
      a = %{rule: :large_defstruct, path: "lib/foo.ex", message: "abc"}
      b = %{rule: :obvious_comment, path: "lib/foo.ex", message: "abc"}
      assert Finding.fingerprint(a) != Finding.fingerprint(b)
    end

    test "differs when path differs" do
      a = %{rule: :large_defstruct, path: "lib/foo.ex", message: "abc"}
      b = %{rule: :large_defstruct, path: "lib/bar.ex", message: "abc"}
      assert Finding.fingerprint(a) != Finding.fingerprint(b)
    end

    test "is invariant to whitespace" do
      # Whitespace collapses (normalize_message folds runs).
      a = %{rule: :r, path: "p", message: "abc def"}
      b = %{rule: :r, path: "p", message: "abc   def"}
      c = %{rule: :r, path: "p", message: "abc\n def"}
      assert Finding.fingerprint(a) == Finding.fingerprint(b)
      assert Finding.fingerprint(a) == Finding.fingerprint(c)
    end

    test "differs on trailing message content (no truncation)" do
      # SHA-256 over the full message — long cross-file messages
      # whose distinguishing data sits past a prefix (cycle members,
      # file lists) now produce distinct fingerprints. Previous
      # implementation truncated at 120 chars and collided.
      long_a = %{rule: :r, path: "p", message: String.duplicate("x", 200) <> "AAA"}
      long_b = %{rule: :r, path: "p", message: String.duplicate("x", 200) <> "BBB"}
      assert Finding.fingerprint(long_a) != Finding.fingerprint(long_b)
    end

    test "returns 16-char uppercase hex (64 bits of SHA-256)" do
      fp = Finding.fingerprint(%{rule: :x, path: "p", message: "m"})
      assert String.length(fp) == 16
      assert fp == String.upcase(fp)
      assert Regex.match?(~r/\A[0-9A-F]{16}\z/, fp)
    end

    test "folds in distinguishing :meta keys (source/target)" do
      a = %{
        rule: :forbidden_module_dependency,
        path: "lib/x.ex",
        message: "MyAppWeb.UserController references MyApp.Repo",
        meta: %{source: "MyAppWeb.UserController", target: "MyApp.Repo"}
      }

      b = %{a | meta: %{source: "MyAppWeb.UserController", target: "MyApp.Mailer"}}

      assert Finding.fingerprint(a) != Finding.fingerprint(b)
    end

    test "folds in :cycle for circular_dependency findings" do
      # `:cycle` is what the rule actually emits — verified against
      # circular_dependency.ex's build_issue/_. Earlier whitelist
      # used `:members` (matching the brief's prose), which the
      # rule doesn't emit — distinct cycles collided silently.
      a = %{
        rule: :circular_module_dependency,
        path: "lib/a.ex",
        message: "cycle",
        meta: %{cycle: ["A", "B", "C"]}
      }

      b = %{a | meta: %{cycle: ["A", "B", "D"]}}
      assert Finding.fingerprint(a) != Finding.fingerprint(b)
    end

    test "folds in :cluster_id for cross_file_duplicate_block" do
      # Distinct subtree shapes that happen to share size + occurrences
      # + file list (rare but possible) get distinct fingerprints via
      # cluster_id. Without it the fingerprints collide.
      a = %{
        rule: :cross_file_duplicate_block,
        path: "lib/a.ex",
        message: "Duplicated subtree (20 nodes, 2 occurrences across 2 files)",
        meta: %{files: ["lib/a.ex", "lib/b.ex"], size: 20, cluster_id: "HASH_AAAA"}
      }

      b = %{a | meta: Map.put(a.meta, :cluster_id, "HASH_BBBB")}
      assert Finding.fingerprint(a) != Finding.fingerprint(b)
    end

    test "handles nil message" do
      assert is_binary(Finding.fingerprint(%{rule: :r, path: "p", message: nil}))
    end
  end
end
