defmodule CredenceRules.SuppressionTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Suppression

  describe "directives/1" do
    test "parses a trailing directive with a reason" do
      assert [%{line: 1, rules: ["foo"], reason: "clearer flat"}] =
               Suppression.directives("a = b # credence:foo — clearer flat")
    end

    test "parses a directive on its own line" do
      assert [%{line: 1, rules: ["bar"], reason: "bounded list"}] =
               Suppression.directives("# credence:bar — bounded list")
    end

    test "comma-separates several rules" do
      assert [%{rules: ["x", "y", "z"]}] =
               Suppression.directives("# credence:x,y,z — many")
    end

    test "`*` and `all` mean every rule" do
      assert [%{rules: :all}] = Suppression.directives("# credence:* — everything")
      assert [%{rules: :all}] = Suppression.directives("# credence:all — everything")
    end

    test "a missing reason yields nil" do
      assert [%{rules: ["foo"], reason: nil}] = Suppression.directives("# credence:foo")
    end

    test "tolerates `:`, `-`, and em-dash separators before the reason" do
      for sep <- ["—", "-", ":", "  —  "] do
        assert [%{reason: "why"}] = Suppression.directives("# credence:foo #{sep}why")
      end
    end

    test "ignores comments that aren't credence directives" do
      assert [] = Suppression.directives("# just a normal comment")
    end

    test "ignores a credence sequence inside a string literal" do
      assert [] = Suppression.directives(~S|x = "# credence:foo not a comment"|)
    end
  end

  describe "filter/2 — line coverage" do
    test "a trailing directive suppresses a finding on its own line" do
      src = "a # credence:foo — ok"
      {kept, _} = Suppression.filter([%{rule: :foo, line: 1}], src)
      assert kept == []
    end

    test "a directive on the line above suppresses the finding below it" do
      src = "# credence:foo — ok\nb\n"
      {kept, _} = Suppression.filter([%{rule: :foo, line: 2}], src)
      assert kept == []
    end

    test "does not reach two lines down" do
      src = "# credence:foo — ok\n\nb\n"
      {kept, _} = Suppression.filter([%{rule: :foo, line: 3}], src)
      assert kept == [%{rule: :foo, line: 3}]
    end
  end

  describe "filter/2 — rule matching" do
    test "only suppresses the named rule" do
      src = "a # credence:foo — ok"
      {kept, _} = Suppression.filter([%{rule: :foo, line: 1}, %{rule: :bar, line: 1}], src)
      assert kept == [%{rule: :bar, line: 1}]
    end

    test "`*` suppresses every rule on the line" do
      src = "a # credence:* — ok"
      {kept, _} = Suppression.filter([%{rule: :foo, line: 1}, %{rule: :bar, line: 1}], src)
      assert kept == []
    end

    test "a finding with no line is never line-suppressed" do
      src = "# credence:* — ok"
      cross_file = %{rule: :module_instability, line: nil}
      {kept, _} = Suppression.filter([cross_file], src)
      assert kept == [cross_file]
    end
  end

  describe "filter/2 — reasonless directives" do
    test "returns reasonless directives separately" do
      src = "a # credence:foo"
      {kept, reasonless} = Suppression.filter([%{rule: :foo, line: 1}], src)
      assert kept == []
      assert [%{line: 1, rules: ["foo"], reason: nil}] = reasonless
    end

    test "a reasoned directive is not reported" do
      src = "a # credence:foo — documented"
      {_, reasonless} = Suppression.filter([%{rule: :foo, line: 1}], src)
      assert reasonless == []
    end
  end

  describe "directives/1 — file scope" do
    test "credence-file: parses as :file scope" do
      assert [%{scope: :file, rules: ["hub_module"], reason: "shared contract"}] =
               Suppression.directives("# credence-file:hub_module — shared contract")
    end

    test "credence: parses as :line scope" do
      assert [%{scope: :line, rules: ["foo"]}] = Suppression.directives("# credence:foo — r")
    end
  end

  describe "filter_cross_file/2 — file-scope suppression" do
    test "a credence-file directive drops a line-less finding" do
      src =
        "# credence-file:hub_module — Rule behaviour is imported everywhere by design\ndefmodule M do\nend\n"

      finding = %{rule: :hub_module, line: nil, path: "lib/m.ex"}
      assert [] = Suppression.filter_cross_file([finding], %{"lib/m.ex" => src})
    end

    test "a line-scope credence directive does NOT reach a line-less finding" do
      src = "# credence:hub_module — wrong scope for a line-less finding\ndefmodule M do\nend\n"
      finding = %{rule: :hub_module, line: nil, path: "lib/m.ex"}
      assert [^finding] = Suppression.filter_cross_file([finding], %{"lib/m.ex" => src})
    end

    test "a file directive for a different rule leaves the finding" do
      src = "# credence-file:cross_file_duplicate_block — ok\ndefmodule M do\nend\n"
      finding = %{rule: :hub_module, line: nil, path: "lib/m.ex"}
      assert [^finding] = Suppression.filter_cross_file([finding], %{"lib/m.ex" => src})
    end

    test "`*` at file scope drops every line-less finding in the file" do
      src = "# credence-file:* — blanket exception, documented\ndefmodule M do\nend\n"
      finding = %{rule: :hub_module, line: nil, path: "lib/m.ex"}
      assert [] = Suppression.filter_cross_file([finding], %{"lib/m.ex" => src})
    end

    test "leaves a finding whose file has no source available" do
      finding = %{rule: :hub_module, line: nil, path: "lib/missing.ex"}
      assert [^finding] = Suppression.filter_cross_file([finding], %{})
    end
  end

  describe "filter/2 — file scope reaches line-bearing findings anywhere" do
    test "a credence-file directive drops a line-bearing finding regardless of line" do
      src = "# credence-file:repeated_subtree_in_function — structural\ndefmodule M do\nend\n"
      {kept, _} = Suppression.filter([%{rule: :repeated_subtree_in_function, line: 134}], src)
      assert kept == []
    end

    test "a credence-file directive leaves other rules in place" do
      src = "# credence-file:repeated_subtree_in_function — structural\ndefmodule M do\nend\n"
      {kept, _} = Suppression.filter([%{rule: :iosp_mixed_function, line: 134}], src)
      assert kept == [%{rule: :iosp_mixed_function, line: 134}]
    end

    test "a reasonless credence-file directive is reported (with the file token)" do
      src = "# credence-file:repeated_subtree_in_function\ndefmodule M do\nend\n"
      {_, reasonless} = Suppression.filter([%{rule: :repeated_subtree_in_function, line: 2}], src)
      assert [%{scope: :file, rules: ["repeated_subtree_in_function"], reason: nil}] = reasonless
    end
  end

  describe "render_rules/1" do
    test "renders :all as *" do
      assert Suppression.render_rules(:all) == "*"
    end

    test "joins a rule list with commas" do
      assert Suppression.render_rules(["a", "b"]) == "a,b"
    end
  end
end
