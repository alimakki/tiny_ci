defmodule TinyCI.Environment.ImageTest do
  @moduledoc """
  Image resolution: inspect to an ID, pull only a missing tag, keep a declared
  digest, and never pull in a dry run. The runtime is injected, so no Docker or
  Podman is required.
  """

  use ExUnit.Case, async: true

  doctest TinyCI.Environment.Image

  alias TinyCI.Environment.Image

  @runtime %{command: "podman", kind: :podman, rootless: true}
  @id "sha256:" <> String.duplicate("b", 64)
  @declared "sha256:" <> String.duplicate("c", 64)

  defp resolve(ref, opts \\ []) do
    Image.resolve(ref, Keyword.merge([runtime: @runtime, run: runner()], opts))
  end

  # Responses are read from the test process dictionary so each test can arrange
  # inspect/pull outcomes without a mock library. Every call is recorded.
  defp runner do
    fn args ->
      Process.put(:calls, [args | Process.get(:calls, [])])

      case args do
        ["image", "inspect" | _] -> Process.get(:inspect, {"", 1})
        ["pull" | _] -> Process.get(:pull, {"", 0})
      end
    end
  end

  defp calls, do: Enum.reverse(Process.get(:calls, []))

  describe "resolve/2" do
    test "inspects a tag and returns the local image ID as the identity" do
      Process.put(:inspect, {@id <> "\n", 0})

      assert {:ok, %{digest: @id, run_ref: @id}} = resolve("alpine:3.22")

      assert calls() == [["image", "inspect", "--format", "{{.Id}}", "alpine:3.22"]]
    end

    test "pulls a missing tag once and inspects it again" do
      Process.put(:inspect, {"", 1})
      Process.put(:pull, {"", 0})

      # The second inspect is the interesting one; the first reports missing.
      parent = self()

      run = fn args ->
        send(parent, {:call, args})

        case args do
          ["image", "inspect" | _] ->
            if Process.get(:inspected, false) do
              {@id <> "\n", 0}
            else
              Process.put(:inspected, true)
              {"", 1}
            end

          ["pull" | _] ->
            {"", 0}
        end
      end

      assert {:ok, %{digest: @id, run_ref: @id}} =
               Image.resolve("alpine:3.22", runtime: @runtime, run: run)

      assert_received {:call, ["image", "inspect", "--format", "{{.Id}}", "alpine:3.22"]}
      assert_received {:call, ["pull", "alpine:3.22"]}
      assert_received {:call, ["image", "inspect", "--format", "{{.Id}}", "alpine:3.22"]}
      refute_received {:call, _}
    end

    test "reports a pull failure" do
      Process.put(:inspect, {"", 1})
      Process.put(:pull, {"manifest unknown", 125})

      assert {:error, {:image_unavailable, "alpine:3.22", 125, "manifest unknown"}} =
               resolve("alpine:3.22")
    end

    test "pull: false never pulls and leaves the digest unresolved" do
      Process.put(:inspect, {"", 1})

      assert {:ok, %{digest: nil, run_ref: "alpine:3.22"}} =
               resolve("alpine:3.22", pull: false)

      refute Enum.any?(calls(), fn [command | _] -> command == "pull" end)
    end

    test "a declared digest is the identity and the local ID is the run reference" do
      Process.put(:inspect, {@id <> "\n", 0})

      assert {:ok, %{digest: @declared, run_ref: @id}} =
               resolve("registry.example/acme/ci@#{@declared}")
    end

    test "a declared digest still resolves without a local image when pull: false" do
      Process.put(:inspect, {"", 1})

      assert {:ok, %{digest: @declared, run_ref: "registry.example/acme/ci@#{@declared}"}} =
               resolve("registry.example/acme/ci@#{@declared}", pull: false)
    end

    test "a malformed @sha256 suffix is not treated as a declared digest" do
      Process.put(:inspect, {@id <> "\n", 0})

      assert {:ok, %{digest: @id, run_ref: @id}} =
               resolve("registry.example/acme/ci@sha256:short")
    end
  end

  describe "validate_ref/1" do
    test "accepts registry references" do
      for ref <- [
            "alpine",
            "alpine:3.22",
            "ghcr.io/acme/ci:24.04",
            "registry.example:5000/acme/ci@sha256:" <> String.duplicate("a", 64)
          ] do
        assert Image.validate_ref(ref) == :ok
      end
    end

    test "rejects a leading dash so a ref cannot become a runtime flag" do
      assert Image.validate_ref("--privileged") == {:error, {:invalid_image, "--privileged"}}
    end

    test "rejects whitespace and control characters" do
      for ref <- ["alpine 3.22", "alpine\t3.22", "alpine\n3.22", "alpine\r3.22"] do
        assert {:error, {:invalid_image, ^ref}} = Image.validate_ref(ref)
      end
    end

    test "rejects an empty reference and non-strings" do
      assert Image.validate_ref("") == {:error, {:invalid_image, ""}}
      assert Image.validate_ref(nil) == {:error, {:invalid_image, nil}}
    end

    test "an invalid reference never reaches the runtime" do
      assert {:error, {:invalid_image, "--privileged"}} = resolve("--privileged")
      assert calls() == []
    end
  end
end
