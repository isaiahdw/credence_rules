defmodule CredenceRules.PathExclusion do
  @moduledoc """
  Per-rule path exclusions.

  Most rules want to run on every scanned file. A few — typically
  heuristic clustering rules — fire by-design on uniform code that
  isn't actually a smell: a catalog of pattern matchers, generated
  TLV decoders, mirrored protocol implementations. Disabling the
  rule project-wide loses real coverage; disabling the file
  loses every rule.

  This module lets a rule's per-rule `:rule_opts` carry an
  `:exclude_paths` list of path prefixes. The rule short-circuits
  to `[]` when the file being analysed starts with any prefix.

      config :credence_rules,
        rule_opts: %{
          cross_file_duplicate_block: [exclude_paths: ["lib/my_app/generated/"]]
        }

  The analyser threads `:source_path` (the file path being
  analysed) into each rule's opts so the rule can compare. For
  cross-file rules, `filter_files/2` filters the `{path, ast}`
  list before the rule sees it.

  All four cross-file rules support it —
  `cross_file_duplicate_block`, `circular_module_dependency`,
  `hub_module`, and `module_instability`. Generated code is the
  usual reason to reach for it: a compiled data model where every
  module references shared struct modules and a registry
  references all of them produces a real cycle and real fan-in,
  but neither is the author's to restructure.

  Filtering happens before graph construction, so excluded files
  contribute no nodes *and* no edges — an excluded dependant stops
  counting toward a kept module's fan-in.
  """

  @doc """
  True if the current file's path (read from `opts[:source_path]`)
  starts with any prefix in `opts[:exclude_paths]`. Per-file rules
  call this at the top of `check/2` and return `[]` when true.
  """
  @spec excluded?(keyword()) :: boolean()
  def excluded?(opts) do
    path = Keyword.get(opts, :source_path)
    excludes = Keyword.get(opts, :exclude_paths, [])

    is_binary(path) and Enum.any?(excludes, &String.starts_with?(path, &1))
  end

  @doc """
  Filter a `[{path, ast}]` list by `opts[:exclude_paths]`. Used by
  cross-file rules to drop excluded files before clustering /
  graph analysis.
  """
  @spec filter_files([{String.t(), term()}], keyword()) :: [{String.t(), term()}]
  def filter_files(files, opts) do
    case Keyword.get(opts, :exclude_paths, []) do
      [] ->
        files

      excludes ->
        Enum.reject(files, fn {path, _ast} ->
          Enum.any?(excludes, &String.starts_with?(path, &1))
        end)
    end
  end
end
