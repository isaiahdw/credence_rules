defmodule CredenceRules.Pattern.ManagerServiceModuleNameTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.ManagerServiceModuleName

  defp analyze(source, opts \\ []) do
    {:ok, ast} = Code.string_to_quoted(source)
    ManagerServiceModuleName.check(ast, opts)
  end

  describe "check/2 — flagged" do
    test "flags Foo.Manager" do
      assert [issue] =
               analyze(~S"""
               defmodule MyApp.UserManager do
               end
               """)

      assert issue.rule == :manager_service_module_name
      assert issue.message =~ "Manager"
    end

    test "flags Foo.Service, Foo.Helper(s), Foo.Util(s), Foo.Handler, Foo.Common, Foo.Shared" do
      for suffix <- ~w(Service Helper Helpers Util Utils Handler Common Shared) do
        source = "defmodule MyApp.Things#{suffix} do\nend\n"
        assert [issue] = analyze(source), "expected to flag suffix `#{suffix}`"
        assert issue.message =~ suffix
      end
    end

    test "flags deeply nested module name" do
      assert [_] =
               analyze(~S"""
               defmodule MyApp.Auth.PermissionsManager do
               end
               """)
    end
  end

  describe "check/2 — not flagged" do
    test "does NOT flag an allowed module" do
      source = ~S"""
      defmodule Legacy.UserManager do
      end
      """

      assert analyze(source, allowed_modules: [Legacy.UserManager]) == []
    end

    test "does NOT flag a behaviour module (defines @callback)" do
      source = ~S"""
      defmodule MyApp.Interaction.CommandHandler do
        @callback handle(map()) :: :ok | {:error, term()}
      end
      """

      assert analyze(source) == []
    end

    test "does NOT flag a behaviour module defining @macrocallback" do
      source = ~S"""
      defmodule MyApp.PluginService do
        @macrocallback init(opts :: term()) :: Macro.t()
      end
      """

      assert analyze(source) == []
    end

    test "still flags a suffixed module with no callback declaration" do
      assert [_] = analyze("defmodule FooHandler do\n  def handle(x), do: x\nend\n")
    end

    test "does NOT flag idiomatic noun names" do
      assert analyze("defmodule MyApp.User do\nend\n") == []
      assert analyze("defmodule MyApp.Auction.Bid do\nend\n") == []
    end

    test "does NOT flag idiomatic verb names" do
      assert analyze("defmodule MyApp.Encode do\nend\n") == []
      assert analyze("defmodule MyApp.Render do\nend\n") == []
    end

    test "respects custom forbidden_suffixes" do
      # Override the default list: only `Helpers` is forbidden here.
      assert analyze("defmodule MyApp.UserManager do\nend\n",
               forbidden_suffixes: ["Helpers"]
             ) == []

      assert [_] =
               analyze("defmodule MyApp.UserHelpers do\nend\n",
                 forbidden_suffixes: ["Helpers"]
               )
    end
  end
end
