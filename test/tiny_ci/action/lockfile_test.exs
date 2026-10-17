defmodule TinyCI.Action.LockfileTest do
  use ExUnit.Case, async: true

  alias TinyCI.Action.Lockfile

  doctest TinyCI.Action.Lockfile

  @lock ~S"""
  %{
    "jason": {:hex, :jason, "1.4.5", "inner_jason", [:mix], [], "hexpm", "outer_jason"},
    "telemetry": {:hex, :telemetry, "1.4.2", "inner_tel", [:rebar3], [], "hexpm", "outer_tel"},
    "my_git_dep": {:git, "https://example.com/x.git", "abc123", []},
    "legacy": {:hex, :legacy, "0.1.0", "only_inner", [:mix], []},
    "ancient": {:hex, :ancient, "0.0.1"},
    "short_hex": {:hex, :short_hex, "1.0.0", "inner_sh"},
    "repo_pinned": {:hex, :repo_pinned, "2.0.0", "inner_rp", [:mix], [], "myhex"},
    "my_path_dep": {:path, "/opt/path_dep", []}
  }
  """

  describe "parse/1" do
    test "normalizes hex entries with outer checksum" do
      {:ok, locks} = Lockfile.parse(@lock)

      assert %{scm: :hex, version: "1.4.5", checksum: "outer_jason", repo: "hexpm"} =
               locks["jason"]
    end

    test "keys are app-name strings" do
      {:ok, locks} = Lockfile.parse(@lock)

      assert Map.has_key?(locks, "telemetry")
      assert locks["telemetry"].version == "1.4.2"
      assert Enum.all?(Map.keys(locks), &is_binary/1)
    end

    test "git deps are recorded as :git, not hash-pinned by hex" do
      {:ok, locks} = Lockfile.parse(@lock)

      assert %{scm: :git, version: "abc123"} = locks["my_git_dep"]
      assert locks["my_git_dep"].repo == "https://example.com/x.git"
    end

    test "path deps are recorded as :path" do
      {:ok, locks} = Lockfile.parse(@lock)

      assert %{scm: :path, version: nil, checksum: nil, repo: "/opt/path_dep"} =
               locks["my_path_dep"]
    end

    test "every hex vintage normalizes the same way" do
      {:ok, locks} = Lockfile.parse(@lock)

      # 8-tuple: prefer the outer (tarball) checksum.
      assert locks["jason"].checksum == "outer_jason"
      # 6-tuple: no repo, checksum falls back to the inner one.
      assert locks["legacy"].checksum == "only_inner"
      assert locks["legacy"].repo == "hexpm"
      # 7-tuple: the repo is already recorded.
      assert locks["repo_pinned"].checksum == "inner_rp"
      assert locks["repo_pinned"].repo == "myhex"
      # 3-tuple: no checksum at all.
      assert locks["ancient"].checksum == nil
      assert locks["ancient"].repo == "hexpm"
      # 4-tuple: the inner checksum is the only one.
      assert locks["short_hex"].checksum == "inner_sh"
      assert locks["short_hex"].repo == "hexpm"
    end

    test "normalizes every key spelling to a string" do
      spellings = [
        ~S|%{"quoted": {:hex, :quoted, "1.0.0"}}|,
        ~S|%{"arrow" => {:hex, :arrow, "1.0.0"}}|,
        ~S|%{plain_atom: {:hex, :plain_atom, "1.0.0"}}|
      ]

      for content <- spellings do
        assert {:ok, locks} = Lockfile.parse(content)
        assert [key] = Map.keys(locks)
        assert is_binary(key)
      end
    end

    test "accepts signed numeric literals" do
      assert {:ok, locks} = Lockfile.parse(~S|%{"neg": -1, "pos": +2, "float": 1.5e3}|)
      assert Enum.sort(Map.keys(locks)) == ["float", "neg", "pos"]
    end

    test "returns an empty map for an empty lock" do
      assert {:ok, locks} = Lockfile.parse("%{}")
      assert locks == %{}
    end

    test "records an unknown tuple tag as :other" do
      assert {:ok, locks} = Lockfile.parse(~S|%{"x": {:foo, 1}}|)

      assert locks["x"] == %{scm: :other, version: nil, checksum: nil, repo: "foo"}
    end

    test "records a non-binary tag as :other without crashing" do
      assert {:ok, locks} = Lockfile.parse(~S|%{"x": {1, 2}}|)

      assert locks["x"] == %{scm: :other, version: nil, checksum: nil, repo: "1"}
    end

    test "degrades a malformed git entry to :other instead of crashing" do
      assert {:ok, locks} = Lockfile.parse(~S|%{"x": {:git, "u", 5, []}}|)

      assert locks["x"].scm == :other
      assert locks["x"].version == nil
    end

    test "keeps the last of duplicate keys" do
      content = ~S|%{"a": {:hex, :a, "1.0.0"}, "a": {:hex, :a, "2.0.0"}}|

      assert {:ok, locks} = Lockfile.parse(content)
      assert locks["a"].version == "2.0.0"
    end

    test "rejects bytes and literals that are not lock maps" do
      not_maps = [
        {"empty", ""},
        {"comment only", "# only a comment\n"},
        {"byte order mark", "\uFEFF%{\"a\": 1}"},
        {"number", "1"},
        {"list", "[1, 2]"},
        {"malformed", "this is not a lockfile {{{"},
        {"invalid UTF-8", <<0xFF, 0xFE>>}
      ]

      for {label, content} <- not_maps do
        assert {:error, :not_a_lock_map} = Lockfile.parse(content),
               "expected #{label} to be rejected"
      end
    end
  end

  describe "parse/1 is data-only (never evaluated)" do
    @tag :tmp_dir
    test "a lockfile containing a call is rejected and the call does not run", %{tmp_dir: dir} do
      marker = Path.join(dir, "pwned")

      content = """
      %{
        "evil": File.write!(#{inspect(marker)}, "x")
      }
      """

      assert {:error, :not_a_lock_map} = Lockfile.parse(content)
      refute File.exists?(marker)
    end

    test "a top-level expression is rejected, not executed" do
      assert {:error, :not_a_lock_map} = Lockfile.parse(~S|String.upcase("boom")|)
      assert {:error, :not_a_lock_map} = Lockfile.parse("1 + 1")
    end

    test "rejects non-literal terms" do
      non_literals = [
        {"variable", ~S|%{"a" => x}|},
        {"call in value", ~S|%{"a" => String.upcase("x")}|},
        {"call as key", ~S|%{String.upcase("x") => 1}|},
        {"interpolation", ~S|%{"a" => "#{x}"}|},
        {"sigil", ~S|%{"a" => ~s(b)}|},
        {"alias", ~S|%{"a" => File}|},
        {"struct", ~S|%{"a" => %URI{}}|},
        {"improper list", ~S(%{"a" => [1 | 2]})},
        {"block", ~S|%{"a" => (x; y)}|},
        {"negated variable", ~S|%{"a" => -x}|},
        {"subtraction", ~S|%{"a" => 1 - 2}|},
        {"map update", ~S(%{"a" => %{%{} | b: 1}})},
        {"capture", ~S|%{"a" => &String.upcase/1}|},
        {"anonymous fn", ~S|%{"a" => fn -> :ok end}|}
      ]

      for {label, content} <- non_literals do
        assert {:error, :not_a_lock_map} = Lockfile.parse(content),
               "expected #{label} to be rejected"
      end
    end

    test "does not intern atoms from lockfile content" do
      name = "tiny_ci_lockfile_probe_#{System.unique_integer([:positive])}"
      content = "%{\"#{name}\": {:hex, :#{name}, \"1.0.0\"}}"

      assert {:ok, locks} = Lockfile.parse(content)
      assert locks[name].version == "1.0.0"
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "rejects hex entries whose fields cannot be trusted" do
      # A non-binary version would crash consumers that interpolate it.
      assert {:error, :not_a_lock_map} =
               Lockfile.parse(~S|%{"x": {:hex, :x, 123, "sum", [:mix], [], "hexpm", "outer"}}|)

      # A non-binary checksum would crash the audit formatter.
      assert {:error, :not_a_lock_map} =
               Lockfile.parse(~S|%{"x": {:hex, :x, "1.0.0", 123, [:mix], []}}|)

      assert {:error, :not_a_lock_map} =
               Lockfile.parse(~S|%{"x": {:hex, :x, "1.0.0", "inner", [:mix], [], "hexpm", 123}}|)
    end
  end

  describe "read/1" do
    @tag :tmp_dir
    test "reads and parses a lockfile from disk", %{tmp_dir: dir} do
      path = Path.join(dir, "mix.lock")
      File.write!(path, @lock)

      {:ok, locks} = Lockfile.read(path)
      assert locks["jason"].version == "1.4.5"
    end

    test "treats a missing lockfile as empty (no crash)" do
      assert {:ok, %{}} = Lockfile.read("/nonexistent/mix.lock")
    end
  end
end
