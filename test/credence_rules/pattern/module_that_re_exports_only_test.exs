defmodule CredenceRules.Pattern.ModuleThatReExportsOnlyTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.ModuleThatReExportsOnly

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    ModuleThatReExportsOnly.check(ast, source: source)
  end

  defp analyze_sourceror(source) do
    {:ok, ast} = Sourceror.parse_string(source)
    ModuleThatReExportsOnly.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags a module where every def is a single delegate" do
      source = ~S"""
      defmodule MyApp.Users do
        def fetch(id), do: Storage.fetch(id)
        def create(attrs), do: Storage.create(attrs)
        def update(user, attrs), do: Storage.update(user, attrs)
        def delete(user), do: Storage.delete(user)
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :module_that_re_exports_only
      assert issue.meta.defs == 4
    end

    test "flags with multi-segment target modules" do
      source = ~S"""
      defmodule Wrap do
        def a(x), do: Foo.Bar.Baz.a(x)
        def b(x), do: Foo.Bar.Baz.b(x)
        def c(x), do: Foo.Bar.Baz.c(x)
      end
      """

      assert [_] = analyze(source)
    end
  end

  describe "check/2 — not flagged" do
    test "ignores modules with fewer than min_defs delegates" do
      source = ~S"""
      defmodule Tiny do
        def a(x), do: Foo.a(x)
        def b(x), do: Foo.b(x)
      end
      """

      assert [] = analyze(source)
    end

    test "ignores when at least one def has real logic" do
      source = ~S"""
      defmodule Mixed do
        def a(x), do: Storage.a(x)
        def b(x), do: Storage.b(x)
        def c(x) do
          y = preprocess(x)
          Storage.c(y)
        end
      end
      """

      assert [] = analyze(source)
    end

    test "ignores when defdelegate is already used (no manual passthrough)" do
      # defdelegate doesn't generate a `def` AST node — it has its own
      # form. A module using only `defdelegate` has zero matching defs,
      # so the rule has no defs to check.
      source = ~S"""
      defmodule Good do
        defdelegate fetch(id), to: Storage
        defdelegate create(attrs), to: Storage
        defdelegate update(user, attrs), to: Storage
      end
      """

      assert [] = analyze(source)
    end

    test "ignores when args don't match params (transformation, not passthrough)" do
      source = ~S"""
      defmodule M do
        def a(x), do: Foo.a(x + 1)
        def b(x), do: Foo.b(transform(x))
        def c(x), do: Foo.c(x)
      end
      """

      assert [] = analyze(source)
    end

    test "ignores local-call defs (not remote)" do
      source = ~S"""
      defmodule M do
        def a(x), do: local(x)
        def b(x), do: local(x)
        def c(x), do: local(x)
      end
      """

      assert [] = analyze(source)
    end
  end

  describe "check/2 — Sourceror-parsed (production path)" do
    test "still flags manual passthrough modules under Sourceror parse" do
      source = ~S"""
      defmodule Wrap do
        def a(x), do: Storage.a(x)
        def b(x), do: Storage.b(x)
        def c(x), do: Storage.c(x)
      end
      """

      assert [_] = analyze_sourceror(source)
    end

    test "still ignores defdelegate-only modules under Sourceror parse" do
      source = ~S"""
      defmodule Good do
        defdelegate a(x), to: Storage
        defdelegate b(x), to: Storage
        defdelegate c(x), to: Storage
      end
      """

      assert [] = analyze_sourceror(source)
    end
  end

  describe "check/2 — single-target requirement" do
    test "does NOT flag a facade that delegates to multiple collaborators" do
      # The docs say "passthroughs to a single target module."
      # A boundary contract that composes several adapters (storage,
      # mailer, notifier) legitimately needs a layer to coordinate;
      # not the same smell as a one-target re-export wrapper.
      source = ~S"""
      defmodule MyApp.Users do
        def fetch(id), do: MyApp.Users.Storage.fetch(id)
        def create(attrs), do: MyApp.Users.Storage.create(attrs)
        def send_welcome(user), do: MyApp.Users.Mailer.send_welcome(user)
        def notify_admins(user), do: MyApp.Users.Notifier.notify(user)
      end
      """

      assert [] = analyze(source)
    end

    test "flags only when ALL defs target the same module" do
      source = ~S"""
      defmodule MyApp.Users do
        def fetch(id), do: MyApp.Users.Storage.fetch(id)
        def create(attrs), do: MyApp.Users.Storage.create(attrs)
        def update(user, attrs), do: MyApp.Users.Storage.update(user, attrs)
      end
      """

      assert [issue] = analyze(source)
      assert issue.meta.target == "MyApp.Users.Storage"
      # Message points at the actual target so reviewers know which
      # module to talk to.
      assert issue.message =~ "MyApp.Users.Storage"
    end
  end
end
