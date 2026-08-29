defmodule CredenceRules.Pattern.TruthyAccessReusedInBodyTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.TruthyAccessReusedInBody

  defp analyze(source, opts \\ []) do
    {:ok, ast} = Code.string_to_quoted(source)
    TruthyAccessReusedInBody.check(ast, [source: source] ++ opts)
  end

  defp analyze_sourceror(source, opts \\ []) do
    {:ok, ast} = Sourceror.parse_string(source)
    TruthyAccessReusedInBody.check(ast, [source: source] ++ opts)
  end

  describe "check/2 — flagged" do
    test "flags `if state.socket6, do: :socket.close(state.socket6)` (the canonical example)" do
      source = ~S"if state.socket6, do: :socket.close(state.socket6)"

      assert [issue] = analyze(source)
      assert issue.rule == :truthy_access_reused_in_body
    end

    test "flags repeated dot field access" do
      source = ~S"if user.email, do: send_email(user.email)"
      assert [_] = analyze(source)
    end

    test "flags nested dot field access (`conn.assigns.current_user`)" do
      source = ~S"""
      if conn.assigns.current_user do
        audit(conn.assigns.current_user)
      end
      """

      assert [_] = analyze(source)
    end

    test "flags `cfg[:url]` bracket access reused in body" do
      source = ~S"if cfg[:url], do: register(cfg[:url])"
      assert [_] = analyze(source)
    end

    test "flags `Map.get/2` reused in body" do
      source = ~S"if Map.get(user, :email), do: send_email(Map.get(user, :email))"
      assert [_] = analyze(source)
    end

    test "flags `Map.get/3` (with default) reused in body" do
      source = ~S"if Map.get(opts, :adapter, nil), do: start(Map.get(opts, :adapter, nil))"
      assert [_] = analyze(source)
    end

    test "flags `Keyword.get/2` reused in body" do
      source = ~S"if Keyword.get(opts, :adapter), do: start(Keyword.get(opts, :adapter))"
      assert [_] = analyze(source)
    end

    test "flags if-do-else form" do
      source = ~S|if user.email, do: send(user.email), else: log("no email")|
      assert [_] = analyze(source)
    end

    test "flags repeated occurrences of the access in body" do
      # Use inside both branches / multiple positions still counts as 1 finding
      source = ~S"if user.email, do: [user.email, audit(user.email)]"
      assert [_] = analyze(source)
    end

    test "flags multiple ifs in a row (each is a separate finding)" do
      source = ~S"""
      def close_sockets(state) do
        if state.socket6, do: :socket.close(state.socket6)
        if state.socket4, do: :socket.close(state.socket4)
      end
      """

      assert [_, _] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "body doesn't reuse the gated value (pure boolean test)" do
      source = ~S|if state.flag, do: log("set")|
      assert [] = analyze(source)
    end

    test "skips `?`-suffix field names (boolean field)" do
      source = ~S"if user.admin?, do: audit(user.admin?)"
      assert [] = analyze(source)
    end

    test "skips `?`-suffix nested field" do
      source = ~S"if state.connected?, do: handle(state.connected?)"
      assert [] = analyze(source)
    end

    test "skips bracket access with `?` key" do
      source = ~S"if opts[:debug?], do: track(opts[:debug?])"
      assert [] = analyze(source)
    end

    test "skips Map.get with `?` key" do
      source = ~S"if Map.get(opts, :enabled?), do: run(Map.get(opts, :enabled?))"
      assert [] = analyze(source)
    end

    test "skips Keyword.get with `?` key" do
      source = ~S"if Keyword.get(opts, :debug?), do: log(Keyword.get(opts, :debug?))"
      assert [] = analyze(source)
    end

    test "skips bare variables (`if user, do: process(user.name)`)" do
      # Bare var is out of scope — rule targets field-access shape
      # specifically. `if user` is checking the var itself for truthy,
      # but the body uses a DIFFERENT expression (`user.name`).
      source = ~S"if user, do: process(user.name)"
      assert [] = analyze(source)
    end

    test "skips `if Enum.empty?(list), do: ...` (predicate function)" do
      source = ~S"if Enum.empty?(list), do: handle_empty()"
      assert [] = analyze(source)
    end

    test "skips comparison conditions" do
      source = ~S"if x > 0, do: y"
      assert [] = analyze(source)
    end

    test "skips arbitrary function calls in condition (separate concern)" do
      # `get_socket(state)` looks like an accessor, but it's an
      # arbitrary call — not within rule scope. Separate "use local
      # binding" rule would cover this.
      source = ~S"if get_socket(state), do: :socket.close(get_socket(state))"
      assert [] = analyze(source)
    end

    test "skips wrong-module Map.get lookalikes" do
      # `MyApp.Map.get(...)` isn't the stdlib Map.get — different module.
      source = ~S"if MyApp.Map.get(user, :email), do: send(MyApp.Map.get(user, :email))"
      assert [] = analyze(source)
    end

    test "skips when the access expression appears in the condition only" do
      source = ~S"if state.socket6, do: send_alert()"
      assert [] = analyze(source)
    end

    test "skips a value only interpolated into a string (displayed, not operated on)" do
      source = ~S|if plan.device_address, do: Mix.shell().info("addr=#{plan.device_address}")|
      assert [] = analyze(source)
    end

    test "skips bracket access only interpolated into a string" do
      source = ~S|if cfg[:url], do: Logger.info("url=#{cfg[:url]}")|
      assert [] = analyze(source)
    end

    test "still flags when the value is interpolated AND operated on" do
      # One reuse is display, but `register/1` consumes the value — the
      # operand reuse is the real smell.
      source = ~S|if cfg[:url], do: (Logger.info("url=#{cfg[:url]}"); register(cfg[:url]))|
      assert [_] = analyze(source)
    end
  end

  describe "check/2 — Sourceror-parsed (production path)" do
    test "still flags the canonical example under Sourceror" do
      source = ~S"""
      defmodule Foo do
        def close_sockets(state) do
          if state.socket6, do: :socket.close(state.socket6)
          if state.socket4, do: :socket.close(state.socket4)
        end
      end
      """

      assert [_, _] = analyze_sourceror(source)
    end

    test "still skips `?`-suffix under Sourceror" do
      source = ~S"""
      defmodule Foo do
        def go(user), do: if user.admin?, do: audit(user.admin?)
      end
      """

      assert [] = analyze_sourceror(source)
    end

    test "skips interpolation-only reuse under Sourceror" do
      source = ~S"""
      defmodule Foo do
        def go(plan) do
          if plan.device_address do
            Mix.shell().info("device_address=#{plan.device_address}:#{plan.device_port}")
          end
        end
      end
      """

      assert [] = analyze_sourceror(source)
    end
  end
end
