defmodule CredenceRules.Pattern.FatControllerTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.FatController

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    FatController.check(ast, source: source)
  end

  defp analyze_sourceror(source) do
    {:ok, ast} = Sourceror.parse_string(source)
    FatController.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags controller with non-action public def" do
      source = ~S"""
      defmodule MyAppWeb.UserController do
        use Phoenix.Controller

        def index(conn, _params), do: render(conn, "index.html")
        def calculate_score(user), do: user.name |> String.length()
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :fat_controller
      assert issue.message =~ "calculate_score/1"
    end

    test "flags `use MyAppWeb, :controller` shape" do
      source = ~S"""
      defmodule MyAppWeb.PageController do
        use MyAppWeb, :controller

        def index(conn, _params), do: render(conn, "index.html")
        def list_active_users, do: []
      end
      """

      assert [_] = analyze(source)
    end

    test "lists multiple non-action functions" do
      source = ~S"""
      defmodule MyAppWeb.UserController do
        use Phoenix.Controller

        def index(conn, _params), do: render(conn, "index.html")
        def helper_a(x), do: x
        def helper_c, do: nil
        def helper_d(a, b, c), do: [a, b, c]
        def helper_e(a, b, c, d), do: [a, b, c, d]
      end
      """

      assert [issue] = analyze(source)
      # 4 non-action defs (helper_b would be arity-2 and look like an
      # action, so it's excluded). Sample shows first 3 + "+1 more".
      assert issue.message =~ "+1 more"
    end

    test "arity-2 functions look like actions even with non-action names" do
      # Action recognition is shape-based, not name-based. `def
      # helper(conn, params)` would be treated as an action — accepted
      # tradeoff because router-validation is out of scope.
      source = ~S"""
      defmodule MyAppWeb.UserController do
        use Phoenix.Controller

        def index(conn, _params), do: render(conn, "index.html")
        def helper(x, y), do: x + y
      end
      """

      assert [] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "ignores controller with only actions" do
      source = ~S"""
      defmodule MyAppWeb.UserController do
        use Phoenix.Controller

        def index(conn, _params), do: render(conn, "index.html")
        def show(conn, %{"id" => id}), do: render(conn, "show.html", id: id)
        def create(conn, params), do: redirect(conn, to: "/")
        def update(conn, params), do: render(conn, "show.html")
        def delete(conn, params), do: redirect(conn, to: "/")
      end
      """

      assert [] = analyze(source)
    end

    test "ignores private helpers (defp is allowed)" do
      source = ~S"""
      defmodule MyAppWeb.UserController do
        use Phoenix.Controller

        def index(conn, _params), do: render(conn, "index.html", users: load_users())

        defp load_users, do: [1, 2, 3]
        defp render_with_extras(conn, template, extras), do: conn
      end
      """

      assert [] = analyze(source)
    end

    test "ignores non-controller modules" do
      source = ~S"""
      defmodule MyApp.Accounts do
        def calculate_score(user), do: user
        def can_publish?(user), do: true
      end
      """

      assert [] = analyze(source)
    end

    test "ignores a `use` whose target doesn't end in Controller" do
      source = ~S"""
      defmodule MyApp.Foo do
        use GenServer

        def init(_), do: {:ok, %{}}
        def calculate(x), do: x
      end
      """

      assert [] = analyze(source)
    end
  end

  describe "check/2 — Sourceror-parsed (production path)" do
    test "still flags fat controllers under Sourceror parse" do
      source = ~S"""
      defmodule MyAppWeb.UserController do
        use Phoenix.Controller

        def index(conn, _params), do: render(conn, "index.html")
        def helper(x), do: x
      end
      """

      assert [_] = analyze_sourceror(source)
    end

    test "still recognises `use MyAppWeb, :controller` under Sourceror parse" do
      source = ~S"""
      defmodule MyAppWeb.PageController do
        use MyAppWeb, :controller

        def index(conn, _params), do: render(conn, "index.html")
        def helper(x), do: x
      end
      """

      assert [_] = analyze_sourceror(source)
    end
  end
end
