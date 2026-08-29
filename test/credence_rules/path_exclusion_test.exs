defmodule CredenceRules.PathExclusionTest do
  use ExUnit.Case, async: true

  alias CredenceRules.PathExclusion

  describe "excluded?/1" do
    test "true when source_path starts with an exclude prefix" do
      opts = [source_path: "lib/foo/bar.ex", exclude_paths: ["lib/foo/"]]
      assert PathExclusion.excluded?(opts)
    end

    test "false when no prefix matches" do
      opts = [source_path: "lib/foo/bar.ex", exclude_paths: ["lib/baz/"]]
      refute PathExclusion.excluded?(opts)
    end

    test "false when exclude_paths is empty or missing" do
      refute PathExclusion.excluded?(source_path: "lib/foo.ex", exclude_paths: [])
      refute PathExclusion.excluded?(source_path: "lib/foo.ex")
    end

    test "false when source_path is missing or nil" do
      refute PathExclusion.excluded?(exclude_paths: ["lib/foo/"])
      refute PathExclusion.excluded?(source_path: nil, exclude_paths: ["lib/foo/"])
    end

    test "matches any of multiple prefixes" do
      opts = [
        source_path: "lib/mix/tasks/x.ex",
        exclude_paths: ["lib/foo/", "lib/mix/", "lib/bar/"]
      ]

      assert PathExclusion.excluded?(opts)
    end
  end

  describe "filter_files/2" do
    test "drops files whose path matches any prefix" do
      files = [
        {"lib/keep/a.ex", :ast_a},
        {"lib/drop/b.ex", :ast_b},
        {"lib/keep/c.ex", :ast_c}
      ]

      assert PathExclusion.filter_files(files, exclude_paths: ["lib/drop/"]) == [
               {"lib/keep/a.ex", :ast_a},
               {"lib/keep/c.ex", :ast_c}
             ]
    end

    test "returns input unchanged when exclude_paths is empty" do
      files = [{"lib/a.ex", :ast}]
      assert PathExclusion.filter_files(files, []) == files
      assert PathExclusion.filter_files(files, exclude_paths: []) == files
    end
  end
end
