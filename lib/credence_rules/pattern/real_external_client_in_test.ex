defmodule CredenceRules.Pattern.RealExternalClientInTest do
  @moduledoc """
  Test quality rule: a `test "..."` block that calls a real
  external HTTP client (`Req`, `HTTPoison`, `Finch`, `Tesla`,
  `Mint`, `Hackney`) without any Mox setup in the file. Tests that
  hit the network are slow, flaky, and break in offline
  environments — they should mock the HTTP layer via a behaviour
  and `Mox`.

  ## Bad

      defmodule MyApp.WeatherTest do
        use ExUnit.Case

        test "fetches forecast" do
          {:ok, %{status: 200, body: body}} = Req.get!("https://api.weather.gov/...")
          assert body["forecast"] != nil
        end
      end

  Calls the real API. Fails when DNS is down, when the API rate-
  limits CI, when the body shape changes, when the test machine
  is offline.

  ## Good — mock the HTTP layer

      defmodule MyApp.WeatherTest do
        use ExUnit.Case

        import Mox
        setup :verify_on_exit!

        test "fetches forecast" do
          expect(MyApp.HTTPMock, :get, fn _url ->
            {:ok, %{status: 200, body: %{"forecast" => "sunny"}}}
          end)

          assert {:ok, %{"forecast" => "sunny"}} = MyApp.Weather.forecast()
        end
      end

  ## Detection

  Flags any `test "..."` body that calls a configured HTTP client
  module, IF the test file contains no `Mox` setup (no
  `import Mox`, no `use Mox.SetupHelper`, no `Mox.set_mox_*` calls,
  no `expect/3` / `stub/3` calls).

  Default flagged clients: `Req`, `HTTPoison`, `Finch`, `Tesla`,
  `Mint`, `Hackney`. Configurable via `:client_modules`.

  Mox-presence detection: if the file imports / uses Mox or
  contains any of `Mox.set_mox_global/0`, `Mox.set_mox_private/0`,
  `set_mox_from_context/1`, `expect/3,4`, or `stub/3,4` calls, the
  file is considered "mock-aware" and skipped. False negatives are
  fine here — the goal is to catch the obvious "test calls real
  HTTP" case, not enforce mock discipline.

  ## What's NOT flagged

  - Calls in `setup` / `setup_all` blocks (those are infrastructure,
    not the test body)
  - Calls in `defp` helpers in the test file (the rule looks at
    test bodies specifically)
  - Calls inside modules that import Mox

  ## Why advisory

  Some test suites deliberately hit real external services
  (contract tests, end-to-end suites, smoke tests against staging).
  Tag those with `@tag :external` and configure your CI to skip
  them in the fast lane. Treat findings as "did I forget to mock
  the HTTP layer?" — not a hard cap.
  """

  use CredenceRules.Rule

  alias CredenceRules.AstKeyword

  @default_clients ~w(Req HTTPoison Finch Tesla Mint Hackney)

  @mox_setup_atoms ~w(set_mox_global set_mox_private set_mox_from_context expect stub allow)a

  @impl true
  def priority, do: 471

  @impl true
  def check(ast, opts) do
    clients = Keyword.get(opts, :client_modules, @default_clients)

    # Gate: only scan files whose modules `use ExUnit.Case` or
    # `use ExUnit.CaseTemplate`. Many Elixir libraries define
    # custom `test/2` macros (Phoenix's controller-test DSL, etc.);
    # without the gate this rule would flag arbitrary HTTP-client
    # calls inside any `test "..."` macro body.
    cond do
      not CredenceRules.TestModule.exunit_file?(ast) -> []
      mox_aware?(ast) -> []
      true -> collect_test_calls(ast, clients)
    end
  end

  # File-wide Mox awareness check. Any of:
  # - `import Mox`
  # - `use Mox.SetupHelper` / `use Mox`
  # - alias to Mox
  # - call to Mox.* or any of the Mox setup atoms (expect, stub,
  #   set_mox_*, allow) anywhere in the file
  defp mox_aware?(ast) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        _node, true ->
          {[], true}

        {:import, _, [{:__aliases__, _, [:Mox]} | _]} = node, _ ->
          {node, true}

        {:use, _, [{:__aliases__, _, [:Mox | _]} | _]} = node, _ ->
          {node, true}

        {:alias, _, [{:__aliases__, _, [:Mox]} | _]} = node, _ ->
          {node, true}

        {{:., _, [{:__aliases__, _, [:Mox | _]}, _fun]}, _, _} = node, _ ->
          {node, true}

        # `expect(Mock, :get, fn -> ... end)` etc. — these are usually
        # available because of `import Mox`. Match by function name
        # alone to catch the case where Mox is imported via a help
        # module or similar.
        {name, _meta, args} = node, _ when name in @mox_setup_atoms and is_list(args) ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found?
  end

  defp collect_test_calls(ast, clients) do
    client_set = MapSet.new(clients)

    {_ast, issues} =
      Macro.prewalk(ast, [], fn
        # `test "name" do ... end` and `test "name", do: ...`
        # Walk the test body for client calls.
        {:test, meta, [name | rest]} = node, acc ->
          body = test_body(rest)

          case find_client_calls(body, client_set) do
            [] ->
              {node, acc}

            calls ->
              name_str = extract_name(name) || "<dynamic>"
              {node, [build_issue(meta, name_str, calls) | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(issues)
  end

  # `test/2` body is either:
  #   test "foo" do ... end  → [[do: body]] (kw list as last arg)
  #   test "foo", do: ...    → [[do: body]]
  #   test "foo", %{ctx} do ... end  → [ctx_pattern, [do: body]]
  defp test_body([]), do: nil

  defp test_body(rest) do
    case List.last(rest) do
      kw when is_list(kw) -> AstKeyword.get(kw, :do)
      _ -> nil
    end
  end

  defp find_client_calls(nil, _client_set), do: []

  defp find_client_calls(body, client_set) do
    {_ast, calls} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, _, segs}, fun]}, _, args} = node, acc
        when is_atom(fun) and is_list(args) ->
          if any_segment_matches?(segs, client_set),
            do: {node, [{segs, fun} | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    calls
    |> Enum.uniq()
    |> Enum.map(fn {segs, fun} ->
      "#{Enum.map_join(segs, ".", &Atom.to_string/1)}.#{fun}"
    end)
  end

  defp any_segment_matches?(segs, client_set) do
    Enum.any?(segs, fn s -> MapSet.member?(client_set, Atom.to_string(s)) end)
  end

  defp extract_name(name) when is_binary(name), do: name
  defp extract_name({:__block__, _, [name]}) when is_binary(name), do: name
  defp extract_name(_), do: nil

  defp build_issue(meta, name, calls) do
    sample = calls |> Enum.take(3) |> Enum.join(", ")

    %Issue{
      rule: :real_external_client_in_test,
      message:
        "Test #{inspect(name)} calls #{sample} directly with no Mox setup in the " <>
          "file. Tests that hit the network are slow, flaky, and break offline. " <>
          "Define a behaviour, generate a `Mox` mock for it, and inject the mock " <>
          "module in test config. If this test deliberately hits a real service, " <>
          "tag it (e.g. `@tag :external`) so it can be filtered out of the fast " <>
          "lane.",
      meta: %{
        line: Keyword.get(meta, :line),
        test_name: name,
        calls: calls
      }
    }
  end
end
