defmodule CredenceRules.Pattern.VagueTestNameTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.VagueTestName

  defp analyze(source, opts \\ []) do
    {:ok, ast} = Code.string_to_quoted(wrap_in_test_module(source))
    VagueTestName.check(ast, [source: source] ++ opts)
  end

  defp analyze_sourceror(source, opts \\ []) do
    {:ok, ast} = Sourceror.parse_string(wrap_in_test_module(source))
    VagueTestName.check(ast, [source: source] ++ opts)
  end

  # The rule gates on `use ExUnit.Case` — bare `test "..."` macro
  # calls in non-test files don't fire. If the test fixture already
  # declares a defmodule with `use ExUnit.Case`, pass it through;
  # otherwise wrap it so the gate accepts the fixture.
  defp wrap_in_test_module(source) do
    if source =~ "use ExUnit.Case" do
      source
    else
      """
      defmodule SyntheticTest do
        use ExUnit.Case, async: true

        #{source}
      end
      """
    end
  end

  describe "check/2 — flagged (vague names)" do
    test ~S(flags `test "it works"`) do
      source = ~S"""
      defmodule MyTest do
        test "it works" do
          assert true
        end
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :vague_test_name
      assert issue.meta.name == "it works"
    end

    test ~S(flags `test "test 1"`, `test "test #1"`, `test "test_2"`) do
      assert [_] = analyze(~S|test "test 1", do: :ok|)
      assert [_] = analyze(~S|test "test #1", do: :ok|)
      assert [_] = analyze(~S|test "test_2", do: :ok|)
    end

    test ~S(flags bare `test "test"`) do
      assert [_] = analyze(~S|test "test", do: :ok|)
    end

    test ~S(flags pure-number names) do
      assert [_] = analyze(~S|test "1", do: :ok|)
      assert [_] = analyze(~S|test "2.5", do: :ok|)
    end

    test ~S(flags single-word verdicts: works/runs/succeeds/valid) do
      for name <- ["works", "runs", "succeeds", "passes", "valid", "ok", "true", "done"] do
        assert [_] = analyze(~s|test "#{name}", do: :ok|),
               "expected to flag #{inspect(name)}"
      end
    end

    test ~S(flags smoke / sanity names) do
      for name <- ["smoke", "smoke test", "sanity", "sanity check"] do
        assert [_] = analyze(~s|test "#{name}", do: :ok|),
               "expected to flag #{inspect(name)}"
      end
    end

    test ~S(flags happy path / basic / simple alone) do
      for name <- ["happy path", "basic", "basic test", "simple", "simple test", "trivial"] do
        assert [_] = analyze(~s|test "#{name}", do: :ok|),
               "expected to flag #{inspect(name)}"
      end
    end

    test ~S(flags WIP / TODO / placeholder) do
      for name <- ["wip", "WIP", "todo", "TODO", "fixme", "placeholder", "empty"] do
        assert [_] = analyze(~s|test "#{name}", do: :ok|),
               "expected to flag #{inspect(name)}"
      end
    end

    test ~S(flags empty / whitespace-only names) do
      assert [_] = analyze(~S|test "", do: :ok|)
      assert [_] = analyze(~S|test "   ", do: :ok|)
    end

    test "is case-insensitive" do
      assert [_] = analyze(~S|test "IT WORKS", do: :ok|)
      assert [_] = analyze(~S|test "Smoke Test", do: :ok|)
    end

    test "honours :additional_vague_patterns" do
      source = ~S|test "works fine", do: :ok|

      assert [] = analyze(source)
      assert [_] = analyze(source, additional_vague_patterns: [~r/\Aworks fine\z/i])
    end

    test "flags multiple vague tests in one file" do
      source = ~S"""
      defmodule MyTest do
        test "works", do: :ok
        test "it works", do: :ok
        test "the actual behaviour we expect", do: :ok
      end
      """

      assert [a, b] = analyze(source)
      names = Enum.map([a, b], & &1.meta.name) |> Enum.sort()
      assert names == ["it works", "works"]
    end
  end

  describe "check/2 — not flagged" do
    test "passes descriptive names" do
      assert [] = analyze(~S|test "list/0 returns empty when no users exist", do: :ok|)
      assert [] = analyze(~S|test "raises ArgumentError when nil", do: :ok|)
      assert [] = analyze(~S|test "happy path: user gets 200 with valid token", do: :ok|)
    end

    test "passes 'test' as a substring" do
      assert [] = analyze(~S|test "test name parser handles unicode", do: :ok|)
    end

    test "passes interpolated names (can't statically evaluate)" do
      assert [] = analyze(~S|test "#{thing} works", do: :ok|)
    end

    test "passes plain code" do
      assert [] = analyze("x = 1")
    end
  end

  describe "check/2 — Sourceror-parsed (production path)" do
    test "still flags under Sourceror parse" do
      source = ~S"""
      defmodule MyTest do
        test "it works" do
          assert true
        end
      end
      """

      assert [_] = analyze_sourceror(source)
    end
  end

  describe "check/2 — ExUnit gate" do
    test "does NOT fire on a non-ExUnit module that defines a `test/2` DSL macro" do
      # Use the underlying VagueTestName.check/2 directly to bypass
      # the test helper's auto-wrap — this fixture is intentionally
      # NOT an ExUnit file.
      source = ~S"""
      defmodule MyAppWeb.SomeMacros do
        # Custom DSL — looks like a test but isn't ExUnit.
        defmacro test(name, opts), do: nil

        test "works", do: nil
        test "it should be true", do: nil
      end
      """

      {:ok, ast} = Code.string_to_quoted(source)
      assert [] = VagueTestName.check(ast, source: source)
    end

    test "fires on a real ExUnit file with vague names" do
      source = ~S"""
      defmodule MyTest do
        use ExUnit.Case, async: true

        test "works", do: assert true
        test "it works", do: assert true
      end
      """

      {:ok, ast} = Code.string_to_quoted(source)
      assert [_, _] = VagueTestName.check(ast, source: source)
    end
  end
end
