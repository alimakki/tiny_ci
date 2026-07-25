defmodule TinyCI.Sandbox.Backend do
  @moduledoc """
  The behaviour an OS sandbox mechanism implements.

  A backend takes an encoded request (see `TinyCI.Sandbox.Protocol`) and a
  `TinyCI.Sandbox.Policy`, runs the action inside an isolated OS environment that
  enforces the policy, and returns the encoded response bytes. The backend is the
  only part of the sandbox that is OS-specific; everything above it (driver,
  policy, protocol, redaction) is portable.

  `TinyCI.Sandbox.Backend.Seatbelt` (macOS Seatbelt via `sandbox-exec`) and
  `TinyCI.Sandbox.Backend.Bubblewrap` (Linux namespaces via `bwrap`) are the two
  reference backends; an OCI-container backend for CI fits the same contract.
  """

  alias TinyCI.Sandbox.Policy

  # Tried in order; the first one available on the host is the default. Seatbelt
  # and Bubblewrap are mutually exclusive by OS, so order only matters if a host
  # somehow satisfies both.
  @backends [
    TinyCI.Sandbox.Backend.Seatbelt,
    TinyCI.Sandbox.Backend.Bubblewrap
  ]

  @doc "Whether this backend can run on the current host."
  @callback available?() :: boolean()

  @doc "Runs an encoded request under `policy`, returning the encoded response."
  @callback run(request :: binary(), policy :: Policy.t(), opts :: keyword()) ::
              {:ok, binary()} | {:error, term()}

  @doc "The sandbox backend to use on this host, or `nil` if none is available."
  @spec default() :: module() | nil
  def default, do: Enum.find(@backends, & &1.available?())
end
