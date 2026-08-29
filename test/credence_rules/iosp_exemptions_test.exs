defmodule CredenceRules.IospExemptionsTest do
  use ExUnit.Case, async: true

  alias CredenceRules.IospExemptions

  defp parse(source), do: Code.string_to_quoted!(source)

  describe "mix_task_module?/1" do
    test "true for `defmodule Mix.Tasks.Foo`" do
      assert IospExemptions.mix_task_module?(parse("defmodule Mix.Tasks.Foo do\nend"))
    end

    test "true for nested-namespace Mix.Tasks.* (Mix.Tasks.MyApp.Sync)" do
      assert IospExemptions.mix_task_module?(parse("defmodule Mix.Tasks.MyApp.Sync do\nend"))
    end

    test "false for regular module" do
      refute IospExemptions.mix_task_module?(parse("defmodule MyApp.Foo do\nend"))
    end

    test "false for module that happens to contain 'Mix' in its name" do
      refute IospExemptions.mix_task_module?(parse("defmodule MyAppMix do\nend"))
      refute IospExemptions.mix_task_module?(parse("defmodule MyApp.MixHelper do\nend"))
    end

    test "false for non-defmodule code" do
      refute IospExemptions.mix_task_module?(parse("x = 1"))
    end
  end

  describe "process_introspection?/1" do
    test "true for Process.alive?(pid)" do
      assert IospExemptions.process_introspection?(parse("Process.alive?(pid)"))
    end

    test "true for Process.info(pid)" do
      assert IospExemptions.process_introspection?(parse("Process.info(pid)"))
    end

    test "true for Process.info(pid, :registered_name)" do
      assert IospExemptions.process_introspection?(parse("Process.info(pid, :registered_name)"))
    end

    test "true for Process.whereis(name)" do
      assert IospExemptions.process_introspection?(parse("Process.whereis(:my_server)"))
    end

    test "true for :erlang.is_process_alive(pid)" do
      assert IospExemptions.process_introspection?(parse(":erlang.is_process_alive(pid)"))
    end

    test "true for Port.info(port)" do
      assert IospExemptions.process_introspection?(parse("Port.info(p)"))
    end

    test "true for custom-aliased MyApp.Process.alive? (trailing segment)" do
      assert IospExemptions.process_introspection?(parse("MyApp.Process.alive?(pid)"))
    end

    test "true when introspection is composed with other calls" do
      # Real shape from the brief — Process.info composed with the
      # rest of the function body.
      source = ~S"""
      case Process.info(server, :registered_name) do
        {:registered_name, name} -> name
        _ -> server
      end
      """

      assert IospExemptions.process_introspection?(parse(source))
    end

    test "false for body with no introspection" do
      refute IospExemptions.process_introspection?(parse("Repo.get(User, id)"))
      refute IospExemptions.process_introspection?(parse("String.downcase(s)"))
    end

    test "false for Process.send/2 (not introspection)" do
      refute IospExemptions.process_introspection?(parse("Process.send(pid, :ping, [])"))
    end
  end

  describe "introspection_call?/2 (per-call)" do
    test "matches Process.alive?/info/whereis" do
      assert IospExemptions.introspection_call?([:Process], :alive?)
      assert IospExemptions.introspection_call?([:Process], :info)
      assert IospExemptions.introspection_call?([:Process], :whereis)
    end

    test "matches Port.info only (Port.alive? etc. don't exist)" do
      assert IospExemptions.introspection_call?([:Port], :info)
      refute IospExemptions.introspection_call?([:Port], :alive?)
      refute IospExemptions.introspection_call?([:Port], :open)
    end

    test "matches trailing-segment aliases (MyApp.Process.alive?)" do
      assert IospExemptions.introspection_call?([:MyApp, :Process], :alive?)
      assert IospExemptions.introspection_call?([:Foo, :Bar, :Process], :info)
    end

    test "doesn't match Process.send / Process.exit (real side effects)" do
      refute IospExemptions.introspection_call?([:Process], :send)
      refute IospExemptions.introspection_call?([:Process], :exit)
      refute IospExemptions.introspection_call?([:Process], :flag)
    end

    test "doesn't match other modules" do
      refute IospExemptions.introspection_call?([:GenServer], :call)
      refute IospExemptions.introspection_call?([:Repo], :exists?)
    end
  end

  describe "introspection_erlang_call?/2 (per-call, bare-atom Erlang)" do
    test "matches :erlang.is_process_alive only" do
      assert IospExemptions.introspection_erlang_call?(:erlang, :is_process_alive)
      refute IospExemptions.introspection_erlang_call?(:erlang, :send)
      refute IospExemptions.introspection_erlang_call?(:erlang, :exit)
    end

    test "matches Sourceror-wrapped :erlang" do
      assert IospExemptions.introspection_erlang_call?(
               {:__block__, [], [:erlang]},
               :is_process_alive
             )
    end

    test "doesn't match other Erlang modules" do
      refute IospExemptions.introspection_erlang_call?(:ets, :lookup)
      refute IospExemptions.introspection_erlang_call?(:persistent_term, :get)
    end
  end
end
