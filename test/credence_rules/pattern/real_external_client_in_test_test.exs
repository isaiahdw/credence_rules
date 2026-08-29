defmodule CredenceRules.Pattern.RealExternalClientInTestTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.RealExternalClientInTest

  defp analyze(source, opts \\ []) do
    {:ok, ast} = Code.string_to_quoted(source)
    RealExternalClientInTest.check(ast, [source: source] ++ opts)
  end

  defp analyze_sourceror(source, opts \\ []) do
    {:ok, ast} = Sourceror.parse_string(source)
    RealExternalClientInTest.check(ast, [source: source] ++ opts)
  end

  describe "check/2 — flagged" do
    test "flags Req.get inside a test with no Mox" do
      source = ~S"""
      defmodule WeatherTest do
        use ExUnit.Case

        test "fetches forecast" do
          {:ok, %{status: 200}} = Req.get!("https://api.weather.gov")
          assert true
        end
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :real_external_client_in_test
      assert issue.meta.test_name == "fetches forecast"
      assert "Req.get!" in issue.meta.calls
    end

    test "flags HTTPoison.post inside a test" do
      source = ~S"""
      defmodule UploadTest do
        use ExUnit.Case

        test "uploads file" do
          assert {:ok, _} = HTTPoison.post("https://api", "body")
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "flags Finch and Tesla" do
      for client <- ["Finch", "Tesla", "Mint", "Hackney"] do
        source = """
        defmodule SomeTest do
          use ExUnit.Case
          test "calls #{client}" do
            #{client}.request(:get, "url", [], "")
          end
        end
        """

        assert [_] = analyze(source), "expected to flag #{client}"
      end
    end

    test "flags a deeply-nested client call (inside a case)" do
      source = ~S"""
      defmodule MyTest do
        use ExUnit.Case

        test "complex" do
          result =
            case Req.get!("url") do
              {:ok, %{status: 200}} -> :ok
              _ -> :error
            end

          assert result == :ok
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "honours custom :client_modules" do
      source = ~S"""
      defmodule MailTest do
        use ExUnit.Case

        test "mails" do
          Bamboo.send_now(email)
        end
      end
      """

      assert [] = analyze(source)
      assert [_] = analyze(source, client_modules: ["Bamboo"])
    end
  end

  describe "check/2 — not flagged (Mox-aware files)" do
    test "skips file with `import Mox`" do
      source = ~S"""
      defmodule WeatherTest do
        use ExUnit.Case
        import Mox

        test "fetches forecast" do
          # Even with a real-looking call, the file imports Mox →
          # skip. The author has clearly opted into mocking.
          Req.get!("https://api")
        end
      end
      """

      assert [] = analyze(source)
    end

    test "skips file with `use Mox.SetupHelper`" do
      source = ~S"""
      defmodule MyTest do
        use ExUnit.Case
        use Mox.SetupHelper

        test "x" do
          Req.get!("url")
        end
      end
      """

      assert [] = analyze(source)
    end

    test "skips file that calls `expect/3`" do
      source = ~S"""
      defmodule MyTest do
        use ExUnit.Case

        setup do
          expect(HTTPMock, :get, fn _ -> {:ok, %{}} end)
          :ok
        end

        test "x" do
          Req.get!("url")
        end
      end
      """

      assert [] = analyze(source)
    end

    test "skips file that calls `Mox.set_mox_global/0` etc." do
      source = ~S"""
      defmodule MyTest do
        use ExUnit.Case

        setup do
          Mox.set_mox_global()
          :ok
        end

        test "x" do
          Req.get!("url")
        end
      end
      """

      assert [] = analyze(source)
    end
  end

  describe "check/2 — not flagged (no test body)" do
    test "skips client call in setup (infrastructure, not test body)" do
      source = ~S"""
      defmodule MyTest do
        use ExUnit.Case

        setup do
          Req.get!("https://api")
          :ok
        end

        test "x", do: assert true
      end
      """

      assert [] = analyze(source)
    end

    test "skips client call in a private helper" do
      source = ~S"""
      defmodule MyTest do
        use ExUnit.Case

        test "x" do
          result = fetch()
          assert result
        end

        defp fetch, do: Req.get!("url")
      end
      """

      assert [] = analyze(source)
    end

    test "skips plain code" do
      assert [] = analyze("x = 1")
    end

    test "skips test body with no HTTP client call" do
      source = ~S"""
      defmodule MyTest do
        use ExUnit.Case

        test "math" do
          assert 1 + 1 == 2
        end
      end
      """

      assert [] = analyze(source)
    end
  end

  describe "check/2 — Sourceror-parsed (production path)" do
    test "still flags Req.get under Sourceror" do
      source = ~S"""
      defmodule MyTest do
        use ExUnit.Case

        test "fetch" do
          Req.get!("https://api")
        end
      end
      """

      assert [_] = analyze_sourceror(source)
    end

    test "still skips files with import Mox under Sourceror" do
      source = ~S"""
      defmodule MyTest do
        use ExUnit.Case
        import Mox

        test "fetch" do
          Req.get!("https://api")
        end
      end
      """

      assert [] = analyze_sourceror(source)
    end
  end

  describe "check/2 — ExUnit gate" do
    test "does NOT fire on a non-ExUnit module that defines a `test/2` DSL macro" do
      # Custom DSL with a `test/2`-shaped macro and an inline Req
      # call — without the ExUnit gate, the rule would flag the
      # Req.get!/1 call. With the gate it doesn't.
      source = ~S"""
      defmodule MyAppWeb.SomeMacros do
        defmacro test(name, opts), do: nil

        test "fetches users" do
          Req.get!("https://api/users")
        end
      end
      """

      assert [] = analyze(source)
    end
  end
end
