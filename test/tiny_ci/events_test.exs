defmodule TinyCI.EventsTest do
  use ExUnit.Case, async: true

  alias TinyCI.Events

  alias TinyCI.Events.{
    BreakpointHit,
    BreakpointResumed,
    CacheLookup,
    HookCompleted,
    HookStarted,
    MatrixRunCompleted,
    MatrixRunStarted,
    PipelineCompleted,
    PipelineStarted,
    RunDiverged,
    StageCompleted,
    StageSkipped,
    StageStarted,
    StepCompleted,
    StepOutputLine,
    StepRetrying,
    StepSkipped,
    StepStarted
  }

  @run_id "run_001"
  @timestamp ~U[2024-01-15 10:30:00.000000Z]
  @timestamp_iso "2024-01-15T10:30:00.000000Z"

  defp decode(struct), do: Jason.decode!(Jason.encode!(struct))

  describe "PipelineStarted" do
    test "constructs with required fields" do
      event = %PipelineStarted{run_id: @run_id, timestamp: @timestamp, pipeline_name: :my_app}
      assert event.run_id == @run_id
      assert event.pipeline_name == :my_app
    end

    test "requires run_id" do
      assert_raise ArgumentError, fn ->
        struct!(PipelineStarted, timestamp: @timestamp, pipeline_name: :my_app)
      end
    end

    test "requires timestamp" do
      assert_raise ArgumentError, fn ->
        struct!(PipelineStarted, run_id: @run_id, pipeline_name: :my_app)
      end
    end

    test "requires pipeline_name" do
      assert_raise ArgumentError, fn ->
        struct!(PipelineStarted, run_id: @run_id, timestamp: @timestamp)
      end
    end

    test "encodes to JSON" do
      event = %PipelineStarted{run_id: @run_id, timestamp: @timestamp, pipeline_name: :my_app}
      json = decode(event)
      assert json["run_id"] == @run_id
      assert json["timestamp"] == @timestamp_iso
      assert json["pipeline_name"] == "my_app"
    end
  end

  describe "PipelineCompleted" do
    test "constructs with required fields" do
      event = %PipelineCompleted{
        run_id: @run_id,
        timestamp: @timestamp,
        status: :passed,
        duration_ms: 1234
      }

      assert event.status == :passed
      assert event.duration_ms == 1234
    end

    test "requires run_id" do
      assert_raise ArgumentError, fn ->
        struct!(PipelineCompleted, timestamp: @timestamp, status: :passed, duration_ms: 0)
      end
    end

    test "requires timestamp" do
      assert_raise ArgumentError, fn ->
        struct!(PipelineCompleted, run_id: @run_id, status: :passed, duration_ms: 0)
      end
    end

    test "encodes to JSON" do
      event = %PipelineCompleted{
        run_id: @run_id,
        timestamp: @timestamp,
        status: :failed,
        duration_ms: 5000
      }

      json = decode(event)
      assert json["run_id"] == @run_id
      assert json["timestamp"] == @timestamp_iso
      assert json["status"] == "failed"
      assert json["duration_ms"] == 5000
    end
  end

  describe "StageStarted" do
    test "constructs with required fields" do
      event = %StageStarted{run_id: @run_id, timestamp: @timestamp, stage: :test}
      assert event.stage == :test
    end

    test "requires run_id" do
      assert_raise ArgumentError, fn ->
        struct!(StageStarted, timestamp: @timestamp, stage: :test)
      end
    end

    test "requires timestamp" do
      assert_raise ArgumentError, fn ->
        struct!(StageStarted, run_id: @run_id, stage: :test)
      end
    end

    test "requires stage" do
      assert_raise ArgumentError, fn ->
        struct!(StageStarted, run_id: @run_id, timestamp: @timestamp)
      end
    end

    test "encodes to JSON" do
      event = %StageStarted{run_id: @run_id, timestamp: @timestamp, stage: :build}
      json = decode(event)
      assert json["stage"] == "build"
      assert json["timestamp"] == @timestamp_iso
    end
  end

  describe "StageSkipped" do
    test "constructs with required fields" do
      event = %StageSkipped{
        run_id: @run_id,
        timestamp: @timestamp,
        stage: :deploy,
        reason: "condition false"
      }

      assert event.reason == "condition false"
    end

    test "requires run_id" do
      assert_raise ArgumentError, fn ->
        struct!(StageSkipped, timestamp: @timestamp, stage: :deploy, reason: "x")
      end
    end

    test "requires timestamp" do
      assert_raise ArgumentError, fn ->
        struct!(StageSkipped, run_id: @run_id, stage: :deploy, reason: "x")
      end
    end

    test "encodes to JSON" do
      event = %StageSkipped{
        run_id: @run_id,
        timestamp: @timestamp,
        stage: :deploy,
        reason: "branch != main"
      }

      json = decode(event)
      assert json["stage"] == "deploy"
      assert json["reason"] == "branch != main"
    end
  end

  describe "StageCompleted" do
    test "constructs with required fields" do
      event = %StageCompleted{
        run_id: @run_id,
        timestamp: @timestamp,
        stage: :test,
        status: :passed,
        duration_ms: 200
      }

      assert event.stage == :test
      assert event.status == :passed
    end

    test "requires run_id" do
      assert_raise ArgumentError, fn ->
        struct!(StageCompleted,
          timestamp: @timestamp,
          stage: :test,
          status: :passed,
          duration_ms: 0
        )
      end
    end

    test "requires timestamp" do
      assert_raise ArgumentError, fn ->
        struct!(StageCompleted, run_id: @run_id, stage: :test, status: :passed, duration_ms: 0)
      end
    end

    test "encodes to JSON" do
      event = %StageCompleted{
        run_id: @run_id,
        timestamp: @timestamp,
        stage: :lint,
        status: :failed,
        duration_ms: 300
      }

      json = decode(event)
      assert json["stage"] == "lint"
      assert json["status"] == "failed"
      assert json["duration_ms"] == 300
    end
  end

  describe "StepStarted" do
    test "constructs with required fields" do
      event = %StepStarted{run_id: @run_id, timestamp: @timestamp, stage: :test, step: :unit}
      assert event.step == :unit
    end

    test "requires run_id" do
      assert_raise ArgumentError, fn ->
        struct!(StepStarted, timestamp: @timestamp, stage: :test, step: :unit)
      end
    end

    test "requires timestamp" do
      assert_raise ArgumentError, fn ->
        struct!(StepStarted, run_id: @run_id, stage: :test, step: :unit)
      end
    end

    test "encodes to JSON" do
      event = %StepStarted{run_id: @run_id, timestamp: @timestamp, stage: :test, step: :unit}
      json = decode(event)
      assert json["stage"] == "test"
      assert json["step"] == "unit"
    end
  end

  describe "StepSkipped" do
    test "constructs with required fields" do
      event = %StepSkipped{
        run_id: @run_id,
        timestamp: @timestamp,
        stage: :test,
        step: :integration,
        reason: "condition false"
      }

      assert event.reason == "condition false"
    end

    test "requires run_id" do
      assert_raise ArgumentError, fn ->
        struct!(StepSkipped, timestamp: @timestamp, stage: :test, step: :integration, reason: "x")
      end
    end

    test "requires timestamp" do
      assert_raise ArgumentError, fn ->
        struct!(StepSkipped, run_id: @run_id, stage: :test, step: :integration, reason: "x")
      end
    end

    test "encodes to JSON" do
      event = %StepSkipped{
        run_id: @run_id,
        timestamp: @timestamp,
        stage: :test,
        step: :integration,
        reason: "env != ci"
      }

      json = decode(event)
      assert json["step"] == "integration"
      assert json["reason"] == "env != ci"
    end
  end

  describe "StepOutputLine" do
    test "constructs with required fields" do
      event = %StepOutputLine{
        run_id: @run_id,
        timestamp: @timestamp,
        stage: :test,
        step: :unit,
        line: "Finished in 0.3s"
      }

      assert event.line == "Finished in 0.3s"
    end

    test "requires run_id" do
      assert_raise ArgumentError, fn ->
        struct!(StepOutputLine, timestamp: @timestamp, stage: :test, step: :unit, line: "x")
      end
    end

    test "requires timestamp" do
      assert_raise ArgumentError, fn ->
        struct!(StepOutputLine, run_id: @run_id, stage: :test, step: :unit, line: "x")
      end
    end

    test "encodes to JSON" do
      event = %StepOutputLine{
        run_id: @run_id,
        timestamp: @timestamp,
        stage: :test,
        step: :unit,
        line: "1 test, 0 failures"
      }

      json = decode(event)
      assert json["line"] == "1 test, 0 failures"
      assert json["step"] == "unit"
    end
  end

  describe "StepRetrying" do
    test "constructs with required fields" do
      event = %StepRetrying{
        run_id: @run_id,
        timestamp: @timestamp,
        stage: :test,
        step: :flaky,
        attempt: 2
      }

      assert event.attempt == 2
    end

    test "requires run_id" do
      assert_raise ArgumentError, fn ->
        struct!(StepRetrying, timestamp: @timestamp, stage: :test, step: :flaky, attempt: 2)
      end
    end

    test "requires timestamp" do
      assert_raise ArgumentError, fn ->
        struct!(StepRetrying, run_id: @run_id, stage: :test, step: :flaky, attempt: 2)
      end
    end

    test "encodes to JSON" do
      event = %StepRetrying{
        run_id: @run_id,
        timestamp: @timestamp,
        stage: :test,
        step: :flaky,
        attempt: 3
      }

      json = decode(event)
      assert json["attempt"] == 3
      assert json["step"] == "flaky"
    end
  end

  describe "StepCompleted" do
    test "constructs with required fields" do
      event = %StepCompleted{
        run_id: @run_id,
        timestamp: @timestamp,
        stage: :test,
        step: :unit,
        status: :passed,
        duration_ms: 150
      }

      assert event.status == :passed
      assert event.duration_ms == 150
    end

    test "requires run_id" do
      assert_raise ArgumentError, fn ->
        struct!(StepCompleted,
          timestamp: @timestamp,
          stage: :test,
          step: :unit,
          status: :passed,
          duration_ms: 0
        )
      end
    end

    test "requires timestamp" do
      assert_raise ArgumentError, fn ->
        struct!(StepCompleted,
          run_id: @run_id,
          stage: :test,
          step: :unit,
          status: :passed,
          duration_ms: 0
        )
      end
    end

    test "encodes to JSON" do
      event = %StepCompleted{
        run_id: @run_id,
        timestamp: @timestamp,
        stage: :test,
        step: :unit,
        status: :passed,
        duration_ms: 150
      }

      json = decode(event)
      assert json["status"] == "passed"
      assert json["duration_ms"] == 150
      assert json["step"] == "unit"
    end
  end

  describe "MatrixRunStarted" do
    test "constructs with required fields" do
      event = %MatrixRunStarted{
        run_id: @run_id,
        timestamp: @timestamp,
        stage: :test,
        combination: [elixir: "1.15", otp: "26"]
      }

      assert event.combination == [elixir: "1.15", otp: "26"]
    end

    test "requires run_id" do
      assert_raise ArgumentError, fn ->
        struct!(MatrixRunStarted, timestamp: @timestamp, stage: :test, combination: [])
      end
    end

    test "requires timestamp" do
      assert_raise ArgumentError, fn ->
        struct!(MatrixRunStarted, run_id: @run_id, stage: :test, combination: [])
      end
    end

    test "encodes to JSON with combination as object" do
      event = %MatrixRunStarted{
        run_id: @run_id,
        timestamp: @timestamp,
        stage: :matrix,
        combination: [elixir: "1.15", otp: "26"]
      }

      json = decode(event)
      assert json["stage"] == "matrix"
      assert json["combination"] == %{"elixir" => "1.15", "otp" => "26"}
    end
  end

  describe "MatrixRunCompleted" do
    test "constructs with required fields" do
      event = %MatrixRunCompleted{
        run_id: @run_id,
        timestamp: @timestamp,
        stage: :test,
        combination: [elixir: "1.15"],
        status: :passed,
        duration_ms: 400
      }

      assert event.status == :passed
    end

    test "requires run_id" do
      assert_raise ArgumentError, fn ->
        struct!(MatrixRunCompleted,
          timestamp: @timestamp,
          stage: :test,
          combination: [],
          status: :passed,
          duration_ms: 0
        )
      end
    end

    test "requires timestamp" do
      assert_raise ArgumentError, fn ->
        struct!(MatrixRunCompleted,
          run_id: @run_id,
          stage: :test,
          combination: [],
          status: :passed,
          duration_ms: 0
        )
      end
    end

    test "encodes to JSON" do
      event = %MatrixRunCompleted{
        run_id: @run_id,
        timestamp: @timestamp,
        stage: :matrix,
        combination: [os: "ubuntu"],
        status: :failed,
        duration_ms: 800
      }

      json = decode(event)
      assert json["status"] == "failed"
      assert json["duration_ms"] == 800
      assert json["combination"] == %{"os" => "ubuntu"}
    end
  end

  describe "HookStarted" do
    test "constructs with required fields" do
      event = %HookStarted{run_id: @run_id, timestamp: @timestamp, hook: :on_success}
      assert event.hook == :on_success
    end

    test "requires run_id" do
      assert_raise ArgumentError, fn ->
        struct!(HookStarted, timestamp: @timestamp, hook: :on_success)
      end
    end

    test "requires timestamp" do
      assert_raise ArgumentError, fn ->
        struct!(HookStarted, run_id: @run_id, hook: :on_success)
      end
    end

    test "encodes to JSON" do
      event = %HookStarted{run_id: @run_id, timestamp: @timestamp, hook: :on_failure}
      json = decode(event)
      assert json["hook"] == "on_failure"
      assert json["timestamp"] == @timestamp_iso
    end
  end

  describe "HookCompleted" do
    test "constructs with required fields" do
      event = %HookCompleted{
        run_id: @run_id,
        timestamp: @timestamp,
        hook: :on_success,
        status: :passed,
        duration_ms: 50
      }

      assert event.hook == :on_success
      assert event.duration_ms == 50
    end

    test "requires run_id" do
      assert_raise ArgumentError, fn ->
        struct!(HookCompleted,
          timestamp: @timestamp,
          hook: :on_success,
          status: :passed,
          duration_ms: 0
        )
      end
    end

    test "requires timestamp" do
      assert_raise ArgumentError, fn ->
        struct!(HookCompleted,
          run_id: @run_id,
          hook: :on_success,
          status: :passed,
          duration_ms: 0
        )
      end
    end

    test "encodes to JSON" do
      event = %HookCompleted{
        run_id: @run_id,
        timestamp: @timestamp,
        hook: :on_failure,
        status: :passed,
        duration_ms: 75
      }

      json = decode(event)
      assert json["hook"] == "on_failure"
      assert json["status"] == "passed"
      assert json["duration_ms"] == 75
    end
  end

  describe "common fields" do
    test "all 14 events have run_id and timestamp" do
      events = [
        %PipelineStarted{run_id: @run_id, timestamp: @timestamp, pipeline_name: :app},
        %PipelineCompleted{
          run_id: @run_id,
          timestamp: @timestamp,
          status: :passed,
          duration_ms: 0
        },
        %StageStarted{run_id: @run_id, timestamp: @timestamp, stage: :test},
        %StageSkipped{run_id: @run_id, timestamp: @timestamp, stage: :test, reason: "x"},
        %StageCompleted{
          run_id: @run_id,
          timestamp: @timestamp,
          stage: :test,
          status: :passed,
          duration_ms: 0
        },
        %StepStarted{run_id: @run_id, timestamp: @timestamp, stage: :test, step: :unit},
        %StepSkipped{
          run_id: @run_id,
          timestamp: @timestamp,
          stage: :test,
          step: :unit,
          reason: "x"
        },
        %StepOutputLine{
          run_id: @run_id,
          timestamp: @timestamp,
          stage: :test,
          step: :unit,
          line: "x"
        },
        %StepRetrying{
          run_id: @run_id,
          timestamp: @timestamp,
          stage: :test,
          step: :unit,
          attempt: 1
        },
        %StepCompleted{
          run_id: @run_id,
          timestamp: @timestamp,
          stage: :test,
          step: :unit,
          status: :passed,
          duration_ms: 0
        },
        %MatrixRunStarted{
          run_id: @run_id,
          timestamp: @timestamp,
          stage: :test,
          combination: []
        },
        %MatrixRunCompleted{
          run_id: @run_id,
          timestamp: @timestamp,
          stage: :test,
          combination: [],
          status: :passed,
          duration_ms: 0
        },
        %HookStarted{run_id: @run_id, timestamp: @timestamp, hook: :on_success},
        %HookCompleted{
          run_id: @run_id,
          timestamp: @timestamp,
          hook: :on_success,
          status: :passed,
          duration_ms: 0
        }
      ]

      assert length(events) == 14

      for event <- events do
        assert Map.has_key?(event, :run_id), "#{inspect(event.__struct__)} missing run_id"
        assert Map.has_key?(event, :timestamp), "#{inspect(event.__struct__)} missing timestamp"
        assert event.run_id == @run_id
        assert event.timestamp == @timestamp
      end
    end

    test "all 14 events serialize timestamp as ISO 8601" do
      events = [
        %PipelineStarted{run_id: @run_id, timestamp: @timestamp, pipeline_name: :app},
        %PipelineCompleted{
          run_id: @run_id,
          timestamp: @timestamp,
          status: :passed,
          duration_ms: 0
        },
        %StageStarted{run_id: @run_id, timestamp: @timestamp, stage: :test},
        %StageSkipped{run_id: @run_id, timestamp: @timestamp, stage: :test, reason: "x"},
        %StageCompleted{
          run_id: @run_id,
          timestamp: @timestamp,
          stage: :test,
          status: :passed,
          duration_ms: 0
        },
        %StepStarted{run_id: @run_id, timestamp: @timestamp, stage: :test, step: :unit},
        %StepSkipped{
          run_id: @run_id,
          timestamp: @timestamp,
          stage: :test,
          step: :unit,
          reason: "x"
        },
        %StepOutputLine{
          run_id: @run_id,
          timestamp: @timestamp,
          stage: :test,
          step: :unit,
          line: "x"
        },
        %StepRetrying{
          run_id: @run_id,
          timestamp: @timestamp,
          stage: :test,
          step: :unit,
          attempt: 1
        },
        %StepCompleted{
          run_id: @run_id,
          timestamp: @timestamp,
          stage: :test,
          step: :unit,
          status: :passed,
          duration_ms: 0
        },
        %MatrixRunStarted{
          run_id: @run_id,
          timestamp: @timestamp,
          stage: :test,
          combination: []
        },
        %MatrixRunCompleted{
          run_id: @run_id,
          timestamp: @timestamp,
          stage: :test,
          combination: [],
          status: :passed,
          duration_ms: 0
        },
        %HookStarted{run_id: @run_id, timestamp: @timestamp, hook: :on_success},
        %HookCompleted{
          run_id: @run_id,
          timestamp: @timestamp,
          hook: :on_success,
          status: :passed,
          duration_ms: 0
        }
      ]

      for event <- events do
        json = decode(event)

        assert json["timestamp"] == @timestamp_iso,
               "#{inspect(event.__struct__)} timestamp not ISO 8601"
      end
    end
  end

  describe "CacheLookup" do
    test "constructs with required fields" do
      event = %CacheLookup{
        run_id: @run_id,
        timestamp: @timestamp,
        stage: :build,
        step: :deps,
        key: "deps-abc123",
        result: :hit
      }

      assert event.result == :hit
      assert event.key == "deps-abc123"
    end

    test "requires run_id" do
      assert_raise ArgumentError, fn ->
        struct!(CacheLookup,
          timestamp: @timestamp,
          stage: :build,
          step: :deps,
          key: "k",
          result: :hit
        )
      end
    end

    test "requires result" do
      assert_raise ArgumentError, fn ->
        struct!(CacheLookup,
          run_id: @run_id,
          timestamp: @timestamp,
          stage: :build,
          step: :deps,
          key: "k"
        )
      end
    end

    test "encodes to JSON" do
      event = %CacheLookup{
        run_id: @run_id,
        timestamp: @timestamp,
        stage: :build,
        step: :deps,
        key: "deps-abc123",
        result: :miss
      }

      json = decode(event)
      assert json["stage"] == "build"
      assert json["step"] == "deps"
      assert json["key"] == "deps-abc123"
      assert json["result"] == "miss"
      assert json["timestamp"] == @timestamp_iso
    end
  end

  describe "StepOutputLine stream field" do
    test "defaults to :stdout" do
      event = %StepOutputLine{
        run_id: @run_id,
        timestamp: @timestamp,
        stage: :test,
        step: :unit,
        line: "x"
      }

      assert event.stream == :stdout
    end

    test "encodes the stream as a string" do
      event = %StepOutputLine{
        run_id: @run_id,
        timestamp: @timestamp,
        stage: :test,
        step: :unit,
        line: "boom",
        stream: :stderr
      }

      json = decode(event)
      assert json["stream"] == "stderr"
      assert json["line"] == "boom"
    end
  end

  describe "StepCompleted output field" do
    test "defaults to an empty string" do
      event = %StepCompleted{
        run_id: @run_id,
        timestamp: @timestamp,
        stage: :test,
        step: :unit,
        status: :passed,
        duration_ms: 1
      }

      assert event.output == ""
    end

    test "encodes the output" do
      event = %StepCompleted{
        run_id: @run_id,
        timestamp: @timestamp,
        stage: :test,
        step: :unit,
        status: :passed,
        duration_ms: 1,
        output: "1 test, 0 failures"
      }

      json = decode(event)
      assert json["output"] == "1 test, 0 failures"
    end
  end

  describe "type/1" do
    test "maps each event struct to its build-plan vocabulary string" do
      mapping = [
        {%PipelineStarted{run_id: @run_id, timestamp: @timestamp, pipeline_name: :app},
         "run_started"},
        {%PipelineCompleted{
           run_id: @run_id,
           timestamp: @timestamp,
           status: :passed,
           duration_ms: 0
         }, "run_finished"},
        {%StageStarted{run_id: @run_id, timestamp: @timestamp, stage: :t}, "stage_started"},
        {%StageSkipped{run_id: @run_id, timestamp: @timestamp, stage: :t, reason: "x"},
         "stage_skipped"},
        {%StageCompleted{
           run_id: @run_id,
           timestamp: @timestamp,
           stage: :t,
           status: :passed,
           duration_ms: 0
         }, "stage_finished"},
        {%StepStarted{run_id: @run_id, timestamp: @timestamp, stage: :t, step: :u},
         "step_started"},
        {%StepSkipped{run_id: @run_id, timestamp: @timestamp, stage: :t, step: :u, reason: "x"},
         "step_skipped"},
        {%StepOutputLine{run_id: @run_id, timestamp: @timestamp, stage: :t, step: :u, line: "x"},
         "step_output"},
        {%StepRetrying{run_id: @run_id, timestamp: @timestamp, stage: :t, step: :u, attempt: 2},
         "step_retrying"},
        {%StepCompleted{
           run_id: @run_id,
           timestamp: @timestamp,
           stage: :t,
           step: :u,
           status: :passed,
           duration_ms: 0
         }, "step_finished"},
        {%MatrixRunStarted{run_id: @run_id, timestamp: @timestamp, stage: :t, combination: []},
         "matrix_run_started"},
        {%MatrixRunCompleted{
           run_id: @run_id,
           timestamp: @timestamp,
           stage: :t,
           combination: [],
           status: :passed,
           duration_ms: 0
         }, "matrix_run_finished"},
        {%HookStarted{run_id: @run_id, timestamp: @timestamp, hook: :on_success}, "hook_started"},
        {%HookCompleted{
           run_id: @run_id,
           timestamp: @timestamp,
           hook: :on_success,
           status: :passed,
           duration_ms: 0
         }, "hook_finished"},
        {%CacheLookup{
           run_id: @run_id,
           timestamp: @timestamp,
           stage: :t,
           step: :u,
           key: "k",
           result: :hit
         }, "cache_lookup"},
        {%BreakpointHit{
           run_id: @run_id,
           timestamp: @timestamp,
           pause_id: "pause_1",
           phase: :before,
           scope: :step,
           stage: :t
         }, "breakpoint_hit"},
        {%BreakpointResumed{
           run_id: @run_id,
           timestamp: @timestamp,
           pause_id: "pause_1",
           command: :continue,
           waited_ms: 0
         }, "breakpoint_resumed"},
        {%RunDiverged{run_id: @run_id, timestamp: @timestamp, reason: :set_store}, "run_diverged"}
      ]

      for {event, expected} <- mapping do
        assert Events.type(event) == expected,
               "#{inspect(event.__struct__)} should map to #{expected}"
      end
    end
  end

  describe "BreakpointHit" do
    defp hit(overrides \\ %{}) do
      Map.merge(
        %BreakpointHit{
          run_id: @run_id,
          timestamp: @timestamp,
          pause_id: "pause_1",
          phase: :before,
          scope: :step,
          stage: :test,
          step: :unit,
          breakpoint: "before:test.unit",
          working_dir: "/repo",
          branch: "main",
          commit: "abc",
          env: %{"MIX_ENV" => "test"},
          store: %{"tag" => "v1"}
        },
        overrides
      )
    end

    test "encodes the whole inspectable payload" do
      json = decode(hit())

      assert json["run_id"] == @run_id
      assert json["timestamp"] == @timestamp_iso
      assert json["pause_id"] == "pause_1"
      assert json["phase"] == "before"
      assert json["scope"] == "step"
      assert json["stage"] == "test"
      assert json["step"] == "unit"
      assert json["breakpoint"] == "before:test.unit"
      assert json["working_dir"] == "/repo"
      assert json["branch"] == "main"
      assert json["commit"] == "abc"
      assert json["env"] == %{"MIX_ENV" => "test"}
      assert json["store"] == %{"tag" => "v1"}
    end

    test "encodes a stage boundary with a null step" do
      assert decode(hit(%{scope: :stage, step: nil}))["step"] == nil
    end

    test "encodes the matrix combination as an object" do
      json = decode(hit(%{matrix_combination: [elixir: "1.18", otp: "27"]}))
      assert json["matrix_combination"] == %{"elixir" => "1.18", "otp" => "27"}
    end

    test "omits the matrix combination when there is none" do
      assert decode(hit())["matrix_combination"] == nil
    end

    test "carries the pending result on an :after boundary" do
      result = %{"status" => "failed", "duration_ms" => 12, "output" => "boom"}
      assert decode(hit(%{phase: :after, result: result}))["result"] == result
    end

    test "requires the fields that identify a pause" do
      assert_raise ArgumentError, fn ->
        struct!(BreakpointHit, run_id: @run_id, timestamp: @timestamp)
      end
    end
  end

  describe "BreakpointResumed" do
    test "encodes the command, wait, and whether a timeout released it" do
      json =
        decode(%BreakpointResumed{
          run_id: @run_id,
          timestamp: @timestamp,
          pause_id: "pause_1",
          command: :abort,
          waited_ms: 1234,
          stage: :test,
          step: :unit,
          timed_out: true
        })

      assert json["pause_id"] == "pause_1"
      assert json["command"] == "abort"
      assert json["waited_ms"] == 1234
      assert json["stage"] == "test"
      assert json["step"] == "unit"
      assert json["timed_out"] == true
    end

    test "defaults timed_out to false" do
      json =
        decode(%BreakpointResumed{
          run_id: @run_id,
          timestamp: @timestamp,
          pause_id: "pause_1",
          command: :continue,
          waited_ms: 0
        })

      assert json["timed_out"] == false
      assert json["stage"] == nil
    end
  end

  describe "RunDiverged" do
    test "encodes the reason and what changed" do
      json =
        decode(%RunDiverged{
          run_id: @run_id,
          timestamp: @timestamp,
          reason: :set_store,
          stage: :deploy,
          step: :push,
          detail: ~s(tag = "v2")
        })

      assert json["reason"] == "set_store"
      assert json["stage"] == "deploy"
      assert json["step"] == "push"
      assert json["detail"] == ~s(tag = "v2")
    end

    test "a run-level divergence carries no stage or step" do
      json = decode(%RunDiverged{run_id: @run_id, timestamp: @timestamp, reason: :skip})

      assert json["reason"] == "skip"
      assert json["stage"] == nil
      assert json["step"] == nil
      assert json["detail"] == nil
    end
  end

  describe "aborted status" do
    test "run_finished can report an aborted run" do
      json =
        decode(%PipelineCompleted{
          run_id: @run_id,
          timestamp: @timestamp,
          status: :aborted,
          duration_ms: 5
        })

      assert json["status"] == "aborted"
    end

    test "stage_finished and step_finished can report an aborted unit" do
      stage =
        decode(%StageCompleted{
          run_id: @run_id,
          timestamp: @timestamp,
          stage: :t,
          status: :aborted,
          duration_ms: 0
        })

      step =
        decode(%StepCompleted{
          run_id: @run_id,
          timestamp: @timestamp,
          stage: :t,
          step: :u,
          status: :aborted,
          duration_ms: 0
        })

      assert stage["status"] == "aborted"
      assert step["status"] == "aborted"
    end
  end
end
