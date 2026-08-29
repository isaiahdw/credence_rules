defmodule CredenceRules.Pattern.GenServerReceiveBlockTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.GenServerReceiveBlock

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    GenServerReceiveBlock.check(ast, [])
  end

  describe "check/2 — flagged" do
    test "flags `receive do … end` in a use-GenServer module" do
      source = ~S"""
      defmodule Worker do
        use GenServer

        def handle_call(:wait, _from, state) do
          receive do
            {:reply, x} -> {:reply, x, state}
          after
            5_000 -> {:reply, :timeout, state}
          end
        end
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :genserver_receive_block
    end

    test "flags receive in a helper function inside the module" do
      source = ~S"""
      defmodule Worker do
        use GenServer

        defp wait_for_reply do
          receive do
            x -> x
          end
        end
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag receive in a plain module" do
      source = ~S"""
      defmodule OneShot do
        def loop do
          receive do
            x -> handle(x)
          end
        end
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag a use-GenServer module without receive" do
      source = ~S"""
      defmodule Cache do
        use GenServer
        def handle_call(:get, _from, state), do: {:reply, state, state}
      end
      """

      assert analyze(source) == []
    end
  end
end
