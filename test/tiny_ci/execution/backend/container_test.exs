defmodule TinyCI.Execution.Backend.ContainerTest do
  @moduledoc """
  Integration tests for the container execution backend.

  Tagged `:container` and excluded automatically when no container runtime is
  available. The suite uses a pinned Alpine image.
  """

  use ExUnit.Case, async: true

  alias TinyCI.Execution.{Command, SessionSpec}
  alias TinyCI.Execution.Backend.Container

  @moduletag :container
  @moduletag :tmp_dir

  defp image, do: "alpine:3.22"

  setup_all do
    runtime = Container.runtime()
    assert match?({:ok, _}, runtime)
    {:ok, runtime} = runtime

    ensure_image(runtime, image())
    :ok
  end

  setup %{tmp_dir: tmp_dir} do
    run_id = "test_#{System.unique_integer([:positive])}"
    {:ok, session} = Container.open(spec(tmp_dir, run_id))
    on_exit(fn -> Container.close(session) end)
    {:ok, session: session, run_id: run_id}
  end

  defp spec(tmp_dir, run_id, opts \\ []) do
    %SessionSpec{
      workspace: tmp_dir,
      run_id: run_id,
      image: Keyword.get(opts, :image, image()),
      network: Keyword.get(opts, :network, true),
      limits: Keyword.get(opts, :limits, %{})
    }
  end

  defp run(session, command, timeout \\ nil) do
    parent = self()

    result =
      Container.exec(
        session,
        %Command{run: {:shell, command}, timeout: timeout},
        fn line -> send(parent, {:line, line}) end
      )

    {result, drain_lines([])}
  end

  defp drain_lines(acc) do
    receive do
      {:line, line} -> drain_lines([line | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "availability and lifecycle" do
    test "name/0 and available?/0 describe a usable runtime" do
      assert Container.name() == :container
      assert Container.available?()
    end

    test "a missing image fails without leaving a container", %{tmp_dir: tmp_dir} do
      run_id = "missing_#{System.unique_integer([:positive])}"

      assert {:error, {:image_unavailable, "tiny_ci_missing:does_not_exist", _, _}} =
               Container.open(spec(tmp_dir, run_id, image: "tiny_ci_missing:does_not_exist"))

      assert containers_for(run_id) == []
    end

    test "the per-session host temp directory is private and removed on close",
         %{session: session} do
      dir = session.host_tmp_dir
      assert File.dir?(dir)
      assert Bitwise.band(File.stat!(dir).mode, 0o777) == 0o700

      assert :ok = Container.close(session)
      refute File.exists?(dir)
    end

    test "a step's environment file is private and removed after the exec",
         %{session: session} do
      task = Task.async(fn -> run(session, "sleep 1") end)

      env_file = wait_for_env_file(session.host_tmp_dir, now_ms() + 2_000)
      assert File.exists?(env_file)
      assert Bitwise.band(File.stat!(env_file).mode, 0o777) == 0o600

      assert {{:passed, _}, _} = Task.await(task, 10_000)
      assert Path.wildcard(Path.join(session.host_tmp_dir, "env-*")) == []
    end

    test "close/1 is idempotent and removes the labelled container",
         %{session: session, run_id: run_id} do
      assert :ok = Container.close(session)
      assert :ok = Container.close(session)
      assert containers_for(run_id) == []
    end
  end

  describe "exec/3" do
    test "round-trips a shell command with the same status and lines as Local",
         %{session: session} do
      assert {{:passed, "hello\n"}, ["hello"]} = run(session, "echo hello")
      assert {{:failed, "nope\n"}, ["nope"]} = run(session, "echo nope; false")
    end

    test "runs inside the image, not on the host", %{session: session} do
      assert {{:passed, output}, _} = run(session, "cat /etc/alpine-release")
      assert String.trim(output) =~ ~r/^\d+\.\d+/
    end

    test "runs an argv command literally", %{session: session} do
      command = %Command{run: {:argv, "printf", ["%s\n", "value; $HOME"]}}
      assert {:passed, "value; $HOME\n"} = Container.exec(session, command, fn _ -> :ok end)
    end

    test "uses a writable HOME and /workspace", %{session: session, tmp_dir: tmp_dir} do
      assert {{:passed, _}, _} = run(session, "echo state > \"$HOME/state\"")
      assert {{:passed, output}, _} = run(session, "cat \"$HOME/state\"")
      assert String.trim(output) == "state"

      assert {{:passed, output}, _} = run(session, "pwd")
      assert String.trim(output) == "/workspace"
      assert tmp_dir != "/workspace"
    end

    test "honours a working directory under the workspace",
         %{session: session, tmp_dir: tmp_dir} do
      File.mkdir_p!(Path.join(tmp_dir, "apps/web"))

      command = %Command{run: {:shell, "pwd"}, working_dir: Path.join(tmp_dir, "apps/web")}
      assert {:passed, output} = Container.exec(session, command, fn _ -> :ok end)
      assert String.trim(output) == "/workspace/apps/web"
    end

    test "fails cleanly for a missing working directory", %{session: session, tmp_dir: tmp_dir} do
      command = %Command{run: {:shell, "true"}, working_dir: Path.join(tmp_dir, "missing")}
      assert {:failed, output} = Container.exec(session, command, fn _ -> :ok end)
      assert output =~ "Working directory not found"
    end

    test "passes only the command environment, never the host environment",
         %{session: session} do
      name = "TINY_CI_HOST_ONLY_#{System.unique_integer([:positive])}"
      System.put_env(name, "leaked")
      on_exit(fn -> System.delete_env(name) end)

      command = %Command{run: {:shell, "printenv #{name} || echo absent"}}
      assert {:passed, "absent\n"} = Container.exec(session, command, fn _ -> :ok end)

      command = %Command{
        run: {:shell, "printenv TINY_CI_STEP_VALUE"},
        env: %{"TINY_CI_STEP_VALUE" => "present"}
      }

      assert {:passed, "present\n"} = Container.exec(session, command, fn _ -> :ok end)
    end

    test "pipeline env cannot control the container runtime client",
         %{session: session} do
      command = %Command{
        run: {:shell, "echo \"$DOCKER_HOST\"; echo \"$HOME\"; printf '%s' \"$MULTI\""},
        env: %{
          "DOCKER_HOST" => "unix:///tmp/tiny_ci_not_a_socket",
          "HOME" => "/tmp/step-home",
          "MULTI" => "line1\nline2"
        }
      }

      assert {:passed, output} = Container.exec(session, command, fn _ -> :ok end)
      assert output =~ "unix:///tmp/tiny_ci_not_a_socket"
      assert output =~ "/tmp/step-home"
      assert output =~ "line1\nline2"

      assert {:passed, "still works\n"} =
               Container.exec(session, %Command{run: {:shell, "echo still works"}}, fn _ ->
                 :ok
               end)
    end

    test "writes into the workspace with host ownership",
         %{session: session, tmp_dir: tmp_dir} do
      assert {{:passed, _}, _} = run(session, "echo written > /workspace/from_container")

      path = Path.join(tmp_dir, "from_container")
      assert File.read!(path) == "written\n"
      assert File.stat!(path).uid == host_uid()
    end

    test "network: false has no default route", %{tmp_dir: tmp_dir} do
      run_id = "net_#{System.unique_integer([:positive])}"
      {:ok, session} = Container.open(spec(tmp_dir, run_id, network: false))
      on_exit(fn -> Container.close(session) end)

      assert {{:passed, output}, _} = run(session, "cat /proc/net/route")
      refute output =~ ~r/^[^\t]+\t00000000\t/m
    end

    test "the .git directory is mounted read-only", %{tmp_dir: tmp_dir} do
      git_dir = Path.join(tmp_dir, ".git")
      config = Path.join(git_dir, "config")
      File.mkdir_p!(git_dir)
      File.write!(config, "[core]\n")

      run_id = "git_#{System.unique_integer([:positive])}"
      {:ok, session} = Container.open(spec(tmp_dir, run_id))
      on_exit(fn -> Container.close(session) end)

      assert {{:failed, _output}, _} =
               run(session, "echo hacked > /workspace/.git/config")

      assert File.read!(config) == "[core]\n"
    end

    test "parallel steps share the session", %{session: session} do
      parent = self()

      tasks =
        for i <- 1..4 do
          Task.async(fn ->
            result =
              Container.exec(
                session,
                %Command{run: {:shell, "echo step#{i}; sleep 0.1"}},
                fn line -> send(parent, {:line, line}) end
              )

            {i, result}
          end)
        end

      results = Task.await_many(tasks, 30_000)
      assert Enum.all?(results, fn {_i, result} -> match?({:passed, _}, result) end)

      lines =
        for {_i, _} <- results do
          assert_receive {:line, "step" <> _ = line}, 2_000
          line
        end

      assert Enum.sort(lines) == ["step1", "step2", "step3", "step4"]
    end
  end

  describe "timeouts" do
    test "kill the step's process group without touching a sibling",
         %{session: session} do
      slow = Task.async(fn -> run(session, "echo $$ > /workspace/timed.pid; sleep 30", 400) end)
      sibling = Task.async(fn -> run(session, "sleep 0.5; echo alive") end)

      assert {{:timeout, _}, _} = Task.await(slow, 30_000)
      assert {{:passed, "alive\n"}, ["alive"]} = Task.await(sibling, 30_000)

      assert {{:failed, _}, _} =
               run(session, "pid=$(cat /workspace/timed.pid); kill -0 \"$pid\" 2>/dev/null")
    end

    test "state does not leak into the next session", %{tmp_dir: tmp_dir} do
      run_id = "isolation_#{System.unique_integer([:positive])}"

      {:ok, first} = Container.open(spec(tmp_dir, run_id <> "_1"))
      assert {{:passed, _}, _} = run(first, "echo secret > \"$HOME/state\"")
      assert :ok = Container.close(first)

      {:ok, second} = Container.open(spec(tmp_dir, run_id <> "_2"))
      on_exit(fn -> Container.close(second) end)

      assert {{:failed, _}, _} = run(second, "cat \"$HOME/state\"")
    end

    test "a timeout with no recorded pgid removes the session", %{tmp_dir: tmp_dir} do
      run_id = "nopgid_#{System.unique_integer([:positive])}"
      {:ok, session} = Container.open(spec(tmp_dir, run_id))
      on_exit(fn -> Container.close(session) end)

      assert {{:timeout, _}, _} =
               run(session, ~s(rm "$TINY_CI_PGID_FILE"; sleep 30), 200)

      assert containers_for(run_id) == []
    end
  end

  defp ensure_image(runtime, image) do
    case System.cmd(runtime.command, ["image", "inspect", image], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {_output, _} ->
        case System.cmd(runtime.command, ["pull", image], stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {output, status} -> flunk("could not pull #{image} (#{status}): #{output}")
        end
    end
  end

  defp containers_for(run_id) do
    {:ok, runtime} = Container.runtime()

    {output, 0} =
      System.cmd(
        runtime.command,
        ["ps", "-a", "--filter", "label=tiny_ci.run_id=#{run_id}", "--format", "{{.ID}}"],
        stderr_to_stdout: true
      )

    output |> String.split("\n", trim: true)
  end

  defp wait_for_env_file(dir, deadline) do
    case Path.wildcard(Path.join(dir, "env-*")) do
      [path | _] ->
        path

      [] ->
        if now_ms() >= deadline do
          flunk("no step environment file appeared in #{dir}")
        else
          Process.sleep(10)
          wait_for_env_file(dir, deadline)
        end
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp host_uid do
    {output, 0} = System.cmd("id", ["-u"])
    String.to_integer(String.trim(output))
  end
end
