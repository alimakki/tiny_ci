defmodule TinyCI.Sandbox.RunnerTest do
  use ExUnit.Case, async: true

  alias TinyCI.Sandbox.{Protocol, Runner}
  alias TinyCI.SandboxFixtures.{Boom, Echo}

  @moduletag :tmp_dir

  defp run(module, config, context, %{tmp_dir: tmp}) do
    request = %{module: module, config: config, context: context, policy: nil}
    {:ok, encoded} = Protocol.encode_request(request)

    req = Path.join(tmp, "req.etf")
    resp = Path.join(tmp, "resp.etf")
    File.write!(req, encoded)

    assert Runner.run(req, resp) == :ok
    Protocol.decode_response(File.read!(resp))
  end

  test "runs an action and returns its store delta", ctx do
    context = %{branch: "feature-x", store: %{seed: 99}}
    assert {:ok, delta} = run(Echo, %{msg: "hello"}, context, ctx)

    assert delta.echoed == "hello"
    assert delta.branch == "feature-x"
    assert delta.seed == 99
  end

  test "catches a crashing action and returns an error", ctx do
    assert {:error, {:crashed, message}} = run(Boom, %{}, %{branch: "main", store: %{}}, ctx)
    assert message =~ "kaboom"
  end

  test "reports a missing request file as an error rather than crashing", %{tmp_dir: tmp} do
    resp = Path.join(tmp, "resp.etf")
    assert Runner.run(Path.join(tmp, "nope.etf"), resp) == :ok
    assert {:error, _reason} = Protocol.decode_response(File.read!(resp))
  end
end
