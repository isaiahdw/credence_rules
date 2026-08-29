defmodule CredenceRules.Pattern.SchemaWithBusinessLogicTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Pattern.SchemaWithBusinessLogic

  defp analyze(source) do
    {:ok, ast} = Code.string_to_quoted(source)
    SchemaWithBusinessLogic.check(ast, source: source)
  end

  defp analyze_sourceror(source) do
    {:ok, ast} = Sourceror.parse_string(source)
    SchemaWithBusinessLogic.check(ast, source: source)
  end

  describe "check/2 — flagged" do
    test "flags schema with business-logic functions" do
      source = ~S"""
      defmodule MyApp.User do
        use Ecto.Schema

        schema "users" do
          field :name, :string
        end

        def changeset(user, attrs), do: cast(user, attrs, [:name])

        def calculate_score(user) do
          # business logic
          user.name |> String.length()
        end

        def can_publish?(user) do
          user.role == :admin
        end
      end
      """

      assert [issue] = analyze(source)
      assert issue.rule == :schema_with_business_logic
      assert issue.message =~ "calculate_score/1"
      assert issue.message =~ "can_publish?/1"
    end

    test "flags embedded_schema with business logic" do
      source = ~S"""
      defmodule MyApp.Address do
        use Ecto.Schema

        embedded_schema do
          field :street, :string
          field :city, :string
        end

        def changeset(addr, attrs), do: cast(addr, attrs, [:street, :city])

        def distance_to(addr, other) do
          haversine(addr, other)
        end
      end
      """

      assert [_] = analyze(source)
    end

    test "lists multiple offending function names" do
      source = ~S"""
      defmodule MyApp.User do
        use Ecto.Schema

        schema "users" do
          field :name, :string
        end

        def calculate(u), do: nil
        def score(u), do: nil
        def can?(u), do: nil
        def send_welcome(u), do: nil
        def send_password_reset(u), do: nil
      end
      """

      assert [issue] = analyze(source)
      assert issue.message =~ "+2 more"
    end
  end

  describe "check/2 — not flagged" do
    test "ignores schema with only changeset functions" do
      source = ~S"""
      defmodule MyApp.User do
        use Ecto.Schema

        schema "users" do
          field :name, :string
          field :email, :string
        end

        def changeset(user, attrs) do
          user
          |> Ecto.Changeset.cast(attrs, [:name, :email])
          |> Ecto.Changeset.validate_required([:name, :email])
        end
      end
      """

      assert [] = analyze(source)
    end

    test "ignores schema with multiple *_changeset functions" do
      source = ~S"""
      defmodule MyApp.User do
        use Ecto.Schema

        schema "users" do
          field :email, :string
          field :password_hash, :string
        end

        def registration_changeset(user, attrs), do: ...
        def password_changeset(user, attrs), do: ...
        def profile_changeset(user, attrs), do: ...
      end
      """

      assert [] = analyze(source)
    end

    test "ignores schema with only private helpers" do
      source = ~S"""
      defmodule MyApp.User do
        use Ecto.Schema

        schema "users" do
          field :email, :string
        end

        def changeset(user, attrs) do
          user |> cast(attrs, [:email]) |> hash_password()
        end

        defp hash_password(changeset) do
          # private helper — allowed
          changeset
        end
      end
      """

      assert [] = analyze(source)
    end

    test "ignores non-schema modules (no use Ecto.Schema)" do
      source = ~S"""
      defmodule MyApp.Accounts do
        def calculate_score(user), do: ...
        def can_publish?(user), do: ...
      end
      """

      assert [] = analyze(source)
    end

    test "ignores module that uses Ecto.Schema but has no schema block" do
      # Schema-using behaviour helpers / Pow extensions; not a schema
      # module per the recognition heuristic.
      source = ~S"""
      defmodule MyApp.SchemaMixin do
        use Ecto.Schema

        def __using__(_), do: nil
      end
      """

      assert [] = analyze(source)
    end
  end

  describe "check/2 — Sourceror-parsed (production path)" do
    test "still flags schemas with business logic under Sourceror parse" do
      source = ~S"""
      defmodule MyApp.User do
        use Ecto.Schema

        schema "users" do
          field :name, :string
        end

        def changeset(user, attrs), do: cast(user, attrs, [:name])
        def calculate_score(user), do: user.name |> String.length()
      end
      """

      assert [_] = analyze_sourceror(source)
    end
  end
end
