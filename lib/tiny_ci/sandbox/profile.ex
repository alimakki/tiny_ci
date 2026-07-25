defmodule TinyCI.Sandbox.Profile do
  @moduledoc """
  Renders a `TinyCI.Sandbox.Policy` into an OS backend's confinement spec: a
  macOS Seatbelt profile (`seatbelt/2`) or Linux Bubblewrap args (`bubblewrap/2`).

  Fully denying reads is impractical for a BEAM (it must read the runtime and
  every loaded `.beam`), so v1 uses a targeted model on both platforms that is
  still enforced by the kernel and survives NIF/native bypass:

    * **network** — denied unless the action declares `:network`;
    * **filesystem writes** — denied by default; allowed only under the scratch
      directory, the system temp locations the runtime needs, and any paths the
      policy explicitly grants;
    * **explicit read denials** — any path the run marks secret is unreadable,
      even though general reads are permitted.

  Env isolation is not expressed here — the backend starts the child with a
  clean environment (`env -i` / `--clearenv`) containing only granted variables.
  """

  alias TinyCI.Sandbox.Policy

  # System locations the runtime legitimately writes to while booting/running.
  @runtime_write_paths ["/dev", "/private/var/folders", "/private/tmp", "/tmp"]

  @doc """
  Builds a Seatbelt profile string for `policy`.

  ## Options

    * `:scratch`    — the sandbox scratch dir (always writable); required
    * `:deny_read`  — paths to make unreadable (e.g. a secrets directory)
  """
  @spec seatbelt(Policy.t(), keyword()) :: String.t()
  def seatbelt(%Policy{} = policy, opts) do
    scratch = Keyword.fetch!(opts, :scratch)
    deny_read = Keyword.get(opts, :deny_read, [])
    writable = [scratch | @runtime_write_paths] ++ policy.filesystem_write

    [
      "(version 1)",
      "(allow default)",
      network_rule(policy.network),
      "(deny file-write*)",
      allow_writes(writable),
      deny_reads(deny_read)
    ]
    |> List.flatten()
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  @doc """
  Builds the `bwrap` argument list for `policy`.

  The child runs in fresh namespaces over a **read-only view of the whole
  filesystem** (`--ro-bind / /`): reads are broadly allowed (the BEAM needs the
  runtime and every `.beam`), but the only writable spots are a fresh `/tmp`,
  the scratch dir, and the policy's granted write paths. Network is an isolated
  namespace (only loopback) unless the action declares `:network`.

  ## Options

    * `:scratch`    — the sandbox scratch dir (always writable); required
    * `:deny_read`  — paths to make unreadable (masked with an empty tmpfs)
  """
  @spec bubblewrap(Policy.t(), keyword()) :: [String.t()]
  def bubblewrap(%Policy{} = policy, opts) do
    scratch = Keyword.fetch!(opts, :scratch)
    deny_read = Keyword.get(opts, :deny_read, [])
    writable = Enum.uniq([scratch | policy.filesystem_write])

    List.flatten([
      ["--ro-bind", "/", "/"],
      ["--dev", "/dev"],
      ["--proc", "/proc"],
      ["--tmpfs", "/tmp"],
      ["--unshare-pid", "--unshare-ipc", "--unshare-uts", "--unshare-cgroup-try"],
      network_args(policy.network),
      ["--die-with-parent"],
      bind_writes(writable),
      mask_reads(deny_read)
    ])
  end

  defp network_rule(true), do: ""
  defp network_rule(false), do: "(deny network*)"

  defp network_args(true), do: []
  defp network_args(false), do: ["--unshare-net"]

  # Later binds override the read-only root, making just these paths writable.
  defp bind_writes(paths) do
    for path <- paths, arg <- ["--bind", expand(path), expand(path)], do: arg
  end

  # An empty tmpfs over a path hides whatever the read-only root exposed there.
  defp mask_reads(paths) do
    for path <- paths, arg <- ["--tmpfs", expand(path)], do: arg
  end

  defp expand(path), do: Path.expand(path)

  defp allow_writes(paths) do
    paths
    |> Enum.uniq()
    |> Enum.map(&"(allow file-write* (subpath #{quote_path(&1)}))")
  end

  defp deny_reads(paths) do
    Enum.map(paths, &"(deny file-read* (subpath #{quote_path(&1)}))")
  end

  defp quote_path(path) do
    ~s("#{path |> Path.expand() |> escape()}")
  end

  defp escape(path), do: String.replace(path, "\"", "\\\"")
end
