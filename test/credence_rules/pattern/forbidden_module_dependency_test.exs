defmodule CredenceRules.Pattern.ForbiddenModuleDependencyTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.ForbiddenModuleDependency

  defp analyze(source, opts \\ []) do
    {:ok, ast} = Code.string_to_quoted(source)
    ForbiddenModuleDependency.check(ast, [source: source] ++ opts)
  end

  defp analyze_sourceror(source, opts \\ []) do
    {:ok, ast} = Sourceror.parse_string(source)
    ForbiddenModuleDependency.check(ast, [source: source] ++ opts)
  end

  describe "check/2 — flagged" do
    test "flags controller calling Repo when edge forbids it" do
      source = ~S"""
      defmodule MyAppWeb.UserController do
        use MyAppWeb, :controller

        def index(conn, _params) do
          users = MyApp.Repo.all(MyApp.User)
          render(conn, "index.html", users: users)
        end
      end
      """

      edges = [{~r/Web\..*Controller$/, ~r/^MyApp\.Repo$/}]
      assert [issue] = analyze(source, forbidden_edges: edges)
      assert issue.rule == :forbidden_module_dependency
      assert issue.meta.source == "MyAppWeb.UserController"
      assert issue.meta.target == "MyApp.Repo"
    end

    test "flags schema-to-context (cycle hazard)" do
      source = ~S"""
      defmodule MyApp.UserSchema do
        use Ecto.Schema

        def fancy_thing(user) do
          MyApp.Context.Profile.calculate(user)
        end
      end
      """

      edges = [{~r/Schema$/, ~r/^MyApp\.Context\./}]
      assert [_] = analyze(source, forbidden_edges: edges)
    end

    test "flags `alias` reference to a forbidden module" do
      source = ~S"""
      defmodule MyAppWeb.UserController do
        alias MyApp.Repo

        def index(conn, _) do
          Repo.all(MyApp.User)
        end
      end
      """

      # The `alias MyApp.Repo` line is the reference; the bare
      # `Repo.all(...)` call is also an `__aliases__` ref but to
      # `Repo` (not `MyApp.Repo`).
      edges = [{~r/Web\..*Controller$/, ~r/^MyApp\.Repo$/}]
      assert [_] = analyze(source, forbidden_edges: edges)
    end

    test "flags multiple edges independently" do
      source = ~S"""
      defmodule MyApp.Lib.Foo do
        def go do
          MyApp.Repo.all(:x)
          MyAppWeb.Endpoint.broadcast("topic", "event", %{})
        end
      end
      """

      edges = [
        {~r/^MyApp\.Lib\./, ~r/^MyApp\.Repo/},
        {~r/^MyApp\.Lib\./, ~r/^MyAppWeb\./}
      ]

      issues = analyze(source, forbidden_edges: edges)
      assert length(issues) >= 2
      targets = issues |> Enum.map(& &1.meta.target) |> Enum.sort()
      assert "MyApp.Repo" in targets
      assert "MyAppWeb.Endpoint" in targets
    end
  end

  describe "check/2 — not flagged" do
    test "does nothing when no edges are configured" do
      source = ~S"""
      defmodule MyAppWeb.UserController do
        def index(conn, _), do: MyApp.Repo.all(MyApp.User)
      end
      """

      assert [] = analyze(source)
    end

    test "ignores when source module doesn't match the edge's source pattern" do
      source = ~S"""
      defmodule MyApp.Accounts do
        def list_users, do: MyApp.Repo.all(MyApp.User)
      end
      """

      # Edge only forbids controllers from touching Repo — Accounts
      # doesn't match the source pattern.
      edges = [{~r/Web\..*Controller$/, ~r/^MyApp\.Repo$/}]
      assert [] = analyze(source, forbidden_edges: edges)
    end

    test "ignores self-references" do
      # A module references itself in its own body (e.g.
      # `%__MODULE__{}` or `MyApp.Foo.helper(...)`). Self-refs
      # aren't violations.
      source = ~S"""
      defmodule MyApp.Foo do
        def go, do: MyApp.Foo.helper()
        def helper, do: :ok
      end
      """

      edges = [{~r/^MyApp\.Foo$/, ~r/^MyApp\.Foo$/}]
      assert [] = analyze(source, forbidden_edges: edges)
    end

    test "ignores files with no defmodule (scripts, configs)" do
      source = ~S"""
      MyApp.Repo.all(:x)
      """

      edges = [{~r/.*/, ~r/^MyApp\.Repo$/}]
      assert [] = analyze(source, forbidden_edges: edges)
    end
  end

  describe "Application env fallback" do
    setup do
      original = Application.get_env(:credence_rules, :forbidden_edges)

      on_exit(fn ->
        if original do
          Application.put_env(:credence_rules, :forbidden_edges, original)
        else
          Application.delete_env(:credence_rules, :forbidden_edges)
        end
      end)
    end

    test "reads :forbidden_edges from Application env when opts don't override" do
      Application.put_env(:credence_rules, :forbidden_edges, [
        {~r/Web\..*Controller$/, ~r/^MyApp\.Repo$/}
      ])

      source = ~S"""
      defmodule MyAppWeb.UserController do
        def index(conn, _), do: MyApp.Repo.all(MyApp.User)
      end
      """

      assert [_] = analyze(source)
    end

    test "rule-opt edges take precedence over Application env" do
      Application.put_env(:credence_rules, :forbidden_edges, [
        {~r/Web\..*Controller$/, ~r/^MyApp\.Repo$/}
      ])

      source = ~S"""
      defmodule MyAppWeb.UserController do
        def index(conn, _), do: MyApp.Repo.all(MyApp.User)
      end
      """

      # Override with an empty list — disables the rule for this run.
      assert [] = analyze(source, forbidden_edges: [])
    end

    test "accepts string patterns and compiles them" do
      source = ~S"""
      defmodule MyAppWeb.UserController do
        def index(conn, _), do: MyApp.Repo.all(MyApp.User)
      end
      """

      assert [_] = analyze(source, forbidden_edges: [{"Web\\..*Controller$", "^MyApp\\.Repo$"}])
    end
  end

  describe "check/2 — Sourceror-parsed (production path)" do
    test "still flags controller calling Repo under Sourceror parse" do
      source = ~S"""
      defmodule MyAppWeb.UserController do
        use MyAppWeb, :controller

        def index(conn, _) do
          MyApp.Repo.all(MyApp.User)
        end
      end
      """

      edges = [{~r/Web\..*Controller$/, ~r/^MyApp\.Repo$/}]
      assert [_] = analyze_sourceror(source, forbidden_edges: edges)
    end
  end

  describe "check/2 — :except source-allowlist" do
    test "skips source modules that match :except (adapters can call Req)" do
      # Rule: nothing under MyApp.* may call Req, EXCEPT Integrations.
      edges = [
        {~r/^MyApp\./, ~r/^Req$/, except: ~r/^MyApp\.Integrations\./}
      ]

      adapter = ~S"""
      defmodule MyApp.Integrations.Stripe do
        def charge(amount), do: Req.post!("https://stripe", json: %{amount: amount})
      end
      """

      assert [] = analyze(adapter, forbidden_edges: edges)

      non_adapter = ~S"""
      defmodule MyApp.Billing.Process do
        def go(amount), do: Req.post!("https://stripe", json: %{amount: amount})
      end
      """

      assert [_] = analyze(non_adapter, forbidden_edges: edges)
    end

    test "no :except means the rule still applies as before (two-tuple form)" do
      edges = [{~r/^MyApp\./, ~r/^Req$/}]

      source = ~S"""
      defmodule MyApp.Integrations.Stripe do
        def charge(amount), do: Req.post!("https://stripe", json: %{amount: amount})
      end
      """

      # Without :except, even the integration module fires.
      assert [_] = analyze(source, forbidden_edges: edges)
    end

    test ":except accepts a string regex" do
      edges = [
        {~r/^MyApp\./, ~r/^Req$/, except: "^MyApp\\.Integrations\\."}
      ]

      source = ~S"""
      defmodule MyApp.Integrations.Stripe do
        def charge, do: Req.post!("url")
      end
      """

      assert [] = analyze(source, forbidden_edges: edges)
    end

    test "two-tuple and three-tuple edges can coexist" do
      edges = [
        {~r/Web\..*Controller$/, ~r/^MyApp\.Repo$/},
        {~r/^MyApp\./, ~r/^Req$/, except: ~r/^MyApp\.Integrations\./}
      ]

      controller = ~S"""
      defmodule MyAppWeb.UserController do
        def index(_, _), do: MyApp.Repo.all(MyApp.User)
      end
      """

      assert [_] = analyze(controller, forbidden_edges: edges)

      integration = ~S"""
      defmodule MyApp.Integrations.Stripe do
        def charge, do: Req.post!("url")
      end
      """

      assert [] = analyze(integration, forbidden_edges: edges)
    end
  end

  describe "check/2 — :beam graph source" do
    test "falls back to :ast when source module isn't compiled" do
      # The synthetic test source defines `Synthetic.NotCompiled`,
      # which doesn't exist as a .beam in our build dir. BeamGraph
      # returns {:error, :not_compiled}; rule falls back to AST.
      source = ~S"""
      defmodule Synthetic.NotCompiled.Controller do
        def go, do: Synthetic.NotCompiled.Repo.all()
      end
      """

      edges = [{~r/Controller$/, ~r/Repo$/}]
      # Falls back to AST → still flags via alias scan.
      assert [_] = analyze(source, forbidden_edges: edges, graph_source: :beam)
    end

    test ":beam scans real compiled modules — drops alias-only references" do
      # The rule's own module (compiled) actually imports BeamGraph
      # but not, say, Logger (no Logger.* calls in its body). If we
      # configure an edge that targets BeamGraph, BEAM source flags
      # it; if we configure an edge targeting a module the rule
      # only aliases without calling, BEAM source does NOT flag.
      #
      # We don't have a clean way to assert the "doesn't flag" case
      # against this catalog's own code without snapshotting, but
      # we can verify the BEAM lookup succeeds and returns something.
      assert {:ok, modules} =
               CredenceRules.CrossFile.BeamGraph.imports_for(
                 "CredenceRules.Pattern.ForbiddenModuleDependency"
               )

      assert is_list(modules)
      # The rule's body calls BeamGraph.imports_for/1 — appears in imports.
      assert "CredenceRules.CrossFile.BeamGraph" in modules
    end
  end
end
