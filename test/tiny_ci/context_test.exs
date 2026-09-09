defmodule TinyCI.ContextTest do
  use ExUnit.Case, async: true

  alias TinyCI.{Context, GitFixtures}

  @empty_tree "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

  defp repo(tmp_dir, name \\ "repo"), do: GitFixtures.init_repo(Path.join(tmp_dir, name))

  defp sha(dir, ref), do: GitFixtures.git!(dir, ["rev-parse", ref])

  describe "build/0" do
    test "returns a TinyCI.Context struct" do
      context = Context.build()
      assert %Context{} = context
      assert is_struct(context, Context)
    end

    test "defaults :store to an empty map" do
      context = Context.build()
      assert context.store == %{}
    end

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

    test "accepts arbitrary metadata keys while remaining a struct" do
      context = Context.build(pr_number: 42, author: "dev")
      assert is_struct(context, Context)
      assert context.pr_number == 42
      assert context.author == "dev"
    end

    test "allows overriding the store" do
      context = Context.build(store: %{image_tag: "v1"})
      assert context.store == %{image_tag: "v1"}
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

  describe "changed_files/2" do
    @describetag :tmp_dir

    test "initial commit with no remote returns every tracked file", %{tmp_dir: tmp} do
      dir = repo(tmp)
      GitFixtures.commit(dir, %{"lib/a.ex" => "a", "README.md" => "r"})

      assert Context.changed_files(dir) == ["README.md", "lib/a.ex"]
    end

    test "on main with a clean tree and no remote, falls back to HEAD~1", %{tmp_dir: tmp} do
      dir = repo(tmp)
      GitFixtures.commit(dir, %{"lib/a.ex" => "a"})
      GitFixtures.commit(dir, %{"docs/b.md" => "b"})

      assert Context.changed_files(dir) == ["docs/b.md"]
    end

    test "includes an unstaged edit to a committed file", %{tmp_dir: tmp} do
      dir = repo(tmp)
      GitFixtures.commit(dir, %{"lib/a.ex" => "a"})
      GitFixtures.commit(dir, %{"docs/b.md" => "b"})
      GitFixtures.write_files(dir, %{"lib/a.ex" => "changed"})

      assert "lib/a.ex" in Context.changed_files(dir)
    end

    test "includes a staged new file", %{tmp_dir: tmp} do
      dir = repo(tmp)
      GitFixtures.commit(dir, %{"lib/a.ex" => "a"})
      GitFixtures.commit(dir, %{"docs/b.md" => "b"})
      GitFixtures.write_files(dir, %{"lib/new.ex" => "n"})
      GitFixtures.git!(dir, ["add", "lib/new.ex"])

      assert "lib/new.ex" in Context.changed_files(dir)
    end

    test "includes untracked files but not ignored ones", %{tmp_dir: tmp} do
      dir = repo(tmp)
      GitFixtures.commit(dir, %{"lib/a.ex" => "a", ".gitignore" => "_build/\n"})
      GitFixtures.commit(dir, %{"docs/b.md" => "b"})
      GitFixtures.write_files(dir, %{"lib/untracked.ex" => "u", "_build/out" => "o"})

      files = Context.changed_files(dir)
      assert "lib/untracked.ex" in files
      refute "_build/out" in files
    end

    test "include_dirty: false excludes uncommitted changes", %{tmp_dir: tmp} do
      dir = repo(tmp)
      GitFixtures.commit(dir, %{"lib/a.ex" => "a"})
      GitFixtures.commit(dir, %{"docs/b.md" => "b"})
      GitFixtures.write_files(dir, %{"lib/a.ex" => "changed", "lib/untracked.ex" => "u"})

      assert Context.changed_files(dir, include_dirty: false) == ["docs/b.md"]
    end

    test "an explicit base: covers every commit after it", %{tmp_dir: tmp} do
      dir = repo(tmp)
      first = GitFixtures.commit(dir, %{"lib/a.ex" => "a"})
      GitFixtures.commit(dir, %{"docs/b.md" => "b"})
      GitFixtures.commit(dir, %{"test/c_test.exs" => "c"})

      assert Context.changed_files(dir, base: first) == ["docs/b.md", "test/c_test.exs"]
    end

    test "a path with a space survives", %{tmp_dir: tmp} do
      dir = repo(tmp)
      GitFixtures.commit(dir, %{"lib/a.ex" => "a"})
      GitFixtures.commit(dir, %{"docs/my notes.md" => "n"})

      assert Context.changed_files(dir) == ["docs/my notes.md"]
    end

    test "returns [] for a directory that is not a repository", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "plain")
      File.mkdir_p!(dir)
      GitFixtures.write_files(dir, %{"lib/a.ex" => "a"})

      # Isolate from any enclosing repository so the test does not depend on cwd.
      assert Context.changed_files(dir, git_env: [{"GIT_CEILING_DIRECTORIES", tmp}]) == []
    end

    test "with base: nil diffs against the empty tree", %{tmp_dir: tmp} do
      dir = repo(tmp)
      GitFixtures.commit(dir, %{"lib/a.ex" => "a"})
      GitFixtures.commit(dir, %{"docs/b.md" => "b"})

      assert Context.changed_files(dir, base: nil) == ["docs/b.md", "lib/a.ex"]
      assert Context.merge_base(dir, nil) == @empty_tree
    end
  end

  describe "detect_base/2" do
    @describetag :tmp_dir

    defp origin_and_clone(tmp) do
      src = repo(tmp, "src")
      GitFixtures.commit(src, %{"lib/a.ex" => "a"})
      origin = GitFixtures.bare_clone(src, Path.join(tmp, "origin.git"))
      work = GitFixtures.clone(origin, Path.join(tmp, "work"))
      {origin, work}
    end

    test "on a feature branch, the base is the upstream main", %{tmp_dir: tmp} do
      {origin, work} = origin_and_clone(tmp)
      origin_main = sha(origin, "main")
      GitFixtures.git!(work, ["checkout", "-q", "-b", "feature/x"])
      GitFixtures.commit(work, %{"lib/feature.ex" => "f"})

      base = Context.detect_base(work)
      assert is_binary(base)
      assert Context.merge_base(work, base) == origin_main
      assert Context.changed_files(work) == ["lib/feature.ex"]
    end

    test "on main with an unpushed commit, the base is origin/main", %{tmp_dir: tmp} do
      {origin, work} = origin_and_clone(tmp)
      origin_main = sha(origin, "main")
      GitFixtures.commit(work, %{"lib/local.ex" => "l"})

      base = Context.detect_base(work)
      assert Context.merge_base(work, base) == origin_main
      assert Context.changed_files(work) == ["lib/local.ex"]
    end

    test "a base equal to HEAD falls back to HEAD~1", %{tmp_dir: tmp} do
      {_origin, work} = origin_and_clone(tmp)
      GitFixtures.commit(work, %{"lib/local.ex" => "l"})
      GitFixtures.git!(work, ["push", "-q", "origin", "main"])

      assert Context.detect_base(work) == "HEAD~1"
      assert Context.changed_files(work) == ["lib/local.ex"]
    end

    test "honours TINY_CI_BASE_REF through the env: option", %{tmp_dir: tmp} do
      dir = repo(tmp)
      first = GitFixtures.commit(dir, %{"lib/a.ex" => "a"})
      GitFixtures.commit(dir, %{"docs/b.md" => "b"})
      GitFixtures.commit(dir, %{"test/c_test.exs" => "c"})

      assert Context.detect_base(dir, env: %{"TINY_CI_BASE_REF" => first}) == first
      assert Context.detect_base(dir, env: %{"TINY_CI_BASE_REF" => ""}) == "HEAD~1"
      assert Context.detect_base(dir, env: %{"TINY_CI_BASE_REF" => "no-such-ref"}) == "HEAD~1"
    end

    test "returns nil on an initial commit with no remote", %{tmp_dir: tmp} do
      dir = repo(tmp)
      GitFixtures.commit(dir, %{"lib/a.ex" => "a"})

      assert Context.detect_base(dir, env: %{}) == nil
    end
  end

  describe "build/1 with root:" do
    @describetag :tmp_dir

    test "runs git in root, not in the current directory", %{tmp_dir: tmp} do
      dir = repo(tmp)
      GitFixtures.commit(dir, %{"lib/a.ex" => "a"})
      GitFixtures.git!(dir, ["checkout", "-q", "-b", "feature/x"])
      head = GitFixtures.commit(dir, %{"lib/b.ex" => "b"})

      ctx = Context.build(root: dir)

      assert ctx.branch == "feature/x"
      assert ctx.commit == head
      # No upstream and no remote, so the local `main` is the base (step 4).
      assert ctx.base_ref == "main"
      assert ctx.changed_files == ["lib/b.ex"]
      assert ctx.root == dir
      refute Map.has_key?(ctx, :include_dirty)
    end

    test "an explicit base: is recorded on the context", %{tmp_dir: tmp} do
      dir = repo(tmp)
      first = GitFixtures.commit(dir, %{"lib/a.ex" => "a"})
      GitFixtures.commit(dir, %{"docs/b.md" => "b"})
      GitFixtures.commit(dir, %{"test/c_test.exs" => "c"})

      ctx = Context.build(root: dir, base: first)

      assert ctx.base_ref == first
      assert ctx.changed_files == ["docs/b.md", "test/c_test.exs"]
    end
  end
end
