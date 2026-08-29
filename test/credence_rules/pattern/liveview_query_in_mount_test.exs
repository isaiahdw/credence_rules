defmodule CredenceRules.Pattern.LiveviewQueryInMountTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.LiveviewQueryInMount

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    LiveviewQueryInMount.check(ast, source: source)
  end

  defp analyze_sourceror(source) do
    {:ok, ast} = Sourceror.parse_string(source)
    LiveviewQueryInMount.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags unguarded Repo call in mount/3" do
      source = ~S"""
      defmodule MyAppWeb.UserLive do
        use Phoenix.LiveView

        def mount(_params, _session, socket) do
          users = MyApp.Repo.all(MyApp.User)
          {:ok, assign(socket, users: users)}
        end
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :liveview_query_in_mount
      assert issue.message =~ "MyApp.Repo.all"
    end

    test "flags HTTP client calls (Req.get etc.)" do
      source = ~S"""
      defmodule MyAppWeb.WeatherLive do
        use Phoenix.LiveView

        def mount(_params, _session, socket) do
          {:ok, %{body: data}} = Req.get("https://api/weather")
          {:ok, assign(socket, data: data)}
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "flags `use MyAppWeb, :live_view` modules" do
      source = ~S"""
      defmodule MyAppWeb.UserLive do
        use MyAppWeb, :live_view

        def mount(_params, _session, socket) do
          users = MyApp.Repo.all(MyApp.User)
          {:ok, assign(socket, users: users)}
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "flags LiveComponent mount/4" do
      source = ~S"""
      defmodule MyAppWeb.WidgetLive do
        use Phoenix.LiveComponent

        def mount(socket) do
          {:ok, socket}
        end

        def mount(_params, _session, socket, _assigns) do
          # 4-arity isn't actually canonical Phoenix; this tests the
          # arity check tolerantly
          widgets = MyApp.Repo.all(MyApp.Widget)
          {:ok, assign(socket, widgets: widgets)}
        end
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "ignores mount guarded by connected?/1" do
      source = ~S"""
      defmodule MyAppWeb.UserLive do
        use Phoenix.LiveView

        def mount(_params, _session, socket) do
          users =
            if connected?(socket),
              do: MyApp.Repo.all(MyApp.User),
              else: []

          {:ok, assign(socket, users: users)}
        end
      end
      """

      assert [] = analyze(source)
    end

    test "ignores load that lives in handle_params/3, not mount/3" do
      source = ~S"""
      defmodule MyAppWeb.UserLive do
        use Phoenix.LiveView

        def mount(_params, _session, socket), do: {:ok, socket}

        def handle_params(_, _, socket) do
          {:noreply, assign(socket, users: MyApp.Repo.all(MyApp.User))}
        end
      end
      """

      assert [] = analyze(source)
    end

    test "ignores mount with no loader-module calls" do
      source = ~S"""
      defmodule MyAppWeb.PageLive do
        use Phoenix.LiveView

        def mount(_params, _session, socket) do
          {:ok, assign(socket, title: "Welcome")}
        end
      end
      """

      assert [] = analyze(source)
    end

    test "ignores non-LiveView modules" do
      source = ~S"""
      defmodule MyApp.Worker do
        def mount(_params, _session, socket) do
          MyApp.Repo.all(MyApp.User)
        end
      end
      """

      assert [] = analyze(source)
    end
  end

  describe "check/2 — Sourceror-parsed (production path)" do
    test "still flags unguarded Repo call under Sourceror parse" do
      source = ~S"""
      defmodule MyAppWeb.UserLive do
        use Phoenix.LiveView

        def mount(_params, _session, socket) do
          users = MyApp.Repo.all(MyApp.User)
          {:ok, assign(socket, users: users)}
        end
      end
      """

      assert [_] = analyze_sourceror(source)
    end

    test "still allows connected?-guarded mount under Sourceror parse" do
      source = ~S"""
      defmodule MyAppWeb.UserLive do
        use Phoenix.LiveView

        def mount(_params, _session, socket) do
          users = if connected?(socket), do: MyApp.Repo.all(MyApp.User), else: []
          {:ok, assign(socket, users: users)}
        end
      end
      """

      assert [] = analyze_sourceror(source)
    end
  end

  describe "check/2 — path-sensitive connected? analysis" do
    test "flags loader at top level even if connected? appears later (real bug shape)" do
      # The old 'any connected? in body suppresses' semantics
      # missed this: the Repo call runs unconditionally before the
      # connected? gate ever fires.
      source = ~S"""
      defmodule MyAppWeb.UserLive do
        use Phoenix.LiveView

        def mount(_params, _session, socket) do
          users = MyApp.Repo.all(MyApp.User)
          if connected?(socket), do: subscribe_to_updates()
          {:ok, assign(socket, users: users)}
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "flags loader in else-arm of connected? check" do
      source = ~S"""
      defmodule MyAppWeb.UserLive do
        use Phoenix.LiveView

        def mount(_params, _session, socket) do
          users =
            if connected?(socket) do
              subscribe_to_updates()
              []
            else
              MyApp.Repo.all(MyApp.User)
            end

          {:ok, assign(socket, users: users)}
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "suppresses loader in do-arm of `if connected?(...) do ... end`" do
      source = ~S"""
      defmodule MyAppWeb.UserLive do
        use Phoenix.LiveView

        def mount(_params, _session, socket) do
          if connected?(socket) do
            users = MyApp.Repo.all(MyApp.User)
            {:ok, assign(socket, users: users)}
          else
            {:ok, assign(socket, users: [])}
          end
        end
      end
      """

      assert [] = analyze(source)
    end

    test "suppresses loader in do-arm of `unless not connected?, do: ...`" do
      source = ~S"""
      defmodule MyAppWeb.UserLive do
        use Phoenix.LiveView

        def mount(_params, _session, socket) do
          unless not connected?(socket) do
            socket = assign(socket, users: MyApp.Repo.all(MyApp.User))
            {:ok, socket}
          else
            {:ok, socket}
          end
        end
      end
      """

      assert [] = analyze(source)
    end

    test "suppresses loader in `connected?(socket) && ...` RHS" do
      source = ~S"""
      defmodule MyAppWeb.UserLive do
        use Phoenix.LiveView

        def mount(_params, _session, socket) do
          _ = connected?(socket) && MyApp.Repo.all(MyApp.User)
          {:ok, socket}
        end
      end
      """

      assert [] = analyze(source)
    end

    test "suppresses loader in `case connected?(...) do; true -> ...` arm" do
      source = ~S"""
      defmodule MyAppWeb.UserLive do
        use Phoenix.LiveView

        def mount(_params, _session, socket) do
          socket =
            case connected?(socket) do
              true -> assign(socket, users: MyApp.Repo.all(MyApp.User))
              false -> socket
            end

          {:ok, socket}
        end
      end
      """

      assert [] = analyze(source)
    end

    test "still flags loader in `false ->` arm of case on connected?" do
      source = ~S"""
      defmodule MyAppWeb.UserLive do
        use Phoenix.LiveView

        def mount(_params, _session, socket) do
          socket =
            case connected?(socket) do
              true -> socket
              false -> assign(socket, users: MyApp.Repo.all(MyApp.User))
            end

          {:ok, socket}
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "flags loader in nested `if false_cond do; if connected? do; …`" do
      # Connected dominates only the inner `do` arm, not the outer
      # — but the loader IS inside that inner arm. Should be
      # suppressed.
      source = ~S"""
      defmodule MyAppWeb.UserLive do
        use Phoenix.LiveView

        def mount(_params, _session, socket) do
          if some_flag?() do
            if connected?(socket) do
              MyApp.Repo.all(MyApp.User)
            end
          end

          {:ok, socket}
        end
      end
      """

      assert [] = analyze(source)
    end

    test "flags loader called from outside the connected? branch" do
      # Top-level loader; the connected? gate guards something
      # else entirely. Old behavior: suppress because connected?
      # appears. New behavior: flag because the loader path isn't
      # dominated.
      source = ~S"""
      defmodule MyAppWeb.UserLive do
        use Phoenix.LiveView

        def mount(_params, _session, socket) do
          socket = assign(socket, users: MyApp.Repo.all(MyApp.User))

          if connected?(socket) do
            subscribe_to_updates()
          end

          {:ok, socket}
        end
      end
      """

      assert [_] = analyze(source)
    end
  end
end
