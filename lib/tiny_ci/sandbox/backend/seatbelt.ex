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

  alias TinyCI.Sandbox.{Policy, Profile}

  @request_env "TINY_CI_SANDBOX_REQUEST"
  @response_env "TINY_CI_SANDBOX_RESPONSE"

  @impl TinyCI.Sandbox.Backend
  def available? do
    match?({:unix, :darwin}, :os.type()) and
      System.find_executable("sandbox-exec") != nil and
      System.find_executable("elixir") != nil
  end

  @impl TinyCI.Sandbox.Backend
  def run(request, %Policy{} = policy, opts) when is_binary(request) do
    scratch = make_scratch()

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
          env_pairs(policy, scratch, request_path, response_path) ++ elixir_command()

      case System.cmd("sandbox-exec", args, stderr_to_stdout: true) do
        {_out, 0} -> read_response(response_path)
        {out, code} -> {:error, {:sandbox_exit, code, String.trim(String.slice(out, 0, 800))}}
      end
    after
      File.rm_rf(scratch)
    end
  end

  defp read_response(path) do
    case File.read(path) do
      {:ok, binary} -> {:ok, binary}
      {:error, reason} -> {:error, {:no_response, reason}}
    end
  end

  # The child inherits nothing (env -i) except a minimal runtime base, the
  # request/response paths, and the env vars the policy explicitly grants.
  defp env_pairs(policy, scratch, request_path, response_path) do
    granted = for name <- policy.env, value = System.get_env(name), do: {name, value}

    base = [
      {"PATH", runtime_path()},
      {"HOME", scratch},
      {@request_env, request_path},
      {@response_env, response_path}
    ]

    for {name, value} <- base ++ granted, do: "#{name}=#{value}"
  end

  defp elixir_command do
    code_paths = for dir <- :code.get_path(), do: ["-pa", List.to_string(dir)]

    [System.find_executable("elixir")] ++
      List.flatten(code_paths) ++ ["-e", "TinyCI.Sandbox.Runner.cli()"]
  end

  # env -i clears PATH, so the child needs enough of one to find both `elixir`
  # and the `erl` it execs (Erlang may live in a separate install dir).
  defp runtime_path do
    elixir_dir = System.find_executable("elixir") |> Path.dirname()
    erl_dir = Path.join(List.to_string(:code.root_dir()), "bin")

    [elixir_dir, erl_dir, "/usr/bin", "/bin"]
    |> Enum.uniq()
    |> Enum.join(":")
  end

  defp make_scratch do
    dir = Path.join(System.tmp_dir!(), "tiny_ci_sandbox_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end
end
