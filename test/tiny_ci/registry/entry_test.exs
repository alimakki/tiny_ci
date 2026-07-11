defmodule TinyCI.Registry.EntryTest do
  use ExUnit.Case, async: true

  alias TinyCI.Registry.Entry

  defp entry do
    %Entry{
      package: :acme_actions,
      version: "1.2.0",
      module: Acme.Deploy,
      name: "acme.deploy",
      summary: "Deploys the app.",
      capabilities: [:network, :env_read],
      inputs: [%{name: :app, type: :string, required: true}],
      tier: :verified
    }
  end

  describe "to_map/1" do
    test "produces a JSON-ready map with string keys" do
      map = Entry.to_map(entry())

      assert map["package"] == "acme_actions"
      assert map["version"] == "1.2.0"
      assert map["module"] == "Acme.Deploy"
      assert map["name"] == "acme.deploy"
      assert map["summary"] == "Deploys the app."
      assert map["capabilities"] == ["network", "env_read"]
      assert map["tier"] == "verified"
      assert [%{"name" => "app", "type" => "string", "required" => true}] = map["inputs"]
    end

    test "is JSON-encodable" do
      assert {:ok, json} = Jason.encode(Entry.to_map(entry()))
      assert is_binary(json)
    end
  end

  describe "from_map/1" do
    test "round-trips through to_map/1" do
      original = entry()
      assert original |> Entry.to_map() |> Entry.from_map() == original
    end

    test "reconstructs the module atom and tier/capability atoms" do
      rebuilt = entry() |> Entry.to_map() |> Entry.from_map()

      assert rebuilt.module == Acme.Deploy
      assert rebuilt.tier == :verified
      assert rebuilt.capabilities == [:network, :env_read]
      assert [%{name: :app, type: :string, required: true}] = rebuilt.inputs
    end

    test "defaults an unknown or missing tier to :unreviewed" do
      assert Entry.from_map(%{"module" => "Acme.Deploy"}).tier == :unreviewed
      assert Entry.from_map(%{"module" => "Acme.Deploy", "tier" => "bogus"}).tier == :unreviewed
    end
  end
end
