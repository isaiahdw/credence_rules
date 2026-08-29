defmodule CredenceRules.Pattern.StaleReferenceCommentTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.StaleReferenceComment

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    StaleReferenceComment.check(ast, source: source)
  end

  describe "explicit PR / issue references" do
    test "flags `# fix for PR #34`" do
      assert [issue] = analyze("# fix for PR #34\n:ok")
      assert issue.rule == :stale_reference_comment
      assert issue.meta.label =~ "PR"
    end

    test "flags `# see issue #32`" do
      assert [_] = analyze("# see issue #32 for the full rationale\n:ok")
    end

    test "flags `# the bug class behind several PR #34 fixes`" do
      assert [_] = analyze("# the bug class behind several PR #34 fixes\n:ok")
    end

    test "flags `# See #32`" do
      assert [_] = analyze("# See #32 for context\n:ok")
    end

    test "flags `# pull request 21`" do
      assert [_] = analyze("# pull request 21 reverted this\n:ok")
    end
  end

  describe "see / fix / regression trails" do
    test "flags `# fixed in v0.4`" do
      assert [_] = analyze("# fixed in v0.4\n:ok")
    end

    test "flags `# regression from #46`" do
      assert [_] = analyze("# regression from #46\n:ok")
    end

    test "flags `# added for the OTA flow`" do
      assert [_] = analyze("# added for the OTA flow\n:ok")
    end

    test "flags `# reverted in PR 88`" do
      assert [_] = analyze("# reverted in PR 88\n:ok")
    end

    test "flags `# see commit abc1234`" do
      assert [_] = analyze("# see commit abc1234 for context\n:ok")
    end
  end

  describe "version markers" do
    test "flags `# since v0.3`" do
      assert [_] = analyze("# since v0.3 this is the default\n:ok")
    end

    test "flags `# removed in v2.0`" do
      assert [_] = analyze("# removed in v2.0 — left for compat\n:ok")
    end
  end

  describe "past-tense narration" do
    test "flags `# previously this returned nil`" do
      assert [_] = analyze("# previously this returned nil\n:ok")
    end

    test "flags `# originally we used Foo`" do
      assert [_] = analyze("# originally we used Foo\n:ok")
    end

    test "flags `# used to call Bar.baz/1`" do
      assert [_] = analyze("# used to call Bar.baz/1\n:ok")
    end
  end

  describe "not flagged" do
    test "ignores TODO / FIXME / HACK keepers" do
      assert [] = analyze("# TODO: revisit PR #34 follow-up\n:ok")
      assert [] = analyze("# FIXME: regression from #46\n:ok")
      assert [] = analyze("# HACK: previously this leaked\n:ok")
    end

    test "ignores tool pragmas" do
      assert [] = analyze("# credo:disable-for-next-line — previously a noisy rule\n:ok")
    end

    test "ignores comments about the current code" do
      assert [] = analyze("# Validates the full chain against trusted PAA roots.\n:ok")
      assert [] = analyze("# Splayed across calls because Application.compile_env pins values.\n:ok")
    end

    test "ignores plain code" do
      assert [] = analyze("x = 1")
    end

    test "ignores a comment that just contains the word `previous` (no -ly)" do
      assert [] = analyze("# the previous record in the run\n:ok")
    end

    test "ignores adjectival `previously <past-participle>` describing a noun" do
      # Domain vocabulary, not narration about past code.
      assert [] = analyze("# adding a previously commissioned device to a fabric\n:ok")
      assert [] = analyze("# retransmitting a previously authenticated message\n:ok")
      assert [] = analyze("# a previously seen address — skip dedup\n:ok")
    end

    test "ignores hyphenated `previously-<participle>` adjectives" do
      assert [] = analyze("# a previously-authenticated message arrives\n:ok")
    end

    test "ignores `<noun> used to <verb>` passive purpose descriptions" do
      assert [] = analyze("# persistent-term key used to publish udp_pid to callers\n:ok")
      assert [] = analyze("# the buffer used to stage outbound frames\n:ok")
    end
  end
end
