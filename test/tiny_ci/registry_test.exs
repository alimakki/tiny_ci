defmodule TinyCI.RegistryTest do
  use ExUnit.Case, async: true

  alias TinyCI.Registry
  alias TinyCI.Registry.{Entry, Index}
  alias TinyCI.RegistryFixtures.{Archive, Deploy}

  @app :registry_test_fake_app

  setup do
    Application.put_env(@app, :tiny_ci_actions, [Deploy, Archive])
    on_exit(fn -> Application.delete_env(@app, :tiny_ci_actions) end)
    :ok
  end

  describe "action_modules/1" do
    test "reads declared action modules from application env" do
      assert Registry.action_modules(@app) == [Deploy, Archive]
    end

    test "returns [] for an app that declares nothing" do
      assert Registry.action_modules(:no_such_app_here) == []
    end
  end

  describe "scan/1" do
    test "builds one entry per declared action, sourced from metadata" do
      index = Registry.scan(apps: [@app])
      entries = Index.search(index, nil)

      assert Enum.map(entries, & &1.name) == ["acme.archive", "acme.deploy"]

      deploy = Enum.find(entries, &(&1.name == "acme.deploy"))
      assert %Entry{} = deploy
      assert deploy.package == @app
      assert deploy.module == Deploy
      assert deploy.capabilities == [:network, :env_read]
      assert deploy.tier == :unreviewed
      assert [%{name: :app, type: :string, required: true}] = deploy.inputs
    end

    test "uses the module's @moduledoc first line as the summary" do
      deploy = Registry.scan(apps: [@app]) |> Index.search("deploy") |> hd()
      assert deploy.summary == "Ships a release to production over SSH."
    end

    test "falls back to the declared metadata version when the app is not loaded" do
      deploy = Registry.scan(apps: [@app]) |> Index.search("deploy") |> hd()
      assert deploy.version == "2.1.0"
    end

    test "each indexed action surfaces its declared capabilities (blast radius)" do
      caps = Registry.scan(apps: [@app]) |> Index.search(nil) |> Enum.flat_map(& &1.capabilities)
      assert :network in caps
      assert :filesystem_write in caps
    end
  end

  describe "load/1 and search/2" do
    setup do
      index = Registry.scan(apps: [@app])
      path = Path.join(System.tmp_dir!(), "reg-#{System.unique_integer([:positive])}.json")
      File.write!(path, Index.to_json(index))
      on_exit(fn -> File.rm_rf(path) end)
      {:ok, path: path}
    end

    test "load/1 reads a generated JSON index", %{path: path} do
      assert {:ok, index} = Registry.load(path)
      assert [_, _] = Index.search(index, nil)
    end

    test "load/1 errors on a missing file" do
      assert {:error, _} = Registry.load("/nope/does-not-exist.json")
    end

    test "search/2 scans and filters when given no index file" do
      assert {:ok, [%Entry{name: "acme.deploy"}]} = Registry.search("deploy", apps: [@app])
    end
  end
end
