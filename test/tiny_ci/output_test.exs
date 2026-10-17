defmodule TinyCI.OutputTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias TinyCI.Output

  # Collects the lines `Output` reports to `:on_line`. `Output` never prints, so
  # the callback is the only output channel.
  defp lines(fun) do
    parent = self()
    fun.(fn line -> send(parent, {:line, line}) end)
    drain([])
  end

  defp drain(acc) do
    receive do
      {:line, line} -> drain([line | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "run_executable/3" do
    test "passes argv literally and preserves the exit status" do
      assert {"value; $HOME", 0} =
               Output.run_executable("printf", ["%s", "value; $HOME"], mode: :buffered)

      assert {"", 7} = Output.run_executable("sh", ["-c", "exit 7"], mode: :buffered)
    end

    test "enforces a deadline for a directly launched executable" do
      assert {_, :timeout} = Output.run_executable("sleep", ["30"], mode: :buffered, timeout: 10)
    end
  end

  describe "resolve_mode/1" do
    test "returns :streaming for explicit :streaming" do
      assert Output.resolve_mode(:streaming) == :streaming
    end

    test "returns :buffered for explicit :buffered" do
      assert Output.resolve_mode(:buffered) == :buffered
    end

    test "resolves :auto to a concrete mode" do
      mode = Output.resolve_mode(:auto)
      assert mode in [:streaming, :buffered]
    end
  end

  describe "run_cmd/2 in buffered mode" do
    test "returns :passed for successful command" do
      assert {:passed, output} = Output.run_cmd("echo hello", mode: :buffered)
      assert output =~ "hello"
    end

    test "returns :failed for failing command" do
      assert {:failed, _output} = Output.run_cmd("false", mode: :buffered)
    end

    test "captures command output" do
      assert {:passed, output} = Output.run_cmd("echo buffered_test", mode: :buffered)
      assert output =~ "buffered_test"
    end

    test "does not print output to stdout" do
      io_output =
        capture_io(fn ->
          {:passed, _} = Output.run_cmd("echo should_not_print", mode: :buffered)
        end)

      refute io_output =~ "should_not_print"
    end

    test "reports complete lines to :on_line in order" do
      reported =
        lines(fn on_line ->
          assert {:passed, _} =
                   Output.run_cmd("echo one && echo two && echo three",
                     mode: :buffered,
                     on_line: on_line
                   )
        end)

      assert reported == ["one", "two", "three"]
    end

    test "passes environment variables" do
      assert {:passed, output} =
               Output.run_cmd("echo $TINY_CI_TEST_VAR",
                 mode: :buffered,
                 env: %{"TINY_CI_TEST_VAR" => "env_value"}
               )

      assert output =~ "env_value"
    end
  end

  describe "run_cmd/2 in streaming mode" do
    test "returns :passed for successful command" do
      assert {:passed, _output} = Output.run_cmd("echo streaming_ok", mode: :streaming)
    end

    test "returns :failed for failing command" do
      assert {:failed, _output} = Output.run_cmd("false", mode: :streaming)
    end

    test "reports output as it arrives" do
      reported =
        lines(fn on_line ->
          Output.run_cmd("echo streamed_line", mode: :streaming, on_line: on_line)
        end)

      assert reported == ["streamed_line"]
    end

    test "reports multiple lines independently" do
      reported =
        lines(fn on_line ->
          Output.run_cmd("echo line_one && echo line_two && echo line_three",
            mode: :streaming,
            on_line: on_line
          )
        end)

      assert reported == ["line_one", "line_two", "line_three"]
    end

    test "also captures output in the return value" do
      assert {:passed, output} = Output.run_cmd("echo captured_too", mode: :streaming)
      assert output =~ "captured_too"
    end

    test "captures stderr merged with stdout" do
      reported =
        lines(fn on_line ->
          Output.run_cmd("echo on_stdout; echo on_stderr >&2", mode: :streaming, on_line: on_line)
        end)

      assert reported == ["on_stdout", "on_stderr"]
    end

    test "passes environment variables" do
      reported =
        lines(fn on_line ->
          Output.run_cmd("echo $TINY_CI_STREAM_VAR",
            mode: :streaming,
            env: %{"TINY_CI_STREAM_VAR" => "stream_env"},
            on_line: on_line
          )
        end)

      assert reported == ["stream_env"]
    end
  end

  describe "run_cmd/2 with redact:" do
    test "masks each reported line and the returned output" do
      reported =
        lines(fn on_line ->
          assert {:passed, output} =
                   Output.run_cmd("echo token=abcd1234",
                     mode: :streaming,
                     redact: ["abcd1234"],
                     on_line: on_line
                   )

          assert output == "token=***\n"
        end)

      assert reported == ["token=***"]
    end

    test "masks the returned output in buffered mode" do
      assert {:passed, "token=***\n"} =
               Output.run_cmd("echo token=abcd1234", mode: :buffered, redact: ["abcd1234"])
    end

    test "masks a secret split across chunks once the line is complete" do
      cmd = "printf 'abcd'; sleep 0.05; printf '1234\\n'"

      assert {:passed, "***\n"} =
               Output.run_cmd(cmd, mode: :buffered, redact: ["abcd1234"])
    end
  end

  describe "run_cmd/2 exit status" do
    test "exit code 0 returns :passed" do
      assert {:passed, _} = Output.run_cmd("true", mode: :buffered)
      assert {:passed, _} = Output.run_cmd("true", mode: :streaming)
    end

    test "non-zero exit code returns :failed" do
      assert {:failed, _} = Output.run_cmd("false", mode: :buffered)
      assert {:failed, _} = Output.run_cmd("false", mode: :streaming)
    end

    test "exit code 1 returns :failed with output" do
      assert {:failed, output} = Output.run_cmd("echo fail_msg && false", mode: :buffered)
      assert output =~ "fail_msg"
    end
  end
end
