defmodule TinyCI.Sandbox.Backend do
  @moduledoc """
  The behaviour an OS sandbox mechanism implements.

  A backend takes an encoded request (see `TinyCI.Sandbox.Protocol`) and a
  `TinyCI.Sandbox.Policy`, runs the action inside an isolated OS environment that
  enforces the policy, and returns the encoded response bytes. The backend is the
  only part of the sandbox that is OS-specific; everything above it (driver,
  policy, protocol, redaction) is portable.

  `TinyCI.Sandbox.Backend.Seatbelt` is the reference backend (macOS Seatbelt via
  `sandbox-exec`); an OCI-container backend for Linux/CI fits the same contract.
  """

  alias TinyCI.Sandbox.Policy

  @doc "Whether this backend can run on the current host."
  @callback available?() :: boolean()

  @doc "Runs an encoded request under `policy`, returning the encoded response."
  @callback run(request :: binary(), policy :: Policy.t(), opts :: keyword()) ::
              {:ok, binary()} | {:error, term()}
end
