defmodule TinyCI.Sandbox.PolicyTest do
  use ExUnit.Case, async: true

  alias TinyCI.Action.Metadata
  alias TinyCI.Sandbox.Policy

  defp meta(caps), do: %Metadata{name: "x", version: "1.0.0", capabilities: caps}

  test "an action with no declared capabilities is fully denied" do
    policy = Policy.from_metadata(nil, read_paths: ["/etc"], env: ["SECRET"])

    assert policy == %Policy{}
    refute policy.network
    refute policy.process_spawn
    assert policy.filesystem_read == []
    assert policy.filesystem_write == []
    assert policy.env == []
  end

  test ":network capability enables network only" do
    policy = Policy.from_metadata(meta([:network]))
    assert policy.network
    assert policy.filesystem_read == []
  end

  test ":process_spawn capability enables process spawning" do
    assert Policy.from_metadata(meta([:process_spawn])).process_spawn
  end

  test "read paths are granted only with a filesystem capability" do
    without = Policy.from_metadata(meta([]), read_paths: ["/data"])
    assert without.filesystem_read == []

    with_cap = Policy.from_metadata(meta([:filesystem_read]), read_paths: ["/data"])
    assert with_cap.filesystem_read == [Path.expand("/data")]
    assert with_cap.filesystem_write == []
  end

  test "writable paths are granted with :filesystem_write and are implicitly readable" do
    policy = Policy.from_metadata(meta([:filesystem_write]), write_paths: ["/out"])

    assert policy.filesystem_write == [Path.expand("/out")]
    assert Path.expand("/out") in policy.filesystem_read
  end

  test "env names are granted only with :env_read" do
    assert Policy.from_metadata(meta([]), env: ["TOKEN"]).env == []
    assert Policy.from_metadata(meta([:env_read]), env: ["TOKEN"]).env == ["TOKEN"]
  end
end
