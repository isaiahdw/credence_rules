defmodule CredenceRules.OtpModuleTest do
  use ExUnit.Case, async: true

  alias CredenceRules.OtpModule

  defp body(source) do
    {:defmodule, _, [_alias, [do: body]]} = Code.string_to_quoted!(source)
    body
  end

  describe "uses_genserver?/1" do
    test "true for `use GenServer`" do
      assert OtpModule.uses_genserver?(body("defmodule M do\n  use GenServer\n  def go, do: :ok\nend"))
    end

    test "true for `use GenServer` with options" do
      assert OtpModule.uses_genserver?(body("defmodule M do\n  use GenServer, restart: :transient\nend"))
    end

    test "true for `use GenStage`" do
      assert OtpModule.uses_genserver?(body("defmodule M do\n  use GenStage\nend"))
    end

    test "false for a plain module" do
      refute OtpModule.uses_genserver?(body("defmodule M do\n  def handle_info(_, s), do: s\nend"))
    end

    test "false for an unrelated `use`" do
      refute OtpModule.uses_genserver?(body("defmodule M do\n  use Agent\nend"))
    end

    test "handles a single-statement body (no __block__)" do
      assert OtpModule.uses_genserver?(body("defmodule M do\n  use GenServer\nend"))
    end
  end
end
