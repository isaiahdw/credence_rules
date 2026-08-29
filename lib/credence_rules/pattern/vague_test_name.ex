defmodule CredenceRules.Pattern.VagueTestName do
  @moduledoc """
  Test quality rule: a `test "..."` whose name is too vague to tell
  a reader what's being verified. Vague names ship for the same
  reason they're useless — when an LLM (or a tired engineer) can't
  describe the expected behaviour in a phrase, the test usually
  isn't testing the behaviour it claims to.

  Failing test output shows the test name, not the body. If the
  name is `"test 1"`, the test failure tells you nothing about
  what broke — a reviewer has to open the file and read the body.
  With dozens of failures in CI that's a tax on every triage.

  ## Bad

      test "it works" do
        assert MyMod.run() == :ok
      end

      test "test 1" do
        # ...
      end

      test "happy path", do: :ok

      test "smoke", do: assert MyMod.start_link() != nil

  ## Good

      test "run/0 returns :ok on success" do
        assert MyMod.run() == :ok
      end

      test "start_link/1 registers under {:via, Registry, _}" do
        # ...
      end

  ## What's flagged (case-insensitive)

  - "test" / "test N" / "test #N" / "test_N"
  - "it works" / "works" / "runs" / "succeeds" / "valid"
  - "smoke" / "smoke test" / "sanity" / "sanity check"
  - "happy path" / "basic" / "basic test" / "simple test"
  - "wip" / "TODO" / "FIXME"
  - Pure-number names: "1", "2.5", etc.
  - Empty or whitespace-only names

  ## What's NOT flagged

  - "test that it works correctly with edge cases"
  - "happy path: user with valid token gets 200"
  - "smoke test for full pipeline end-to-end"

  The detector requires the *entire* name to match a vague pattern.
  Adding any descriptive text after the vague phrase passes.

  ## Configuration

  - `:additional_vague_patterns` — regexes appended to the default
    set. Useful for project-specific cliches ("works fine",
    "should work as expected").

  ## Why advisory

  Some test names are genuinely terse and informative for the
  surrounding `describe` (e.g. `describe "list_users/0"` + `test
  "empty"`). Treat findings as "would I know what failed from this
  name alone, with no context?" — not a hard cap.
  """

  use CredenceRules.Rule

  # Each regex is anchored — only matches names that are ENTIRELY
  # a vague phrase. Adding any descriptive text past the cliche
  # passes the rule.
  @default_vague_patterns [
    # "test", "test 1", "test #1", "test_1", "test:1"
    ~r/\Atest\z/i,
    ~r/\Atest[\s_#:-]*\d+\z/i,
    # Pure numeric
    ~r/\A\d+(\.\d+)?\z/,
    # Single-word verdicts
    ~r/\A(it works|works|runs|succeeds|passes|valid|ok|true|done)\z/i,
    # Smoke/sanity
    ~r/\A(smoke|smoke test|sanity|sanity check)\z/i,
    # Happy path / basic / simple — alone
    ~r/\A(happy path|basic|basic test|simple test|simple|trivial)\z/i,
    # WIP / placeholder
    ~r/\A(wip|todo|fixme|placeholder|empty)\z/i,
    # Empty / whitespace
    ~r/\A\s*\z/
  ]

  @impl true
  def priority, do: 470

  @impl true
  def check(ast, opts) do
    extra = Keyword.get(opts, :additional_vague_patterns, [])
    patterns = @default_vague_patterns ++ extra

    # Gate: only scan files whose modules `use ExUnit.Case` or
    # `use ExUnit.CaseTemplate`. Many Elixir libraries define
    # custom `test/2` macros for DSLs — without the gate this
    # rule would fire on them.
    if CredenceRules.TestModule.exunit_file?(ast) do
      collect_findings(ast, patterns)
    else
      []
    end
  end

  defp collect_findings(ast, patterns) do
    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        # `test "name" do ... end` and `test "name", do: ...`
        {:test, meta, [name | _rest]} = node, acc ->
          case extract_name(name) do
            {:ok, name_str} ->
              if vague?(name_str, patterns),
                do: {node, [build_issue(meta, name_str) | acc]},
                else: {node, acc}

            :error ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  # Test name is either a string literal directly or a Sourceror-wrapped
  # block holding the string. Interpolated names like `"#{thing} works"`
  # have a more complex AST shape — skip those (we can't statically
  # evaluate them, and they're already specific by virtue of having
  # interpolation).
  defp extract_name(name) when is_binary(name), do: {:ok, name}

  defp extract_name({:__block__, _, [name]}) when is_binary(name), do: {:ok, name}

  defp extract_name(_), do: :error

  defp vague?(name, patterns) do
    trimmed = String.trim(name)
    Enum.any?(patterns, &Regex.match?(&1, trimmed))
  end

  defp build_issue(meta, name) do
    %Issue{
      rule: :vague_test_name,
      message:
        "Test name #{inspect(name)} is too vague to tell what's being verified " <>
          "from the failure line alone. Name it after the behaviour: " <>
          "`test \"function/arity returns :ok on success\"`, `test \"raises when " <>
          "the lookup is missing\"`. Failing CI output shows the name — make it " <>
          "carry the information.",
      meta: %{line: Keyword.get(meta, :line), name: name}
    }
  end
end
