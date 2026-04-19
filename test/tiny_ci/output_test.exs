defmodule TinyCI.OutputTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias TinyCI.Output

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
      {result, _io} =
        with_io(fn ->
          Output.run_cmd("echo streaming_ok", mode: :streaming)
        end)

      assert {:passed, _output} = result
    end

    test "returns :failed for failing command" do
      {result, _io} =
        with_io(fn ->
          Output.run_cmd("false", mode: :streaming)
        end)

      assert {:failed, _output} = result
    end

    test "prints output to stdout as it arrives" do
      {_result, io_output} =
        with_io(fn ->
          Output.run_cmd("echo streamed_line", mode: :streaming)
        end)

      assert io_output =~ "streamed_line"
    end

    test "also captures output in the return value" do
      {result, _io} =
        with_io(fn ->
          Output.run_cmd("echo captured_too", mode: :streaming)
        end)

      assert {:passed, output} = result
      assert output =~ "captured_too"
    end

    test "prints multiple lines" do
      {_result, io_output} =
        with_io(fn ->
          Output.run_cmd("echo line_one && echo line_two && echo line_three", mode: :streaming)
        end)

      assert io_output =~ "line_one"
      assert io_output =~ "line_two"
      assert io_output =~ "line_three"
    end

    test "captures stderr merged with stdout" do
      {result, io_output} =
        with_io(fn ->
          Output.run_cmd("echo on_stdout; echo on_stderr >&2", mode: :streaming)
        end)

      assert {:passed, output} = result
      assert output =~ "on_stdout"
      assert output =~ "on_stderr"
      assert io_output =~ "on_stdout"
      assert io_output =~ "on_stderr"
    end

    test "passes environment variables" do
      {result, io_output} =
        with_io(fn ->
          Output.run_cmd("echo $TINY_CI_STREAM_VAR",
            mode: :streaming,
            env: %{"TINY_CI_STREAM_VAR" => "stream_env"}
          )
        end)

      assert {:passed, output} = result
      assert output =~ "stream_env"
      assert io_output =~ "stream_env"
    end
  end

  describe "run_cmd/2 in streaming mode with prefix" do
    test "prefixes each output line with the step name" do
      {_result, io_output} =
        with_io(fn ->
          Output.run_cmd("echo prefixed_line", mode: :streaming, prefix: "unit")
        end)

      assert io_output =~ "[unit]"
      assert io_output =~ "prefixed_line"
    end

    test "prefixes multiple lines independently" do
      {_result, io_output} =
        with_io(fn ->
          Output.run_cmd("echo first && echo second",
            mode: :streaming,
            prefix: "lint"
          )
        end)

      lines = String.split(io_output, "\n", trim: true)
      prefixed_lines = Enum.filter(lines, &(&1 =~ "[lint]"))
      assert length(prefixed_lines) >= 2
    end

    test "no prefix when prefix option is nil" do
      {_result, io_output} =
        with_io(fn ->
          Output.run_cmd("echo no_prefix_here", mode: :streaming, prefix: nil)
        end)

      assert io_output =~ "no_prefix_here"
      refute io_output =~ "["
    end

    test "captured output does not include the prefix" do
      {result, _io} =
        with_io(fn ->
          Output.run_cmd("echo raw_output", mode: :streaming, prefix: "test")
        end)

      assert {:passed, output} = result
      assert output =~ "raw_output"
      refute output =~ "[test]"
    end
  end

  describe "run_cmd/2 exit status" do
    test "exit code 0 returns :passed" do
      assert {:passed, _} = Output.run_cmd("true", mode: :buffered)

      {result, _io} = with_io(fn -> Output.run_cmd("true", mode: :streaming) end)
      assert {:passed, _} = result
    end

    test "non-zero exit code returns :failed" do
      assert {:failed, _} = Output.run_cmd("false", mode: :buffered)

      {result, _io} = with_io(fn -> Output.run_cmd("false", mode: :streaming) end)
      assert {:failed, _} = result
    end

    test "exit code 1 returns :failed with output" do
      assert {:failed, output} = Output.run_cmd("echo fail_msg && false", mode: :buffered)
      assert output =~ "fail_msg"
    end
  end
end
