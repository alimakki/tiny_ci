defmodule TinyCI.Action.LockfileTest do
  use ExUnit.Case, async: true

  alias TinyCI.Action.Lockfile

  @lock ~S"""
  %{
    "jason": {:hex, :jason, "1.4.5", "inner_jason", [:mix], [], "hexpm", "outer_jason"},
    "telemetry": {:hex, :telemetry, "1.4.2", "inner_tel", [:rebar3], [], "hexpm", "outer_tel"},
    "my_git_dep": {:git, "https://example.com/x.git", "abc123", []},
    "legacy": {:hex, :legacy, "0.1.0", "only_inner", [:mix], []}
  }
  """

  describe "parse/1" do
    test "normalizes hex entries with outer checksum" do
      {:ok, locks} = Lockfile.parse(@lock)

      assert %{scm: :hex, version: "1.4.5", checksum: "outer_jason", repo: "hexpm"} =
               locks[:jason]
    end

    test "keys are app atoms" do
      {:ok, locks} = Lockfile.parse(@lock)
      assert Map.has_key?(locks, :telemetry)
      assert locks[:telemetry].version == "1.4.2"
    end

    test "git deps are recorded as :git, not hash-pinned by hex" do
      {:ok, locks} = Lockfile.parse(@lock)
      assert %{scm: :git, version: "abc123"} = locks[:my_git_dep]
      assert locks[:my_git_dep].repo == "https://example.com/x.git"
    end

    test "falls back to the inner checksum for short hex tuples" do
      {:ok, locks} = Lockfile.parse(@lock)
      assert locks[:legacy].checksum == "only_inner"
    end

    test "returns an empty map for an empty lock" do
      assert {:ok, locks} = Lockfile.parse("%{}")
      assert locks == %{}
    end

    test "returns an error for malformed content" do
      assert {:error, _} = Lockfile.parse("this is not a lockfile {{{")
    end
  end

  describe "read/1" do
    @tag :tmp_dir
    test "reads and parses a lockfile from disk", %{tmp_dir: dir} do
      path = Path.join(dir, "mix.lock")
      File.write!(path, @lock)

      {:ok, locks} = Lockfile.read(path)
      assert locks[:jason].version == "1.4.5"
    end

    test "treats a missing lockfile as empty (no crash)" do
      assert {:ok, %{}} = Lockfile.read("/nonexistent/mix.lock")
    end
  end
end
