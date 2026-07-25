defmodule TinyCI.Sandbox.Backend.Seatbelt do
  @moduledoc """
  Sandbox backend using macOS Seatbelt via `sandbox-exec`.

  It starts a fresh BEAM confined by a `TinyCI.Sandbox.Profile` generated from
  the policy, running `TinyCI.Sandbox.Runner` on a single request. The child is
  launched with `env -i` so it inherits **no** environment except a minimal
  runtime base and the env vars the policy grants — an ungranted secret is
  simply absent from the child's environment, not merely hidden.

  The kernel enforces the profile, so a NIF or `System.cmd/3` that tries to open
  a socket (network denied) or write outside the granted paths is blocked just
  as BEAM code would be — the whole point of an OS boundary.
  """

  @behaviour TinyCI.Sandbox.Backend

  alias TinyCI.Sandbox.Backend.Runtime
  alias TinyCI.Sandbox.{Policy, Profile}

  @impl TinyCI.Sandbox.Backend
  def available? do
    match?({:unix, :darwin}, :os.type()) and
      System.find_executable("sandbox-exec") != nil and
      System.find_executable("elixir") != nil
  end

  @impl TinyCI.Sandbox.Backend
  def run(request, %Policy{} = policy, opts) when is_binary(request) do
    scratch = Runtime.make_scratch()

    try do
      request_path = Path.join(scratch, "request.etf")
      response_path = Path.join(scratch, "response.etf")
      profile_path = Path.join(scratch, "policy.sb")

      File.write!(request_path, request)

      File.write!(
        profile_path,
        Profile.seatbelt(policy, scratch: scratch, deny_read: opts[:deny_read] || [])
      )

      args =
        ["-f", profile_path, "env", "-i"] ++
          env_i_pairs(policy, scratch, request_path, response_path) ++ Runtime.elixir_command()

      case System.cmd("sandbox-exec", args, stderr_to_stdout: true) do
        {_out, 0} -> Runtime.read_response(response_path)
        {out, code} -> {:error, {:sandbox_exit, code, String.trim(String.slice(out, 0, 800))}}
      end
    after
      File.rm_rf(scratch)
    end
  end

  # `env -i` takes NAME=VALUE strings; the child then inherits nothing except a
  # minimal runtime base and the env vars the policy explicitly grants.
  defp env_i_pairs(policy, scratch, request_path, response_path) do
    for {name, value} <- Runtime.env_pairs(policy, scratch, request_path, response_path),
        do: "#{name}=#{value}"
  end
end
