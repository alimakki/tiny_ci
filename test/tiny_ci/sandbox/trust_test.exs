defmodule TinyCI.Sandbox.TrustTest do
  use ExUnit.Case, async: true

  alias TinyCI.Sandbox.Trust
  alias TinyCI.SandboxFixtures.Echo

  defmodule ScriptLocal do
    @moduledoc false
    def execute(_c, _ctx), do: :ok
  end

  describe "classify/2" do
    test "a module owned by the root app is first-party" do
      assert Trust.classify(Echo, root_app: :tiny_ci) == :first_party
    end

    test "a module owned by another app is third-party" do
      assert Trust.classify(Echo, root_app: :some_other_app) == :third_party
    end

    test "an OTP/Elixir module is builtin" do
      assert Trust.classify(Enum, root_app: :tiny_ci) == :builtin
    end

    test "a module with no owning application is local" do
      assert Trust.classify(ScriptLocal, root_app: :tiny_ci) == :local
    end
  end

  describe "trusted?/2" do
    test "first-party, builtin, and local are trusted; third-party is not" do
      assert Trust.trusted?(Echo, root_app: :tiny_ci)
      assert Trust.trusted?(Enum, root_app: :tiny_ci)
      assert Trust.trusted?(ScriptLocal, root_app: :tiny_ci)
      refute Trust.trusted?(Echo, root_app: :some_other_app)
    end
  end
end
