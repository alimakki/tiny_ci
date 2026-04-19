defmodule TinyCI.ContextTest do
  use ExUnit.Case, async: true

  alias TinyCI.Context

  describe "build/0" do
    test "returns a map with :branch key" do
      context = Context.build()
      assert is_binary(context.branch)
      assert context.branch != ""
    end

    test "returns a map with :commit key as a 40-character hex SHA" do
      context = Context.build()
      assert is_binary(context.commit)
      assert String.match?(context.commit, ~r/^[0-9a-f]{40}$/)
    end

    test "returns a map with :timestamp as a DateTime" do
      context = Context.build()
      assert %DateTime{} = context.timestamp
    end

    test "detects the actual git branch" do
      {branch, 0} = System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"])
      expected = String.trim(branch)

      context = Context.build()
      assert context.branch == expected
    end

    test "detects the actual git commit SHA" do
      {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"])
      expected = String.trim(sha)

      context = Context.build()
      assert context.commit == expected
    end
  end

  describe "build/1 with overrides" do
    test "allows overriding the branch" do
      context = Context.build(branch: "feature/custom")
      assert context.branch == "feature/custom"
    end

    test "allows overriding the commit" do
      context = Context.build(commit: "abc123")
      assert context.commit == "abc123"
    end

    test "preserves non-overridden fields when overriding branch" do
      {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"])
      expected_commit = String.trim(sha)

      context = Context.build(branch: "override")
      assert context.branch == "override"
      assert context.commit == expected_commit
    end

    test "accepts arbitrary metadata keys" do
      context = Context.build(pr_number: 42, author: "dev")
      assert context.pr_number == 42
      assert context.author == "dev"
    end
  end

  describe "build/0 includes changed_files" do
    test "returns a list of strings for :changed_files" do
      context = Context.build()
      assert is_list(context.changed_files)
      assert Enum.all?(context.changed_files, &is_binary/1)
    end

    test "allows overriding changed_files" do
      context = Context.build(changed_files: ["lib/foo.ex", "test/foo_test.exs"])
      assert context.changed_files == ["lib/foo.ex", "test/foo_test.exs"]
    end
  end

  describe "changed_files/0" do
    test "returns a list of strings" do
      files = Context.changed_files()
      assert is_list(files)
      assert Enum.all?(files, &is_binary/1)
    end
  end

  describe "any_file_matches?/2" do
    test "matches simple glob pattern" do
      files = ["lib/tiny_ci/executor.ex", "test/executor_test.exs"]
      assert Context.any_file_matches?(files, "lib/**/*.ex")
    end

    test "returns false when no files match" do
      files = ["lib/tiny_ci/executor.ex"]
      refute Context.any_file_matches?(files, "test/**/*.exs")
    end

    test "matches wildcard at end" do
      files = ["README.md", "CHANGELOG.md"]
      assert Context.any_file_matches?(files, "*.md")
    end

    test "matches exact file name" do
      files = ["mix.exs", "lib/app.ex"]
      assert Context.any_file_matches?(files, "mix.exs")
    end

    test "returns false for empty file list" do
      refute Context.any_file_matches?([], "**/*.ex")
    end

    test "matches double-star glob across directories" do
      files = ["lib/tiny_ci/deep/nested/file.ex"]
      assert Context.any_file_matches?(files, "lib/**/*.ex")
    end

    test "single star does not match across directories" do
      files = ["lib/tiny_ci/executor.ex"]
      refute Context.any_file_matches?(files, "lib/*.ex")
    end

    test "matches files in root with single star" do
      files = ["foo.ex", "bar.ex"]
      assert Context.any_file_matches?(files, "*.ex")
    end
  end

  describe "branch/0" do
    test "returns the current git branch as a string" do
      assert is_binary(Context.branch())
      assert Context.branch() != ""
    end
  end

  describe "commit/0" do
    test "returns the current commit SHA as a string" do
      assert is_binary(Context.commit())
      assert String.match?(Context.commit(), ~r/^[0-9a-f]{40}$/)
    end
  end
end
