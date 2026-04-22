defmodule TinyCI.MatrixTest do
  use ExUnit.Case, async: true

  alias TinyCI.Matrix

  describe "combinations/1" do
    test "returns [[]] for an empty spec" do
      assert [[]] = Matrix.combinations([])
    end

    test "returns one combination per value for a single-key spec" do
      combos = Matrix.combinations(elixir: ["1.17", "1.18"])
      assert length(combos) == 2
      assert [elixir: "1.17"] in combos
      assert [elixir: "1.18"] in combos
    end

    test "returns cartesian product for a two-key spec" do
      combos = Matrix.combinations(elixir: ["1.17", "1.18"], otp: ["26", "27"])
      assert length(combos) == 4
      assert [elixir: "1.17", otp: "26"] in combos
      assert [elixir: "1.17", otp: "27"] in combos
      assert [elixir: "1.18", otp: "26"] in combos
      assert [elixir: "1.18", otp: "27"] in combos
    end

    test "returns cartesian product for a three-key spec" do
      combos = Matrix.combinations(a: ["x", "y"], b: ["1", "2"], c: ["p", "q"])
      assert length(combos) == 8
    end

    test "preserves declaration order within each combination" do
      [[first_key | _] | _] = Matrix.combinations(elixir: ["1.17"], otp: ["26"])
      assert elem(first_key, 0) == :elixir
    end
  end

  describe "env_vars/1" do
    test "uppercases atom keys and preserves string values" do
      assert Matrix.env_vars(elixir: "1.17", otp: "26") == %{"ELIXIR" => "1.17", "OTP" => "26"}
    end

    test "returns empty map for empty combination" do
      assert Matrix.env_vars([]) == %{}
    end

    test "handles multi-word atom keys" do
      assert Matrix.env_vars(my_var: "value") == %{"MY_VAR" => "value"}
    end
  end

  describe "label/1" do
    test "formats a combination as key=value pairs joined by commas" do
      assert Matrix.label(elixir: "1.17", otp: "26") == "elixir=1.17, otp=26"
    end

    test "returns empty string for empty combination" do
      assert Matrix.label([]) == ""
    end

    test "handles a single-key combination" do
      assert Matrix.label(os: "ubuntu") == "os=ubuntu"
    end
  end
end
