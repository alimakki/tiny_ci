defmodule TinyCI.Execution.Backend.LocalTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias TinyCI.Execution
  alias TinyCI.Execution.{Command, SessionSpec}
  alias TinyCI.Execution.Backend.Local

  @moduletag :tmp_dir

  defp collect_lines(command) do
    parent = self()

    result =
      Execution.with_session(
        %SessionSpec{workspace: File.cwd!()},
        fn session ->
          Execution.exec(session, command, fn line -> send(parent, {:line, line}) end)
        end,
        backend: Local
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

  defp run(%Command{} = command), do: Local.exec(:local, command, fn _ -> :ok end)

  describe "open/1 and close/1" do
    test "carry the run id and are trivial", %{tmp_dir: tmp_dir} do
      assert {:ok, %{run_id: "run_local"}} =
               Local.open(%SessionSpec{workspace: tmp_dir, run_id: "run_local"})

      assert :ok = Local.close(:local)
    end

    test "name/0 and available?/0 describe the host backend" do
      assert Local.name() == :local
      assert Local.available?()
    end
  end

  describe "exec/3 with shell commands" do
    test "returns :passed and captures output" do
      assert {:passed, output} = run(%Command{run: {:shell, "echo hello_local"}})
      assert output =~ "hello_local"
    end

    test "returns :failed for a non-zero exit" do
      assert {:failed, _output} = run(%Command{run: {:shell, "false"}})
    end

    test "reports complete lines in order" do
      assert {{:passed, _output}, ["one", "two", "three"]} =
               collect_lines(%Command{run: {:shell, "echo one && echo two && echo three"}})
    end

    test "never prints output to stdout" do
      output =
        capture_io(fn ->
          assert {:passed, _} = run(%Command{run: {:shell, "echo should_not_print"}})
        end)

      refute output =~ "should_not_print"
    end

    test "reports lines exactly as produced, without redacting" do
      command = %Command{run: {:shell, "echo token=abcd1234"}}

      assert {{:passed, output}, ["token=abcd1234"]} = collect_lines(command)
      assert output == "token=abcd1234\n"
    end

    test "passes environment variables" do
      command = %Command{
        run: {:shell, "echo $TINY_CI_LOCAL_VAR"},
        env: %{"TINY_CI_LOCAL_VAR" => "local_value"}
      }

      assert {:passed, output} = run(command)
      assert output =~ "local_value"
    end

    test "honours the working directory", %{tmp_dir: tmp_dir} do
      command = %Command{run: {:shell, "pwd"}, working_dir: tmp_dir}

      assert {:passed, output} = run(command)
      assert String.trim(output) == tmp_dir
    end

    test "timeout kills the process subtree" do
      marker = "sleep 63.#{System.unique_integer([:positive])}"
      command = %Command{run: {:shell, "#{marker} && echo done"}, timeout: 200}

      assert {:timeout, _output} = run(command)
      assert wait_until_gone(marker, 10_000)
    end
  end

  describe "exec/3 with argv commands" do
    test "passes argv literally and preserves pass/fail" do
      assert {:passed, "value; $HOME\n"} =
               run(%Command{run: {:argv, "printf", ["%s\n", "value; $HOME"]}})

      assert {:failed, ""} = run(%Command{run: {:argv, "sh", ["-c", "exit 7"]}})
    end

    test "enforces a deadline" do
      assert {:timeout, _output} = run(%Command{run: {:argv, "sleep", ["30"]}, timeout: 10})
    end
  end

  defp wait_until_gone(marker, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until_gone(marker, deadline)
  end

  defp do_wait_until_gone(marker, deadline) do
    {out, _status} = System.cmd("pgrep", ["-f", marker], stderr_to_stdout: true)

    cond do
      out == "" ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(50)
        do_wait_until_gone(marker, deadline)
    end
  end
end
