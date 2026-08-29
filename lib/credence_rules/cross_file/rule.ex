defmodule CredenceRules.CrossFile.Rule do
  @moduledoc """
  Behaviour for cross-file analysis rules.

  Cross-file rules see every scanned file's AST at once, so they can
  detect duplicates across files, build module dependency graphs,
  flag circular dependencies, identify hub modules, etc. — anything
  that needs more than one file's worth of context.

  Per-file rules (the older, larger set under
  `CredenceRules.Pattern.*`) implement the
  `Credence.Pattern.Rule` behaviour and see one file at a time.
  Cross-file rules are a separate channel with their own callback
  signature.

  ## Callback

      check(files :: [{Path.t(), Macro.t()}], opts :: keyword()) :: [Credence.Issue.t()]

  The `files` argument is a list of `{path, ast}` tuples — all
  scanned files, parsed once and shared across every cross-file
  rule. Returned `Issue` structs must include `:path` in `:meta` so
  the formatter can render them; unlike per-file rules where the
  Mix task sets the path, here the rule chooses which file each
  finding attaches to (a cycle could attach to any module's file;
  by convention we pick the lexicographically-smallest module's
  file for determinism).

  ## Discovery

  Auto-discovered the same way per-file rules are: every module
  under `CredenceRules.CrossFile.*` that exports `check/2`
  (and isn't this `Rule` behaviour module itself) is registered
  via `CredenceRules.cross_file_rules/0`.

  Disabled selectively via `:disabled_rules` Application env, same
  shape as per-file rules.
  """

  @callback check(files :: [{Path.t(), Macro.t()}], opts :: keyword()) :: [Credence.Issue.t()]
end
