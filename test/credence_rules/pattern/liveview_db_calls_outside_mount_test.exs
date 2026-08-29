defmodule CredenceRules.Pattern.LiveviewDbCallsOutsideMountTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.LiveviewDbCallsOutsideMount

  defp analyze(source, opts \\ []) do
    {:ok, ast} = Code.string_to_quoted(source)
    LiveviewDbCallsOutsideMount.check(ast, [source: source] ++ opts)
  end

  describe "check/2 — flagged" do
    test "flags Repo call in handle_event" do
      source = ~S"""
      defmodule UserLive do
        use Phoenix.LiveView

        def handle_event("delete", %{"id" => id}, socket) do
          user = Repo.get!(User, id)
          Repo.delete!(user)
          {:noreply, socket}
        end
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :liveview_db_calls_outside_mount
      assert issue.meta.function == :handle_event
      assert issue.meta.arity == 3
      assert "Repo.get!" in issue.meta.calls
      assert "Repo.delete!" in issue.meta.calls
    end

    test "flags Req call in handle_info" do
      source = ~S"""
      defmodule ProfileLive do
        use Phoenix.LiveView

        def handle_info({:user_updated, id}, socket) do
          {:ok, profile} = Req.get!("https://profiles/" <> id)
          {:noreply, assign(socket, profile: profile)}
        end
      end
      """

      assert [issue] = analyze(source)
      assert "Req.get!" in issue.meta.calls
    end

    test "flags loader call in a private helper" do
      source = ~S"""
      defmodule UserLive do
        use Phoenix.LiveView

        def handle_event("refresh", _, socket) do
          users = load_users()
          {:noreply, assign(socket, users: users)}
        end

        defp load_users, do: Repo.all(User)
      end
      """

      # Both handle_event (via load_users) and load_users itself
      # would be candidates, but load_users is the one with the
      # direct Repo call — flag it.
      assert [issue] = analyze(source)
      assert issue.meta.function == :load_users
    end

    test "flags MyApp.Repo (trailing-segment match)" do
      source = ~S"""
      defmodule UserLive do
        use Phoenix.LiveView

        def handle_event("load", _, socket) do
          {:noreply, assign(socket, users: MyApp.Repo.all(User))}
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "flags inside a `use Phoenix.LiveComponent` module" do
      source = ~S"""
      defmodule UserCard do
        use Phoenix.LiveComponent

        def handle_event("toggle", _, socket) do
          Repo.update!(socket.assigns.user)
          {:noreply, socket}
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "flags inside a `use MyAppWeb, :live_view` module" do
      source = ~S"""
      defmodule UserLive do
        use MyAppWeb, :live_view

        def handle_params(_params, _uri, socket) do
          Repo.all(User)
          {:noreply, socket}
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "flags multiple loader calls in one function (de-duplicated)" do
      source = ~S"""
      defmodule UserLive do
        use Phoenix.LiveView

        def handle_event("sync", _, socket) do
          users = Repo.all(User)
          Repo.transaction(fn -> Repo.update_all(User, set: [synced: true]) end)
          {:noreply, socket}
        end
      end
      """

      assert [issue] = analyze(source)
      assert length(issue.meta.calls) == 3
    end

    test "flags Oban.insert (queueing is a side effect)" do
      source = ~S"""
      defmodule WorkerLive do
        use Phoenix.LiveView

        def handle_event("enqueue", _, socket) do
          Oban.insert(MyApp.SyncJob.new(%{}))
          {:noreply, socket}
        end
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "ignores Repo call in mount (covered by liveview_query_in_mount)" do
      source = ~S"""
      defmodule UserLive do
        use Phoenix.LiveView

        def mount(_params, _session, socket) do
          {:ok, assign(socket, users: Repo.all(User))}
        end
      end
      """

      assert [] = analyze(source)
    end

    test "ignores context call (delegated load)" do
      source = ~S"""
      defmodule UserLive do
        use Phoenix.LiveView

        def handle_event("refresh", _, socket) do
          users = MyApp.Accounts.list_users()
          {:noreply, assign(socket, users: users)}
        end
      end
      """

      assert [] = analyze(source)
    end

    test "ignores Repo call in a non-LiveView module" do
      source = ~S"""
      defmodule MyApp.Accounts do
        def list_users do
          Repo.all(User)
        end
      end
      """

      assert [] = analyze(source)
    end

    test "ignores plain code" do
      assert [] = analyze("x = 1")
    end
  end

  describe "check/2 — config" do
    test "honours custom :loader_modules" do
      source = ~S"""
      defmodule UserLive do
        use Phoenix.LiveView

        def handle_event("send", _, socket) do
          MyApp.Mailer.deliver_now(welcome_email())
          {:noreply, socket}
        end
      end
      """

      assert [] = analyze(source)
      assert [_] = analyze(source, loader_modules: ["Mailer"])
    end
  end
end
