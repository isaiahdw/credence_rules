# credence_rules

[![CI](https://github.com/isaiahdw/credence_rules/actions/workflows/ci.yml/badge.svg)](https://github.com/isaiahdw/credence_rules/actions/workflows/ci.yml)

Reusable [Credence](https://github.com/Cinderella-Man/credence) `Pattern.Rule`
modules that target LLM failure modes not yet covered by the upstream
catalog, plus a `mix credence.check` task with a boundary / advisory
taxonomy.

CI runs the catalog against this project's own `lib/` under
`--strict` — the project eats its own dog food, and the boundary-
finding count is held at zero. Advisory findings still appear in
the report; PRs that add boundary findings fail the gate.

## Installation

Add `:credence_rules` (and `:credence` itself) to your deps:

```elixir
defp deps do
  [
    {:credence, "~> 0.8", only: [:dev, :test], runtime: false},
    {:credence_rules,
     git: "https://github.com/isaiahdw/credence_rules.git",
     only: [:dev, :test], runtime: false}
  ]
end
```

Then run:

```sh
mix deps.get
mix credence.check                 # report-only, scans lib/ + test/
mix credence.check --strict        # exits 1 on boundary findings only
mix credence.check --paths lib     # restrict to a subset of roots
mix credence.check --format github # GitHub Actions PR annotations
mix credence.check --format ai     # compact JSON envelope for LLM agents
```

## Output formats

`--format` picks the serialisation. Findings are the same in every
format; only the presentation differs.

| Format | Use case |
|---|---|
| `text` (default) | Local terminal use. Per-file finding lists + score summary. |
| `github` | `::error file=…,line=…::message` workflow commands. Inline PR annotations. Pair with `--strict` to gate CI. |
| `ai` | Single-line JSON envelope grouped by file. Each finding carries `severity`, `confidence`, `fingerprint`, plus agent-targeted `hint` / `carve_outs` / `docs_url` fields for LLM consumption. Pipe to a coding agent. |

### Fields exposed to LLM agents (the `ai` format)

Each finding includes structured fields beyond the prose `detail`
message — the agent doesn't have to re-parse English to act:

- `hint` — concrete fix recommendation with before/after code, or
  `null` for rules that haven't defined one yet.
- `carve_outs` — list of conditions where the rule would be wrong.
  Agents should self-check each before applying the fix.
- `docs_url` — URL pointing at the rule module's source. Agents
  can `WebFetch` (or curl, or paste in a browser) for the full
  moduledoc when extra context helps. Defaults to
  `https://github.com/isaiahdw/credence_rules/blob/main/…`;
  override with `:docs_url_base` Application env.
- `docs_fetch_command` — pre-baked shell command that returns the
  rule's source as raw text. Default uses `gh api` with the raw
  Accept header. For agents in shell-only environments (no
  `WebFetch`): copy / paste, get the file content back. Override
  the command template via `:docs_fetch_command_template` (e.g.
  to use curl instead).

Rules opt into hints / carve-outs via `@hint` and `@carve_outs`
module attributes (see `CredenceRules.Rule`). The ~10
biggest-value rules ship with both today; others fall through to
`null` / `[]` until audited.

Every format ends with a Quality Score and per-category breakdown:

```
═══ Summary ═══
  Files: 42    Lines: 5380    Quality Score: 99.3%
  Findings: 3 (1 boundary, 2 advisory) — 7 weighted

  Concurrency:   100.0%
  Safety:         99.5%
  Test Quality:  100.0%
  Architecture:  100.0%
  DRY:           100.0%
  Documentation:  99.8%
  Naming:        100.0%
  Idioms:        100.0%
```

The **Quality Score** is a **severity-weighted penalty** —
each finding subtracts points by severity:

```
quality_score = max(0, 100 × (1 − weighted_findings / SCALE))

severity_weight(:high)   = 5
severity_weight(:medium) = 2
severity_weight(:low)    = 1
```

With the default `SCALE = 1000`, one severity:low finding costs
**0.1 points**, one medium costs **0.2**, one high costs **0.5**.

Each fix moves the score by exactly that amount — and the score
is **immune to codebase growth**. Adding clean code doesn't
inflate the score, and adding code with findings tanks it by
the right amount regardless of how much code came along.

Each per-category score uses the same formula filtered to that
category's findings.

> **Heuristic rules cap at `:low` severity.** Rules whose
> detection is name-based, clustering, or threshold-based (see
> `CredenceRules.Finding`'s heuristic table) cap at `:low`
> regardless of category. A `rescue_catch_all` finding really IS
> a bug; a `repeated_subtree_in_module` is "you might want to
> extract a helper" — they shouldn't contribute equally to the
> score, and the cap encodes that.

### Tuning SCALE

The default is calibrated to give a useful gradient on a
typical project (mid-80s for a healthy codebase, mid-60s for a
project with significant churn). If you want a sharper signal
that bottoms out faster, lower SCALE:

```elixir
config :credence_rules,
  # SCALE=200 — each weight unit costs 0.5 points instead of 0.1
  score_scale: 200
```

Reference values for a project with ~170 weighted findings:

| SCALE | Quality Score | per low-sev fix | per high-sev fix |
|---|---|---|---|
| 200 | 15% | +0.5 | +2.5 |
| 500 | 66% | +0.2 | +1.0 |
| 1000 (default) | 83% | +0.1 | +0.5 |
| 2000 | 91.5% | +0.05 | +0.25 |

You can also override severity weights:

```elixir
config :credence_rules,
  severity_weights: %{high: 10, medium: 3, low: 1}
```

Missing keys fall back to defaults.

### What's NOT in the formula

- **Confidence** — drives `--strict`'s exit gate via
  `Finding.strict_fail?/3`, not the score.
- **Codebase size** — by design. Adding clean code shouldn't
  inflate the score; adding code with findings shouldn't be
  masked by the volume.

## Baseline gating

`mix credence.check` can compare findings against a snapshot so
strict mode fails only on **new** issues — drift prevention without
forcing a green-field rewrite.

```sh
# Snapshot current findings once
mix credence.check --update-baseline

# In CI: fail only on new boundary findings vs the snapshot
mix credence.check --baseline --strict
```

Default baseline path is `credence-baseline.json` (commit it). Pass
`--baseline PATH` / `--update-baseline PATH` for a custom location.
Baselined findings show in the per-file output with a `(baselined)`
tag; the `github` formatter demotes them to `::notice` so they
appear on the PR diff as context without contributing to the
failing-check verdict. Tighten over time by deleting baseline
entries as the code improves.

### Fingerprint-based matching (v2 format)

Baselines key on a **stable fingerprint** — SHA-256 (truncated to
64 bits, 16 hex chars) of `{rule, path, normalized_message,
extracted_meta}` — not the `{path, rule, line}` triple the older
v1 format used. Three properties:

- **Line-independent.** Small line moves don't churn the baseline.
- **Meta-aware.** Cross-file findings fold in distinguishing
  fields from `:meta` (cycle members, source/target module,
  cluster id) so two findings on the same `line: nil` slot for
  the same rule on the same file don't collide.
- **Cryptographic.** Previous implementation used `:erlang.phash2/1`
  with 120-char message truncation — collision-prone for long
  cross-file messages where distinguishing evidence sat past the
  prefix. SHA-256 over the full payload eliminates that class.

`--update-baseline` always writes v2. v1 files (from earlier
versions of this library) still load — the matcher tries both
keys per entry, so existing baselines keep working until you
regenerate.

## Complementing with Credo

This catalog targets LLM failure modes — runtime hazards, idiom
misuse, narration, GenServer / OTP shape, IOSP, naming
conventions. It deliberately doesn't measure raw **complexity**
(cyclomatic, nesting, function length, function arity) — those
are well-covered by [Credo](https://github.com/rrrene/credo) and
that's where they belong.

This catalog **does** ship DRY rules — `repeated_subtree_in_function`,
`repeated_subtree_in_module`, `cross_file_duplicate_block`,
`repeated_case_arm_body`, `wildcard_import` (see the DRY section
in the rule catalog below). They overlap with some Credo checks
but the AST-clustering approach catches structurally-equivalent
duplicates that Credo's surface-level checks miss.

Running both is fine; nothing duplicate-reports verbatim. A
minimal `.credo.exs` for the dimensions this catalog skips:

```elixir
%{
  configs: [
    %{
      name: "default",
      strict: false,
      checks: [
        # Complexity — caught by Credo, not here.
        {Credo.Check.Refactor.CyclomaticComplexity, max_complexity: 12},
        {Credo.Check.Refactor.Nesting, max_nesting: 3},
        {Credo.Check.Refactor.FunctionArity, max_arity: 6},
        # Disable anything that overlaps with this catalog if you
        # don't want double-reporting (e.g. Credo's Refactor.UnlessWithElse
        # overlaps with this project's WithComplexElse intent).
      ]
    }
  ]
}
```

`mix credo --strict` plus `mix credence.check --baseline --strict`
gives you both gates.

## Configuration

`Application` env keys read by `mix credence.check`:

```elixir
# config/config.exs (or config/dev.exs + config/test.exs)
config :credence_rules,
  # Default output format. Overridden by `--format` on the CLI.
  default_format: :github,
  # Files excluded from the scan — typically codegen output.
  generated_paths: ["lib/my_app/generated_names.ex"],
  # Pre-existing modules whose names end in OOP-style suffixes
  # (Manager / Service / Helper / Handler / …) but are grandfathered
  # in rather than renamed.
  allowed_modules: [
    MyApp.Discovery.Manager,
    MyApp.OTA.Manager
  ],
  # Layer enforcement for `forbidden_module_dependency`. Each entry
  # is a `{source_pattern, target_pattern}` regex pair: any time a
  # module matching the source references one matching the target,
  # the rule fires (boundary-tier — fails `--strict`).
  forbidden_edges: [
    # Controllers can't call Repo directly — go through a context.
    {~r/Web\..*Controller$/, ~r/^MyApp\.Repo$/},
    # Schemas can't call contexts (cycle hazard).
    {~r/Schema$/, ~r/^MyApp\.Context\./},
    # Lib code can't depend on the web layer.
    {~r/^MyApp\.Lib\./, ~r/^MyAppWeb\./}
  ]
```

### Per-rule options (`:rule_opts`)

Every rule in this catalog accepts options for tuning thresholds,
allowlists, and detection knobs. To set them project-wide, use
`:rule_opts` keyed by the rule's atom name (the same atom the
finding output shows):

```elixir
config :credence_rules,
  rule_opts: %{
    # Lift large_defstruct's clustering bar
    large_defstruct: [
      min_clusters: 3,
      min_cluster_size: 4,
      scan_min_fields: 15
    ],
    # Tighten GenServer thresholds across the per-instance and
    # read-bypass shapes too
    genserver_handle_call_explosion: [
      max_handle_call: 12,
      max_handle_call_per_instance: 20,
      max_handle_call_read_bypass: 24
    ],
    # Use BEAM imports for forbidden_module_dependency edges —
    # drops alias/typespec noise
    forbidden_module_dependency: [graph_source: :beam],
    # Add project-specific side-effect modules to the predicate /
    # normalizer detectors
    iosp_predicate_side_effects: [
      side_effect_modules: ~w(Repo Req Phoenix.PubSub MyApp.Mailer MyApp.Cache)
    ],
    iosp_normalizer_side_effects: [
      normalizer_prefixes: ~w(normalize_ parse_ to_ from_ coerce_)
    ],
    # Add project cliches to the vague-test-name detector
    vague_test_name: [
      additional_vague_patterns: [~r/\Aworks fine\z/i]
    ],
    # Treat additional HTTP clients as "real external"
    real_external_client_in_test: [
      client_modules: ~w(Req HTTPoison Bamboo)
    ]
  }
```

The analyser merges these opts on top of the global ones
(`:source`, `:allowed_modules`) before calling each rule's
`check/2`. Rules without an entry use their defaults; rules with
an entry get the merged opts. See each rule's moduledoc for the
full option list.

## Suppressing findings inline (`# credence:`)

A genuine exception to a rule belongs **at the code**, where the next
reader sees it — not buried in config. There are two scopes, each with
its own comment token.

### Line scope — `# credence:<rule>`

Exempts a single occurrence. Place it trailing the finding's line or on
the line directly above:

```elixir
# credence:filter_then_first — bounded 3-element list; clarity beats the micro-opt here
first_admin = users |> Enum.filter(& &1.admin?) |> List.first()

def child_spec(opts), do: adapter().child_spec(opts) # credence:nested_calls_should_pipe — facade delegation reads clearer flat
```

A directive on line _N_ covers findings on line _N_ (trailing comment)
and line _N+1_ (comment directly above).

### File scope — `# credence-file:<rule>`

Exempts the **whole file** — every matching finding in it, including
line-less cross-file findings (`hub_module`,
`cross_file_duplicate_block`, …). Place it at the top of the file,
above `defmodule`. Use it when the rule's premise doesn't hold for the
file as a whole (e.g. a module that is, by contract, a uniform pattern
matcher). This is the inline replacement for config `exclude_paths` /
`exclude_modules`:

```elixir
# credence-file:repeated_subtree_in_function — every Pattern rule shares the
#   check/2 + Macro.prewalk + build_issue shape by contract
defmodule CredenceRules.Pattern.TaggedTupleElemAccess do
```

### Common rules

Syntax: `# credence:<rule>[,<rule>…] <reason>` (and the `credence-file:`
variant).

- `<rule>` is the rule's atom name (as shown in finding output).
  Comma-separate several; `*` or `all` covers everything in scope.
- **A reason is required.** A directive with no justification still
  suppresses its target, but is itself reported as
  `credence_suppression_without_reason` — a boundary finding that fails
  `--strict`. Undocumented exceptions rot; the linter makes you write
  down _why_.
- Directives are read from real source comments only — a `# credence:`
  sequence inside a string or docstring is ignored.
- A line-less cross-file finding can only be suppressed with
  `credence-file:` (it has no line for the line-scope token to match).

## Severity, confidence, and strict mode

Every finding carries two ordinal dimensions on top of the rule / file / line:

- **`severity`** — how bad the finding is if it's real.
  - `:high` runtime hazards (data loss, deadlock, race), OTP role violations
  - `:medium` architecture / SRP / DRY smells
  - `:low` documentation, naming, narration
- **`confidence`** — how likely the detection is correct.
  - `:high` structural pattern matches that can't fire on the wrong shape
  - `:medium` heuristic detection (IOSP "mixed function" counts, name-based clustering)
  - `:low` name-only signals (vague test names, OOP-style suffixes)

Defaults come from the rule's category. Heuristic rules
(`iosp_mixed_function`, `repeated_subtree_*`, `large_defstruct`,
`vague_test_name`, `manager_service_module_name`, etc.) get
lower confidence. Rules can override per-module:

```elixir
defmodule MyApp.MyRule do
  use CredenceRules.Rule

  @severity :high
  @confidence :medium
end
```

### `--strict` gates on both dimensions

```sh
# Default: fails on severity:high AND confidence:high (preserves the
# prior "boundary fails" behaviour exactly — every previous boundary
# rule maps to high/high; every advisory caps at severity:medium).
mix credence.check --strict

# Stricter: include medium-severity findings (architecture, DRY,
# IOSP smells). Heuristic-confidence rules still excluded.
mix credence.check --strict --strict-min-severity medium

# Strictest: any non-:low severity, any confidence.
mix credence.check --strict --strict-min-severity medium --strict-min-confidence low
```

Output tags every finding with its dimensions: `[rule_name:42] (S:high C:high)`.

### Boundary vs advisory — backward compat

The older `boundary` / `advisory` split is preserved as a default
mapping: `advisory_rules` MapSet entries cap their severity at
`:medium`, so `--strict` (default high+high) never fails on an
advisory rule. Add a rule to `@advisory_rules` in
`lib/credence_rules.ex` to opt it out of the default gate
even if its category would otherwise push it to `:high`.

When adding a new rule, prefer "this violates an OTP role boundary"
over "this looks AI-ish." Treat global mutable facilities
(`:persistent_term`, `Application.put_env`, the process dictionary) as
suspicious by default — LLMs overuse them because they resemble static
variables or app globals.

The advisory list is maintained in `lib/credence_rules.ex` as
`@advisory_rules`. If you add a new rule, decide which tier it belongs
in and add it there if advisory.

## Boundary rules

### OTP role discipline

The Iron Law: no process without a runtime reason. GenServers
coordinate; they don't block, share global state, or do the work
themselves.

| Rule | Native replacement |
|------|--------------------|
| `conditional_supervisor_child` | child `start_link/1` returns `:ignore` |
| `ets_extract_then_enum` | `:ets.select/2` (match-spec) / `:ets.foldl/3` |
| `ets_owner_lifecycle_mismatch` | long-lived owner, OR `:persistent_term` for one-shot hydration |
| `genserver_as_kv_store` | ETS (`read_concurrency: true`), `:persistent_term`, or plain state |
| `genserver_receive_block` | spawn out + `handle_info/2` |
| `genserver_self_call_deadlock` | plain function call (or `GenServer.cast`) |
| `genserver_with_immutable_state` | plain functions on a struct (no `use GenServer`) |
| `no_genserver_callback_missing_impl` | `@impl true` annotation |
| `no_send_self_in_init` | `{:ok, state, {:continue, msg}}` + `handle_continue/2` |
| `persistent_term_abuse` | one-shot `init/1` hydration, OR ETS for live updates |
| `process_dict_in_genserver` | thread state through callback `state` arg |
| `process_whereis_for_liveness` | `Registry` + `{:via, …}` tuples |
| `sleep_in_genserver_callback` | `Process.send_after/3` + `handle_info/2` |
| `task_await_in_genserver_callback` | `Task.Supervisor.async_nolink/3` + `handle_info({ref, …}, _)` |
| `task_supervisor_without_down_handling` | `handle_info({ref, _}, _)` + `handle_info({:DOWN, _, _, _, _}, _)` |
| `unsupervised_spawn` | `Task.Supervisor.start_child/2`, `{Task, fn}` in a children list, or `Task.async/1` |

### Function shape & contract

The `!` suffix, the `{:ok, _} | {:error, _}` envelope, and `m.k` vs
`m[:k]` are all contracts callers rely on. Rules in this section keep
those contracts honest.

| Rule | Native replacement |
|------|--------------------|
| `alternative_return_types` | split into `foo/N` and `foo!/N` |
| `bang_function_that_doesnt_raise` | raise on the error path (or drop the `!`) |
| `dual_key_access` | normalize keys at the boundary (atom or string, not both) |
| `non_assertive_map_access` | `map.key` for required, `Map.get/2,3` for optional |
| `rescue_catch_all` | `rescue e in [SomeError]` (or let supervisor restart) |
| `static_apply` | `Module.fun(args)` (direct dispatch) |
| `unused_enum_operation` | `Enum.each/2` for side effects, or use the return |

### Safety

Boundaries against untrusted input and atom-table / GC blowup.

| Rule | Native replacement |
|------|--------------------|
| `binary_to_term_without_safe` | `:erlang.binary_to_term(bin, [:safe])` |
| `string_to_atom_unsafe` | `String.to_existing_atom/1` |
| `atom_interpolation` | confirm the interpolated values are bounded (advisory — `:"a_#{b}"` has no `to_existing_atom` sugar form) |
| `mix_shell_outside_mix_task` | `Logger.<level>` or caller-injected `notify` callback (Mix is unavailable in releases) |

### Configuration

Compile-time vs runtime is a sharp boundary in Elixir releases —
`Application.get_env` at module-attribute level pins to the build
node's config forever.

| Rule | Native replacement |
|------|--------------------|
| `application_get_env_at_compile_time` | `Application.compile_env!/2` |
| `application_put_env_in_code` | `config/*.exs` (declarative) |

### Ecto (database) boundary

These rules fire on N+1 queries and predicate-pushdown misses the
moment a project adopts Ecto.

| Rule | Native replacement |
|------|--------------------|
| `query_in_enum_map` | `Repo.all(from x in Q, where: x.id in ^ids)` / `Repo.preload/3` / `*_all/3` |
| `repo_all_then_filter` | push predicate into `from … where: …` |

### Release / runtime correctness

| Rule | Native replacement |
|------|--------------------|
| `path_expand_priv` | `Path.join(:code.priv_dir(:app), "file")` |

### Performance shapes that encode immutability

`length(list)` is O(n) because lists are linked; `String.length` is
O(n) because binaries are UTF-8. These rules catch the canonical
"I thought this was O(1)" mistakes.

| Rule | Native replacement |
|------|--------------------|
| `length_list_for_emptiness` | `list == []` / `match?([_ \| _], list)` |
| `string_concat_in_reduce` | iodata: `Enum.reduce(_, [], &[&2, &1]) \|> IO.iodata_to_binary` |
| `string_length_for_emptiness` | `s == ""` / `byte_size(s) == 0` |
| `list_append_in_reduce` | `acc ++ [x]` in `Enum.reduce` is O(n²) (`++` copies the left list). Prepend `[x \| acc]` and `Enum.reverse/1` once, or use `Enum.map/2`. |
| `sort_then_take_first` (advisory) | `Enum.sort(x) \|> hd()` / `List.first`/`List.last` → `Enum.min`/`max` (or `min_by`/`max_by`). O(n log n) → O(n). |
| `filter_then_count` (advisory) | `Enum.filter(e, f) \|> Enum.count()` / `length(Enum.filter(...))` → `Enum.count(e, f)` (one pass, no intermediate list). |
| `filter_then_first` (advisory) | `Enum.filter(e, f) \|> List.first()` / `hd(...)` → `Enum.find(e, f)` (short-circuits). |

## Advisory rules

These catch real LLM output patterns but aren't architectural — they're
naming, comments, or local readability.

### Test quality

| Rule | Catches |
|------|---------|
| `assert_enum_all` | `assert Enum.all?(enum, fun)` (use a `for`-comprehension for per-element messages) |
| `assert_match_question` | `assert match?(pattern, expr)` (use `assert =`) |
| `no_test_without_assertion` | `test "..."` blocks with no `assert`/`refute` |
| `no_trivially_truthy_assertion` | `assert true`, `assert :ok`, `assert _ = expr` |
| `process_sleep_in_test` | `Process.sleep/1` inside an `ExUnit.Case` module — use `assert_receive` / `assert_eventually` / `Mox.verify!` instead |

### Conventions / naming

| Rule | Catches |
|------|---------|
| `def_is_prefix` | `def is_foo?` (reserved for `defguard`) |
| `manager_service_module_name` | `Foo.Manager`/`.Service`/`.Helper(s)`/`.Util(s)`/`.Handler` (OOP service naming). Behaviour modules — those declaring `@callback`/`@macrocallback`, e.g. `CommandHandler` — are exempt: the suffix names a real contract. |

### Readability / local shape

| Rule | Catches |
|------|---------|
| `case_with_single_wildcard_arm` | `case x do _ -> body end` (dead case) |
| `case_destructure_should_be_function_clause` | A function whose whole body is a two-arm `case` on a parameter — one arm destructures and binds data (binary/tuple/map/struct/list), the other is `_` with a simple fallback (`{:error, _}`, `nil`, …). Prefer function-head pattern matching + a fallback clause. Common LLM/binary-parser habit. Complements `case_arg_could_be_function_clauses` (3+ clauses) and `case_with_single_wildcard_arm` (1 arm). |
| `with_complex_else` | `with ... else` block with 4+ arms (threshold configurable) |

### Hygiene

| Rule | Catches |
|------|---------|
| `io_inspect_in_lib` | `IO.inspect` in library code (debugging leftover) |
| `magic_timeout_literal` | bare integer timeouts (extract to module attribute) |

### Error-handling shape

LLMs default to Java/Python-style "log and continue" error handling, which is
the opposite of the Elixir-supervisor model. These rules push back.

| Rule | Catches |
|------|---------|
| `rescue_without_reraise` | `rescue e -> Logger.error(...); :error` — logs but swallows the exception with a generic atom (different from `rescue_catch_all`, which is for `rescue _ -> _`) |
| `reraise_without_stacktrace` | `reraise e, []` / `reraise e, nil` — `reraise` exists to preserve the stack, and `[]`/`nil` drops it. Use `__STACKTRACE__`. |
| `raise_without_module` | `raise "message"` — becomes a generic `RuntimeError`. Pick a stdlib exception (`ArgumentError`, `KeyError`, …) or a `defexception` in your app so callers can rescue / pattern-match the failure class. |

### Idiomaticity (LLM-shape tells)

Patterns that LLMs ship because they pattern-match surface text without
grasping flow. Each rule names one specific "rewrap / threading-by-hand /
trinket" shape and points to the native primitive.

| Rule | Catches |
|------|---------|
| `identity_passthrough` | `case r do {:ok, v} -> {:ok, v}; {:error, e} -> {:error, e} end` — pure rewrap |
| `with_identity_do` | `with {:ok, r} <- f() do {:ok, r} end` — ceremony around a single match |
| `with_identity_else` | `with … else {:error, e} -> {:error, e}` — `else` block does nothing |
| `redundant_boolean_if` | `if cond, do: true, else: false` — the condition IS the boolean |
| `flat_map_filter` | `Enum.flat_map(fn x -> if cond, do: [x], else: [] end)` → `Enum.filter` |
| `map_into_literal` | `Enum.map(...) \|> Enum.into(%{})` → `Map.new(enum, fun)` (single pass) |
| `reduce_map_put` | `Enum.reduce(%{}, fn x, acc -> Map.put(acc, k, v) end)` → `Map.new/2` |
| `try_rescue_with_safe_alternative` | `try do String.to_integer(x) rescue _ -> nil end` → `Integer.parse(x)` (also covers `Jason.decode!`, `Map.fetch!`, `Keyword.fetch!`, `Enum.fetch!`, `File.read!`, `File.write!`) |
| `nil_predicate_lambda` | `Enum.filter(fn x -> x != nil end)` / `Enum.reject(fn x -> x == nil end)` → `Enum.reject(&is_nil/1)` |
| `doc_false_on_public_function` | 2+ `@doc false` on public `def`s in one module (cargo-culted hiding) |
| `anonymous_fn_capture_wrap` | `fn x -> foo(x) end` → `&foo/1`; `fn x -> Mod.foo(x) end` → `&Mod.foo/1` |
| `enum_each_assigned` | `result = Enum.each(...)` — `Enum.each/2` always returns `:ok`; the binding is wrong (wanted `Enum.map`) |
| `enum_into_for_map_new` | `Enum.into(pairs, %{})` (also piped + 3-arg mapper forms) → `Map.new/1,2`. Complement to `map_into_literal`, which owns `Enum.map(...) \|> Enum.into(%{})`. |
| `hd_or_tl_call` | `hd(list)` / `tl(list)` → pattern match `[head \| rest]`. `hd([])` raises a generic `ArgumentError`; pattern matching produces an actionable `MatchError`. |
| `if_value_else_nil` | `if value, do: value, else: nil` (and implicit-`else` form) — redundant; the bare expression already does this |
| `reduce_as_map` | `Enum.reduce([], fn x, acc -> [f(x) \| acc] end)` (reinvents `Enum.map`) — also catches the O(n²) `acc ++ [f(x)]` variant |
| `single_stage_pipe` | `x \|> foo()` with no further pipe stages — `foo(x)` is shorter and doesn't trick readers into looking for a chain that isn't there |
| `side_effect_in_pipe` | A `Logger.*` / `IO.puts`/`write`/`warn` call as a **non-terminal** pipe stage — it returns `:ok`, so the next stage gets `:ok` instead of the threaded data. Use `tap/1` (effect, value passes through) or lift it out. `IO.inspect` and last-stage effects are exempt. Advisory. |
| `nested_calls_should_pipe` | 3+ function calls nested through the **first** argument (`f(g(h(x)))`, `Enum.map(Enum.filter(Enum.uniq(l), p), f)`) read inside-out; a pipe reads top-to-bottom. Threshold `:min_pipe_depth` (default 3). Operators, control-flow, captures, data constructors, definition forms, and non-first-arg threading are excluded. Pairs with `single_stage_pipe`. Advisory. |
| `spec_returns_any` | `@spec foo(...) :: any()` / `:: term()` (also unions containing `any()`) — Dialyzer can't use it; spell out the real return type |
| `truthy_access_reused_in_body` | `if state.socket, do: :socket.close(state.socket)` — gates on an access expression then re-reads it in the body. Bind once with a pattern-matched helper or local `case` (preserving BOTH `nil` and `false` clauses to match `if`'s falsey semantics). Scoped to dot field access + `Map.get`/`Keyword.get` + bracket access; auto-skips `?`-suffix fields and bare variables. |
| `unaliased_module_use` | Fully-qualified `Some.Long.Module.func/1` used 3+ times in one function body (configurable via `min_count`) |
| `useless_try` | `try do ... end` with no `rescue`/`catch`/`after` — the `try` does nothing; drop it (let it crash) or use `case` if you wanted to branch |

### Comment & doc quality

LLM-generated code routinely ships with narrator commentary, restate-the-code
comments, "Phase 2" forward markers, and "fixed in PR #34" backward markers
that all rot the moment the surrounding code moves. These rules push the
project toward comments that describe the **current** code and explain WHY.

| Rule | Catches |
|------|---------|
| `narrator_comment` | `# Here we fetch X` / `# Now we validate` / `# Let's create` |
| `obvious_comment` | `# Fetch the user` above `Repo.get(User, id)` — short verb+article restatement |
| `step_comment` | `# Step 1: …` / `# Step 2: …` (decompose into functions) |
| `narrator_doc` | `@moduledoc "This module provides …"` / `@doc "This function creates …"` |
| `boilerplate_doc_params` | `## Parameters\n- conn: The connection struct\n- params: A map of parameters` |
| `no_todo_or_roadmap_comment` | Forward markers: `# TODO`, `# FIXME`, `# Phase N`, `# follow-up`, `# we'll add … later` |
| `stale_reference_comment` | Backward markers: `# fixed in PR #34`, `# regression from #46`, `# previously …`, `# used to …`, `# since v0.3`, `# see commit abc123` |

The forward/backward split between `no_todo_or_roadmap_comment` and
`stale_reference_comment` is deliberate: forward markers are roadmap rot
("what we will do") and backward markers are history rot ("what we used to
do"). The right fix in both cases is to either do the work, capture the
context in the PR description, or rewrite the comment to describe the
current code.

### Architecture (module shape & function boundaries)

Module-level shape rules, IOSP, and framework-specific architectural
boundaries. None of these overlap Credo's per-function complexity
checks — they target the LLM "do everything in one place" failure
modes.

| Rule | Catches |
|------|---------|
| `iosp_mixed_function` | Functions that mix Integration (calls into other modules) and Operation (logic) — 3+ `Foo.bar(...)` calls + 3+ `if`/`case`/`cond` constructs **nested** (effective nesting depth ≥ 2) in one body. `with` and `try` never add depth; a single top-level `case`/`with` is treated as an integration dispatch, so flat protocol parsers and sequential `init/1` setup (control-flow as siblings, not nesting) are spared. Tunable via `:iosp_min_nesting_depth` (set 1 for count-only). |
| `large_defstruct` | `defstruct` whose field names form ≥ 2 naming clusters of ≥ 3 fields each (e.g. `auth_*`, `billing_*`, `pref_*` all under one struct). The clusters signal sub-entities glued together. Wide-but-single-entity structs (wire-format mirrors, persisted records, cache entries with heterogeneous names) don't cluster and aren't flagged. Allowlist: `use GenServer`/`GenStage`/`:gen_statem`, `@behaviour GenServer`/`:gen_statem`/`:gen_event`, `use Ecto.Schema`. |
| `module_that_re_exports_only` | A module where every public `def` is a one-line passthrough to a single remote module with no parameter transformation. Use `defdelegate` to document the passthrough, or drop the wrapper entirely. |
| `module_with_many_use_statements` | A `defmodule` with 4+ top-level `use` statements (configurable via `:max_uses`). LLM "kitchen sink" tell. |
| `option_branched_function` | `def go(opts \\ []) do case Keyword.get(opts, :mode) do ...` with 3+ branches. Manual dispatch via opts; split into one function per mode. |
| `boolean_flag_argument` | A function with a boolean flag parameter — a default arg whose default is `true`/`false` (`def render(doc, compact \\ false)`). A boolean usually means the function does two things, and `render(doc, true)` is unreadable. Split into two intention-named, composable functions. Advisory. |
| `oversized_message_handler_module` | A module with > 20 (configurable via `:max_handlers`) total `handle_info` + `handle_call` + `handle_cast` + `handle_event` clauses. Cross-behaviour cousin of `genserver_handle_call_explosion` — fires on `:gen_statem`, `GenEvent`, and behaviour-implementing modules that the GenServer-gated rule misses. Test modules skipped; honours `:exclude_modules`. |
| `schema_with_business_logic` | An Ecto schema module (has `use Ecto.Schema` + `schema do ... end`) that defines functions beyond `changeset/_` and trivial accessors. Schemas are data; logic belongs in a context. |
| `fat_controller` | Phoenix controllers (`use ...Controller`, `use ..., :controller`) with non-action public defs (arity != 2). Move helpers into a context — LiveViews, mailers, and tests can reuse them without going through a conn. |
| `liveview_query_in_mount` | Phoenix LiveView `mount/3` (or `mount/4`) that calls `Repo.*` / HTTP clients / `Oban.insert` without a `connected?(socket)` guard. `mount` fires twice (HTTP render + WebSocket connect); each call runs twice per page view. |
| `forbidden_module_dependency` | **Opt-in** — declare layer rules as `{source_pattern, target_pattern}` regex pairs in `:forbidden_edges`. The rule flags any time a module matching `source_pattern` references one matching `target_pattern`. Boundary-tier (fails `--strict`) since it's opt-in. |
| `logger_call_in_mix_task` | `Logger.<level>` call inside a `Mix.Tasks.*` module. Mix tasks should use `Mix.shell().info/error` for user-facing output so tests can swap in `Mix.Shell.Process` / `Mix.Shell.Quiet`. Advisory because long-running production-shaped maintenance tasks may legitimately use Logger for aggregation. |

#### Cross-file architecture rules

These see every scanned file at once, so they can flag patterns that span files. Built on a shared module dependency graph (`CredenceRules.CrossFile.ModuleGraph`) — only project-local modules count; stdlib and deps are filtered out.

| Rule | Tier | Catches |
|------|------|---------|
| `circular_module_dependency` | boundary | SCCs of size ≥ 2 in the module dependency graph. Cycles couple build, test, and reasoning lifetimes. Pair with the baseline gate to pin existing cycles. |
| `hub_module` | advisory | Modules with fan-in ≥ 15 (`:max_fan_in`) AND larger than `:max_vocab_loc` (default 60) lines. High-fan-in modules are change bottlenecks. Tiny modules are auto-exempt: a small high-fan-in module is a stable vocabulary type (`NodeId`, `Version`) whose wide reach is by design, not an accumulation of logic. |
| `module_instability` | advisory | Modules with instability = `fan_out / (fan_in + fan_out)` ≥ 0.8 AND fan-out ≥ 5 AND ≥ 2 corroborating smell signals from {`broad_interface` (≥ 5 public fns = shallow), `callback_explosion` (≥ 10 GenServer/gen_statem callback clauses), `large_shallow` (≥ 100 LOC **and** broad interface — size alone isn't a signal, since a narrow interface over a large body is a *deep* module), `cycle` (in a dependency SCC)}. Robert Martin's SDP + Ousterhout's deep modules. Role-aware: composition roots (`use Application`/`Supervisor`, `Mix.Tasks.*`) are exempt; process owners (GenServer/gen_statem) go through the gate, so a focused one is spared but a god-process fires. A deep protocol module spanning crypto/TLV/framing for one vertical flow scores zero and is spared (no `multi_domain` signal — "unrelated vs cohesive" isn't graph-decidable). Tunable: `:max_instability`, `:min_fan_out`, `:min_signals`, `:min_public_api`, `:min_loc`, `:min_callbacks`, `:role_aware`. |

### DRY (duplication / scope hygiene)

The GenServer SRP rule lives in `:concurrency` (it's a runtime
bottleneck concern, not just shape):

| Rule | Catches |
|------|---------|
| `genserver_handle_call_explosion` | GenServers with 8+ `handle_call/3` clauses (configurable via `:max_handle_call`). All callers serialise through one mailbox — split by concern instead of accumulating responsibilities. |

### DRY (duplication / scope hygiene)

Inspired by the kiron0/dry VS Code extension but normalised at the AST
level — variable names and literal values are stripped before hashing, so
two subtrees that differ only in those count as the same shape.

| Rule | Catches |
|------|---------|
| `repeated_subtree_in_function` | Same normalised AST subtree (≥ 14 nodes) appearing 2+ times in one `def`/`defp` body. Suggests extracting a private helper that takes the varying pieces as args. Dropped by default: pure data literals (lookup-table rows, tuple specs, argument keyword lists — `flag_pure_data_duplicates: true` to report) and logging / CLI scaffolding (`Logger.*`, `Mix.shell().*`, `OptionParser.parse`, `inspect`/`to_string`/`Integer.to_string(_, 16)` shapes with no project-module call — `flag_logging_idioms: true` to report). |
| `repeated_subtree_in_module` | Same normalised AST subtree (≥ 16 nodes) appearing in 2+ distinct functions in one module. Suggests extracting a private function. Same pure-data and logging/CLI-scaffolding carve-outs as `repeated_subtree_in_function` (e.g. identical keyword-list arg shapes to a builder call; `Logger` / `Mix.shell()` / `OptionParser.parse` lines shared across functions). |
| `repeated_case_arm_body` | Two or more non-wildcard `case` clauses with structurally identical bodies AND identical literal values. Suggests merging with a guard (`x when x in [a, b] -> body`). Literal-sensitive — lookup tables (`:a -> 1; :b -> 2`) are not flagged. |
| `wildcard_import` | `import Foo` without `:only` / `:except`. Brings every public function into local scope; readers can't tell whether `name(...)` is local, Kernel, or imported. |
| `cross_file_duplicate_block` | Same normalised AST subtree (≥ 20 nodes) appearing in 2+ distinct files. Cross-file equivalent of `repeated_subtree_in_module`. Higher threshold (cross-file extraction has higher activation energy). Language idioms — subtrees that touch only stdlib (`Enum`, `Map`, `Logger`, `Application`, …) + control-flow + literals, with no call into a project module — are dropped (`flag_language_idioms: true` to report them; `extra_stdlib_modules: [...]` to widen stdlib). Attaches finding to the lexicographically-smallest path; message names every file the cluster appears in. |

## Layout

```
credence_rules/
├── lib/
│   ├── credence_rules.ex                          # rules/0, advisory_rules/0
│   ├── credence_rules/pattern/                    # 44 rule modules
│   └── mix/tasks/credence/check.ex                       # `mix credence.check`
├── priv/runner.exs                                       # per-file subprocess runner
└── test/credence_rules/pattern/                   # one test file per rule
```

## Adding a rule

1. Create `lib/credence_rules/pattern/my_rule.ex`:

   ```elixir
   defmodule CredenceRules.Pattern.MyRule do
     use Credence.Pattern.Rule

     @impl true
     def priority, do: 500

     @impl true
     def check(ast, _opts) do
       {_ast, issues} =
         Macro.prewalk(ast, [], fn node, acc ->
           # pattern-match and accumulate issues
           {node, acc}
         end)

       Enum.reverse(issues)
     end
   end
   ```

2. Add a matching test file under `test/credence_rules/pattern/`.
3. **That's it.** `CredenceRules.rules/0` auto-discovers every
   module under `CredenceRules.Pattern.*` that exports `check/2`
   — no central registration list to keep in sync.
4. If the rule is advisory rather than a boundary check, add the rule
   atom to the `@advisory_rules` set in `lib/credence_rules.ex`
   (advisory classification is the one decision a linter can't auto-
   discover for you).

## Disabling individual rules

If a rule isn't a good fit for your project, exclude it via Application
env — by atom or by module reference:

```elixir
# config/config.exs
config :credence_rules,
  disabled_rules: [
    :obvious_comment,
    :step_comment,
    CredenceRules.Pattern.UnaliasedModuleUse
  ]
```

Unknown atoms are ignored silently, so a stale entry from a deleted
rule won't break the build.
