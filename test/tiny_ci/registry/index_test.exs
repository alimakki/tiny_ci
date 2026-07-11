defmodule TinyCI.Registry.IndexTest do
  use ExUnit.Case, async: true

  alias TinyCI.Registry.{Entry, Index}

  defp entries do
    [
      %Entry{
        package: :acme_actions,
        version: "1.2.0",
        module: Acme.Deploy,
        name: "acme.deploy",
        summary: "Ships a release to production.",
        capabilities: [:network],
        tier: :verified
      },
      %Entry{
        package: :acme_actions,
        version: "1.2.0",
        module: Acme.Notify,
        name: "acme.notify",
        summary: "Posts a Slack message.",
        capabilities: [:network],
        tier: :community
      },
      %Entry{
        package: :fs_tools,
        version: "0.3.0",
        module: FsTools.Archive,
        name: "fs_tools.archive",
        summary: "Tars up the workspace.",
        capabilities: [:filesystem_read, :filesystem_write],
        tier: :unreviewed
      }
    ]
  end

  defp index, do: Index.new(entries())

  describe "search/3" do
    test "returns all entries for a nil or empty term, sorted by name" do
      names = index() |> Index.search(nil) |> Enum.map(& &1.name)
      assert names == ["acme.deploy", "acme.notify", "fs_tools.archive"]
      assert Index.search(index(), "") == Index.search(index(), nil)
    end

    test "matches the term against name, package, module, and summary (case-insensitive)" do
      assert [%Entry{name: "acme.deploy"}] = Index.search(index(), "DEPLOY")
      assert [%Entry{name: "fs_tools.archive"}] = Index.search(index(), "tar")

      slack = Index.search(index(), "slack")
      assert [%Entry{name: "acme.notify"}] = slack
    end

    test "filters by capability" do
      results = Index.search(index(), nil, capability: :filesystem_write)
      assert [%Entry{name: "fs_tools.archive"}] = results
    end

    test "filters by tier" do
      results = Index.search(index(), nil, tier: :verified)
      assert [%Entry{name: "acme.deploy"}] = results
    end

    test "combines term and filters" do
      assert [] == Index.search(index(), "acme", tier: :unreviewed)
      assert [%Entry{name: "acme.deploy"}] = Index.search(index(), "acme", tier: :verified)
    end
  end

  describe "merge/2" do
    test "applies curated tiers from the overlay onto scanned entries" do
      scanned =
        Index.new([
          %Entry{
            package: :acme_actions,
            module: Acme.Deploy,
            name: "acme.deploy",
            tier: :unreviewed
          }
        ])

      overlay =
        Index.new([
          %Entry{
            package: :acme_actions,
            module: Acme.Deploy,
            name: "acme.deploy",
            tier: :verified
          }
        ])

      assert [%Entry{tier: :verified}] = Index.merge(scanned, overlay) |> Index.search(nil)
    end

    test "keeps live version/capabilities from the base while taking tier from the overlay" do
      base =
        Index.new([
          %Entry{
            package: :acme_actions,
            module: Acme.Deploy,
            name: "acme.deploy",
            version: "9.9.9",
            capabilities: [:network],
            tier: :unreviewed
          }
        ])

      overlay =
        Index.new([
          %Entry{
            package: :acme_actions,
            module: Acme.Deploy,
            name: "acme.deploy",
            tier: :verified
          }
        ])

      assert [entry] = Index.merge(base, overlay) |> Index.search(nil)
      assert entry.version == "9.9.9"
      assert entry.capabilities == [:network]
      assert entry.tier == :verified
    end

    test "includes overlay-only entries (curated but not locally installed)" do
      base = Index.new([])

      overlay =
        Index.new([
          %Entry{package: :remote, module: Remote.Thing, name: "remote.thing", tier: :community}
        ])

      assert [%Entry{name: "remote.thing"}] = Index.merge(base, overlay) |> Index.search(nil)
    end
  end

  describe "JSON round-trip" do
    test "to_json/1 then from_json/1 preserves entries" do
      json = Index.to_json(index())
      assert {:ok, rebuilt} = Index.from_json(json)
      assert Index.search(rebuilt, nil) == Index.search(index(), nil)
    end

    test "from_json/1 rejects invalid JSON" do
      assert {:error, _} = Index.from_json("{not json")
    end
  end
end
