defmodule CredenceRules.Pattern.RepeatedSubtreeInFunctionTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.RepeatedSubtreeInFunction

  defp analyze(source, opts \\ []) do
    {:ok, ast} = Code.string_to_quoted(source)
    RepeatedSubtreeInFunction.check(ast, [source: source] ++ opts)
  end

  defp analyze_sourceror(source, opts \\ []) do
    {:ok, ast} = Sourceror.parse_string(source)
    RepeatedSubtreeInFunction.check(ast, [source: source] ++ opts)
  end

  describe "check/2 — flagged" do
    test "flags duplicated multi-stage pipeline" do
      # Threshold is 14 nodes. The pipelines differ only in the input
      # variable (a vs b) — atoms preserved in canonical form, so a
      # divergent atom literal between the two pipelines would prevent
      # the match.
      source = ~S"""
      def normalize(a, b) do
        x =
          a
          |> Enum.filter(& &1.active)
          |> Enum.map(& &1.name)
          |> Enum.uniq()
          |> Enum.sort()

        y =
          b
          |> Enum.filter(& &1.active)
          |> Enum.map(& &1.name)
          |> Enum.uniq()
          |> Enum.sort()

        {x, y}
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :repeated_subtree_in_function
      assert issue.meta.occurrences >= 2
    end

    test "flags duplicated case expressions with same shape" do
      source = ~S"""
      def go(a, b) do
        x =
          case lookup(a) do
            {:ok, val} -> {:found, val}
            :error -> {:missing, a}
          end

        y =
          case lookup(b) do
            {:ok, val} -> {:found, val}
            :error -> {:missing, b}
          end

        {x, y}
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "ignores function with no duplicated subtrees" do
      source = ~S"""
      def go(x) do
        a = preprocess(x)
        b = transform(a)
        c = format(b)
        {a, b, c}
      end
      """

      assert [] = analyze(source)
    end

    test "ignores duplicates below the size threshold" do
      # Single function calls: `foo(x)` is 2 nodes — well below the
      # default threshold of 8.
      source = ~S"""
      def go(x, y) do
        a = foo(x)
        b = foo(y)
        {a, b}
      end
      """

      assert [] = analyze(source)
    end

    test "ignores duplicates across different functions" do
      # `repeated_subtree_in_module` handles cross-function duplicates;
      # this rule only looks within one function body.
      source = ~S"""
      def first(x) do
        x
        |> Enum.filter(&active?/1)
        |> Enum.map(& &1.name)
        |> Enum.sort()
      end

      def second(x) do
        x
        |> Enum.filter(&active?/1)
        |> Enum.map(& &1.name)
        |> Enum.sort()
      end
      """

      assert [] = analyze(source)
    end

    test "ignores trivial bodies" do
      assert [] = analyze("def go, do: :ok")
    end

    @verhoeff_table ~S"""
    def multiply_table do
      [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3],
        [1, 2, 3, 4, 0, 6, 7, 8, 9, 5, 1, 2, 3, 4],
        [2, 3, 4, 0, 1, 7, 8, 9, 5, 6, 2, 3, 4, 0],
        [3, 4, 0, 1, 2, 8, 9, 5, 6, 7, 3, 4, 0, 1]
      ]
    end
    """

    test "ignores rows of a flat data table (Verhoeff-style lookup)" do
      # Each inner list is structurally identical (`[N, N, …]`) but is a
      # mathematical constant, not repeated logic. The enclosing list IS
      # the table; there's nothing to extract. Parsed via Sourceror —
      # the production path, where list literals carry the trivia
      # metadata that makes them cluster.
      assert [] = analyze_sourceror(@verhoeff_table)
    end

    test "flag_pure_data_duplicates: true reports data tables anyway" do
      assert [_] = analyze_sourceror(@verhoeff_table, flag_pure_data_duplicates: true)
    end

    @log_branches ~S"""
    def open(primary_opts, fallback_opts) do
      case :gen_udp.open(0, primary_opts) do
        {:ok, socket} ->
          {:ok, socket}

        {:error, reason} ->
          Logger.error("[Udp] primary open failed: #{inspect(reason)} opts=#{inspect(primary_opts)}")

          case :gen_udp.open(0, fallback_opts) do
            {:ok, socket} ->
              {:ok, socket}

            {:error, reason} ->
              Logger.error("[Udp] primary open failed: #{inspect(reason)} opts=#{inspect(fallback_opts)}")
              {:stop, reason}
          end
      end
    end
    """

    test "ignores a Logger error-log shape repeated in one body" do
      assert [] = analyze(@log_branches)
    end

    test "flag_logging_idioms: true reports the repeated log shape" do
      assert [_] = analyze(@log_branches, flag_logging_idioms: true)
    end
  end

  describe "check/2 — Sourceror-parsed (production path)" do
    test "still flags duplicated pipelines under Sourceror parse" do
      source = ~S"""
      def normalize(a, b) do
        x =
          a
          |> Enum.filter(& &1.active)
          |> Enum.map(& &1.name)
          |> Enum.uniq()
          |> Enum.sort()

        y =
          b
          |> Enum.filter(& &1.active)
          |> Enum.map(& &1.name)
          |> Enum.uniq()
          |> Enum.sort()

        {x, y}
      end
      """

      assert [_] = analyze_sourceror(source)
    end
  end
end
