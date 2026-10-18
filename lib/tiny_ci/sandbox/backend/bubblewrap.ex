defmodule TinyCI.Sandbox.Backend.Bubblewrap do
  @moduledoc """
  Sandbox backend for Linux using Bubblewrap (`bwrap`).

  It is the Linux counterpart of `TinyCI.Sandbox.Backend.Seatbelt`: it starts a
  fresh BEAM confined by a mount/PID/network namespace derived from the policy
  (see `TinyCI.Sandbox.Profile.bubblewrap/2`), running `TinyCI.Sandbox.Runner`
  on a single request. `bwrap` needs no root — it relies on unprivileged user
  namespaces, so it runs the same in a developer shell and in CI.

  The child is launched with `--clearenv`, so it inherits **no** environment
  except a minimal runtime base and the env vars the policy grants — an
  ungranted secret is simply absent from the child's environment, not merely
  hidden. The kernel enforces the namespaces, so a NIF or `System.cmd/3` that
  tries to open a socket (network denied) or write outside the granted paths is
  blocked just as BEAM code would be — the whole point of an OS boundary.
  """

  @behaviour TinyCI.Sandbox.Backend

  alias TinyCI.Execution
  alias TinyCI.Execution.{Backend.Local, Command, SessionSpec}
  alias TinyCI.Sandbox.Backend.Runtime
  alias TinyCI.Sandbox.{Policy, Profile}

  @impl TinyCI.Sandbox.Backend
  def available? do
    match?({:unix, :linux}, :os.type()) and
      System.find_executable("bwrap") != nil and
      System.find_executable("elixir") != nil
  end

  @impl TinyCI.Sandbox.Backend
  def run(request, %Policy{} = policy, opts) when is_binary(request) do
    scratch = Runtime.make_scratch()

    try do
      request_path = Path.join(scratch, "request.etf")
      response_path = Path.join(scratch, "response.etf")

      File.write!(request_path, request)

      args =
        Profile.bubblewrap(policy, scratch: scratch, deny_read: opts[:deny_read] || []) ++
          env_args(policy, scratch, request_path, response_path) ++
          ["--"] ++ Runtime.elixir_command()

      case run_bwrap(args, opts) do
        {:passed, _out} -> Runtime.read_response(response_path)
        {:timeout, _out} -> {:error, :timeout}
        {:failed, out} -> {:error, {:sandbox_exit, :failed, trim(out)}}
      end
    after
      File.rm_rf(scratch)
    end
  end

  # Sandboxed actions only run in trusted local runs, so this bypasses backend
  # policy and goes straight to the host backend. The bwrap argv is already
  # assembled, so the command is literal.
  defp run_bwrap(args, opts) do
    command = %Command{run: {:argv, "bwrap", args}, timeout: opts[:timeout]}

    Execution.with_session(
      %SessionSpec{workspace: File.cwd!(), run_id: opts[:run_id]},
      fn session -> Execution.exec(session, command, fn _line -> :ok end) end,
      backend: Local
    )
  end

  defp trim(output), do: String.trim(String.slice(output, 0, 800))

  # bwrap expresses env inline: clear everything, then set each granted var.
  # LANG keeps the confined BEAM on a UTF-8 locale (a cleared env has none).
  defp env_args(policy, scratch, request_path, response_path) do
    pairs = [
      {"LANG", "C.UTF-8"}
      | Runtime.env_pairs(policy, scratch, request_path, response_path)
    ]

    ["--clearenv"] ++ Enum.flat_map(pairs, fn {name, value} -> ["--setenv", name, value] end)
  end
end
