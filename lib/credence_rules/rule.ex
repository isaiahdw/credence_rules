# credence-file:hub_module — the Rule behaviour is the shared contract every
#   catalog rule `use`s, so its high fan-in is the catalog scaling by design
#   rather than a god-module
defmodule CredenceRules.Rule do
  @moduledoc """
  Thin wrapper around `Credence.Pattern.Rule` for this catalog.

  Three responsibilities:

  1. **Default `fix_patches/2`.** Every rule here is check-only —
     no auto-fixes — so without the default, every rule module
     triggers `function fix_patches/2 required by behaviour
     Credence.Pattern.Rule is not implemented` at compile time. CI
     runs with `--warnings-as-errors`, so each rule needs the
     callback present. Marked `defoverridable` so a rule that
     wants auto-fix support later can override.

  2. **`@severity` / `@confidence` module attributes.** Rules can
     declare per-rule severity/confidence overrides that the
     wrapper exposes as `severity/0` / `confidence/0` functions.
     The analyser reads these to build the enriched finding
     shape. Without the attributes, defaults come from
     `CredenceRules.Finding`.

  3. **`@hint` / `@carve_outs` module attributes.** Rules can
     declare a structured fix recommendation and a list of
     well-known carve-outs (cases where the rule would be wrong).
     The AI format surfaces these alongside `:message` so an LLM
     agent can act on the finding without re-parsing English from
     the prose message. The text and github formats stay terse —
     hints are agent-targeted, message stays human-targeted.

  Usage:

      defmodule CredenceRules.Pattern.Foo do
        use CredenceRules.Rule

        @severity :high
        @confidence :medium

        @hint \"""
        Split the GenServer by concern: extract the cache handlers
        into `MyApp.Cache` and the config handlers into `MyApp.Config`.
        Each new GenServer registers with its own `name: __MODULE__`.
        \"""

        @carve_outs [
          "Per-instance GenServers (registered via {:via, Registry, ...}) — see :max_handle_call_per_instance",
          "ETS-owning GenServers whose reads bypass the mailbox — see :max_handle_call_read_bypass"
        ]

        @impl true
        def check(ast, _opts), do: []
      end

  All four attributes are optional. When absent, the analyser
  uses defaults (severity from category, confidence from heuristic
  table, hint/carve_outs left as nil/[]).
  """

  defmacro __using__(opts) do
    quote do
      use Credence.Pattern.Rule, unquote(opts)

      # Pick up module attributes. Defaults to `nil` (severity /
      # confidence / hint) or `[]` (carve_outs); the wrapper
      # treats nil/[] as "no per-rule override, use the default."
      Module.register_attribute(__MODULE__, :severity, persist: false)
      Module.register_attribute(__MODULE__, :confidence, persist: false)
      Module.register_attribute(__MODULE__, :hint, persist: false)
      Module.register_attribute(__MODULE__, :carve_outs, persist: false)

      @before_compile CredenceRules.Rule

      @impl Credence.Pattern.Rule
      def fix_patches(_ast, _opts), do: []

      defoverridable fix_patches: 2
    end
  end

  defmacro __before_compile__(env) do
    severity = Module.get_attribute(env.module, :severity)
    confidence = Module.get_attribute(env.module, :confidence)
    hint = Module.get_attribute(env.module, :hint)
    carve_outs = Module.get_attribute(env.module, :carve_outs) || []

    quote do
      @doc false
      def severity, do: unquote(severity)

      @doc false
      def confidence, do: unquote(confidence)

      @doc false
      def hint, do: unquote(hint)

      @doc false
      def carve_outs, do: unquote(carve_outs)
    end
  end
end
