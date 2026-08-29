defmodule CredenceRules.Pattern.DocFalseOnPublicFunctionTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.DocFalseOnPublicFunction

  defp analyze(source, opts \\ []) do
    {:ok, ast} = Code.string_to_quoted(source)
    DocFalseOnPublicFunction.check(ast, [source: source] ++ opts)
  end

  describe "check/2 — flagged" do
    test "flags 2+ @doc false on public defs in one module" do
      source = ~S"""
      defmodule MyApp.C do
        @doc false
        def index(_), do: :ok

        @doc false
        def show(_), do: :ok
      end
      """

      issues = analyze(source)
      assert length(issues) == 2
      assert Enum.all?(issues, &(&1.rule == :doc_false_on_public_function))
    end

    test "flags 3 hits when present" do
      source = ~S"""
      defmodule MyApp.C do
        @doc false
        def a, do: :ok

        @doc false
        def b, do: :ok

        @doc false
        def c, do: :ok
      end
      """

      assert length(analyze(source)) == 3
    end

    test "reports the function name, not :when, for guarded heads" do
      source = ~S"""
      defmodule MyApp.C do
        @doc false
        def index(x) when is_list(x), do: :ok

        @doc false
        def show(x) when is_map(x), do: :ok
      end
      """

      assert [%{meta: %{name: :index}}, %{meta: %{name: :show}}] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag a single @doc false (below threshold)" do
      source = ~S"""
      defmodule MyApp.C do
        @doc false
        def internal, do: :ok

        def public, do: :ok
      end
      """

      assert [] = analyze(source)
    end

    test "does NOT flag @doc false on @impl true callbacks (OTP)" do
      source = ~S"""
      defmodule MyApp.Server do
        use GenServer

        @doc false
        @impl true
        def init(state), do: {:ok, state}

        @doc false
        @impl true
        def handle_call(_, _, s), do: {:reply, :ok, s}
      end
      """

      assert [] = analyze(source)
    end

    test "does NOT flag @doc false on exempt OTP names without @impl" do
      source = ~S"""
      defmodule MyApp.Server do
        @doc false
        def init(state), do: {:ok, state}

        @doc false
        def handle_info(_msg, s), do: {:noreply, s}
      end
      """

      assert [] = analyze(source)
    end

    test "does NOT flag @doc false on exempt OTP names with guards" do
      source = ~S"""
      defmodule MyApp.Server do
        @doc false
        def handle_call(msg, _from, s) when is_atom(msg), do: {:reply, :ok, s}

        @doc false
        def handle_info(msg, s) when is_tuple(msg), do: {:noreply, s}
      end
      """

      assert [] = analyze(source)
    end

    test "does NOT flag @doc false on dunder functions" do
      source = ~S"""
      defmodule MyApp.Macros do
        @doc false
        def __using__(_opts), do: nil

        @doc false
        def __before_compile__(_env), do: nil
      end
      """

      assert [] = analyze(source)
    end

    test "does NOT flag @doc false on private functions" do
      source = ~S"""
      defmodule MyApp.M do
        @doc false
        defp helper, do: :ok

        @doc false
        defp helper2, do: :ok
      end
      """

      assert [] = analyze(source)
    end

    test "respects min_count override" do
      source = ~S"""
      defmodule MyApp.C do
        @doc false
        def a, do: :ok

        @doc false
        def b, do: :ok
      end
      """

      assert [] = analyze(source, min_count: 3)
    end
  end
end
