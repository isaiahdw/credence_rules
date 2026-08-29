defmodule CredenceRules.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/isaiahdw/credence_rules"

  def project do
    [
      app: :credence_rules,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: false,
      deps: deps(),
      description: description(),
      package: package(),
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:credence, "~> 0.8.1"},
      {:jason, "~> 1.4"},
      # Direct dep — the cross-file phase parses files via Sourceror.
      # Credence pulls Sourceror transitively, but depending on a
      # transitive dep is fragile (a credence release could swap to
      # a different parser).
      {:sourceror, "~> 1.11"}
    ]
  end

  defp description do
    "Reusable Credence Pattern rules targeting LLM failure modes not covered by the upstream catalog, " <>
      "plus a `mix credence.check` task with boundary/advisory taxonomy."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE .formatter.exs)
    ]
  end
end
