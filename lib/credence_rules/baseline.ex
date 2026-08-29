defmodule CredenceRules.Baseline do
  @moduledoc """
  Snapshot of accepted findings, used to gate CI on **new** issues only.

  Run `mix credence.check --update-baseline` once to capture the
  current findings, commit the resulting `credence-baseline.json`,
  then run `mix credence.check --baseline --strict` in CI. The strict
  gate fails only on findings (at or above the configured severity +
  confidence thresholds) that aren't in the baseline, so existing
  accepted code stays accepted while preventing new drift.

  This mirrors the rustqual pattern (`rustqual-baseline.json`): pin
  what you have today, tighten by deleting baseline entries as the
  code improves.

  ## File format

  ### Version 3 (current, SHA-256 fingerprint)

      {
        "version": "3",
        "generated_at": "2026-05-22T14:32:01Z",
        "findings": [
          {"fingerprint": "4F4A1B8C2DE60809"},
          {"fingerprint": "A23BCD1255AAFE91"}
        ]
      }

  Each entry's `fingerprint` is a 16-char SHA-256 hash (64-bit
  truncation) over a canonical
  `{rule, path, normalized_message, meta_extract}` payload — see
  `CredenceRules.Finding.fingerprint/1`. Line numbers are
  NOT part of the key; small line moves don't churn the
  baseline. Cross-file findings (`line: nil`) fold in a
  whitelist of distinguishing meta keys
  (`source`, `target`, `cycle`, `files`, `cluster_id`, ...) so
  distinct findings don't collide.

  ### Version 2 (legacy, phash2 fingerprint — STALE)

  v2 used `:erlang.phash2/1` truncated to 8 hex chars.
  `load/1` still accepts v2 files but emits a stderr warning:
  the new SHA-256 fingerprints can't match the old phash2
  values, so EVERY finding would surface as "new vs baseline."
  Regenerate with `mix credence.check --update-baseline`.

  ### Version 1 (legacy, line-keyed)

      {
        "version": "1",
        "findings": [
          {"path": "lib/foo.ex", "rule": "obvious_comment", "line": 12}
        ]
      }

  Still loadable for backward compatibility — `load/1` detects v1
  by absent `:version` or `"version": "1"` and uses
  `{path, rule, line}` as the matching key alongside fingerprint
  via `diff/2`'s dual-key matcher. Running `--update-baseline`
  always writes v3; v1 / v2 files are upgraded on the next
  snapshot.
  """

  alias CredenceRules.Finding

  @type finding :: %{
          required(:path) => String.t(),
          required(:rule) => atom(),
          required(:line) => pos_integer() | nil,
          optional(:fingerprint) => String.t() | nil,
          optional(:message) => String.t()
        }

  @type key :: {:v2, String.t()} | {:v1, String.t(), atom(), pos_integer() | nil}

  @type t :: %__MODULE__{
          version: String.t(),
          generated_at: String.t() | nil,
          findings: MapSet.t(key())
        }

  defstruct version: "2", generated_at: nil, findings: MapSet.new()

  @default_path "credence-baseline.json"

  @doc "The conventional baseline path when none is given."
  @spec default_path() :: String.t()
  def default_path, do: @default_path

  @doc """
  Load a baseline from disk. Returns `{:ok, baseline}` on success or
  `{:error, reason}` when the file is missing, unreadable, or
  malformed. Handles both v1 and v2 formats transparently.
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path) do
    with {:ok, body} <- File.read(path),
         {:ok, payload} <- Jason.decode(body) do
      {:ok, from_payload(payload)}
    end
  end

  @doc """
  Build a baseline struct from a list of finding maps. Each map
  must include `:fingerprint` (computed by the analyser); falls
  back to the v1 `{path, rule, line}` key if `:fingerprint` is
  absent.
  """
  @spec from_findings([map()]) :: t()
  def from_findings(findings) do
    %__MODULE__{
      version: "3",
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      findings: MapSet.new(findings, &to_key/1)
    }
  end

  @doc """
  Write a baseline to disk. Always writes v3. Creates parent
  directories as needed. Returns `:ok` or `{:error, reason}`.

  Format history:
  - v1: `{path, rule, line}` triple per entry. Line-keyed; collisions
    on cross-file rules with `line: nil`. Still loadable for backward
    compat.
  - v2: 8-char `:erlang.phash2/1` fingerprint per entry. Fingerprint
    algorithm changed in v3; v2 fingerprints are 8 hex chars and
    won't match the new 16-char SHA-256 fingerprints. Loader emits
    a one-time warning when a v2 file is read.
  - v3 (current): 16-char SHA-256 fingerprint over a canonical
    `{rule, path, normalized_message, meta_extract}` payload. See
    `CredenceRules.Finding.fingerprint/1`.
  """
  @spec save(t(), Path.t()) :: :ok | {:error, term()}
  def save(%__MODULE__{} = baseline, path) do
    payload = %{
      "version" => "3",
      "generated_at" => baseline.generated_at,
      "findings" =>
        baseline.findings
        |> Enum.sort()
        |> Enum.map(&key_to_payload_entry/1)
    }

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, Jason.encode_to_iodata!(payload, pretty: true))
    end
  end

  @doc """
  Split a list of findings into `{baselined, new}` based on the
  given baseline. A finding is "baselined" when EITHER its
  fingerprint matches a v2 baseline entry OR its `{path, rule,
  line}` matches a v1 baseline entry. This dual-key behaviour
  means v1 baselines keep working after the format upgrade.
  """
  @spec diff([map()], t()) :: {[map()], [map()]}
  def diff(findings, %__MODULE__{findings: baseline_keys}) do
    Enum.split_with(findings, fn finding ->
      MapSet.member?(baseline_keys, v2_key(finding)) or
        MapSet.member?(baseline_keys, v1_key(finding))
    end)
  end

  # Pick the best key for a fresh finding — fingerprint when available,
  # otherwise fall back to v1 shape. The analyser sets fingerprint on
  # every finding so the v1 path is only for hand-built test inputs.
  defp to_key(finding) do
    case Map.get(finding, :fingerprint) do
      nil -> v1_key(finding)
      _ -> v2_key(finding)
    end
  end

  defp v2_key(%{fingerprint: fp}) when is_binary(fp), do: {:v2, fp}

  defp v2_key(finding) do
    # Compute on the fly when not pre-baked (test inputs).
    {:v2, Finding.fingerprint(finding)}
  end

  defp v1_key(%{path: path, rule: rule, line: line}) do
    {:v1, relative(path), normalize_rule(rule), line}
  end

  defp key_to_payload_entry({:v2, fingerprint}), do: %{"fingerprint" => fingerprint}

  defp key_to_payload_entry({:v1, path, rule, line}),
    do: %{"path" => path, "rule" => Atom.to_string(rule), "line" => line}

  defp from_payload(%{"findings" => raw_findings} = payload) do
    version = Map.get(payload, "version", "1")
    maybe_warn_stale_fingerprints(version, raw_findings)

    %__MODULE__{
      version: version,
      generated_at: Map.get(payload, "generated_at"),
      findings: MapSet.new(raw_findings, &payload_entry_to_key(&1, version))
    }
  end

  defp from_payload(_), do: %__MODULE__{}

  # v2 baselines used 8-char `:erlang.phash2/1` fingerprints; v3
  # bumped the algorithm to 16-char SHA-256. The fingerprints
  # stored in v2 files can't possibly match v3 fingerprints
  # computed from current findings — every finding would be
  # treated as "new" and `--strict --baseline` would surface a
  # spurious wall of failures.
  #
  # Print a one-time warning when a v2 baseline is loaded so the
  # user knows to regenerate (`mix credence.check
  # --update-baseline`). Skip the warning for v1 (line-keyed,
  # still works via the dual-key matcher) and v3 (current).
  defp maybe_warn_stale_fingerprints("2", _entries) do
    IO.puts(:stderr, """
    [credence.check] WARNING: loading a v2 baseline (8-char phash2 fingerprints).
    The fingerprint algorithm was upgraded to SHA-256 in v3 — old fingerprints
    can no longer match new findings. Regenerate the baseline:

      mix credence.check --update-baseline

    Until then, every finding will be reported as "new vs baseline."
    """)
  end

  defp maybe_warn_stale_fingerprints(_, _), do: :ok

  # V2 entries carry only "fingerprint". V1 entries carry "path" +
  # "rule" + "line" (no "fingerprint"). Mixed-version files are
  # handled per-entry — if a v2 file contains a stray v1-shaped
  # entry, it's still loaded as a v1 key (and continues to match
  # findings of the same path/rule/line).
  defp payload_entry_to_key(entry, version) do
    case Map.get(entry, "fingerprint") do
      nil when version == "1" or version == 1 ->
        {:v1, Map.fetch!(entry, "path"), to_rule_atom(Map.fetch!(entry, "rule")), Map.get(entry, "line")}

      nil ->
        # v2 file but the entry lacks a fingerprint — try v1 shape
        # if fields are present.
        case entry do
          %{"path" => path, "rule" => rule} ->
            {:v1, path, to_rule_atom(rule), Map.get(entry, "line")}

          _ ->
            # Malformed entry — use a dummy key that won't match
            # anything real.
            {:v2, ""}
        end

      fp when is_binary(fp) ->
        {:v2, fp}
    end
  end

  # Normalise stored paths to relative for portability — a baseline
  # generated on one developer's checkout has to be readable on another's.
  defp relative(path), do: Path.relative_to_cwd(path)

  defp normalize_rule(rule) when is_atom(rule), do: rule
  defp normalize_rule(rule) when is_binary(rule), do: to_rule_atom(rule)

  # Rule atoms are all defined by rule modules at compile time, so
  # `String.to_existing_atom/1` is safe. Bonus: if a baseline references
  # a rule that's been renamed or removed, the entry fails to load
  # explicitly (user regenerates the baseline) rather than silently
  # creating a new atom and never matching anything.
  defp to_rule_atom(name) when is_binary(name), do: String.to_existing_atom(name)
end
