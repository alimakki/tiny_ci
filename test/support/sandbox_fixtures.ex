defmodule TinyCI.SandboxFixtures do
  @moduledoc """
  Compiled action modules for the sandbox tests. They are compiled to disk (in
  the test build) so the child BEAM the Seatbelt backend spawns can load them
  from the parent's code path.
  """

  defmodule Echo do
    @moduledoc "Echoes its config and some context back into the store."
    use TinyCI.Action

    @impl true
    def execute(config, ctx) do
      {:ok,
       %{
         echoed: config[:msg],
         branch: ctx.branch,
         seed: Map.get(ctx.store, :seed)
       }}
    end

    @impl true
    def metadata, do: %TinyCI.Action.Metadata{name: "fixture.echo", version: "1.0.0"}
  end

  defmodule Boom do
    @moduledoc "Raises, to exercise crash handling at the boundary."
    use TinyCI.Action

    @impl true
    def execute(_config, _ctx), do: raise("kaboom")

    @impl true
    def metadata, do: %TinyCI.Action.Metadata{name: "fixture.boom", version: "1.0.0"}
  end

  defmodule TcpProbe do
    @moduledoc "Attempts an outbound TCP connection (no network capability declared)."
    use TinyCI.Action

    @impl true
    def execute(config, _ctx), do: {:ok, %{connect: TinyCI.SandboxFixtures.tcp_connect(config)}}

    @impl true
    def metadata, do: %TinyCI.Action.Metadata{name: "fixture.tcp_probe", version: "1.0.0"}
  end

  defmodule TcpProbeAllowed do
    @moduledoc "Attempts an outbound TCP connection with the :network capability."
    use TinyCI.Action

    @impl true
    def execute(config, _ctx), do: {:ok, %{connect: TinyCI.SandboxFixtures.tcp_connect(config)}}

    @impl true
    def metadata do
      %TinyCI.Action.Metadata{
        name: "fixture.tcp_probe_net",
        version: "1.0.0",
        capabilities: [:network]
      }
    end
  end

  defmodule WriteProbe do
    @moduledoc "Attempts to write a file (no filesystem_write capability declared)."
    use TinyCI.Action

    @impl true
    def execute(config, _ctx), do: {:ok, %{write: TinyCI.SandboxFixtures.write(config)}}

    @impl true
    def metadata, do: %TinyCI.Action.Metadata{name: "fixture.write_probe", version: "1.0.0"}
  end

  defmodule WriteProbeAllowed do
    @moduledoc "Attempts to write a file with the :filesystem_write capability."
    use TinyCI.Action

    @impl true
    def execute(config, _ctx), do: {:ok, %{write: TinyCI.SandboxFixtures.write(config)}}

    @impl true
    def metadata do
      %TinyCI.Action.Metadata{
        name: "fixture.write_probe_fs",
        version: "1.0.0",
        capabilities: [:filesystem_write]
      }
    end
  end

  defmodule EnvProbe do
    @moduledoc "Reports which env vars are visible inside the sandbox."
    use TinyCI.Action

    @impl true
    def execute(config, _ctx) do
      {:ok, %{seen: Map.new(config[:vars] || [], &{&1, System.get_env(&1)})}}
    end

    @impl true
    def metadata do
      %TinyCI.Action.Metadata{
        name: "fixture.env_probe",
        version: "1.0.0",
        capabilities: [:env_read]
      }
    end
  end

  defmodule NativeEscape do
    @moduledoc """
    A native escape attempt: shells out to `/usr/bin/touch` (a native binary, not
    BEAM code) to create a file outside any granted path. Seatbelt confines a
    sandboxed process *and all its descendants*, so the write must be blocked —
    proving isolation is enforced by the OS, not the BEAM.
    """
    use TinyCI.Action

    @impl true
    def execute(config, _ctx) do
      {output, status} = System.cmd("/usr/bin/touch", [config[:path]], stderr_to_stdout: true)
      {:ok, %{exit: status, output: String.slice(output, 0, 200)}}
    rescue
      e -> {:ok, %{error: Exception.message(e)}}
    end

    @impl true
    def metadata, do: %TinyCI.Action.Metadata{name: "fixture.native_escape", version: "1.0.0"}
  end

  @doc false
  def tcp_connect(config) do
    host = String.to_charlist(config[:host] || "127.0.0.1")

    case :gen_tcp.connect(host, config[:port], [:binary, active: false], 2000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        "ok"

      {:error, reason} ->
        "error:#{inspect(reason)}"
    end
  end

  @doc false
  def write(config) do
    case File.write(config[:path], "written by sandbox\n") do
      :ok -> "ok"
      {:error, reason} -> "error:#{inspect(reason)}"
    end
  end
end
