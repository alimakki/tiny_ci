defmodule TinyCI.Action.ResolverTest do
  use ExUnit.Case, async: true

  alias TinyCI.Action.Resolver
  alias TinyCI.{Hook, PipelineSpec, Stage, Step}

  @locks %{
    good_action: %{scm: :hex, version: "1.2.0", checksum: "sum1", repo: "hexpm"},
    git_action: %{scm: :git, version: "abc", checksum: nil, repo: "https://x/y.git"}
  }

  defp ref(module, app, version), do: %{module: module, app: app, version: version}

  describe "references/1" do
    test "collects distinct module atoms from steps and hooks" do
      spec = %PipelineSpec{
        name: :p,
        stages: [
          %Stage{name: :a, steps: [%Step{name: :s, module: ModA}, %Step{name: :t, cmd: "x"}]},
          %Stage{name: :b, steps: [%Step{name: :u, module: ModB}]}
        ],
        hooks: %{on_success: [%Hook{name: :h, module: ModA}], on_failure: []}
      }

      assert Resolver.references(spec) |> Enum.sort() == Enum.sort([ModA, ModB])
    end

    test "ignores shell steps and hooks with no module" do
      spec = %PipelineSpec{
        name: :p,
        stages: [%Stage{name: :a, steps: [%Step{name: :s, cmd: "echo"}]}],
        hooks: %{on_success: [%Hook{name: :h, cmd: "echo"}], on_failure: []}
      }

      assert Resolver.references(spec) == []
    end
  end

  describe "resolve/3 classification" do
    test "a locked hex action with a matching version is :ok" do
      [entry] = Resolver.resolve([ref(Good, :good_action, "1.2.0")], @locks, root_app: :myapp)
      assert %{source: :hex, status: :ok, version: "1.2.0", checksum: "sum1"} = entry
    end

    test "a locked hex action with a mismatched version is an error" do
      [entry] = Resolver.resolve([ref(Good, :good_action, "1.3.0")], @locks, root_app: :myapp)
      assert entry.status == :error
      assert entry.message =~ "1.3.0"
      assert entry.message =~ "1.2.0"
      assert entry.message =~ "lockfile" or entry.message =~ "mix deps.get"
    end

    test "a git dependency is allowed but flagged as unpinned" do
      [entry] = Resolver.resolve([ref(G, :git_action, "abc")], @locks, root_app: :myapp)
      assert entry.source == :git
      assert entry.status == :ok
    end

    test "the root application is first-party" do
      [entry] = Resolver.resolve([ref(My.Step, :myapp, "0.1.0")], @locks, root_app: :myapp)
      assert entry.source == :first_party
      assert entry.status == :ok
    end

    test "a module with no owning app is local" do
      [entry] = Resolver.resolve([ref(InlineMod, nil, nil)], @locks, root_app: :myapp)
      assert entry.source == :local
      assert entry.status == :ok
    end

    test "an OTP/Elixir builtin app is not flagged" do
      [entry] = Resolver.resolve([ref(Some, :elixir, "1.20.0")], @locks, root_app: :myapp)
      assert entry.source == :builtin
      assert entry.status == :ok
    end

    test "a loaded third-party action absent from the lock fails closed" do
      [entry] = Resolver.resolve([ref(Sneaky, :not_locked, "9.9.9")], @locks, root_app: :myapp)
      assert entry.source == :unlocked
      assert entry.status == :error
      assert entry.message =~ ":not_locked"
      assert entry.message =~ "lockfile" or entry.message =~ "pinned"
    end
  end

  describe "verify/3" do
    test "returns :ok when every action resolves cleanly" do
      refs = [ref(Good, :good_action, "1.2.0"), ref(My.Step, :myapp, "0.1.0")]
      assert Resolver.verify(refs, @locks, root_app: :myapp) == :ok
    end

    test "returns the collected problems when an action is unlocked or drifted" do
      refs = [
        ref(Sneaky, :not_locked, "9.9.9"),
        ref(Good, :good_action, "1.3.0")
      ]

      assert {:error, {:action_lock, messages}} =
               Resolver.verify(refs, @locks, root_app: :myapp)

      assert length(messages) == 2
      assert Enum.any?(messages, &(&1 =~ ":not_locked"))
      assert Enum.any?(messages, &(&1 =~ "1.2.0"))
    end

    test "empty references verify trivially" do
      assert Resolver.verify([], @locks, root_app: :myapp) == :ok
    end
  end
end
