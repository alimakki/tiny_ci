defmodule TinyCI.Runs.ProjectionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  doctest TinyCI.Runs.Projection

  alias TinyCI.{Executor, Reporter, Results, Stage, Step}
  alias TinyCI.Events.Sink.NDJSON
  alias TinyCI.Runs.Projection

  alias TinyCI.Events.{
    BreakpointHit,
    BreakpointResumed,
    CacheLookup,
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

  @ts ~U[2026-01-02 03:04:05.000000Z]
  @iso "2026-01-02T03:04:05.000000Z"

  # Events are built as real structs and pushed through the real NDJSON envelope, so
  # these tests cannot drift from the wire format the recorder writes.
  defp ev(module, fields), do: struct!(module, [run_id: "r1", timestamp: @ts] ++ fields)

  defp wire(events) do
    events
    |> Enum.with_index(1)
    |> Enum.map(fn {event, seq} -> seq |> NDJSON.encode_line(event) |> Jason.decode!() end)
  end

  defp fold(events), do: events |> wire() |> Projection.fold()

  defp started(fields \\ []),
    do: ev(PipelineStarted, [pipeline_name: :app] ++ fields)

  defp finished(status, ms \\ 100),
    do: ev(PipelineCompleted, status: status, duration_ms: ms)

  defp step(stage, name, status, ms, lines \\ []) do
    [ev(StepStarted, stage: stage, step: name)] ++
      Enum.map(lines, &ev(StepOutputLine, stage: stage, step: name, line: &1)) ++
      [ev(StepCompleted, stage: stage, step: name, status: status, duration_ms: ms)]
  end

  defp stage(name, status, ms, steps) do
    [ev(StageStarted, stage: name)] ++
      List.flatten(steps) ++
      [ev(StageCompleted, stage: name, status: status, duration_ms: ms)]
  end

  describe "fold/1 of a passing two-stage run" do
    setup do
      events =
        [
          started(branch: "main", commit: "abc1234def", base_ref: "origin/main", root: "/w/app")
        ] ++
          stage(:build, :passed, 30, [
            step(:build, :compile, :passed, 12, ["compiling", "done"]),
            step(:build, :lint, :passed, 8)
          ]) ++
          stage(:test, :passed, 50, [step(:test, :unit, :passed, 40, ["1 test"])]) ++
          [finished(:passed, 90)]

      {:ok, projection: fold(events), count: length(events)}
    end

    test "records the run's identity and timing", %{projection: p, count: count} do
      assert %Projection{
               run_id: "r1",
               pipeline: "app",
               status: :passed,
               schema_version: 3,
               branch: "main",
               commit: "abc1234def",
               base_ref: "origin/main",
               root: "/w/app",
               started_at: @iso,
               finished_at: @iso,
               duration_ms: 90,
               divergent?: false,
               breakpoints: []
             } = p

      assert p.last_seq == count
    end

    test "keeps stages and steps in order with their statuses and durations", %{projection: p} do
      assert [%{name: "build", status: :passed, duration_ms: 30}, %{name: "test"}] = p.stages
      [build, test] = p.stages
      assert [%{name: "compile", duration_ms: 12}, %{name: "lint", duration_ms: 8}] = build.steps
      assert [%{name: "unit", status: :passed, duration_ms: 40}] = test.steps
    end

    test "joins output lines with newlines", %{projection: p} do
      [build, test] = p.stages
      assert hd(build.steps).output == "compiling\ndone"
      assert List.last(build.steps).output == ""
      assert hd(test.steps).output == "1 test"
    end
  end

  describe "fold/1 of a failing run" do
    test "a failing serial stage has no later steps, and the run fails" do
      events =
        [started()] ++
          stage(:test, :failed, 20, [step(:test, :unit, :failed, 15, ["boom"])]) ++
          [finished(:failed, 25)]

      p = fold(events)

      assert p.status == :failed

      assert [%{name: "test", status: :failed, steps: [%{name: "unit", status: :failed}]}] =
               p.stages
    end

    test "an aborted run is reported as aborted" do
      p = fold([started(), finished(:aborted, 5)])
      assert p.status == :aborted
    end

    test "a stream with no run_finished stays running" do
      p = fold([started(), ev(StageStarted, stage: :build)])
      assert p.status == :running
      assert [%{name: "build", status: :running}] = p.stages
      assert p.finished_at == nil
    end
  end

  describe "fold/1 of a matrix stage" do
    setup do
      combo_a = [os: "linux", otp: "27"]
      combo_b = [os: "mac", otp: "27"]

      for_combo = fn combo, status ->
        [
          ev(MatrixRunStarted, stage: :compat, combination: combo),
          ev(StepStarted, stage: :compat, step: :unit, matrix_combination: combo),
          ev(StepOutputLine,
            stage: :compat,
            step: :unit,
            line: "in #{combo[:os]}",
            matrix_combination: combo
          ),
          ev(StepCompleted,
            stage: :compat,
            step: :unit,
            status: status,
            duration_ms: 5,
            matrix_combination: combo
          ),
          ev(MatrixRunCompleted,
            stage: :compat,
            combination: combo,
            status: status,
            duration_ms: 7
          )
        ]
      end

      events =
        [started(), ev(StageStarted, stage: :compat)] ++
          for_combo.(combo_a, :passed) ++
          for_combo.(combo_b, :failed) ++
          [
            ev(StageCompleted, stage: :compat, status: :failed, duration_ms: 20),
            finished(:failed)
          ]

      {:ok, stage: hd(fold(events).stages)}
    end

    test "has one matrix run per combination with its status", %{stage: stage} do
      assert [
               %{combination: %{"os" => "linux", "otp" => "27"}, status: :passed, duration_ms: 7},
               %{combination: %{"os" => "mac", "otp" => "27"}, status: :failed}
             ] = stage.matrix_runs
    end

    test "attributes each step to its own combination, not the stage", %{stage: stage} do
      assert stage.steps == []
      [linux, mac] = stage.matrix_runs
      assert [%{name: "unit", status: :passed, output: "in linux"}] = linux.steps
      assert [%{name: "unit", status: :failed, output: "in mac"}] = mac.steps
    end
  end

  describe "fold/1 step details" do
    test "retries set attempts to the latest attempt number" do
      events = [
        started(),
        ev(StageStarted, stage: :t),
        ev(StepStarted, stage: :t, step: :flaky),
        ev(StepRetrying, stage: :t, step: :flaky, attempt: 2),
        ev(StepRetrying, stage: :t, step: :flaky, attempt: 3),
        ev(StepCompleted, stage: :t, step: :flaky, status: :passed, duration_ms: 3)
      ]

      assert [%{attempts: 3}] = hd(fold(events).stages).steps
    end

    test "a finished step's output is the exact captured text" do
      events = [
        started(),
        ev(StageStarted, stage: :t),
        ev(StepStarted, stage: :t, step: :a),
        ev(StepOutputLine, stage: :t, step: :a, line: "one"),
        ev(StepOutputLine, stage: :t, step: :a, line: "two"),
        ev(StepCompleted,
          stage: :t,
          step: :a,
          status: :passed,
          duration_ms: 1,
          output: "one\n\ntwo\n"
        )
      ]

      assert [%{output: "one\n\ntwo\n"}] = hd(fold(events).stages).steps
    end

    test "while a step runs, its output is built from the line events" do
      events = [
        started(),
        ev(StageStarted, stage: :t),
        ev(StepStarted, stage: :t, step: :a),
        ev(StepOutputLine, stage: :t, step: :a, line: "one"),
        ev(StepOutputLine, stage: :t, step: :a, line: "two")
      ]

      assert [%{status: :running, output: "one\ntwo"}] = hd(fold(events).stages).steps
    end

    test "a cache lookup records hit or miss" do
      events = [
        started(),
        ev(StageStarted, stage: :t),
        ev(StepStarted, stage: :t, step: :deps),
        ev(CacheLookup, stage: :t, step: :deps, key: "k", result: :hit),
        ev(StepCompleted, stage: :t, step: :deps, status: :passed, duration_ms: 0)
      ]

      assert [%{cache: :hit}] = hd(fold(events).stages).steps
    end

    test "a tolerated failure keeps its allowed_failure flag" do
      events = [
        started(),
        ev(StageStarted, stage: :t),
        ev(StepStarted, stage: :t, step: :flaky),
        ev(StepCompleted,
          stage: :t,
          step: :flaky,
          status: :failed,
          duration_ms: 1,
          allowed_failure: true
        )
      ]

      assert [%{status: :failed, allowed_failure: true}] = hd(fold(events).stages).steps
    end

    test "a step skipped by its condition appears even though it never started" do
      events = [
        started(),
        ev(StageStarted, stage: :t),
        ev(StepSkipped, stage: :t, step: :maybe, reason: "condition not met")
      ]

      assert [%{name: "maybe", status: :skipped, duration_ms: 0}] = hd(fold(events).stages).steps
    end

    test "a skipped stage records the reason" do
      events = [
        started(),
        ev(StageStarted, stage: :deploy),
        ev(StageSkipped, stage: :deploy, reason: "dependency failed")
      ]

      assert [%{name: "deploy", status: :skipped, reason: "dependency failed", duration_ms: 0}] =
               fold(events).stages
    end
  end

  describe "fold/1 execution control" do
    test "records a pause once, merging in how it was released" do
      events = [
        started(),
        ev(BreakpointHit,
          pause_id: "p1",
          phase: :before,
          scope: :step,
          stage: :deploy,
          step: :push,
          breakpoint: "before:deploy.push"
        ),
        ev(RunDiverged, reason: :set_store, stage: :deploy, step: :push, detail: "x = 1"),
        ev(BreakpointResumed, pause_id: "p1", command: :continue, waited_ms: 40)
      ]

      p = fold(events)

      assert p.divergent?
      assert [pause] = p.breakpoints

      assert %{
               "pause_id" => "p1",
               "phase" => "before",
               "stage" => "deploy",
               "step" => "push",
               "command" => "continue",
               "waited_ms" => 40,
               "timed_out" => false
             } = pause
    end

    test "a run without control events is not divergent" do
      refute fold([started(), finished(:passed)]).divergent?
    end
  end

  describe "fold/1 forward compatibility" do
    test "ignores unknown types, hook events, and non-map input" do
      known = wire([started(), finished(:passed)])
      unknown = [%{"type" => "from_the_future", "seq" => 99}, :junk, "line", nil]
      hook = wire([ev(HookStarted, hook: :on_success)])

      p = Projection.fold(known ++ unknown ++ hook)

      assert p.status == :passed
      assert p.last_seq == 99
    end

    test "tolerates a schema 2 stream that has no git identity or allowed_failure" do
      events =
        [
          %{
            "type" => "run_started",
            "seq" => 1,
            "run_id" => "r",
            "ts" => @iso,
            "pipeline_name" => "p",
            "schema_version" => 2
          },
          %{"type" => "stage_started", "seq" => 2, "stage" => "t"},
          %{"type" => "step_started", "seq" => 3, "stage" => "t", "step" => "a"},
          %{
            "type" => "step_finished",
            "seq" => 4,
            "stage" => "t",
            "step" => "a",
            "status" => "passed",
            "duration_ms" => 1
          }
        ]

      p = Projection.fold(events)

      assert p.branch == nil
      assert [%{steps: [%{allowed_failure: false, status: :passed}]}] = p.stages
    end

    test "an unrecognised status decodes to :unknown, never a new atom" do
      events = [started(), ev(StageStarted, stage: :t)] |> wire()

      events =
        events ++
          [
            %{
              "type" => "stage_finished",
              "seq" => 9,
              "stage" => "t",
              "status" => "exploded",
              "duration_ms" => 1
            }
          ]

      assert [%{status: :unknown}] = Projection.fold(events).stages
    end
  end

  describe "finalize/1" do
    test "marks an unfinished run and everything still running as interrupted" do
      p =
        fold([
          started(),
          ev(StageStarted, stage: :t),
          ev(StepStarted, stage: :t, step: :a)
        ])
        |> Projection.finalize()

      assert p.status == :interrupted
      assert [%{status: :interrupted, steps: [%{status: :interrupted}]}] = p.stages
    end

    test "leaves a finished run untouched" do
      p = fold([started(), finished(:passed)])
      assert Projection.finalize(p) == p
    end
  end

  describe "to_json/1 and from_json/1" do
    setup do
      events =
        [started(branch: "main", commit: "abc", root: "/w")] ++
          stage(:build, :passed, 30, [
            step(:build, :compile, :passed, 12, ["one", "two"]),
            [
              ev(StepStarted, stage: :build, step: :flaky),
              ev(StepRetrying, stage: :build, step: :flaky, attempt: 2),
              ev(CacheLookup, stage: :build, step: :flaky, key: "k", result: :miss),
              ev(StepCompleted,
                stage: :build,
                step: :flaky,
                status: :failed,
                duration_ms: 3,
                allowed_failure: true
              )
            ]
          ]) ++
          [
            ev(StageStarted, stage: :compat),
            ev(MatrixRunStarted, stage: :compat, combination: [v: "a"]),
            ev(MatrixRunCompleted,
              stage: :compat,
              combination: [v: "a"],
              status: :passed,
              duration_ms: 2
            ),
            ev(StageCompleted, stage: :compat, status: :passed, duration_ms: 2),
            ev(BreakpointHit, pause_id: "p", phase: :after, scope: :stage, stage: :build),
            ev(RunDiverged, reason: :skip),
            finished(:passed)
          ]

      {:ok, projection: fold(events)}
    end

    test "round-trips through JSON", %{projection: p} do
      decoded = p |> Projection.to_json() |> Jason.encode!() |> Jason.decode!()
      assert Projection.from_json(decoded) == p
    end

    test "renders the status as a string and output as one string", %{projection: p} do
      json = Projection.to_json(p)
      assert json["status"] == "passed"
      assert json["divergent"] == true
      assert [%{"steps" => [%{"output" => "one\ntwo"} | _]} | _] = json["stages"]
    end

    test "a missing key decodes to its default" do
      p = Projection.from_json(%{"run_id" => "r"})

      assert %Projection{run_id: "r", stages: [], breakpoints: [], last_seq: 0, status: :running} =
               p
    end
  end

  describe "to_stage_results/1" do
    test "feeds the console reporter, including markers and matrix runs" do
      events =
        [started()] ++
          stage(:build, :passed, 30, [
            step(:build, :compile, :passed, 12),
            [
              ev(StepStarted, stage: :build, step: :flaky),
              ev(StepCompleted,
                stage: :build,
                step: :flaky,
                status: :failed,
                duration_ms: 3,
                allowed_failure: true
              )
            ]
          ]) ++
          [
            ev(StageStarted, stage: :compat),
            ev(MatrixRunStarted, stage: :compat, combination: [v: "a"]),
            ev(StepStarted, stage: :compat, step: :unit, matrix_combination: [v: "a"]),
            ev(StepCompleted,
              stage: :compat,
              step: :unit,
              status: :passed,
              duration_ms: 1,
              matrix_combination: [v: "a"]
            ),
            ev(MatrixRunCompleted,
              stage: :compat,
              combination: [v: "a"],
              status: :passed,
              duration_ms: 2
            ),
            ev(StageCompleted, stage: :compat, status: :passed, duration_ms: 2),
            finished(:passed)
          ]

      out =
        capture_io(fn ->
          events |> fold() |> Projection.to_stage_results() |> Reporter.print_summary()
        end)

      assert out =~ "build"
      assert out =~ "compile"
      assert out =~ "(allowed failure)"
      assert out =~ "[v=a]"
      assert out =~ "unit"
    end

    test "a stage that never finished is reported as aborted, not a crash" do
      p = [started(), ev(StageStarted, stage: :t)] |> fold() |> Projection.finalize()

      out = capture_io(fn -> p |> Projection.to_stage_results() |> Reporter.print_summary() end)

      assert out =~ "aborted"
    end
  end

  describe "parity with Results.to_json/3 for a real run" do
    @silent [listener: TinyCI.Listener.Silent, output: :buffered, record: false]

    defp key_paths(map, prefix \\ [])

    defp key_paths(map, prefix) when is_map(map) do
      Enum.flat_map(map, fn {key, value} ->
        path = prefix ++ [key]
        [path | key_paths(value, path)]
      end)
    end

    defp key_paths(list, prefix) when is_list(list),
      do: Enum.flat_map(list, &key_paths(&1, prefix))

    defp key_paths(_scalar, _prefix), do: []

    defp run(stages) do
      opts = @silent ++ [extra_sinks: [{TinyCI.TestSink, pid: self()}]]

      {status, stage_results} =
        case Executor.run_pipeline(stages, nil, opts) do
          {:ok, results} -> {:ok, results}
          {:error, reason, results} -> {{:error, reason}, results}
        end

      {drain([]), status, stage_results}
    end

    defp drain(acc) do
      receive do
        {:event, event} -> drain([event | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    defp fixture_stages do
      [
        %Stage{
          name: :prep,
          mode: :serial,
          steps: [
            %Step{name: :hello, cmd: "echo hi"},
            %Step{name: :flaky, cmd: "false", allow_failure: true},
            %Step{name: :retried, cmd: "false", retry: 1, allow_failure: true}
          ]
        },
        %Stage{
          name: :par,
          mode: :parallel,
          steps: [%Step{name: :a, cmd: "echo a"}, %Step{name: :b, cmd: "echo b"}]
        },
        %Stage{
          name: :compat,
          mode: :serial,
          matrix: [v: ["x", "y"]],
          steps: [%Step{name: :say, cmd: "echo $V"}]
        },
        %Stage{
          name: :never,
          mode: :serial,
          steps: [%Step{name: :n, cmd: "true"}],
          when_condition: fn _ -> false end
        }
      ]
    end

    test "to_json/1 carries every key Results.to_json/3 does" do
      {events, status, stage_results} = run(fixture_stages())

      oracle = status |> Results.to_json(stage_results, 1) |> Jason.decode!()
      projection = events |> wire() |> Projection.fold() |> Projection.to_json()

      missing =
        MapSet.difference(MapSet.new(key_paths(oracle)), MapSet.new(key_paths(projection)))

      assert MapSet.size(missing) == 0, "projection lacks: #{inspect(MapSet.to_list(missing))}"
    end

    test "statuses, attempts and allowed_failure match the run's own results" do
      {events, status, stage_results} = run(fixture_stages())

      oracle = status |> Results.to_json(stage_results, 1) |> Jason.decode!()
      projection = events |> wire() |> Projection.fold() |> Projection.to_json()

      assert projection["status"] == oracle["status"]

      # Parallel steps and matrix combinations start concurrently, so event arrival
      # order is not definition order; compare as sets.
      pick = fn stages ->
        for stage <- stages do
          {stage["name"], stage["status"],
           Enum.sort(
             for(
               s <- stage["steps"],
               do: {s["name"], s["status"], s["attempts"], s["allowed_failure"]}
             )
           ),
           Enum.sort(
             for(
               m <- stage["matrix_runs"],
               do:
                 {m["combination"], m["status"],
                  for(s <- m["steps"], do: {s["name"], s["status"], s["attempts"]})}
             )
           )}
        end
      end

      assert pick.(projection["stages"]) == pick.(oracle["stages"])
    end

    test "step output matches the run's own results exactly" do
      {events, status, stage_results} = run(fixture_stages())

      oracle = status |> Results.to_json(stage_results, 1) |> Jason.decode!()
      projection = events |> wire() |> Projection.fold() |> Projection.to_json()

      # Parallel steps arrive in start order, so compare as sets.
      outputs = fn json ->
        for stage <- json["stages"], step <- stage["steps"], do: {step["name"], step["output"]}
      end

      assert Enum.sort(outputs.(projection)) == Enum.sort(outputs.(oracle))
      assert {"hello", "hi\n"} in outputs.(projection)
    end

    test "a failing run reports failed and the failing stage" do
      stages = [%Stage{name: :t, mode: :serial, steps: [%Step{name: :bad, cmd: "false"}]}]
      {events, status, _results} = run(stages)

      assert {:error, _} = status
      p = events |> wire() |> Projection.fold()

      assert p.status == :failed
      assert [%{name: "t", status: :failed}] = p.stages
    end
  end
end
