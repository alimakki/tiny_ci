defmodule TinyCiTest do
  use ExUnit.Case
  doctest TinyCi

  test "greets the world" do
    assert TinyCi.hello() == :world
  end
end
