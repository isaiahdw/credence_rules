defmodule CredenceRules.FindingAgentFieldsTest do
  # async: false — several tests mutate Application env, which is
  # per-VM-global. Serial avoids flakes from concurrent runs.
  use ExUnit.Case, async: false

  alias CredenceRules.Finding

  describe "hint_for/1" do
    test "returns the @hint string for rules that define it" do
      hint = Finding.hint_for(:single_stage_pipe)
      assert is_binary(hint)
      assert hint =~ "Before"
      assert hint =~ "After"
    end

    test "returns nil for rules that don't define @hint" do
      # Pick a rule that hasn't been audited yet — most rules
      # don't have hints. Pure idiomatic rules typically don't.
      assert Finding.hint_for(:not_a_real_rule) == nil
    end
  end

  describe "carve_outs_for/1" do
    test "returns the @carve_outs list for rules that define it" do
      list = Finding.carve_outs_for(:iosp_predicate_side_effects)
      assert is_list(list)
      assert length(list) > 0
      # Each entry is a string describing a known exemption case
      Enum.each(list, &assert(is_binary(&1)))
    end

    test "returns [] for rules that don't define @carve_outs" do
      assert Finding.carve_outs_for(:not_a_real_rule) == []
    end
  end

  describe "docs_url/1" do
    test "returns GitHub URL for a known rule module" do
      url = Finding.docs_url(:large_defstruct)
      assert is_binary(url)

      assert url ==
               "https://github.com/isaiahdw/credence_rules/blob/main/lib/credence_rules/pattern/large_defstruct.ex"
    end

    test "uses GenServer-override path for the genserver rules" do
      # `genserver_handle_call_explosion` → module
      # `CredenceRules.Pattern.GenserverHandleCallExplosion`
      # → path "lib/.../genserver_handle_call_explosion.ex".
      url = Finding.docs_url(:genserver_handle_call_explosion)
      assert url =~ "genserver_handle_call_explosion.ex"
    end

    test "uses cross-file-override path for cross-file rules" do
      url = Finding.docs_url(:circular_module_dependency)
      assert is_binary(url)
      assert url =~ "cross_file"
      assert url =~ "circular_dependency.ex"
    end

    test "returns nil for unknown rule atoms" do
      assert Finding.docs_url(:not_a_real_rule) == nil
    end

    test "honours :docs_url_base Application env" do
      original = Application.get_env(:credence_rules, :docs_url_base)

      try do
        Application.put_env(
          :credence_rules,
          :docs_url_base,
          "https://example.com/code/"
        )

        url = Finding.docs_url(:large_defstruct)
        assert String.starts_with?(url, "https://example.com/code/")
      after
        case original do
          nil -> Application.delete_env(:credence_rules, :docs_url_base)
          v -> Application.put_env(:credence_rules, :docs_url_base, v)
        end
      end
    end
  end

  describe "docs_fetch_command/1" do
    test "returns a ready-to-paste `gh api` command by default" do
      cmd = Finding.docs_fetch_command(:large_defstruct)

      assert cmd ==
               ~s|gh api repos/isaiahdw/credence_rules/contents/lib/credence_rules/pattern/large_defstruct.ex -H "Accept: application/vnd.github.raw"|
    end

    test "uses the same path resolution as docs_url" do
      # Both should target the same file.
      url = Finding.docs_url(:large_defstruct)
      cmd = Finding.docs_fetch_command(:large_defstruct)

      assert url =~ "lib/credence_rules/pattern/large_defstruct.ex"
      assert cmd =~ "lib/credence_rules/pattern/large_defstruct.ex"
    end

    test "uses correct path for GenServer-override and cross-file rules" do
      assert Finding.docs_fetch_command(:genserver_handle_call_explosion) =~
               "genserver_handle_call_explosion.ex"

      assert Finding.docs_fetch_command(:circular_module_dependency) =~
               "cross_file/circular_dependency.ex"
    end

    test "returns nil for unknown rule atoms" do
      assert Finding.docs_fetch_command(:not_a_real_rule) == nil
    end

    test "honours :docs_fetch_command_template Application env" do
      original = Application.get_env(:credence_rules, :docs_fetch_command_template)

      try do
        Application.put_env(
          :credence_rules,
          :docs_fetch_command_template,
          "curl -fsSL https://raw.githubusercontent.com/{repo_slug}/main/{path}"
        )

        cmd = Finding.docs_fetch_command(:large_defstruct)
        assert String.starts_with?(cmd, "curl -fsSL")
        assert cmd =~ "isaiahdw/credence_rules"
        assert cmd =~ "lib/credence_rules/pattern/large_defstruct.ex"
      after
        case original do
          nil -> Application.delete_env(:credence_rules, :docs_fetch_command_template)
          v -> Application.put_env(:credence_rules, :docs_fetch_command_template, v)
        end
      end
    end

    test "honours :repo_slug Application env (custom fork)" do
      original = Application.get_env(:credence_rules, :repo_slug)

      try do
        Application.put_env(:credence_rules, :repo_slug, "myorg/myfork")
        cmd = Finding.docs_fetch_command(:large_defstruct)
        assert cmd =~ "repos/myorg/myfork/contents"
      after
        case original do
          nil -> Application.delete_env(:credence_rules, :repo_slug)
          v -> Application.put_env(:credence_rules, :repo_slug, v)
        end
      end
    end

    test "derives repo_slug from :docs_url_base when :repo_slug not set" do
      original_slug = Application.get_env(:credence_rules, :repo_slug)
      original_base = Application.get_env(:credence_rules, :docs_url_base)

      try do
        Application.delete_env(:credence_rules, :repo_slug)

        Application.put_env(
          :credence_rules,
          :docs_url_base,
          "https://github.com/derived/from-base/blob/main/"
        )

        cmd = Finding.docs_fetch_command(:large_defstruct)
        assert cmd =~ "repos/derived/from-base/contents"
      after
        case original_slug do
          nil -> :ok
          v -> Application.put_env(:credence_rules, :repo_slug, v)
        end

        case original_base do
          nil -> Application.delete_env(:credence_rules, :docs_url_base)
          v -> Application.put_env(:credence_rules, :docs_url_base, v)
        end
      end
    end
  end
end
