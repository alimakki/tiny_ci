defmodule TinyCI.Sandbox.Policy do
  @moduledoc """
  The concrete authority granted to a sandboxed action: which env vars it may
  read, which filesystem paths it may read or write, whether it may reach the
  network, and whether it may spawn OS processes.

  A policy is the intersection of two things:

    * the capabilities the action **declares** in its `TinyCI.Action.Metadata`
      (`:network`, `:filesystem_read/write`, `:env_read`, `:process_spawn`), and
    * the concrete **grants** the run supplies (which env keys, which paths).

  It is **deny-by-default**: a grant only takes effect when the matching
  capability is declared, and an undeclared capability grants nothing no matter
  what the run offers. This is what a sandbox backend translates into an OS
  policy (a Seatbelt profile, a container config, …).
  """

  @type t :: %__MODULE__{
          network: boolean(),
          filesystem_read: [String.t()],
          filesystem_write: [String.t()],
          env: [String.t()],
          process_spawn: boolean()
        }

  defstruct network: false,
            filesystem_read: [],
            filesystem_write: [],
            env: [],
            process_spawn: false

  @doc """
  Builds a policy from an action's declared metadata and the run's grants.

  ## Grants

    * `:read_paths`  — paths the action may read (needs `:filesystem_read` or
      `:filesystem_write`)
    * `:write_paths` — paths the action may write (needs `:filesystem_write`);
      writable paths are implicitly readable
    * `:env`         — env var names the action may read (needs `:env_read`)
  """
  @spec from_metadata(TinyCI.Action.Metadata.t() | nil, keyword()) :: t()
  def from_metadata(metadata, grants \\ []) do
    caps = capabilities(metadata)

    writable = if :filesystem_write in caps, do: paths(grants[:write_paths]), else: []
    readable = if readable?(caps), do: paths(grants[:read_paths]), else: []

    %__MODULE__{
      network: :network in caps,
      process_spawn: :process_spawn in caps,
      filesystem_write: writable,
      filesystem_read: Enum.uniq(readable ++ writable),
      env: if(:env_read in caps, do: names(grants[:env]), else: [])
    }
  end

  defp readable?(caps), do: :filesystem_read in caps or :filesystem_write in caps

  defp capabilities(nil), do: []
  defp capabilities(%{capabilities: caps}) when is_list(caps), do: caps
  defp capabilities(_), do: []

  defp paths(nil), do: []
  defp paths(list) when is_list(list), do: list |> Enum.map(&Path.expand/1) |> Enum.uniq()
  defp paths(path) when is_binary(path), do: paths([path])

  defp names(nil), do: []
  defp names(list) when is_list(list), do: list |> Enum.map(&to_string/1) |> Enum.uniq()
  defp names(name), do: names([name])
end
