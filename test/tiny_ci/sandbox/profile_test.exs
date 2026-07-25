defmodule TinyCI.Sandbox.ProfileTest do
  use ExUnit.Case, async: true

  alias TinyCI.Sandbox.{Policy, Profile}

  test "denies network when the policy does not grant it" do
    profile = Profile.seatbelt(%Policy{network: false}, scratch: "/tmp/s")
    assert profile =~ "(deny network*)"
  end

  test "omits the network deny when the policy grants network" do
    profile = Profile.seatbelt(%Policy{network: true}, scratch: "/tmp/s")
    refute profile =~ "(deny network*)"
  end

  test "denies writes by default and allows the scratch dir plus granted writes" do
    profile =
      Profile.seatbelt(%Policy{filesystem_write: ["/data/out"]}, scratch: "/tmp/scratch")

    assert profile =~ "(deny file-write*)"
    assert profile =~ ~s[(allow file-write* (subpath "/tmp/scratch"))]
    assert profile =~ ~s[(allow file-write* (subpath "/data/out"))]
  end

  test "emits explicit read denials for secret paths" do
    profile = Profile.seatbelt(%Policy{}, scratch: "/tmp/s", deny_read: ["/secrets"])
    assert profile =~ ~s[(deny file-read* (subpath "/secrets"))]
  end
end
