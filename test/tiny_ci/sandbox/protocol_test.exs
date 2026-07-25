defmodule TinyCI.Sandbox.ProtocolTest do
  use ExUnit.Case, async: true

  alias TinyCI.Sandbox.{Policy, Protocol}

  defp request do
    %{
      module: SomeApp.Action,
      config: %{msg: "hi", count: 3},
      context: %{branch: "main", store: %{seed: 1}},
      policy: %Policy{network: true}
    }
  end

  describe "request round-trip" do
    test "encodes and decodes a request" do
      assert {:ok, binary} = Protocol.encode_request(request())
      assert {:ok, decoded} = Protocol.decode_request(binary)
      assert decoded.module == SomeApp.Action
      assert decoded.config == %{msg: "hi", count: 3}
      assert decoded.context.branch == "main"
    end

    test "refuses to encode a request carrying a pid" do
      req = put_in(request().config[:pid], self())
      assert {:error, {:not_serializable, :pid}} = Protocol.encode_request(req)
    end

    test "refuses to encode a request carrying a function" do
      req = put_in(request().context[:fun], fn -> :x end)
      assert {:error, {:not_serializable, :function}} = Protocol.encode_request(req)
    end

    test "decode_request rejects a non-request payload" do
      assert {:error, :malformed_request} = Protocol.decode_request(:erlang.term_to_binary(%{}))
      assert {:error, :undecodable} = Protocol.decode_request(<<0, 1, 2>>)
    end
  end

  describe "response round-trip" do
    test "encodes and decodes a success delta" do
      assert {:ok, binary} = Protocol.encode_response({:ok, %{result: 42}})
      assert {:ok, %{result: 42}} = Protocol.decode_response(binary)
    end

    test "encodes and decodes an error reason" do
      assert {:ok, binary} = Protocol.encode_response({:error, :nope})
      assert {:error, :nope} = Protocol.decode_response(binary)
    end

    test "reduces a non-serializable error reason to a printable string" do
      assert {:ok, binary} = Protocol.encode_response({:error, {:boom, self()}})
      assert {:error, reason} = Protocol.decode_response(binary)
      assert is_binary(reason)
    end

    test "decode_response is safe against a malformed payload" do
      assert {:error, :malformed_response} =
               Protocol.decode_response(:erlang.term_to_binary(:weird))
    end
  end

  describe "ensure_serializable/1" do
    test "accepts plain data and rejects pids, refs, ports, and funs" do
      assert Protocol.ensure_serializable(%{a: [1, "two", {:three}]}) == :ok
      assert {:error, {:not_serializable, :pid}} = Protocol.ensure_serializable(%{p: self()})

      assert {:error, {:not_serializable, :reference}} =
               Protocol.ensure_serializable([make_ref()])

      assert {:error, {:not_serializable, :function}} =
               Protocol.ensure_serializable({fn -> :x end})
    end
  end
end
