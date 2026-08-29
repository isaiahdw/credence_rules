defmodule CredenceRules.Pattern.OptionBranchedFunctionTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.OptionBranchedFunction

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    OptionBranchedFunction.check(ast, source: source)
  end

  defp analyze_sourceror(source) do
    {:ok, ast} = Sourceror.parse_string(source)
    OptionBranchedFunction.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags `case Keyword.get(opts, :mode)` dispatch with 3+ branches" do
      source = ~S"""
      def go(input, opts \\ []) do
        case Keyword.get(opts, :mode) do
          :fast -> do_fast(input)
          :safe -> do_safe(input)
          :paranoid -> do_paranoid(input)
        end
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :option_branched_function
      assert issue.meta.opts_param == :opts
      assert issue.meta.clauses == 3
    end

    test "flags with `options` parameter name" do
      source = ~S"""
      def go(x, options \\ []) do
        case Keyword.get(options, :strategy) do
          :a -> handle_a(x)
          :b -> handle_b(x)
          :c -> handle_c(x)
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "flags with `config` parameter name" do
      source = ~S"""
      def go(config) do
        case Keyword.get(config, :mode) do
          :a -> a()
          :b -> b()
          :c -> c()
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "flags `opts[:key]` access shape" do
      source = ~S"""
      def go(input, opts) do
        case opts[:mode] do
          :a -> a(input)
          :b -> b(input)
          :c -> c(input)
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "flags `Keyword.fetch!(opts, :mode)` shape" do
      source = ~S"""
      def go(opts) do
        case Keyword.fetch!(opts, :mode) do
          :a -> a()
          :b -> b()
          :c -> c()
        end
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "ignores 2-branch dispatch (not enough fan-out)" do
      source = ~S"""
      def go(opts) do
        case Keyword.get(opts, :mode) do
          :a -> a()
          :b -> b()
        end
      end
      """

      assert [] = analyze(source)
    end

    test "ignores when the case subject isn't an opts lookup" do
      source = ~S"""
      def go(input, opts) do
        case classify(input) do
          :a -> a(input, opts)
          :b -> b(input, opts)
          :c -> c(input, opts)
        end
      end
      """

      assert [] = analyze(source)
    end

    test "ignores functions with no opts parameter" do
      source = ~S"""
      def go(x) do
        case x do
          :a -> a()
          :b -> b()
          :c -> c()
        end
      end
      """

      assert [] = analyze(source)
    end

    test "ignores when the case is wrapped in other logic (not top-level)" do
      # A `case` nested inside a `with` or after other statements is
      # different — this rule is about the "dispatch is the function"
      # shape specifically. Other case-mixed shapes are out of scope.
      source = ~S"""
      def go(input, opts) do
        x = preprocess(input)
        result =
          case Keyword.get(opts, :mode) do
            :a -> a(x)
            :b -> b(x)
            :c -> c(x)
          end
        postprocess(result)
      end
      """

      assert [] = analyze(source)
    end

    test "ignores wildcard-only fall-through (only counts non-wildcard arms)" do
      # 2 specific + wildcard = only 2 non-wildcard clauses.
      source = ~S"""
      def go(opts) do
        case Keyword.get(opts, :mode) do
          :a -> a()
          :b -> b()
          _ -> :default
        end
      end
      """

      assert [] = analyze(source)
    end
  end

  describe "check/2 — Sourceror-parsed (production path)" do
    test "still flags dispatch under Sourceror parse" do
      source = ~S"""
      def go(input, opts \\ []) do
        case Keyword.get(opts, :mode) do
          :a -> a(input)
          :b -> b(input)
          :c -> c(input)
        end
      end
      """

      assert [_] = analyze_sourceror(source)
    end
  end
end
