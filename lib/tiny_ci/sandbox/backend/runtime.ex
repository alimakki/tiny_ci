defmodule TinyCI.Sandbox.Backend.Runtime do
  @moduledoc """
  Helpers shared by the OS backends that confine an action by spawning a fresh
  BEAM running `TinyCI.Sandbox.Runner`.

  Every backend does the same three portable things and differs only in *how* it
  wraps the child (a Seatbelt profile, `bwrap` args, a container spec, …):

    * builds the child's environment — a clean base plus the vars the policy
      grants, and the request/response file paths the runner reads and writes;
    * builds the `elixir` command that boots the runner with the parent's code
      path so it can load the action's `.beam` files;
    * manages the scratch directory the request/response cross through.

  Keeping this here means both `TinyCI.Sandbox.Backend.Seatbelt` and
  `TinyCI.Sandbox.Backend.Bubblewrap` produce an identically configured child.
  """

  alias TinyCI.Sandbox.Policy

  # Must match the names `TinyCI.Sandbox.Runner` reads inside the child.
  @request_env "TINY_CI_SANDBOX_REQUEST"
  @response_env "TINY_CI_SANDBOX_RESPONSE"

  @doc """
  The `{name, value}` env pairs the child should run with.

  The child inherits nothing on its own (backends start it with a cleared
  environment); this base plus the policy-granted vars is *all* it sees. An
  ungranted secret is simply absent, not merely hidden.
  """
  @spec env_pairs(Policy.t(), Path.t(), Path.t(), Path.t()) :: [{String.t(), String.t()}]
  def env_pairs(%Policy{} = policy, scratch, request_path, response_path) do
    granted = for name <- policy.env, value = System.get_env(name), do: {name, value}

    [
      {"PATH", runtime_path()},
      {"HOME", scratch},
      {@request_env, request_path},
      {@response_env, response_path}
    ] ++ granted
  end

  @doc "The `elixir` argv that boots the runner with the parent's code path."
  @spec elixir_command() :: [String.t()]
  def elixir_command do
    code_paths = for dir <- :code.get_path(), do: ["-pa", List.to_string(dir)]

    [System.find_executable("elixir")] ++
      List.flatten(code_paths) ++ ["-e", "TinyCI.Sandbox.Runner.cli()"]
  end

  @doc """
  A minimal `PATH` for the confined child.

  A cleared environment drops `PATH`, so the child needs enough of one to find
  both `elixir` and the `erl` it execs (Erlang may live in a separate install
  dir than Elixir).
  """
  @spec runtime_path() :: String.t()
  def runtime_path do
    elixir_dir = System.find_executable("elixir") |> Path.dirname()
    erl_dir = Path.join(List.to_string(:code.root_dir()), "bin")

    [elixir_dir, erl_dir, "/usr/bin", "/bin"]
    |> Enum.uniq()
    |> Enum.join(":")
  end

  @doc "Creates and returns a fresh scratch directory the request/response cross through."
  @spec make_scratch() :: Path.t()
  def make_scratch do
    dir = Path.join(System.tmp_dir!(), "tiny_ci_sandbox_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  @doc "Reads the encoded response the child wrote, or an error if it produced none."
  @spec read_response(Path.t()) :: {:ok, binary()} | {:error, term()}
  def read_response(path) do
    case File.read(path) do
      {:ok, binary} -> {:ok, binary}
      {:error, reason} -> {:error, {:no_response, reason}}
    end
  end
end
