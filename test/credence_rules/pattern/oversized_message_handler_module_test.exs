defmodule CredenceRules.Pattern.OversizedMessageHandlerModuleTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.OversizedMessageHandlerModule

  defp analyze(source, opts \\ []) do
    {:ok, ast} = Code.string_to_quoted(source)
    OversizedMessageHandlerModule.check(ast, [source: source] ++ opts)
  end

  defp module_with_handlers(handler_name, arity, count) do
    args =
      case arity do
        2 -> "msg_NN, state"
        3 -> "{:msg_NN, x}, _from, state"
        4 -> "msg_NN, _content, _state_name, data"
      end

    handlers =
      1..count
      |> Enum.map(fn n ->
        "def #{handler_name}(#{String.replace(args, "NN", to_string(n))}), do: :ok"
      end)
      |> Enum.join("\n  ")

    "defmodule Bloat do\n  #{handlers}\nend"
  end

  describe "check/2 — flagged" do
    test "flags >20 handle_info clauses by default" do
      assert [issue] = analyze(module_with_handlers("handle_info", 2, 25))
      assert issue.rule == :oversized_message_handler_module
      assert issue.meta.handler_clauses == 25
      assert issue.meta.breakdown.handle_info == 25
    end

    test "sums handle_info + handle_call + handle_cast + handle_event" do
      source = """
      defmodule Bloat do
        #{for n <- 1..7, do: "def handle_info(#{n}, s), do: s\n  "}
        #{for n <- 1..6, do: "def handle_call(#{n}, _, s), do: {:reply, s, s}\n  "}
        #{for n <- 1..5, do: "def handle_cast(#{n}, s), do: {:noreply, s}\n  "}
        #{for n <- 1..5, do: "def handle_event(#{n}, _, _, d), do: d\n  "}
      end
      """

      # 7 + 6 + 5 + 5 = 23 > 20
      assert [issue] = analyze(source)
      assert issue.meta.handler_clauses == 23

      assert issue.meta.breakdown == %{
               handle_info: 7,
               handle_call: 6,
               handle_cast: 5,
               handle_event: 5
             }
    end

    test "fires on :gen_statem module (handle_event/4 only) — the motivating case" do
      assert [issue] = analyze(module_with_handlers("handle_event", 4, 30))
      assert issue.meta.breakdown.handle_event == 30
      assert issue.message =~ "handle_event=30"
    end

    test "fires regardless of `use` macro (no GenServer required)" do
      handlers =
        1..25
        |> Enum.map(fn n -> "def handle_info(#{n}, s), do: s" end)
        |> Enum.join("\n  ")

      # No `use GenServer`, no `@behaviour` — plain module with handler-named
      # functions. This is the gap the sibling GenServer-only rule misses.
      source = "defmodule Plain do\n  #{handlers}\nend"
      assert [_] = analyze(source)
    end

    test "honours custom :max_handlers threshold" do
      assert [_] = analyze(module_with_handlers("handle_info", 2, 6), max_handlers: 5)
    end

    test "message names the source line count when source is provided" do
      source = module_with_handlers("handle_info", 2, 25)
      assert [issue] = analyze(source)
      lines = source |> String.split("\n") |> length()
      assert issue.message =~ "#{lines}-line module"
      assert issue.meta.line_count == lines
    end
  end

  describe "check/2 — not flagged" do
    test "ignores module with fewer handlers" do
      assert [] = analyze(module_with_handlers("handle_info", 2, 15))
      assert [] = analyze(module_with_handlers("handle_info", 2, 20))
    end

    test "ignores ExUnit.Case test modules" do
      handlers =
        1..30
        |> Enum.map(fn n -> "def handle_info(#{n}, s), do: s" end)
        |> Enum.join("\n  ")

      source = """
      defmodule MyTest do
        use ExUnit.Case
        #{handlers}
      end
      """

      assert [] = analyze(source)
    end

    test "ignores ExUnit.CaseTemplate modules" do
      handlers =
        1..30
        |> Enum.map(fn n -> "def handle_call(#{n}, _, s), do: {:reply, s, s}" end)
        |> Enum.join("\n  ")

      source = """
      defmodule MyTest.Case do
        use ExUnit.CaseTemplate
        #{handlers}
      end
      """

      assert [] = analyze(source)
    end

    test "honours :exclude_modules opt" do
      source = module_with_handlers("handle_info", 2, 25)

      assert [_] = analyze(source)
      assert [] = analyze(source, exclude_modules: [Bloat])
    end

    test "ignores non-handler functions of the same shape" do
      # `do_thing/2` matches handle_call's arity but isn't a handler name
      handlers =
        1..30
        |> Enum.map(fn n -> "def do_thing_#{n}(_a, _b), do: :ok" end)
        |> Enum.join("\n  ")

      source = "defmodule Plain do\n  #{handlers}\nend"
      assert [] = analyze(source)
    end

    test "counts each clause head, not multi-clause def bodies as one" do
      # 30 separate `def handle_info` heads — each counts as one.
      assert [issue] = analyze(module_with_handlers("handle_info", 2, 30))
      assert issue.meta.handler_clauses == 30
    end
  end

  describe "check/2 — edge cases" do
    test "empty module" do
      assert [] = analyze("defmodule M do\nend")
    end

    test "guarded handle_info clauses are counted" do
      source = """
      defmodule Bloat do
        def handle_info(msg, s) when is_atom(msg), do: s
        #{for n <- 1..24, do: "def handle_info(#{n}, s), do: s\n  "}
      end
      """

      # 1 guarded + 24 plain = 25 > 20
      assert [issue] = analyze(source)
      assert issue.meta.handler_clauses == 25
    end

    test "handles missing :source opt gracefully (no line_count)" do
      {:ok, ast} = Code.string_to_quoted(module_with_handlers("handle_info", 2, 25))
      [issue] = OversizedMessageHandlerModule.check(ast, [])
      assert issue.meta.line_count == nil
      refute issue.message =~ "-line module"
    end
  end
end
