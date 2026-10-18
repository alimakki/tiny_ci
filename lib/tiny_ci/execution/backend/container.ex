defmodule TinyCI.Execution.Backend.Container do
  @moduledoc """
  Container execution backend.

  One session is one long-lived container (`run -d --init`) with a keepalive;
  every step is a `docker exec`/`podman exec` into it. Steps in a stage therefore
  share `$HOME`, installed tools, and the container filesystem, while nothing
  outside the workspace is mounted from the host.

  The workspace is bind-mounted read-write at `/workspace`, and the container
  runs as the invoking host uid/gid so files the steps write stay owned by the
  user. The host environment is not passed through: each exec receives only the
  variables on its `TinyCI.Execution.Command`.

  Each step runs in its own process group inside the container (via `setsid`),
  recording the group id so a timeout can kill the step and its descendants
  without touching sibling steps in the same session.

  The image must provide a POSIX `sh`, `setsid`, and `sleep`; `open/1` probes
  for them and fails closed with a clear error when they are missing.
  """

  @behaviour TinyCI.Execution.Backend

  alias TinyCI.Execution.{Command, SessionSpec}

  @container_workdir "/workspace"
  @home "/tmp/tiny_ci/home"
  @pgid_dir "/tmp/tiny_ci/pgid"

  @keepalive "while :; do sleep 3600; done"

  @wrapper """
  while IFS= read -r line; do
    key=${line%%=*}
    val=${line#*=}
    decoded=$(printf '%bX' "$val")
    decoded=${decoded%X}
    export "$key=$decoded"
  done < "$TINY_CI_ENV_FILE"
  printf '%s' "$$" > "$TINY_CI_PGID_FILE"
  exec sh -c "$TINY_CI_STEP_CMD"
  """

  @launch "setsid sh -c \"$TINY_CI_WRAPPER\"; status=$?; exit $status"

  @impl true
  def name, do: :container

  @impl true
  def available? do
    match?({:ok, _runtime}, runtime())
  end

  @doc """
  Resolves the configured container runtime.

  `:auto` tries Docker, then Podman. A configured runtime is used only if its
  executable exists and answers `version`.
  """
  @spec runtime() ::
          {:ok, %{command: String.t(), kind: :docker | :podman, rootless: boolean()}}
          | {:error, term()}
  def runtime do
    case Application.get_env(:tiny_ci, :container_runtime, :auto) do
      :auto -> find_runtime(["docker", "podman"])
      :docker -> probe_runtime("docker", :docker)
      :podman -> probe_runtime("podman", :podman)
      other -> {:error, {:invalid_container_runtime, other}}
    end
  end

  @impl true
  def open(%SessionSpec{} = spec) do
    with {:ok, runtime} <- runtime(),
         {:ok, image} <- image(spec),
         :ok <- ensure_workspace(spec) do
      session_tag = "s_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      session_run_id = spec.run_id || "none"

      try do
        with {:ok, id} <- start(runtime, spec, image, session_tag),
             :ok <- prepare(runtime, id),
             {:ok, host_tmp_dir} <- make_host_tmp_dir() do
          {:ok,
           %{
             id: id,
             runtime: runtime,
             workspace: Path.expand(spec.workspace),
             run_id: spec.run_id,
             session_tag: session_tag,
             host_tmp_dir: host_tmp_dir
           }}
        else
          {:error, reason} ->
            cleanup_label(runtime, session_run_id, session_tag)
            {:error, reason}
        end
      rescue
        e ->
          cleanup_label(runtime, session_run_id, session_tag)
          {:error, {:container_session_failed, Exception.message(e)}}
      end
    end
  end

  @impl true
  def exec(session, %Command{} = command, on_line) when is_function(on_line, 1) do
    with {:ok, workdir} <- container_workdir(session.workspace, command.working_dir),
         :ok <- ensure_workdir(session, workdir, command.working_dir) do
      run_command(session, command, workdir, on_line)
    else
      {:error, message} -> {:failed, message}
    end
  end

  @impl true
  def close(%{runtime: runtime, id: id} = session) do
    remove(runtime, id)

    case Map.get(session, :host_tmp_dir) do
      nil -> :ok
      dir -> File.rm_rf(dir)
    end

    :ok
  end

  def close(_session), do: :ok

  # ---------------------------------------------------------------------------
  # Runtime discovery
  # ---------------------------------------------------------------------------

  defp find_runtime(commands) do
    Enum.find_value(commands, {:error, :no_isolation_backend}, fn command ->
      case probe_runtime(command, String.to_atom(command)) do
        {:ok, runtime} -> {:ok, runtime}
        {:error, _} -> nil
      end
    end)
  end

  defp probe_runtime(command, kind) do
    case System.find_executable(command) do
      nil ->
        {:error, :no_isolation_backend}

      executable ->
        case System.cmd(executable, ["version"], stderr_to_stdout: true) do
          {_out, 0} ->
            {:ok, %{command: executable, kind: kind, rootless: rootless?(executable, kind)}}

          {_out, _status} ->
            {:error, :no_isolation_backend}
        end
    end
  rescue
    ErlangError -> {:error, :no_isolation_backend}
  end

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  defp image(%SessionSpec{image: image}) do
    if is_binary(image) and image != "",
      do: {:ok, image},
      else: {:error, :no_default_image}
  end

  defp ensure_workspace(%SessionSpec{workspace: workspace}) do
    if File.dir?(workspace),
      do: :ok,
      else: {:error, {:workspace_missing, workspace}}
  end

  defp start(runtime, spec, image, session_tag) do
    workspace = Path.expand(spec.workspace)
    run_id = spec.run_id || "none"

    args =
      ["run", "-d", "--init"] ++
        label_args(run_id, session_tag) ++
        user_args(runtime) ++
        [
          "-e",
          "HOME=#{@home}",
          "-v",
          mount_arg(runtime, workspace),
          "-w",
          @container_workdir
        ] ++
        git_args(runtime, workspace) ++
        network_args(spec.network) ++
        limit_args(spec.limits) ++
        ["--entrypoint", "sh", image, "-c", @keepalive]

    with :ok <- ensure_image(runtime, image) do
      launch(runtime, args)
    end
  end

  defp launch(runtime, args) do
    case System.cmd(runtime.command, args, stderr_to_stdout: true) do
      {output, 0} -> started(runtime, output)
      {output, status} -> {:error, {:container_start_failed, status, String.trim(output)}}
    end
  end

  defp started(runtime, output) do
    case container_id(output) do
      {:ok, id} -> ensure_running(runtime, id)
      :error -> {:error, {:container_start_failed, String.trim(output)}}
    end
  end

  defp ensure_running(runtime, id) do
    if running?(runtime, id) do
      {:ok, id}
    else
      logs = container_logs(runtime, id)
      remove(runtime, id)
      {:error, {:container_start_failed, logs}}
    end
  end

  defp label_args(run_id, session_tag) do
    [
      "--label",
      "tiny_ci.run_id=#{run_id}",
      "--label",
      "tiny_ci.session=#{session_tag}"
    ]
  end

  defp container_id(output) do
    output
    |> String.split("\n", trim: true)
    |> List.last()
    |> case do
      nil ->
        :error

      candidate ->
        candidate = String.trim(candidate)

        if Regex.match?(~r/^[0-9a-f]{12,64}$/, candidate),
          do: {:ok, candidate},
          else: :error
    end
  end

  defp ensure_image(runtime, image) do
    case System.cmd(runtime.command, ["image", "inspect", image], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {_output, _status} ->
        case System.cmd(runtime.command, ["pull", image], stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {output, status} -> {:error, {:image_unavailable, image, status, String.trim(output)}}
        end
    end
  end

  defp git_args(runtime, workspace) do
    git = Path.join(workspace, ".git")
    label = if runtime.kind == :podman, do: ",Z", else: ""

    case File.lstat(git) do
      {:ok, %{type: type}} when type in [:directory, :regular] ->
        ["-v", "#{git}:#{@container_workdir}/.git:ro#{label}"]

      _ ->
        []
    end
  end

  defp make_host_tmp_dir do
    name = "tiny_ci_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    dir = Path.join(System.tmp_dir!(), name)

    case File.mkdir(dir) do
      :ok ->
        File.chmod!(dir, 0o700)
        {:ok, dir}

      {:error, reason} ->
        {:error, {:host_tmp_dir_failed, reason}}
    end
  end

  defp cleanup_label(runtime, run_id, session_tag) do
    args = [
      "ps",
      "-aq",
      "--filter",
      "label=tiny_ci.run_id=#{run_id}",
      "--filter",
      "label=tiny_ci.session=#{session_tag}"
    ]

    case System.cmd(runtime.command, args, stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.each(fn id -> remove(runtime, id) end)

      _ ->
        :ok
    end
  rescue
    ErlangError -> :ok
  end

  defp rootless?(executable, :podman) do
    case System.cmd(executable, ["info", "--format", "{{.Host.Security.Rootless}}"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.trim(output) == "true"
      _ -> false
    end
  end

  defp rootless?(executable, :docker) do
    case System.cmd(executable, ["info", "--format", "{{json .SecurityOptions}}"],
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.contains?(output, "rootless")
      _ -> false
    end
  end

  defp user_args(%{kind: :podman, rootless: true}), do: ["--userns=keep-id"]
  defp user_args(%{kind: :docker, rootless: true}), do: []

  defp user_args(_runtime) do
    case {id_flag("-u"), id_flag("-g")} do
      {uid, gid} when is_binary(uid) and is_binary(gid) -> ["--user", "#{uid}:#{gid}"]
      _ -> []
    end
  end

  defp mount_arg(%{kind: :podman}, workspace), do: "#{workspace}:#{@container_workdir}:Z"
  defp mount_arg(_runtime, workspace), do: "#{workspace}:#{@container_workdir}"

  defp id_flag(flag) do
    case System.cmd("id", [flag], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  rescue
    ErlangError -> nil
  end

  defp network_args(false), do: ["--network=none"]
  defp network_args(_network), do: []

  defp limit_args(limits) when is_map(limits) or is_list(limits) do
    [
      limit_arg(limits, :memory, "--memory"),
      limit_arg(limits, :cpus, "--cpus"),
      limit_arg(limits, :pids, "--pids-limit")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp limit_args(_limits), do: []

  defp limit_arg(limits, key, flag) do
    case value(limits, key) do
      nil -> nil
      value -> [flag, to_string(value)]
    end
  end

  defp value(limits, key) when is_map(limits), do: Map.get(limits, key)
  defp value(limits, key) when is_list(limits), do: Keyword.get(limits, key)

  defp running?(runtime, id) do
    case System.cmd(runtime.command, ["inspect", "-f", "{{.State.Running}}", id],
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.trim(output) == "true"
      _ -> false
    end
  end

  defp container_logs(runtime, id) do
    case System.cmd(runtime.command, ["logs", id], stderr_to_stdout: true) do
      {output, _} -> String.trim(output)
    end
  end

  # The image must provide a shell, a reaper-friendly sleep, and setsid. A
  # distroless image fails here instead of producing a half-working session.
  defp prepare(runtime, id) do
    script =
      "mkdir -p #{@home} #{@pgid_dir} && " <>
        "command -v sh >/dev/null 2>&1 && " <>
        "command -v cat >/dev/null 2>&1 && " <>
        "command -v sleep >/dev/null 2>&1 && " <>
        "command -v setsid >/dev/null 2>&1 && " <>
        "command -v rm >/dev/null 2>&1 && " <>
        "setsid sh -c true"

    case System.cmd(runtime.command, ["exec", id, "sh", "-c", script], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:missing_container_tools, status, String.trim(output)}}
    end
  end

  defp remove(runtime, id) do
    System.cmd(runtime.command, ["rm", "-f", id], stderr_to_stdout: true)
    :ok
  rescue
    ErlangError -> :ok
  end

  # ---------------------------------------------------------------------------
  # Exec
  # ---------------------------------------------------------------------------

  defp container_workdir(_workspace, nil), do: {:ok, @container_workdir}

  defp container_workdir(workspace, working_dir) do
    expanded =
      case Path.type(working_dir) do
        :absolute -> Path.expand(working_dir)
        _relative -> Path.expand(working_dir, workspace)
      end

    cond do
      expanded == workspace ->
        {:ok, @container_workdir}

      String.starts_with?(expanded, workspace <> "/") ->
        {:ok, Path.join(@container_workdir, Path.relative_to(expanded, workspace))}

      true ->
        {:error, "Working directory is outside the workspace: #{working_dir}\n"}
    end
  end

  defp ensure_workdir(session, container_dir, original) do
    args = ["exec", session.id, "sh", "-c", "test -d \"$1\"", "sh", container_dir]

    case System.cmd(session.runtime.command, args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      _ -> {:error, "Working directory not found: #{original || container_dir}"}
    end
  end

  defp run_command(session, command, workdir, on_line) do
    pgid_file = Path.join(@pgid_dir, "step-#{System.unique_integer([:positive])}")
    env_file = Path.join(@pgid_dir, "env-#{System.unique_integer([:positive])}")

    host_env_file = Path.join(session.host_tmp_dir, "env-#{System.unique_integer([:positive])}")
    step_cmd = command_string(command.run)
    env = Map.put_new(command.env, "HOME", @home)

    write_env_file(host_env_file, env_file_content(env))

    try do
      case copy_env_file(session, host_env_file, env_file) do
        :ok ->
          args =
            ["exec", "-w", workdir] ++
              [
                "-e",
                "TINY_CI_ENV_FILE=#{env_file}",
                "-e",
                "TINY_CI_PGID_FILE=#{pgid_file}",
                "-e",
                "TINY_CI_STEP_CMD=#{step_cmd}",
                "-e",
                "TINY_CI_WRAPPER=#{@wrapper}",
                session.id,
                "sh",
                "-c",
                @launch
              ]

          command = %Command{
            run: {:argv, session.runtime.command, args},
            timeout: command.timeout
          }

          run_port(command, session, pgid_file, on_line)

        {:error, output} ->
          {:failed, output}
      end
    after
      File.rm(host_env_file)
      remove_container_file(session, env_file)
    end
  end

  defp write_env_file(path, content) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, io} ->
        try do
          File.chmod!(path, 0o600)
          IO.binwrite(io, content)
        after
          File.close(io)
        end

      {:error, reason} ->
        raise File.Error, reason: reason, action: "write the step environment", path: path
    end
  end

  defp env_file_content(env) do
    env
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join(fn {key, value} -> "#{key}=#{escape_env(value)}\n" end)
  end

  defp escape_env(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
  end

  defp copy_env_file(session, host_file, container_file) do
    case System.cmd(
           session.runtime.command,
           ["cp", host_file, "#{session.id}:#{container_file}"],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        :ok

      {output, _status} ->
        {:error, "Could not copy the step environment into the container: #{String.trim(output)}"}
    end
  end

  defp remove_container_file(session, container_file) do
    System.cmd(session.runtime.command, ["exec", session.id, "rm", "-f", container_file],
      stderr_to_stdout: true
    )

    :ok
  rescue
    ErlangError -> :ok
  end

  defp command_string({:shell, cmd}), do: cmd

  defp command_string({:argv, executable, args}) do
    [executable | args] |> Enum.map_join(" ", &shell_quote/1)
  end

  defp shell_quote(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end

  # A port wrapper of our own: the Local backend's Output cannot terminate a
  # process inside the container, so timeout handling runs `kill` in the
  # container against the step's recorded process group.
  defp run_port(command, session, pgid_file, on_line) do
    port_opts = [
      :stderr_to_stdout,
      :binary,
      :exit_status,
      {:args, elem(command.run, 2)}
    ]

    port = Port.open({:spawn_executable, elem(command.run, 1)}, port_opts)
    deadline = if command.timeout, do: now_ms() + command.timeout, else: nil
    collect(port, session, pgid_file, deadline, on_line, [], "")
  end

  defp collect(port, session, pgid_file, deadline, on_line, chunks, line_buf) do
    receive do
      {^port, {:data, data}} ->
        {lines, remaining} = split_lines(line_buf <> data)
        Enum.each(lines, on_line)
        collect(port, session, pgid_file, deadline, on_line, [chunks, data], remaining)

      {^port, {:exit_status, status}} ->
        flush_line(line_buf, on_line)
        {if(status == 0, do: :passed, else: :failed), IO.iodata_to_binary(chunks)}
    after
      remaining_ms(deadline) ->
        flush_line(line_buf, on_line)
        ensure_killed(session, pgid_file)
        stop_port(port, now_ms() + 2_000)
        {:timeout, IO.iodata_to_binary(chunks)}
    end
  end

  # The wrapper records the step's process-group id immediately, but a very
  # short deadline can fire before Docker has even started it. Poll briefly for
  # the file; if it never appears, remove the session so the step cannot keep
  # running unobserved.
  defp ensure_killed(session, pgid_file) do
    deadline = now_ms() + 1_000

    case await_pgid(session, pgid_file, deadline) do
      {:ok, pgid} ->
        signal_group(session, pgid)

      :error ->
        remove(session.runtime, session.id)
        :ok
    end
  end

  defp await_pgid(session, pgid_file, deadline) do
    case read_pgid(session, pgid_file) do
      {:ok, pgid} ->
        {:ok, pgid}

      :error ->
        if now_ms() >= deadline do
          :error
        else
          Process.sleep(20)
          await_pgid(session, pgid_file, deadline)
        end
    end
  end

  defp read_pgid(session, pgid_file) do
    case System.cmd(session.runtime.command, ["exec", session.id, "cat", pgid_file],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {pgid, ""} -> {:ok, pgid}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp stop_port(port, deadline) do
    receive do
      {^port, {:data, _data}} -> stop_port(port, deadline)
      {^port, {:exit_status, _status}} -> :ok
    after
      max(deadline - now_ms(), 0) ->
        if Port.info(port), do: close_port(port)
        :ok
    end
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp signal_group(session, pgid) do
    script =
      "kill -TERM -#{pgid} 2>/dev/null || true; sleep 1; " <>
        "kill -KILL -#{pgid} 2>/dev/null || true"

    System.cmd(session.runtime.command, ["exec", session.id, "sh", "-c", script],
      stderr_to_stdout: true
    )

    :ok
  end

  defp split_lines(buffer) do
    parts = String.split(buffer, "\n")
    {Enum.drop(parts, -1), List.last(parts) || ""}
  end

  defp flush_line("", _on_line), do: :ok

  defp flush_line(line, on_line) do
    on_line.(line)
    :ok
  end

  defp remaining_ms(nil), do: :infinity
  defp remaining_ms(deadline), do: max(deadline - now_ms(), 0)

  defp now_ms, do: System.monotonic_time(:millisecond)
end
