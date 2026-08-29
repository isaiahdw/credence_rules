defmodule CredenceRules.Pattern.BoilerplateDocParamsTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.BoilerplateDocParams

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    BoilerplateDocParams.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags `## Parameters` section listing conn + the connection struct" do
      source = ~S'''
      defmodule MyApp.Controller do
        @doc """
        Renders the index page.

        ## Parameters

        - conn: The connection struct
        - params: A map of parameters
        """
        def index(_conn, _params), do: :ok
      end
      '''

      assert [issue] = analyze(source)
      assert issue.rule == :boilerplate_doc_params
      assert issue.message =~ "## Parameters"
    end

    test "flags `## Args` heading variant" do
      source = ~S'''
      defmodule MyApp.LV do
        @doc """
        Mounts the LiveView.

        ## Args

        - socket: The socket
        """
        def mount(_p, _s, socket), do: {:ok, socket}
      end
      '''

      assert [_] = analyze(source)
    end

    test "flags backtick-wrapped param names" do
      source = ~S'''
      defmodule MyApp.C do
        @doc """
        Index page.

        ## Parameters

        - `assigns`: The assigns map
        """
        def index(assigns), do: assigns
      end
      '''

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "ignores docs that document real constraints" do
      source = ~S'''
      defmodule MyApp.C do
        @doc """
        Renders the index page.

        ## Parameters

        - params: Must include `"page"` (integer >= 1) and optionally
          `"per_page"` (default 20, max 100).
        """
        def index(_params), do: :ok
      end
      '''

      assert [] = analyze(source)
    end

    test "ignores docs with no `## Parameters` heading at all" do
      source = ~S'''
      defmodule MyApp.C do
        @doc "Renders the index page, paginated."
        def index(_params), do: :ok
      end
      '''

      assert [] = analyze(source)
    end

    test "ignores `## Parameters` with non-conn param names" do
      source = ~S'''
      defmodule MyApp.Pricing do
        @doc """
        Computes the discount.

        ## Parameters

        - cart: The cart struct
        - coupon: The coupon code
        """
        def compute(_cart, _coupon), do: :ok
      end
      '''

      assert [] = analyze(source)
    end

    test "ignores `@doc false`" do
      source = ~S"""
      defmodule MyApp.X do
        @doc false
        def internal(_conn, _params), do: :ok
      end
      """

      assert [] = analyze(source)
    end
  end
end
