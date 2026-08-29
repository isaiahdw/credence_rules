defmodule CredenceRules.AstClassifyTest do
  use ExUnit.Case, async: true

  alias CredenceRules.AstClassify

  defp q(source), do: Code.string_to_quoted!(source)
  defp s(source), do: Sourceror.parse_string!(source)

  describe "pure_data?/1" do
    test "true for a flat numeric table row" do
      assert AstClassify.pure_data?(q("[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]"))
    end

    test "true for nested tuples and atoms" do
      assert AstClassify.pure_data?(q("{{:context, 1}, {:type, :foo}}"))
    end

    test "true for a keyword list of variable values" do
      assert AstClassify.pure_data?(q("[serial: serial, issuer: dn, not_after: ts]"))
    end

    test "true for signed numeric literals" do
      assert AstClassify.pure_data?(q("[-5, 3.0, -1]"))
    end

    test "true for maps and structs of data" do
      assert AstClassify.pure_data?(q("%{a: 1, b: var, c: :ok}"))
      assert AstClassify.pure_data?(q("%Range{first: a, last: b}"))
    end

    test "true through Sourceror's __block__ literal wrappers" do
      # Sourceror wraps literals and list literals in `__block__` nodes;
      # a data table parsed by Sourceror is a tree of those wrappers.
      assert AstClassify.pure_data?(s("[0, 1, 2, 3, 4, 5, 6, 7]"))
      assert AstClassify.pure_data?(s("[serial: serial, issuer: dn]"))
    end

    test "false when a function call is present" do
      refute AstClassify.pure_data?(q("Tlv.encode(:context, 1)"))
      refute AstClassify.pure_data?(q("[a: compute(x)]"))
    end

    test "false for operators and control-flow" do
      refute AstClassify.pure_data?(q("(flags &&& 1) != 0"))
      refute AstClassify.pure_data?(q("case x do nil -> d; v -> v end"))
    end
  end

  describe "references_module?/2" do
    test "true for an aliased non-stdlib call" do
      assert AstClassify.references_module?(q("MyApp.Store.load(id)"))
      assert AstClassify.references_module?(q("MyApp.Deep.Mod.run(x, y)"))
    end

    test "false for stdlib-only idioms" do
      refute AstClassify.references_module?(q("case Map.get(m, k) do nil -> d; v -> v end"))
      refute AstClassify.references_module?(q(~s|Logger.warning("[M] failed: \#{inspect(r)}")|))
      refute AstClassify.references_module?(q("try do x rescue _ -> :error end"))

      refute AstClassify.references_module?(
               q("x |> Enum.filter(& &1.active) |> Enum.map(& &1.name) |> Enum.sort()")
             )
    end

    test "false for local and bare Kernel calls" do
      refute AstClassify.references_module?(q("decode(x)"))
      refute AstClassify.references_module?(q("inspect(reason)"))
    end

    test "extra_stdlib_modules widens what counts as stdlib" do
      ast = q("MyApp.Store.load(id)")
      assert AstClassify.references_module?(ast)
      refute AstClassify.references_module?(ast, extra_stdlib_modules: [:MyApp])
    end

    test "a custom module shadowing a stdlib name still counts as stdlib by root" do
      # Root-segment matching: `Enum.x` is exempt; we don't try to tell
      # a project's own `Enum` apart from the standard one.
      refute AstClassify.references_module?(q("Enum.each(list, &run/1)"))
    end
  end

  describe "formatting_only?/2" do
    test "true for a Logger call with inspect interpolation" do
      assert AstClassify.formatting_only?(q(~s|Logger.error("open failed: \#{inspect(reason)}")|))
      assert AstClassify.formatting_only?(s(~s|Logger.error("open failed: \#{inspect(reason)}")|))
    end

    test "true for a log line followed by a data return" do
      assert AstClassify.formatting_only?(q(~s|(Logger.warning("[M] failed: \#{inspect(r)}"); {:stop, r})|))
    end

    test "true through a stdlib-only branch (Exception.message)" do
      assert AstClassify.formatting_only?(
               q("try do work() rescue e -> Logger.error(Exception.message(e)) end")
             )
    end

    test "false once the subtree also calls a project module" do
      refute AstClassify.formatting_only?(q(~s|(Audit.record(r); Logger.error("failed: \#{inspect(r)}"))|))
    end

    test "false when there's no formatting call at all" do
      refute AstClassify.formatting_only?(q("case Map.get(m, k) do nil -> parse(k); v -> v end"))
      refute AstClassify.formatting_only?(q("case :os.type() do {:unix, _} -> a(); _ -> b() end"))
    end

    test "true for Mix.shell() CLI output (with and without inspect)" do
      assert AstClassify.formatting_only?(q(~s|Mix.shell().info("done syncing records")|))
      assert AstClassify.formatting_only?(q(~s|Mix.shell().error("failed: \#{inspect(reason)}")|))
      assert AstClassify.formatting_only?(s(~s|Mix.shell().info("done")|))
    end

    test "true for OptionParser.parse CLI scaffolding" do
      assert AstClassify.formatting_only?(q("OptionParser.parse(argv, strict: [foo: :string])"))
      assert AstClassify.formatting_only?(q("OptionParser.parse!(argv, strict: [bar: :integer])"))
    end

    test "true for Integer.to_string hex formatting" do
      assert AstClassify.formatting_only?(q("Integer.to_string(value, 16)"))
    end

    test "false when CLI scaffolding also calls a project module" do
      refute AstClassify.formatting_only?(q("Mix.shell().info(MyApp.Report.render(data))"))
    end
  end

  describe "boilerplate_duplicate?/2" do
    test "data and logging idioms drop by default, kept behind their flags" do
      data = q("[serial: serial, issuer: dn, subject: dn, not_before: now]")
      log = q(~s|Logger.error("failed: \#{inspect(reason)} ctx=\#{inspect(ctx)}")|)

      assert AstClassify.boilerplate_duplicate?(data)
      refute AstClassify.boilerplate_duplicate?(data, flag_pure_data_duplicates: true)

      assert AstClassify.boilerplate_duplicate?(log)
      refute AstClassify.boilerplate_duplicate?(log, flag_logging_idioms: true)
    end
  end
end
