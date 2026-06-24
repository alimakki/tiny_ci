defmodule TinyCI.Action.MetadataTest do
  use ExUnit.Case, async: true

  alias TinyCI.Action.Metadata

  doctest TinyCI.Action.Metadata

  describe "struct defaults" do
    test "inputs, outputs, and capabilities default to empty lists" do
      meta = %Metadata{}
      assert meta.name == nil
      assert meta.version == nil
      assert meta.inputs == []
      assert meta.outputs == []
      assert meta.capabilities == []
    end
  end

  describe "new/1" do
    test "builds a metadata struct from a keyword list" do
      meta =
        Metadata.new(
          name: "my_app.deploy",
          version: "1.2.0",
          inputs: [%{name: :app, type: :string, required: true}],
          capabilities: [:network]
        )

      assert %Metadata{} = meta
      assert meta.name == "my_app.deploy"
      assert meta.version == "1.2.0"
      assert meta.inputs == [%{name: :app, type: :string, required: true}]
      assert meta.capabilities == [:network]
    end

    test "accepts a map as well as a keyword list" do
      meta = Metadata.new(%{name: "x", version: "0.1.0"})
      assert meta.name == "x"
      assert meta.version == "0.1.0"
    end

    test "fills in defaults for omitted fields" do
      meta = Metadata.new(name: "x")
      assert meta.inputs == []
      assert meta.outputs == []
      assert meta.capabilities == []
    end

    test "captures declared store outputs" do
      meta = Metadata.new(name: "build", version: "1.0.0", outputs: [:image_tag, :digest])
      assert meta.outputs == [:image_tag, :digest]
    end

    test "raises when given an unknown capability" do
      assert_raise ArgumentError, ~r/unknown capabilit/i, fn ->
        Metadata.new(name: "x", capabilities: [:network, :mine_bitcoin])
      end
    end
  end

  describe "input/3" do
    test "builds an input descriptor with required defaulting to false" do
      assert Metadata.input(:app, :string) == %{name: :app, type: :string, required: false}
    end

    test "builds a required input descriptor" do
      assert Metadata.input(:token, :string, true) ==
               %{name: :token, type: :string, required: true}
    end
  end

  describe "known_capabilities/0" do
    test "includes the documented capability atoms" do
      caps = Metadata.known_capabilities()
      assert :network in caps
      assert :filesystem_write in caps
      assert :env_read in caps
    end
  end
end
