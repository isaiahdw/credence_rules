defmodule CredenceRules.Pattern.CaseDestructureShouldBeFunctionClauseTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.CaseDestructureShouldBeFunctionClause

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    CaseDestructureShouldBeFunctionClause.check(ast, source: source)
  end

  defp analyze_sourceror(source) do
    {:ok, ast} = Sourceror.parse_string(source)
    CaseDestructureShouldBeFunctionClause.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "binary parser destructure with truncation fallback" do
      source = ~S"""
      defp read_rr_header(packet, off) do
        case packet do
          <<_::binary-size(off), type::16, class_raw::16, ttl::32, rdlength::16, _::binary>> ->
            {:ok, %{type: type, class_raw: class_raw, ttl: ttl, rdlength: rdlength}, off + 10}

          _ ->
            {:error, :truncated}
        end
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :case_destructure_should_be_function_clause
      assert issue.meta.function == :read_rr_header
    end

    test "tuple destructure with simple fallback" do
      source = ~S"""
      def parse(msg) do
        case msg do
          {:ok, val} -> {:done, val}
          _ -> :error
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "map destructure with nil fallback" do
      source = ~S"""
      def extract(input) do
        case input do
          %{token: token, exp: exp} -> {:ok, token, exp}
          _ -> nil
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "wildcard arm written first still flags" do
      source = ~S"""
      def go(packet) do
        case packet do
          _ -> {:error, :truncated}
          <<a::8, rest::binary>> -> {:ok, a, rest}
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "flags under Sourceror parse (production path)" do
      source = ~S"""
      defmodule P do
        defp read_rdata(packet, off, len) do
          case packet do
            <<_::binary-size(off), rdata::binary-size(len), _::binary>> -> {:ok, rdata}
            _ -> {:error, :truncated}
          end
        end
      end
      """

      assert [_] = analyze_sourceror(source)
    end
  end

  describe "check/2 — not flagged" do
    test "3+ branches (case_arg_could_be_function_clauses' domain)" do
      source = ~S"""
      def handle(event) do
        case event do
          {:a, v} -> a(v)
          {:b, v} -> b(v)
          _ -> :ignore
        end
      end
      """

      assert [] = analyze(source)
    end

    test "subject is a function call, not a parameter" do
      source = ~S"""
      def go(x) do
        case fetch(x) do
          {:ok, v} -> v
          _ -> :error
        end
      end
      """

      assert [] = analyze(source)
    end

    test "value dispatch with no destructuring binding" do
      source = ~S"""
      def go(state) do
        case state do
          :ready -> :go
          _ -> :wait
        end
      end
      """

      assert [] = analyze(source)
    end

    test "fallback arm does real work" do
      source = ~S"""
      def go(packet) do
        case packet do
          <<a::8, _::binary>> ->
            {:ok, a}

          _ ->
            Logger.error("bad packet")
            {:error, :bad}
        end
      end
      """

      assert [] = analyze(source)
    end

    test "pre-work before the case (not the whole body)" do
      source = ~S"""
      def go(packet) do
        log(packet)

        case packet do
          <<a::8, _::binary>> -> {:ok, a}
          _ -> {:error, :x}
        end
      end
      """

      assert [] = analyze(source)
    end

    test "guard on the destructure arm" do
      source = ~S"""
      def go(packet) do
        case packet do
          <<a::8, _::binary>> when a > 0 -> {:ok, a}
          _ -> {:error, :x}
        end
      end
      """

      assert [] = analyze(source)
    end

    test "both arms destructure (no wildcard fallback)" do
      source = ~S"""
      def go(input) do
        case input do
          {:ok, v} -> {:done, v}
          {:error, e} -> {:failed, e}
        end
      end
      """

      assert [] = analyze(source)
    end

    test "single-wildcard case (case_with_single_wildcard_arm's domain)" do
      source = ~S"""
      def go(x) do
        case x do
          _ -> :ok
        end
      end
      """

      assert [] = analyze(source)
    end
  end
end
