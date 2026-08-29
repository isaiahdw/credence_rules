defmodule CredenceRules.Pattern.UnsafeAssertiveMatchOnFallibleResultTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.UnsafeAssertiveMatchOnFallibleResult

  defp analyze(source, opts \\ []) do
    {:ok, ast} = Code.string_to_quoted(source)
    UnsafeAssertiveMatchOnFallibleResult.check(ast, [source: source] ++ opts)
  end

  describe "check/2 — flagged" do
    test "{:ok, _} = Repo.insert(_)" do
      source = ~S"""
      defmodule M do
        def import_user(attrs) do
          {:ok, user} = Repo.insert(changeset(attrs))
          user
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "{:ok, _} = Jason.decode(_)" do
      source = ~S"""
      defmodule M do
        def parse(json) do
          {:ok, body} = Jason.decode(json)
          body
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "{:ok, _} = File.read(_)" do
      source = ~S"""
      defmodule M do
        def load(path) do
          {:ok, contents} = File.read(path)
          contents
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "multiple flagged assignments in one function" do
      source = ~S"""
      defmodule M do
        def chain(json, path) do
          {:ok, body} = Jason.decode(json)
          {:ok, file} = File.read(path)
          {body, file}
        end
      end
      """

      assert length(analyze(source)) == 2
    end

    test "{:ok, _} = HTTPoison.get(_)" do
      source = ~S"""
      defmodule M do
        def fetch(url) do
          {:ok, resp} = HTTPoison.get(url)
          resp.body
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "honours :fallible_calls opt" do
      source = ~S"""
      defmodule M do
        def fetch(url) do
          {:ok, resp} = MyApp.Client.fetch(url)
          resp
        end
      end
      """

      # Default list doesn't include MyApp.Client.fetch
      assert [] = analyze(source)

      # Add it → flagged
      assert [_] = analyze(source, fallible_calls: ["MyApp.Client.fetch"])
    end
  end

  describe "check/2 — not flagged" do
    test "bang-suffix function (intentional crash convention)" do
      source = ~S"""
      defmodule M do
        def decode!(json) do
          {:ok, body} = Jason.decode(json)
          body
        end
      end
      """

      assert [] = analyze(source)
    end

    test "ExUnit test file (`assert {:ok, _} = ...` pattern)" do
      source = ~S"""
      defmodule MyTest do
        use ExUnit.Case

        test "creates a user" do
          {:ok, user} = Repo.insert(changeset(attrs))
          assert user.id
        end
      end
      """

      assert [] = analyze(source)
    end

    test "ExUnit.CaseTemplate also skips" do
      source = ~S"""
      defmodule M.Case do
        use ExUnit.CaseTemplate

        def setup_user do
          {:ok, user} = Repo.insert(changeset())
          user
        end
      end
      """

      assert [] = analyze(source)
    end

    test "inside case (not top-level assignment)" do
      source = ~S"""
      defmodule M do
        def go(json) do
          case some_check() do
            true ->
              # This assertive match isn't at the function's top level —
              # the rule only walks function-body statements.
              {:ok, body} = Jason.decode(json)
              body
            false -> :skip
          end
        end
      end
      """

      # Currently the rule walks top-level statements only, so this
      # NESTED match isn't flagged. (Future: extend to flag in
      # arbitrary positions.)
      assert [] = analyze(source)
    end

    test "case branching (correct shape)" do
      source = ~S"""
      defmodule M do
        def parse(json) do
          case Jason.decode(json) do
            {:ok, body} -> body
            {:error, _} -> nil
          end
        end
      end
      """

      assert [] = analyze(source)
    end

    test "with chain (correct shape)" do
      source = ~S"""
      defmodule M do
        def parse(json) do
          with {:ok, body} <- Jason.decode(json),
               {:ok, user} <- build_user(body) do
            {:ok, user}
          end
        end
      end
      """

      assert [] = analyze(source)
    end

    test "unknown call (not in fallible list)" do
      source = ~S"""
      defmodule M do
        def parse(s) do
          {:ok, parts} = MyApp.Parser.parse(s)
          parts
        end
      end
      """

      assert [] = analyze(source)
    end

    test "plain code" do
      assert [] = analyze("x = 1")
    end
  end
end
