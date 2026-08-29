defmodule CredenceRules.Finding do
  @moduledoc """
  Helpers for the enriched finding shape — `:severity`,
  `:confidence`, and `:fingerprint` fields layered onto the basic
  `{rule, line, message, path}` issue map.

  Severity and confidence are independent dimensions:

  - **severity** — how bad the finding is if real.
    `:high` runtime hazards (data loss, deadlock, race), OTP
    violations; `:medium` architecture / SRP / DRY smells;
    `:low` documentation, naming, narration.
  - **confidence** — how likely the detection is correct.
    `:high` structural pattern matches that can't fire on the
    wrong shape; `:medium` heuristic detection that's right most
    of the time (IOSP "mixed function" counts, clustered names);
    `:low` name-only signals (vague test name patterns,
    OOP-style suffixes).

  ## Strict mode

  `mix credence.check --strict` exits 1 when a finding's
  severity is at-or-above the configured `:strict_min_severity`
  AND its confidence is at-or-above `:strict_min_confidence`.
  Defaults: both `:high`. So the default strict gate fires only
  on findings the rule is sure about AND that genuinely matter at
  runtime.

  Tune for stricter or looser CI:

      mix credence.check --strict --strict-min-severity medium
      # fails on architecture / DRY too, not just runtime hazards

      mix credence.check --strict --strict-min-confidence low
      # fails on heuristic / name-based rules too

  ## Per-rule overrides

  A rule module can declare its own defaults via module attributes
  picked up by the `CredenceRules.Rule` wrapper:

      defmodule MyRule do
        use CredenceRules.Rule

        @severity :high
        @confidence :medium  # heuristic detection
      end

  Without these attributes the rule gets defaults from its
  category (see `severity_for/1`) and `:confidence => :high`.

  ## Fingerprint

  Stable hash for baseline matching, derived from a canonical
  payload of `{rule, path, normalized_message, extracted_meta}`
  using SHA-256 (truncated to 16 hex chars / 64 bits). Line
  number is NOT part of the key — small line moves don't churn
  the baseline. The message normaliser collapses whitespace
  but does NOT truncate; wording tweaks DO change the
  fingerprint (run `--update-baseline` to refresh). Cross-file
  rules fold in whitelisted `:meta` fields
  (`source`, `target`, `cycle`, `files`, `cluster_id`, etc.)
  so distinct findings that share the same prose don't collide.

  See `CredenceRules.Baseline` for the file format that
  stores these fingerprints (currently v3).
  """

  alias CredenceRules.Category

  @typedoc "Severity / confidence ordinals."
  @type level :: :high | :medium | :low

  @level_rank %{high: 3, medium: 2, low: 1}

  # Rules whose detection is intentionally heuristic — name-based,
  # structural-shape clustering, or threshold-based checks that're
  # right most of the time but not bulletproof. Per-rule
  # @confidence attribute overrides this.
  #
  # `severity_for/1` ALSO caps these at `:low` regardless of
  # category — a heuristic suggestion shouldn't carry the same
  # score weight as a runtime hazard. A `rescue_catch_all` finding
  # really IS a bug; a `repeated_subtree_in_module` is "you might
  # want to extract a helper." The score model treats them
  # accordingly.
  @heuristic_rule_confidence %{
    iosp_mixed_function: :medium,
    repeated_subtree_in_function: :medium,
    repeated_subtree_in_module: :medium,
    repeated_case_arm_body: :medium,
    cross_file_duplicate_block: :medium,
    large_defstruct: :medium,
    vague_test_name: :low,
    manager_service_module_name: :low,
    obvious_comment: :medium,
    narrator_comment: :medium,
    narrator_doc: :medium,
    stale_reference_comment: :low,
    step_comment: :low,
    option_branched_function: :medium,
    fat_controller: :medium,
    schema_with_business_logic: :medium,
    module_that_re_exports_only: :medium,
    module_instability: :medium,
    hub_module: :medium,
    oversized_message_handler_module: :medium
  }

  @doc """
  Returns the default severity for a rule atom.

  Three-step resolution:

  1. **Heuristic rules cap at `:low`** — if the rule is in the
     internal heuristic table (clustering / threshold / name-based
     detection), severity is forced to `:low` regardless of
     category. These are advisory suggestions, not runtime bugs;
     their score weight reflects that.
  2. **Advisory rules cap at `:medium`** — if the rule is in
     `@advisory_rules` and the category default would be `:high`,
     cap at `:medium`. Preserves the prior boundary/advisory
     semantics for `--strict`'s default gate.
  3. **Otherwise** — category default (`:concurrency` /
     `:safety` → `:high`; `:test_quality` / `:architecture` /
     `:dry` / `:idioms` → `:medium`; `:documentation` /
     `:naming` → `:low`).

  Override per-rule via `@severity` module attribute.
  """
  @spec severity_for(atom()) :: level()
  def severity_for(rule) when is_atom(rule) do
    if Map.has_key?(@heuristic_rule_confidence, rule) do
      :low
    else
      base = category_severity(rule)

      if CredenceRules.advisory?(rule) and base == :high,
        do: :medium,
        else: base
    end
  end

  # Per-category default severity. Categories not listed (or
  # absent from the lookup) fall back to :medium.
  @category_severity %{
    concurrency: :high,
    safety: :high,
    test_quality: :medium,
    architecture: :medium,
    dry: :medium,
    idioms: :medium,
    documentation: :low,
    naming: :low
  }

  defp category_severity(rule) do
    Map.get(@category_severity, Category.for_rule(rule), :medium)
  end

  @doc """
  Returns the default confidence for a rule atom. Most rules are
  structural matches with high confidence; the heuristic ones
  (IOSP mixed-function counts, name-based detectors,
  multi-clustering) get medium.
  """
  @spec confidence_for(atom()) :: level()
  def confidence_for(rule) when is_atom(rule) do
    Map.get(@heuristic_rule_confidence, rule, :high)
  end

  @doc """
  Comparison helper for the ordinal levels. `gte?(severity,
  min)` returns true iff `severity` is at-or-above `min`.

      iex> CredenceRules.Finding.gte?(:high, :medium)
      true
      iex> CredenceRules.Finding.gte?(:low, :medium)
      false
  """
  @spec gte?(level(), level()) :: boolean()
  def gte?(level, threshold) do
    Map.fetch!(@level_rank, level) >= Map.fetch!(@level_rank, threshold)
  end

  @doc """
  Strict-mode predicate: a finding triggers the gate iff both its
  severity AND confidence are at-or-above the configured
  thresholds. Single source of truth for both the Mix task's exit
  code and the GitHub formatter's summary annotation — keeping
  them in sync, so a CI run can't fail while the summary shows
  green (or vice versa).

  When `:severity` or `:confidence` is missing on the finding,
  falls back to the rule's category-derived default (via
  `severity_for/1` / `confidence_for/1`). This handles two
  cases correctly:

  - **Crash-synthetic findings** carry explicit `severity: :high`,
    `confidence: :high` so they trip the gate without depending
    on the rule atom — `:analyse_crashed` and
    `:cross_file_rule_crashed` aren't in the category map.
  - **Hand-built test fixtures** (without explicit severity) get
    the same defaults the real pipeline assigns, so they behave
    consistently with production findings.
  """
  @spec strict_fail?(map(), level(), level()) :: boolean()
  def strict_fail?(finding, min_severity, min_confidence) do
    rule = Map.get(finding, :rule)
    sev = Map.get(finding, :severity) || severity_for(rule)
    conf = Map.get(finding, :confidence) || confidence_for(rule)

    gte?(sev, min_severity) and gte?(conf, min_confidence)
  end

  @doc "Parse a string level (\"high\"/\"medium\"/\"low\") into atom."
  @spec parse_level(String.t() | atom() | nil) :: {:ok, level()} | :error
  def parse_level(nil), do: :error
  def parse_level(level) when level in [:high, :medium, :low], do: {:ok, level}
  def parse_level("high"), do: {:ok, :high}
  def parse_level("medium"), do: {:ok, :medium}
  def parse_level("low"), do: {:ok, :low}
  def parse_level(_), do: :error

  @doc """
  Compute a stable fingerprint for a finding. Used by the baseline
  to match findings across runs even when line numbers shift.

  Hashes a canonical payload of `{rule, path, normalized_message,
  meta_extract}` with SHA-256 and returns the first 16 hex chars.
  64-bit truncation gives ~2^32 collision resistance — more than
  enough for baselines that hold at most tens of thousands of
  findings. Previously used `:erlang.phash2/1` which is only
  ~2^27 entropy across its output space; collisions were
  reachable for large baselines.

  ## What's in the payload

  - `rule` — atom, distinguishes rule type
  - `path` — relative path to the file
  - normalized message — collapsed whitespace, full string (no
    longer truncated at 120 chars; long cross-file messages
    carry distinguishing evidence past the prefix)
  - extracted meta — see below

  ## Meta extraction

  Cross-file findings often carry structured `:meta` that's MORE
  distinguishing than the prose message — cycle member lists,
  cluster sizes, source/target module names. When `:meta` is
  present, a small whitelist of stable keys is included in the
  payload:

  - `:source`, `:target` — module names (forbidden_module_dependency,
    no_internal_module_crossing)
  - `:members` — cycle member list (circular_module_dependency)
  - `:cluster_size`, `:cluster_id` — duplicate-block clusters
  - `:source_modules`, `:target_modules` — hub-module fan-in/out

  The whitelist is conservative: only fields that are deterministic
  given the input code are included. Position / size counters that
  change with code growth are excluded.

      iex> CredenceRules.Finding.fingerprint(%{
      ...>   rule: :large_defstruct,
      ...>   path: "lib/foo.ex",
      ...>   message: "`defstruct` with 12 fields ..."
      ...> })
      "2DE60809410C625C"
  """
  @spec fingerprint(%{
          required(:rule) => atom(),
          required(:path) => String.t(),
          optional(:message) => String.t() | nil,
          optional(:meta) => map() | nil
        }) ::
          String.t()
  def fingerprint(%{rule: rule, path: path} = finding) do
    payload =
      IO.iodata_to_binary([
        "rule=",
        Atom.to_string(rule),
        "\npath=",
        path || "",
        "\nmsg=",
        normalize_message(Map.get(finding, :message)),
        "\nmeta=",
        meta_payload(Map.get(finding, :meta))
      ])

    # 16 hex chars = 64 bits — small enough to eyeball in baselines,
    # large enough that collisions are ~impossible at our scale.
    :sha256
    |> :crypto.hash(payload)
    |> Base.encode16(case: :upper)
    |> binary_part(0, 16)
  end

  # Whitespace collapse only — no truncation. Long cross-file
  # messages (cycle members, file lists) keep their distinguishing
  # tail intact, so SHA-256 over the full normalised message can
  # tell two same-prefix findings apart. The hash cost is cheap;
  # the truncation would silently collide.
  defp normalize_message(nil), do: ""

  defp normalize_message(message) when is_binary(message) do
    message
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  # Stable structured meta keys to fold into the fingerprint
  # payload. Whitelist over allowlist — folding all of :meta would
  # mean transient counters (file sizes, position offsets) shift
  # the fingerprint as the codebase grows; cycle members and
  # source/target module names are much more stable than prose.
  # Sourced from what cross-file rules actually emit
  # today — keep this list in sync with rules under
  # `lib/credence_rules/cross_file/` and `lib/credence_rules/pattern/`:
  #
  # - `source` / `target` — forbidden_module_dependency,
  #   no_internal_module_crossing
  # - `cycle` — circular_dependency (list of module names)
  # - `files` — cross_file_duplicate_block (sorted file list)
  # - `cluster_id` — cross_file_duplicate_block (subtree hash —
  #   distinguishes clusters with same files/size/count)
  # - `function` — fat_controller, iosp_*, etc.
  # - `source_modules` / `target_modules` — hub_module
  #
  # Adding a new whitelisted key without checking the rule that
  # emits it is a no-op; the key just isn't present in :meta.
  # Removing a key whose rule still emits it CHANGES fingerprints
  # (baseline-invalidating). Add freely, remove with version bump.
  @meta_fingerprint_keys ~w(
    source target cycle files cluster_id
    source_modules target_modules function
  )a

  defp meta_payload(nil), do: ""
  defp meta_payload(meta) when not is_map(meta), do: ""

  defp meta_payload(meta) do
    @meta_fingerprint_keys
    |> Enum.flat_map(fn key ->
      case Map.get(meta, key) do
        nil -> []
        value -> ["#{key}=", inspect(value, limit: :infinity, printable_limit: :infinity), ";"]
      end
    end)
    |> IO.iodata_to_binary()
  end

  @doc """
  Returns a public URL pointing at the rule module's source on
  GitHub (or wherever `:docs_url_base` Application env points).
  Used by the AI format so an LLM agent can fetch the moduledoc
  for full context on a finding.

  Default base is `https://github.com/isaiahdw/credence_rules/blob/main/`.
  Override per-project:

      config :credence_rules,
        docs_url_base: "https://github.com/myorg/myfork/blob/main/"

  Returns `nil` if the rule atom doesn't resolve to a known module
  (built-in Credence rules, custom user rules not in the catalog).
  """
  @spec docs_url(atom()) :: String.t() | nil
  def docs_url(rule) when is_atom(rule) do
    case rule_module_path(rule) do
      nil -> nil
      path -> docs_url_base() <> path
    end
  end

  @doc """
  Returns a shell command that fetches the rule module's source as
  raw text — pre-baked for LLM agents in shell-oriented
  environments (no `WebFetch` tool available).

  Default uses `gh api` with the raw Accept header against the
  catalog's GitHub repo. The command outputs the file's bytes to
  stdout with no JSON wrapping or base64 — agent can pipe to a
  pager or capture directly:

      $ gh api repos/isaiahdw/credence_rules/contents/lib/credence_rules/pattern/large_defstruct.ex \\
            -H "Accept: application/vnd.github.raw"

  Customize via `:docs_fetch_command_template` Application env.
  The template is a string with `{path}` and `{repo_slug}`
  placeholders:

      config :credence_rules,
        docs_fetch_command_template:
          "curl -fsSL https://raw.githubusercontent.com/{repo_slug}/main/{path}"

  Returns `nil` for unknown rule atoms.
  """
  @spec docs_fetch_command(atom()) :: String.t() | nil
  def docs_fetch_command(rule) when is_atom(rule) do
    case rule_module_path(rule) do
      nil ->
        nil

      path ->
        docs_fetch_command_template()
        |> String.replace("{path}", path)
        |> String.replace("{repo_slug}", repo_slug())
    end
  end

  defp rule_module_path(rule) do
    module = find_rule_module(rule)
    if module, do: module_to_source_path(module), else: nil
  end

  defp find_rule_module(rule) do
    Enum.find(
      CredenceRules.rules() ++ CredenceRules.cross_file_rules(),
      fn mod -> CredenceRules.rule_atom(mod) == rule end
    )
  end

  # `CredenceRules.Pattern.LargeDefstruct` →
  # "lib/credence_rules/pattern/large_defstruct.ex".
  defp module_to_source_path(module) do
    segments =
      module
      |> Module.split()
      |> Enum.map(&Macro.underscore/1)

    "lib/" <> Enum.join(segments, "/") <> ".ex"
  end

  # Default repo slug — derive from the docs_url_base if it's a
  # GitHub URL; fall back to the catalog's own slug. Override via
  # `:repo_slug` Application env if you've forked or use a custom
  # docs_url_base shape the parse can't handle.
  defp repo_slug do
    Application.get_env(:credence_rules, :repo_slug) ||
      slug_from_base(docs_url_base()) ||
      "isaiahdw/credence_rules"
  end

  defp slug_from_base(base) do
    case Regex.run(~r{https?://github\.com/([^/]+/[^/]+)/}, base, capture: :all_but_first) do
      [slug] -> slug
      _ -> nil
    end
  end

  defp docs_fetch_command_template do
    Application.get_env(
      :credence_rules,
      :docs_fetch_command_template,
      ~s|gh api repos/{repo_slug}/contents/{path} -H "Accept: application/vnd.github.raw"|
    )
  end

  defp docs_url_base do
    Application.get_env(
      :credence_rules,
      :docs_url_base,
      "https://github.com/isaiahdw/credence_rules/blob/main/"
    )
  end

  @doc """
  Returns the rule's `@hint` (a structured fix recommendation), or
  `nil` if the rule doesn't define one. Looked up via
  `c:hint/0` on the rule module.

  Hints are agent-targeted: they appear in the AI format alongside
  the prose `:message`, structured so an LLM can act on the fix
  without re-parsing English. The text and github formats don't
  surface hints — they stay terse for human reading.
  """
  @spec hint_for(atom()) :: String.t() | nil
  def hint_for(rule) when is_atom(rule) do
    case find_rule_module(rule) do
      nil ->
        nil

      module ->
        if function_exported?(module, :hint, 0), do: module.hint(), else: nil
    end
  end

  @doc """
  Returns the rule's `@carve_outs` — a list of conditions where
  the rule would be wrong, suitable for an LLM agent to
  self-check whether a flagged case is actually a false positive.
  Defaults to `[]`.
  """
  @spec carve_outs_for(atom()) :: [String.t()]
  def carve_outs_for(rule) when is_atom(rule) do
    case find_rule_module(rule) do
      nil ->
        []

      module ->
        if function_exported?(module, :carve_outs, 0), do: module.carve_outs(), else: []
    end
  end
end
