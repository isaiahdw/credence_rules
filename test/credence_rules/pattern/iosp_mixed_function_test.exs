defmodule CredenceRules.Pattern.IospMixedFunctionTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.IospMixedFunction

  defp analyze(source, opts \\ []) do
    {:ok, ast} = Code.string_to_quoted(source)
    IospMixedFunction.check(ast, [source: source] ++ opts)
  end

  defp analyze_sourceror(source) do
    {:ok, ast} = Sourceror.parse_string(source)
    IospMixedFunction.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags do-everything function (many calls + many control-flow)" do
      source = ~S"""
      def commission(device, opts) do
        case Storage.fetch(device.id) do
          {:ok, creds} ->
            if Validator.ok?(creds) do
              encrypted = Crypto.encrypt(creds, opts)
              case Storage.persist(device.id, encrypted) do
                {:ok, _} -> Formatter.format(device, :ok)
                {:error, e} -> Formatter.format(device, {:error, e})
              end
            else
              Formatter.format(device, {:error, :invalid})
            end

          {:error, e} ->
            Formatter.format(device, {:error, e})
        end
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :iosp_mixed_function
      assert issue.meta.user_calls >= 2
      assert issue.meta.control_flow >= 2
    end

    test "flags function with 3+ user calls + 3+ control flow" do
      source = ~S"""
      def go(x, y, z) do
        if Foo.check?(x) do
          case Bar.lookup(y) do
            {:ok, v} ->
              cond do
                Baz.ready?(v) -> v
                true -> nil
              end

            :error ->
              nil
          end
        else
          nil
        end
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "ignores pure Integration with `with` chain" do
      # `with` is the canonical Integration shape — excluded from
      # control-flow count.
      source = ~S"""
      def commission(device, opts) do
        with {:ok, creds} <- Storage.fetch(device.id),
             :ok <- Validator.ensure_valid(creds),
             encrypted = Crypto.encrypt(creds, opts),
             {:ok, _} <- Storage.persist(device.id, encrypted) do
          Formatter.format(device, :ok)
        end
      end
      """

      assert [] = analyze(source)
    end

    test "ignores pure Operation (logic only, no user-fn calls)" do
      source = ~S"""
      def classify(score) do
        cond do
          score > 90 -> :a
          score > 80 -> :b
          score > 70 -> :c
          true -> :f
        end
      end
      """

      assert [] = analyze(source)
    end

    test "ignores single user-fn call + control flow (only 1 call)" do
      source = ~S"""
      def fetch_user(id) do
        case Repo.get(User, id) do
          nil -> {:error, :not_found}
          user -> {:ok, user}
        end
      end
      """

      assert [] = analyze(source)
    end

    test "ignores function below the size threshold" do
      source = ~S"""
      def small(x) do
        if Foo.ok?(x), do: Bar.go(x)
      end
      """

      assert [] = analyze(source)
    end

    test "ignores local-call helpers (only Foo.bar/... counts)" do
      source = ~S"""
      def go(x) do
        if helper?(x) do
          case other_helper(x) do
            {:ok, v} -> v
            :error -> nil
          end
        else
          nil
        end
      end
      """

      assert [] = analyze(source)
    end

    test "ignores a flat protocol parser (single dispatch, linear steps)" do
      # The whole body is one top-level `case`; its happy arm runs the
      # protocol steps top-to-bottom. 4 user calls + 3 control-flow, but
      # the control-flow is siblings under the dispatch, not nested
      # branching — effective nesting depth 1.
      source = ~S"""
      def parse_sigma2(tlv, ctx, state) do
        case Envelope.decode(tlv) do
          {:ok, elements} ->
            decrypted = case Crypto.decrypt(elements) do
              {:ok, p} -> p
              e -> e
            end

            checked = if Validator.ok?(decrypted), do: decrypted, else: nil
            Payload.decode(checked)

          {:error, _} = err ->
            err
        end
      end
      """

      assert [] = analyze(source)
    end

    test "ignores a sequential init/setup (no nested branching)" do
      # A linear setup script: ten-ish steps, each a single line. The
      # control-flow constructs are top-level siblings, not nested.
      source = ~S"""
      def init(opts) do
        config = Config.parse(opts)
        ip = Network.normalize_ip(config.host)

        family = if String.contains?(ip, ":"), do: :inet6, else: :inet

        server = case family do
          :inet6 -> Udp.start_v6(ip)
          :inet -> Udp.start_v4(ip)
        end

        log = unless server == nil, do: Telemetry.up(server), else: Telemetry.down()

        {:ok, State.build(config, server, log)}
      end
      """

      assert [] = analyze(source)
    end

    test "iosp_min_nesting_depth: 1 restores count-only behaviour" do
      source = ~S"""
      def parse_sigma2(tlv, ctx, state) do
        case Envelope.decode(tlv) do
          {:ok, elements} ->
            decrypted = case Crypto.decrypt(elements) do
              {:ok, p} -> p
              e -> e
            end

            checked = if Validator.ok?(decrypted), do: decrypted, else: nil
            Payload.decode(checked)

          {:error, _} = err ->
            err
        end
      end
      """

      assert [_] = analyze(source, iosp_min_nesting_depth: 1)
    end

    test "honours custom thresholds" do
      # With min_user_calls=4, a 3-call body shouldn't fire.
      source = ~S"""
      def go(x, y, z) do
        if Foo.check?(x) do
          case Bar.lookup(y) do
            {:ok, v} ->
              cond do
                Baz.ready?(v) -> v
                true -> nil
              end

            :error ->
              nil
          end
        end
      end
      """

      assert [] = analyze(source, iosp_min_user_calls: 4)
    end
  end

  describe "check/2 — Sourceror-parsed (production path)" do
    test "still flags mixed functions under Sourceror parse" do
      source = ~S"""
      def go(x, y, z) do
        if Foo.check?(x) do
          case Bar.lookup(y) do
            {:ok, v} ->
              cond do
                Baz.ready?(v) -> Baz.handle(v)
                true -> :none
              end

            :error ->
              Baz.handle(:none)
          end
        end
      end
      """

      assert [_] = analyze_sourceror(source)
    end
  end

  describe "check/2 — Mix.Tasks.* exemption" do
    test "skips a long mixed function inside a Mix.Tasks.* module" do
      source = ~S"""
      defmodule Mix.Tasks.MyApp.Sync do
        def run(args) do
          Foo.parse(args)
          Bar.validate(args)
          Baz.persist(args)

          case Foo.config() do
            {:ok, cfg} -> if cfg.enabled?, do: Bar.go(cfg), else: :skip
            :error -> :error
          end

          if some_flag(), do: Foo.cleanup(), else: :ok
        end
      end
      """

      assert [] = analyze(source)
    end

    test "still flags a long mixed function in a normal module" do
      source = ~S"""
      defmodule MyApp.Worker do
        def run(args) do
          Foo.parse(args)
          Bar.validate(args)
          Baz.persist(args)

          case Foo.config() do
            {:ok, cfg} -> if cfg.enabled?, do: Bar.go(cfg), else: :skip
            :error -> :error
          end

          if some_flag(), do: Foo.cleanup(), else: :ok
        end
      end
      """

      assert [_] = analyze(source)
    end
  end
end
