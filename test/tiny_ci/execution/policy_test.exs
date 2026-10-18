defmodule TinyCI.Execution.PolicyTest do
  use ExUnit.Case, async: true

  doctest TinyCI.Execution.Policy

  alias TinyCI.Execution
  alias TinyCI.Execution.Policy
  alias TinyCI.Execution.Backend.{Container, Local}

  defp available, do: [available?: fn -> true end]
  defp unavailable, do: [available?: fn -> false end]

  describe "resolve/3: the D1 table" do
    test "a trusted run with no image keeps running on the host" do
      assert {:ok, %{backend: Local, image: nil}} =
               Policy.resolve(%{trust: :trusted}, nil, available())
    end

    test "a trusted run ignores the operator default image" do
      assert {:ok, %{backend: Local, image: nil}} =
               Policy.resolve(%{trust: :trusted}, nil, available() ++ [default_image: "operator"])

      assert {:ok, %{backend: Local, image: nil}} =
               Policy.resolve(
                 %{trust: :trusted},
                 nil,
                 unavailable() ++ [default_image: "operator"]
               )
    end

    test "a trusted run with an image uses the container backend" do
      assert {:ok, %{backend: Container, image: "alpine"}} =
               Policy.resolve(%{trust: :trusted}, "alpine", available())
    end

    test "a trusted run with an image fails closed when the runtime is missing" do
      assert {:error, :no_isolation_backend} =
               Policy.resolve(%{trust: :trusted}, "alpine", unavailable())
    end

    test "an untrusted run with an image uses the container backend" do
      assert {:ok, %{backend: Container, image: "alpine"}} =
               Policy.resolve(%{trust: :untrusted}, "alpine", available())
    end

    test "an untrusted run without an image uses the default image" do
      assert {:ok, %{backend: Container, image: "default"}} =
               Policy.resolve(
                 %{trust: :untrusted},
                 nil,
                 available() ++ [default_image: "default"]
               )
    end

    test "an untrusted run without an image or default fails explicitly" do
      assert {:error, :no_default_image} =
               Policy.resolve(%{trust: :untrusted}, nil, available() ++ [default_image: nil])
    end

    test "an untrusted run fails closed when the runtime is missing" do
      assert {:error, :no_isolation_backend} =
               Policy.resolve(%{trust: :untrusted}, "alpine", unavailable())
    end

    test "an untrusted run never resolves to Local" do
      inputs = [nil, "alpine", "default"]

      for image <- inputs,
          opts <- [
            available(),
            unavailable(),
            available() ++ [default_image: "default"],
            unavailable() ++ [default_image: "default"]
          ] do
        case Policy.resolve(%{trust: :untrusted}, image, opts) do
          {:ok, %{backend: backend}} -> assert backend != Local
          {:error, _} -> :ok
        end
      end
    end
  end

  describe "backend/3" do
    test "returns only the selected module" do
      assert {:ok, Local} = Policy.backend(%{trust: :trusted}, nil, available())
      assert {:ok, Container} = Policy.backend(%{trust: :untrusted}, "alpine", available())
      assert {:error, :no_default_image} = Policy.backend(%{trust: :untrusted}, nil, [])
    end
  end

  describe "Execution.resolve/2" do
    test "uses an explicit image and carries it into the decision" do
      assert {:ok, %{backend: Container, image: "alpine"}} =
               Execution.resolve(%{trust: :untrusted},
                 image: "alpine",
                 available?: fn -> true end
               )
    end

    test "uses the context image when no option is given" do
      assert {:ok, %{backend: Container, image: "from-ctx"}} =
               Execution.resolve(%{trust: :untrusted, image: "from-ctx"},
                 available?: fn -> true end
               )
    end

    test "accepts the operator default image" do
      assert {:ok, %{backend: Container, image: "operator"}} =
               Execution.resolve(%{trust: :untrusted},
                 default_image: "operator",
                 available?: fn -> true end
               )
    end

    test "an explicit non-Local backend is the test seam" do
      assert {:ok, %{backend: TinyCI.ExecutionFixtures.RecordingBackend}} =
               Execution.resolve(%{trust: :untrusted},
                 backend: TinyCI.ExecutionFixtures.RecordingBackend
               )
    end
  end

  describe "session_spec/2" do
    test "carries image, network, and limits" do
      spec =
        Execution.session_spec(
          %{
            root: "/repo",
            run_id: "run_1",
            execution_image: "alpine",
            container_limits: %{memory: "512m"}
          },
          network: false
        )

      assert spec.workspace == "/repo"
      assert spec.run_id == "run_1"
      assert spec.image == "alpine"
      assert spec.network == false
      assert spec.limits == %{memory: "512m"}
    end

    test "network defaults to true" do
      assert Execution.session_spec(%{root: "/repo"}).network == true
    end
  end
end
