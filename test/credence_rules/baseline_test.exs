defmodule CredenceRules.BaselineTest do
  use ExUnit.Case, async: true

  alias CredenceRules.Baseline

  describe "from_findings/1 + diff/2" do
    test "splits findings into baselined and new based on {path, rule, line}" do
      baselined_findings = [
        %{path: "lib/a.ex", rule: :obvious_comment, line: 12, message: ""},
        %{path: "lib/b.ex", rule: :rescue_catch_all, line: 87, message: ""}
      ]

      baseline = Baseline.from_findings(baselined_findings)

      current = [
        # baselined (matches an entry)
        %{path: "lib/a.ex", rule: :obvious_comment, line: 12, message: ""},
        # new (different line)
        %{path: "lib/a.ex", rule: :obvious_comment, line: 99, message: ""},
        # new (different rule, same file/line)
        %{path: "lib/b.ex", rule: :step_comment, line: 87, message: ""},
        # baselined
        %{path: "lib/b.ex", rule: :rescue_catch_all, line: 87, message: ""},
        # new (new file)
        %{path: "lib/c.ex", rule: :obvious_comment, line: 1, message: ""}
      ]

      {baselined, new} = Baseline.diff(current, baseline)
      assert length(baselined) == 2
      assert length(new) == 3
    end

    test "diff treats nil-line findings as matching" do
      baseline =
        Baseline.from_findings([
          %{path: "lib/a.ex", rule: :stale_reference_comment, line: nil, message: ""}
        ])

      current = [%{path: "lib/a.ex", rule: :stale_reference_comment, line: nil, message: ""}]

      {baselined, new} = Baseline.diff(current, baseline)
      assert length(baselined) == 1
      assert new == []
    end

    test "empty baseline marks everything as new" do
      baseline = Baseline.from_findings([])
      current = [%{path: "lib/a.ex", rule: :obvious_comment, line: 1, message: ""}]

      {baselined, new} = Baseline.diff(current, baseline)
      assert baselined == []
      assert length(new) == 1
    end
  end

  describe "save/2 + load/1 round-trip" do
    @tag :tmp_dir
    test "writes JSON readable by load/1", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "credence-baseline.json")

      findings = [
        %{path: "lib/a.ex", rule: :obvious_comment, line: 12, message: ""},
        %{path: "lib/b.ex", rule: :rescue_catch_all, line: 87, message: ""},
        %{path: "lib/c.ex", rule: :stale_reference_comment, line: nil, message: ""}
      ]

      baseline = Baseline.from_findings(findings)
      assert :ok = Baseline.save(baseline, path)
      assert {:ok, loaded} = Baseline.load(path)

      # MapSet equality on the {path, rule, line} keys means a perfect
      # round-trip — `diff` against the loaded baseline matches everything.
      {baselined, new} = Baseline.diff(findings, loaded)
      assert length(baselined) == 3
      assert new == []
    end

    @tag :tmp_dir
    test "creates parent directories", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "nested", "subdir", "baseline.json"])
      baseline = Baseline.from_findings([])
      assert :ok = Baseline.save(baseline, path)
      assert File.exists?(path)
    end

    test "load/1 returns {:error, :enoent} for missing file" do
      assert {:error, :enoent} = Baseline.load("/tmp/this-should-not-exist-#{System.unique_integer()}")
    end
  end

  describe "default_path/0" do
    test "is the conventional baseline filename" do
      assert Baseline.default_path() == "credence-baseline.json"
    end
  end

  describe "v3 format (fingerprint-based, SHA-256)" do
    @tag :tmp_dir
    test "writes v3 with fingerprint entries", %{tmp_dir: tmp_dir} do
      finding = %{
        path: "lib/foo.ex",
        rule: :large_defstruct,
        line: 42,
        message: "test message",
        fingerprint: "DEADBEEF12345678"
      }

      path = Path.join(tmp_dir, "baseline.json")
      baseline = Baseline.from_findings([finding])
      :ok = Baseline.save(baseline, path)

      payload = path |> File.read!() |> Jason.decode!()
      assert payload["version"] == "3"
      assert [%{"fingerprint" => "DEADBEEF12345678"}] = payload["findings"]
    end

    @tag :tmp_dir
    test "round-trip: fingerprint diff matches", %{tmp_dir: tmp_dir} do
      finding = %{
        path: "lib/foo.ex",
        rule: :large_defstruct,
        line: 42,
        message: "test",
        fingerprint: "AAAA1111"
      }

      path = Path.join(tmp_dir, "baseline.json")
      Baseline.from_findings([finding]) |> Baseline.save(path)

      {:ok, loaded} = Baseline.load(path)

      # Same fingerprint → baselined.
      assert {[^finding], []} = Baseline.diff([finding], loaded)

      # Different fingerprint (line moved, message stayed identical) →
      # still baselined because fingerprint is line-independent.
      moved = %{finding | line: 99}
      assert {[^moved], []} = Baseline.diff([moved], loaded)
    end

    @tag :tmp_dir
    test "v1 file still loads (backward compat)", %{tmp_dir: tmp_dir} do
      # Hand-write a v1 file (the format the older versions of this
      # library wrote).
      v1_payload = %{
        "version" => "1",
        "generated_at" => "2026-01-01T00:00:00Z",
        "findings" => [
          %{"path" => "lib/foo.ex", "rule" => "large_defstruct", "line" => 42}
        ]
      }

      path = Path.join(tmp_dir, "baseline.json")
      File.write!(path, Jason.encode!(v1_payload))

      {:ok, loaded} = Baseline.load(path)
      assert loaded.version == "1"

      # v1 matching: {path, rule, line} triple.
      finding = %{path: "lib/foo.ex", rule: :large_defstruct, line: 42}
      assert {[^finding], []} = Baseline.diff([finding], loaded)

      # Different line → no longer matches (v1 was line-keyed).
      moved = %{finding | line: 99}
      assert {[], [^moved]} = Baseline.diff([moved], loaded)
    end

    @tag :tmp_dir
    test "fingerprint match works with hand-built findings that omit :fingerprint",
         %{tmp_dir: tmp_dir} do
      # If a caller passes a finding without :fingerprint, from_findings
      # falls back to v1 key. Saving + reloading + diffing should still
      # round-trip cleanly.
      finding = %{path: "lib/foo.ex", rule: :obvious_comment, line: 7}

      path = Path.join(tmp_dir, "baseline.json")
      Baseline.from_findings([finding]) |> Baseline.save(path)

      {:ok, loaded} = Baseline.load(path)
      assert {[^finding], []} = Baseline.diff([finding], loaded)
    end

    @tag :tmp_dir
    test "v2 baseline still recognises v1-shape findings on the in-memory side",
         %{tmp_dir: tmp_dir} do
      # A v2 baseline file with one fingerprint. Diff a finding that
      # has the SAME (path, rule, line) but a different fingerprint —
      # should NOT match. (No accidental fallthrough through v1 key.)
      finding = %{
        path: "lib/foo.ex",
        rule: :large_defstruct,
        line: 42,
        message: "msg one",
        fingerprint: "FP1AAAAA"
      }

      path = Path.join(tmp_dir, "baseline.json")
      Baseline.from_findings([finding]) |> Baseline.save(path)
      {:ok, loaded} = Baseline.load(path)

      different_message = %{finding | message: "completely different msg", fingerprint: "FP2BBBBB"}
      assert {[], [^different_message]} = Baseline.diff([different_message], loaded)
    end

    @tag :tmp_dir
    test "loading a v2 baseline prints a stale-fingerprint warning",
         %{tmp_dir: tmp_dir} do
      # v2 baselines used 8-char phash2 fingerprints. v3 bumped to
      # 16-char SHA-256. Old fingerprints can't match new ones, so
      # we warn the user to regenerate the baseline.
      v2_payload = %{
        "version" => "2",
        "generated_at" => "2026-04-01T00:00:00Z",
        "findings" => [%{"fingerprint" => "DEADBEEF"}]
      }

      path = Path.join(tmp_dir, "baseline.json")
      File.write!(path, Jason.encode!(v2_payload))

      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          {:ok, _loaded} = Baseline.load(path)
        end)

      assert warning =~ "loading a v2 baseline"
      assert warning =~ "--update-baseline"
    end

    @tag :tmp_dir
    test "loading a v3 baseline does NOT warn", %{tmp_dir: tmp_dir} do
      finding = %{
        path: "lib/foo.ex",
        rule: :large_defstruct,
        line: 42,
        message: "test",
        fingerprint: "AAAA1111BBBB2222"
      }

      path = Path.join(tmp_dir, "baseline.json")
      Baseline.from_findings([finding]) |> Baseline.save(path)

      warning =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          {:ok, _loaded} = Baseline.load(path)
        end)

      assert warning == ""
    end
  end
end
