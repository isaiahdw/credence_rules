defmodule CredenceRules.Pattern.IospNormalizerSideEffectsTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.IospNormalizerSideEffects

  defp analyze(source, opts \\ []) do
    {:ok, ast} = Code.string_to_quoted(source)
    IospNormalizerSideEffects.check(ast, opts)
  end

  defp analyze_sourceror(source, opts \\ []) do
    {:ok, ast} = Sourceror.parse_string(source)
    IospNormalizerSideEffects.check(ast, opts)
  end

  describe "check/2 — flagged" do
    test "flags parse_* that calls Repo" do
      source = ~S"""
      defmodule Auth do
        def parse_token(token) do
          Repo.get(Session, token: token)
        end
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :iosp_normalizer_side_effects
      assert issue.meta.function == :parse_token
    end

    test "flags normalize_* that calls an HTTP client" do
      source = ~S"""
      defmodule Email do
        def normalize_email(email) do
          Req.get!("https://verify", json: %{email: email})
          String.downcase(email)
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "flags to_* / from_* / cast_* / format_*" do
      for prefix <- ~w(to_ from_ cast_ format_ encode_ decode_ serialize_) do
        source = """
        defmodule M do
          def #{prefix}thing(x) do
            Repo.get(Thing, x)
          end
        end
        """

        assert [_] = analyze(source), "expected to flag prefix #{prefix}"
      end
    end

    test "flags bare-atom :ets calls in a normalizer" do
      source = ~S"""
      defmodule M do
        def parse_id(raw) do
          :ets.lookup(:ids, raw)
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "flags defp normalizers too" do
      source = ~S"""
      defmodule M do
        defp parse_token(token), do: Repo.get(Session, token: token)
      end
      """

      assert [_] = analyze(source)
    end

    test "honours custom :normalizer_prefixes" do
      source = ~S"""
      defmodule M do
        def coerce_email(e), do: Repo.get(Email, e)
      end
      """

      assert [] = analyze(source)
      assert [_] = analyze(source, normalizer_prefixes: ["coerce_"])
    end
  end

  describe "check/2 — not flagged" do
    test "ignores predicate (ends in ?) — that's the predicate rule's job" do
      source = ~S"""
      defmodule M do
        def to_valid?(x), do: Repo.exists?(Thing, x)
      end
      """

      # `to_valid?` ends in `?` — skip; iosp_predicate_side_effects
      # owns this shape, no double-flag.
      assert [] = analyze(source)
    end

    test "ignores pure transformations (no side effects)" do
      source = ~S"""
      defmodule M do
        def normalize_email(email), do: email |> String.trim() |> String.downcase()
        def parse_int(s), do: Integer.parse(s)
        def to_iso(dt), do: DateTime.to_iso8601(dt)
      end
      """

      assert [] = analyze(source)
    end

    test "ignores non-normalizer named functions even with side effects" do
      source = ~S"""
      defmodule M do
        def fetch(id), do: Repo.get(User, id)
        def load(id), do: Repo.get(User, id)
      end
      """

      assert [] = analyze(source)
    end

    test "ignores plain code" do
      assert [] = analyze("x = 1")
    end
  end

  describe "check/2 — Sourceror-parsed" do
    test "still flags parse_* with Repo under Sourceror" do
      source = ~S"""
      defmodule Auth do
        def parse_token(token) do
          Repo.get(Session, token: token)
        end
      end
      """

      assert [_] = analyze_sourceror(source)
    end
  end

  describe "check/2 — IO precision (pure IO.* functions)" do
    test "skips encoder that calls IO.iodata_to_binary/1" do
      # The canonical false-positive shape from the brief: TLV /
      # ASN.1 / DNS encoders that build iolists and convert. Pure
      # binary plumbing, not actual I/O.
      source = ~S"""
      defmodule Tlv do
        def encode_invoke_request(req) do
          [<<1>>, req.tag, encode_payload(req.payload)]
          |> IO.iodata_to_binary()
        end
      end
      """

      assert [] = analyze(source)
    end

    test "skips encoder using IO.iodata_length/1" do
      source = ~S"""
      defmodule Tlv do
        def encode_length(bytes) do
          size = IO.iodata_length(bytes)
          <<size::32, IO.iodata_to_binary(bytes)::binary>>
        end
      end
      """

      assert [] = analyze(source)
    end

    test "skips encoder using IO.chardata_to_string/1" do
      source = ~S"""
      defmodule M do
        def to_string(parts), do: IO.chardata_to_string(parts)
      end
      """

      assert [] = analyze(source)
    end

    test "skips encoder using IO.ANSI.* (escape strings)" do
      source = ~S"""
      defmodule Color do
        def format_status(status), do: [IO.ANSI.green(), status, IO.ANSI.reset()]
      end
      """

      assert [] = analyze(source)
    end

    test "STILL flags encoder that calls IO.puts/1 (real output)" do
      source = ~S"""
      defmodule Logger do
        def format_warning(msg) do
          IO.puts("WARNING: " <> msg)
          msg
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "STILL flags encoder that calls IO.inspect/1 (debug output)" do
      source = ~S"""
      defmodule M do
        def encode_thing(x) do
          IO.inspect(x, label: "encoding")
          do_encode(x)
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "honours custom :pure_io_functions" do
      source = ~S"""
      defmodule M do
        def parse_thing(x), do: IO.collect(x)
      end
      """

      # IO.collect isn't in the default pure list → flagged.
      assert [_] = analyze(source)

      # Add it → exempt.
      assert [] = analyze(source, pure_io_functions: [:collect, :iodata_to_binary])
    end
  end

  describe "check/2 — per-call introspection exemption (bug fix)" do
    test "flags Process.alive? AND Repo.exists? composed" do
      # Before per-call fix: whole-function exemption hid the Repo
      # call alongside the harmless Process.alive?. Now the
      # exemption is per-call, so the Repo call still fires.
      source = ~S"""
      defmodule M do
        def parse_active(pid) do
          if Process.alive?(pid), do: Repo.get(Session, pid: pid), else: nil
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "flags Process.info AND File.read composed" do
      source = ~S"""
      defmodule M do
        def normalize_name(pid) do
          case Process.info(pid, :registered_name) do
            {:registered_name, name} -> File.read!("/etc/" <> Atom.to_string(name))
            _ -> nil
          end
        end
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — Process introspection exemption" do
    test "skips normalize_* that calls Process.info/2 for registered_name" do
      # Real-world shape: pid → registered name translation
      # that can't be lifted without TOCTOU.
      source = ~S"""
      defmodule Transport do
        def normalize_key(server) when is_pid(server) do
          case Process.info(server, :registered_name) do
            {:registered_name, name} when is_atom(name) and name != [] -> name
            _ -> server
          end
        end
      end
      """

      assert [] = analyze(source)
    end

    test "skips parse_* that calls Process.whereis/1" do
      source = ~S"""
      defmodule M do
        def parse_registration(name) do
          case Process.whereis(name) do
            nil -> {:error, :not_registered}
            pid -> {:ok, pid}
          end
        end
      end
      """

      assert [] = analyze(source)
    end

    test "skips from_* that calls :erlang.is_process_alive/1" do
      source = ~S"""
      defmodule M do
        def from_pid(pid) do
          if :erlang.is_process_alive(pid), do: {:ok, pid}, else: {:error, :dead}
        end
      end
      """

      assert [] = analyze(source)
    end
  end

  describe "check/2 — function name encodes I/O boundary" do
    test "skips parse_file/1 (name says it reads a file)" do
      # The name IS the integration contract. Lifting File.read would
      # push the boundary to every caller for no gain.
      source = ~S"""
      defmodule Header do
        def parse_file(path) do
          case File.read(path) do
            {:ok, data} -> parse(data)
            error -> error
          end
        end
      end
      """

      assert [] = analyze(source)
    end

    test "skips encode_to_file/2" do
      source = ~S"""
      defmodule M do
        def encode_to_file(data, path), do: File.write!(path, encode(data))
      end
      """

      assert [] = analyze(source)
    end

    test "skips decode_from_path / from_stream / to_stream / to_io variants" do
      for suffix <- ~w(_from_path _from_stream _to_stream _to_io _from_io _from_file _to_file _file) do
        name = "parse#{suffix}"

        source = """
        defmodule M do
          def #{name}(arg), do: File.read!(arg)
        end
        """

        assert [] = analyze(source), "expected to skip #{name}"
      end
    end

    test "still flags parse_token (no I/O-boundary suffix)" do
      # Sanity: the rule still fires on normal normalizer names.
      source = ~S"""
      defmodule M do
        def parse_token(token), do: Repo.get(Session, token: token)
      end
      """

      assert [_] = analyze(source)
    end

    test "honours custom :io_boundary_suffixes" do
      source = ~S"""
      defmodule M do
        def parse_blob(data), do: File.read!(data)
      end
      """

      # _blob isn't in defaults → flagged.
      assert [_] = analyze(source)

      # Add it → skipped.
      assert [] = analyze(source, io_boundary_suffixes: ["_blob"])
    end
  end

  describe "check/2 — Mix.Tasks.* exemption" do
    test "skips ALL defs inside a Mix.Tasks.* module" do
      # Mix tasks are orchestration + I/O by definition.
      source = ~S"""
      defmodule Mix.Tasks.MyApp.Sync do
        def decode_chunked(data) do
          File.mkdir_p!("priv/cache")
          File.write!("priv/cache/data", encode(data))
        end

        def parse_response(body), do: Repo.insert(parse(body))
      end
      """

      assert [] = analyze(source)
    end

    test "still flags inside a normal module" do
      source = ~S"""
      defmodule MyApp.Sync do
        def parse_response(body), do: Repo.insert(parse(body))
      end
      """

      assert [_] = analyze(source)
    end
  end
end
