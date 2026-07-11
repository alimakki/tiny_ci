defmodule Mix.Tasks.TinyCi.Actions.RegistryTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias TinyCI.Registry.Index
  alias TinyCI.RegistryFixtures.{Archive, Deploy}

  @tmp_dir "test/tmp/registry"

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  # Register the fixtures under the (loaded) :tiny_ci app so the tasks' default
  # scan over loaded applications discovers them.
  defp with_registered_actions(fun) do
    Application.put_env(:tiny_ci, :tiny_ci_actions, [Deploy, Archive])
    fun.()
  after
    Application.delete_env(:tiny_ci, :tiny_ci_actions)
  end

  describe "actions.index task" do
    test "scans and writes a JSON index of self-identified actions" do
      out = Path.join(@tmp_dir, "actions.json")

      with_registered_actions(fn ->
        capture_io(fn ->
          assert Mix.Tasks.TinyCi.Actions.Index.run(["--out", out]) == :ok
        end)
      end)

      assert {:ok, index} = Index.from_json(File.read!(out))
      names = index |> Index.search(nil) |> Enum.map(& &1.name)
      assert "acme.deploy" in names
      assert "acme.archive" in names
    end
  end

  describe "actions.search task" do
    defp write_index(entries) do
      path = Path.join(@tmp_dir, "index.json")
      File.write!(path, Index.to_json(Index.new(entries)))
      path
    end

    test "lists matching actions with version, capabilities, and tier" do
      alias TinyCI.Registry.Entry

      path =
        write_index([
          %Entry{
            package: :acme_actions,
            version: "2.1.0",
            module: Acme.Deploy,
            name: "acme.deploy",
            summary: "Ships a release.",
            capabilities: [:network, :env_read],
            tier: :verified
          }
        ])

      output =
        capture_io(fn ->
          assert Mix.Tasks.TinyCi.Actions.Search.run(["deploy", "--index", path]) == :ok
        end)

      assert output =~ "acme.deploy"
      assert output =~ "2.1.0"
      assert output =~ "network"
      assert output =~ "verified"
    end

    test "reports when nothing matches (exit 0)" do
      path = write_index([])

      output =
        capture_io(fn ->
          assert Mix.Tasks.TinyCi.Actions.Search.run(["nope", "--index", path]) == :ok
        end)

      assert output =~ "No actions"
    end

    test "filters by capability" do
      alias TinyCI.Registry.Entry

      path =
        write_index([
          %Entry{
            package: :a,
            module: A.Net,
            name: "a.net",
            capabilities: [:network],
            tier: :community
          },
          %Entry{
            package: :b,
            module: B.Fs,
            name: "b.fs",
            capabilities: [:filesystem_read],
            tier: :community
          }
        ])

      output =
        capture_io(fn ->
          assert Mix.Tasks.TinyCi.Actions.Search.run(["--index", path, "--capability", "network"]) ==
                   :ok
        end)

      assert output =~ "a.net"
      refute output =~ "b.fs"
    end

    test "scans locally-installed actions when no --index is given" do
      output =
        with_registered_actions(fn ->
          capture_io(fn ->
            assert Mix.Tasks.TinyCi.Actions.Search.run(["deploy"]) == :ok
          end)
        end)

      assert output =~ "acme.deploy"
    end
  end
end
