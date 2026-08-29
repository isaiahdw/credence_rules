defmodule CredenceRules.Pattern.ObviousCommentTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.ObviousComment

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    ObviousComment.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test ~s(flags `# Fetch the user`) do
      assert [issue] = analyze("# Fetch the user\nuser = nil")
      assert issue.rule == :obvious_comment
      assert issue.meta.line == 1
    end

    test "flags a sample of obvious verbs" do
      for {verb, article} <- [
            {"Get", "the"},
            {"Create", "a"},
            {"Build", "the"},
            {"Update", "the"},
            {"Delete", "the"},
            {"Parse", "an"},
            {"Validate", "the"},
            {"Return", "the"}
          ] do
        assert [_] = analyze("# #{verb} #{article} thing\n:ok"),
               "expected to flag `# #{verb} #{article} thing`"
      end
    end

    test "flags indented obvious comment" do
      assert [_] = analyze("def foo do\n  # Fetch the user\n  :ok\nend")
    end

    test "flags each occurrence with correct line numbers" do
      source = """
      def go do
        # Fetch the user
        user = get_user()
        # Validate the input
        check(user)
      end
      """

      assert [a, b] = analyze(source)
      assert a.meta.line == 2
      assert b.meta.line == 4
    end
  end

  describe "check/2 — not flagged" do
    test "ignores comments with technical detail" do
      assert [] = analyze("# Fetch the connection, blocking up to 5s\n:ok")
      assert [] = analyze("# Get the value because the cache is cold\n:ok")
      assert [] = analyze("# Create the changeset to avoid double-insert\n:ok")
    end

    test "ignores comments that contain digits" do
      assert [] = analyze("# Fetch the row from table 3\n:ok")
    end

    test "ignores comments without verb+article shape" do
      assert [] = analyze("# Fetch users efficiently\n:ok")
      assert [] = analyze("# Some other comment\n:ok")
    end

    test "ignores comments where verb is not at start" do
      # "the" is not after a flagged verb at position 0
      assert [] = analyze("# Now fetch the user\n:ok")
    end

    test "ignores comments above the length limit" do
      long = "# Fetch the user " <> String.duplicate("x", 100)
      assert [] = analyze(long <> "\n:ok")
    end

    test "ignores TODO / FIXME / tool pragmas" do
      assert [] = analyze("# TODO: Fetch the user\n:ok")
      assert [] = analyze("# credo:disable Fetch the user\n:ok")
    end

    test "ignores keeper keywords NOTE / SAFETY / WARN / BUG / PERF" do
      assert [] = analyze("# NOTE: Fetch the user\n:ok")
      assert [] = analyze("# SAFETY: Fetch the user before unlocking\n:ok")
      assert [] = analyze("# WARN: Fetch the user only once\n:ok")
      assert [] = analyze("# BUG: Fetch the user races with cache\n:ok")
      assert [] = analyze("# PERF: Fetch the user lazily\n:ok")
    end

    test "ignores plain code" do
      assert [] = analyze("user = Repo.get(User, id)")
    end

    test "ignores obvious-shaped lines inside an @doc heredoc" do
      source = ~S'''
      defmodule M do
        @doc """
        ## Usage

            # Store a fabric
            Storage.put(fabric)
        """
        def store(_), do: :ok
      end
      '''

      assert [] = analyze(source)
    end

    test "ignores obvious-shaped lines inside @moduledoc and @typedoc heredocs" do
      source = ~S'''
      defmodule M do
        @moduledoc """
        Example:

            # Fetch the user
            user = Repo.get(User, 1)
        """

        @typedoc """
            # Build the changeset
            changeset = User.changeset(%User{}, attrs)
        """
        @type t :: term()
      end
      '''

      assert [] = analyze(source)
    end

    test "resumes flagging after a heredoc closes" do
      source = ~S'''
      defmodule M do
        @doc """
            # Store a fabric
            Storage.put(fabric)
        """
        def store(_) do
          # Fetch the user
          user = nil
          user
        end
      end
      '''

      assert [issue] = analyze(source)
      assert issue.meta.line == 7
    end
  end
end
