defmodule TinyCI.ControlIntegrationTest do
  @moduledoc """
  End-to-end execution control against real runs.

  Every test drives the run through `TinyCI.Control`'s subscribe/resume protocol —
  the same seam the terminal REPL, and later the DAP adapter, use. Nothing here
  reaches into executor internals, which is the point: if these pass, a transport
  wired to the same protocol works too.
  """

  use ExUnit.Case, async: true

  alias TinyCI.Control.Session
  alias TinyCI.{Context, Executor, Listener, Stage, StageResult, Step, StepResult}

  # Collects the run's events so we can assert on the stream, not on return values.
  defmodule Collector do
    @behaviour TinyCI.EventSink

    @impl true
    def init(opts), do: {:ok, Keyword.fetch!(opts, :test)}

    @impl true
    def handle_event(seq, event, test) do
      send(test, {:event, seq, event})
      {:ok, test}
    end

    @impl true
    def close(_test), do: :ok
  end

  defp context(overrides \\ []) do
    Context.build(
      Keyword.merge(
        [branch: "main", commit: String.duplicate("a", 40), root: File.cwd!()],
        overrides
      )
    )
  end

  # Starts a run in a task with breakpoints armed and this process subscribed.
  # `subscribers:` rather than `subscribe/1` because the control server does not
  # exist until the run begins — subscribing after the fact would race the first
  # breakpoint.
  defp run(stages, breaks, opts \\ []) do
    control =
      [breakpoints: breaks, subscribers: [self()]]
      |> Keyword.merge(Keyword.get(opts, :control, []))

    run_opts =
      [
        output: :buffered,
        listener: Listener.Silent,
        control: control,
        extra_sinks: [{Collector, test: self()}]
      ]
      |> Keyword.merge(Keyword.drop(opts, [:control, :context]))

    context = Keyword.get(opts, :context) || context()

    Task.async(fn -> Executor.run_pipeline(stages, context, run_opts) end)
  end

  defp await_pause do
    assert_receive {:tiny_ci_control, :breakpoint_hit, %Session{} = session}, 2_000
    session
  end

  defp command(session, command) do
    assert :ok = TinyCI.Control.resume(session.run_id, session.pause_id, command)
  end

  defp edit(session, key, value) do
    assert {:ok, :applied} =
             TinyCI.Control.resume(session.run_id, session.pause_id, {:set_store, key, value})
  end

  defp marker_action(module, value) do
    Module.create(
      module,
      quote do
        @behaviour TinyCI.Action
        def execute(_config, ctx), do: {:ok, %{seen: Map.get(ctx.store, :tag, unquote(value))}}
      end,
      Macro.Env.location(__ENV__)
    )

    module
  end

  # ---------------------------------------------------------------------------

  describe "no breakpoints armed" do
    test "the context carries no control plane and no control events appear" do
      stages = [%Stage{name: :test, mode: :serial, steps: [%Step{name: :one, cmd: "true"}]}]

      {:ok, [result]} =
        Executor.run_pipeline(stages, context(),
          output: :buffered,
          listener: Listener.Silent,
          extra_sinks: [{Collector, test: self()}]
        )

      assert result.status == :passed

      events = drain_events()
      assert Enum.any?(events, &match?(%TinyCI.Events.StepCompleted{}, &1))
      refute Enum.any?(events, &match?(%TinyCI.Events.BreakpointHit{}, &1))
      refute Enum.any?(events, &match?(%TinyCI.Events.BreakpointResumed{}, &1))
      refute Enum.any?(events, &match?(%TinyCI.Events.RunDiverged{}, &1))
    end

    test "an unarmed run registers no control plane at all" do
      stages = [%Stage{name: :test, mode: :serial, steps: [%Step{name: :one, cmd: "true"}]}]

      Executor.run_pipeline(stages, context(),
        output: :buffered,
        listener: Listener.Silent,
        extra_sinks: [{Collector, test: self()}]
      )

      run_id = find_event(drain_events(), TinyCI.Events.PipelineStarted).run_id
      refute TinyCI.Control.armed?(run_id)
    end
  end

  describe "addressing a live run" do
    test "an armed run is reachable by run_id, so any transport can drive it" do
      stages = [%Stage{name: :test, mode: :serial, steps: [%Step{name: :one, cmd: "true"}]}]

      task = run(stages, ["before:test.one"])
      session = await_pause()

      # This is the whole basis of the transport-agnostic surface: a process that
      # knows only the run id can inspect and release the pause.
      assert TinyCI.Control.armed?(session.run_id)
      assert [%Session{pause_id: pause_id}] = TinyCI.Control.paused(session.run_id)
      assert pause_id == session.pause_id
      refute TinyCI.Control.divergent?(session.run_id)

      command(session, :continue)
      Task.await(task, 5_000)
    end

    test "a late subscriber can attach to a run already in flight" do
      stages = [
        %Stage{
          name: :test,
          mode: :serial,
          steps: [
            %Step{name: :one, cmd: "true"},
            %Step{name: :two, cmd: "true"}
          ]
        }
      ]

      task = run(stages, ["before:test.one", "before:test.two"])
      first = await_pause()

      # A driver that shows up mid-run — a DAP adapter attaching, say — sees every
      # boundary from that point on.
      test = self()

      relay =
        spawn_link(fn ->
          receive do
            {:tiny_ci_control, :breakpoint_hit, s} -> send(test, {:relayed, s.step})
          end
        end)

      assert :ok = TinyCI.Control.subscribe(first.run_id, relay)

      command(first, :continue)
      second = await_pause()

      assert_receive {:relayed, :two}, 2_000
      assert second.step == :two

      command(second, :continue)
      Task.await(task, 5_000)
    end

    test "reports not_found once the run is over" do
      stages = [%Stage{name: :test, mode: :serial, steps: [%Step{name: :one, cmd: "true"}]}]

      task = run(stages, ["before:test.one"])
      session = await_pause()
      command(session, :continue)
      Task.await(task, 5_000)

      refute TinyCI.Control.armed?(session.run_id)

      assert TinyCI.Control.resume(session.run_id, session.pause_id, :continue) ==
               {:error, :not_found}
    end
  end

  describe "before:step" do
    test "pauses before the step runs and continue lets it run" do
      path = tmp_path()

      stages = [
        %Stage{
          name: :test,
          mode: :serial,
          steps: [%Step{name: :touch, cmd: "touch #{path}"}]
        }
      ]

      task = run(stages, ["before:test.touch"])
      session = await_pause()

      # The proof it really paused: the side effect has not happened yet.
      refute File.exists?(path)
      assert session.phase == :before
      assert session.scope == :step
      assert session.stage == :test
      assert session.step == :touch

      command(session, :continue)

      assert {:ok, [%StageResult{status: :passed}]} = Task.await(task, 5_000)
      assert File.exists?(path)
    end

    test "skip prevents the body from running and records the step as skipped" do
      path = tmp_path()

      stages = [
        %Stage{name: :test, mode: :serial, steps: [%Step{name: :touch, cmd: "touch #{path}"}]}
      ]

      task = run(stages, ["before:test.touch"])
      command(await_pause(), :skip)

      assert {:ok, [%StageResult{status: :passed, step_results: [step]}]} =
               Task.await(task, 5_000)

      assert %StepResult{name: :touch, status: :skipped} = step
      refute File.exists?(path)

      events = drain_events()

      assert Enum.any?(events, fn
               %TinyCI.Events.StepSkipped{reason: reason} ->
                 reason == "skipped by execution control"

               _ ->
                 false
             end)
    end

    test "abort stops the run and reports :aborted, not :failed" do
      stages = [
        %Stage{name: :test, mode: :serial, steps: [%Step{name: :one, cmd: "true"}]},
        %Stage{name: :deploy, mode: :serial, steps: [%Step{name: :push, cmd: "true"}]}
      ]

      task = run(stages, ["before:test.one"])
      command(await_pause(), :abort)

      assert {:error, {:aborted, :test}, [%StageResult{name: :test, status: :aborted}]} =
               Task.await(task, 5_000)
    end

    test "the payload exposes resolved env, working dir, store, and git context" do
      stages = [
        %Stage{
          name: :test,
          mode: :serial,
          env: %{"STAGE_VAR" => "stage"},
          steps: [%Step{name: :one, cmd: "true", env: %{"STEP_VAR" => {:store, :seed}}}]
        }
      ]

      ctx = context(pipeline_env: %{"PIPE_VAR" => "pipe"}, store: %{seed: "s3ed"})
      task = run(stages, ["before:test.one"], context: ctx)
      session = await_pause()

      assert session.env["PIPE_VAR"] == "pipe"
      assert session.env["STAGE_VAR"] == "stage"
      assert session.env["STEP_VAR"] == "s3ed"
      assert session.store == %{"seed" => "s3ed"}
      assert session.branch == "main"
      assert session.commit == String.duplicate("a", 40)
      assert session.working_dir == File.cwd!()

      command(session, :continue)
      Task.await(task, 5_000)
    end

    test "emits breakpoint_hit then breakpoint_resumed into the event stream" do
      stages = [%Stage{name: :test, mode: :serial, steps: [%Step{name: :one, cmd: "true"}]}]

      task = run(stages, ["before:test.one"])
      session = await_pause()
      command(session, :continue)
      Task.await(task, 5_000)

      events = drain_events()

      assert %TinyCI.Events.BreakpointHit{} =
               hit = find_event(events, TinyCI.Events.BreakpointHit)

      assert hit.pause_id == session.pause_id
      assert hit.breakpoint == "before:test.one"
      assert hit.phase == :before

      assert %TinyCI.Events.BreakpointResumed{command: :continue} =
               resumed = find_event(events, TinyCI.Events.BreakpointResumed)

      assert resumed.pause_id == session.pause_id
    end
  end

  describe "after:step" do
    test "sees the step's result and can keep it" do
      stages = [%Stage{name: :test, mode: :serial, steps: [%Step{name: :one, cmd: "false"}]}]

      task = run(stages, ["after:test.one"])
      session = await_pause()

      assert session.phase == :after
      assert session.result["status"] == "failed"

      command(session, :continue)

      assert {:error, {:stage_failed, :test, :failed}, _} = Task.await(task, 5_000)
    end

    test "skip converts a failure into a skip, rescuing the stage" do
      stages = [%Stage{name: :test, mode: :serial, steps: [%Step{name: :one, cmd: "false"}]}]

      task = run(stages, ["after:test.one"])
      command(await_pause(), :skip)

      assert {:ok, [%StageResult{status: :passed, step_results: [%{status: :skipped}]}]} =
               Task.await(task, 5_000)
    end

    test "retry re-runs the body, bypassing the cache" do
      path = tmp_path()

      stages = [
        %Stage{
          name: :test,
          mode: :serial,
          steps: [%Step{name: :append, cmd: "echo x >> #{path}"}]
        }
      ]

      task = run(stages, ["after:test.append"])

      command(await_pause(), :retry)
      # The breakpoint re-arms, so the second pass pauses again.
      command(await_pause(), :continue)

      assert {:ok, [%StageResult{status: :passed}]} = Task.await(task, 5_000)
      assert File.read!(path) |> String.split("\n", trim: true) |> length() == 2
    end

    test "retry marks the run divergent" do
      stages = [%Stage{name: :test, mode: :serial, steps: [%Step{name: :one, cmd: "true"}]}]

      task = run(stages, ["after:test.one"])
      command(await_pause(), :retry)
      command(await_pause(), :continue)
      Task.await(task, 5_000)

      assert %TinyCI.Events.RunDiverged{reason: :retry} =
               find_event(drain_events(), TinyCI.Events.RunDiverged)
    end

    test "the payload's store already includes the step's own store delta" do
      module = marker_action(ControlIntegrationAfterStore, "from_action")

      stages = [
        %Stage{name: :test, mode: :serial, steps: [%Step{name: :act, module: module}]}
      ]

      task = run(stages, ["after:test.act"])
      session = await_pause()

      assert session.store["seen"] == "from_action"

      command(session, :continue)
      Task.await(task, 5_000)
    end
  end

  describe "set_store" do
    test "an edited value reaches the next step in the same stage" do
      module = marker_action(ControlIntegrationSetStore, "original")

      stages = [
        %Stage{
          name: :test,
          mode: :serial,
          steps: [
            %Step{name: :first, cmd: "true"},
            %Step{name: :second, module: module}
          ]
        }
      ]

      task = run(stages, ["after:test.first"])
      session = await_pause()
      edit(session, :tag, "edited")
      command(session, :continue)

      assert {:ok, [%StageResult{store: store}]} = Task.await(task, 5_000)
      assert store[:tag] == "edited"
      assert store[:seen] == "edited"
    end

    test "an edited value reaches the next stage" do
      stages = [
        %Stage{name: :first, mode: :serial, steps: [%Step{name: :one, cmd: "true"}]},
        %Stage{name: :second, mode: :serial, steps: [%Step{name: :two, cmd: "true"}]}
      ]

      task = run(stages, ["after:first.one", "before:second.two"])

      first = await_pause()
      edit(first, :handoff, "carried")
      command(first, :continue)

      second = await_pause()
      assert second.store["handoff"] == "carried"
      command(second, :continue)

      Task.await(task, 5_000)
    end

    test "an edit made in a parallel step still propagates out of that branch" do
      stages = [
        %Stage{
          name: :test,
          mode: :parallel,
          steps: [
            %Step{name: :a, cmd: "true"},
            %Step{name: :b, cmd: "true"}
          ]
        }
      ]

      task = run(stages, ["after:test.a"])
      session = await_pause()
      edit(session, :from_branch, "yes")
      command(session, :continue)

      assert {:ok, [%StageResult{store: store}]} = Task.await(task, 5_000)
      assert store[:from_branch] == "yes"
    end

    test "leaves the run paused so several keys can be edited before resuming" do
      stages = [%Stage{name: :test, mode: :serial, steps: [%Step{name: :one, cmd: "true"}]}]

      task = run(stages, ["before:test.one"])
      session = await_pause()

      edit(session, :a, "1")
      edit(session, :b, "2")
      command(session, :continue)

      assert {:ok, [%StageResult{store: store}]} = Task.await(task, 5_000)
      assert store[:a] == "1"
      assert store[:b] == "2"
    end

    test "marks the run divergent with the key that changed" do
      stages = [%Stage{name: :test, mode: :serial, steps: [%Step{name: :one, cmd: "true"}]}]

      task = run(stages, ["before:test.one"])
      session = await_pause()
      edit(session, :tag, "v2")
      command(session, :continue)
      Task.await(task, 5_000)

      assert %TinyCI.Events.RunDiverged{reason: :set_store, detail: detail} =
               find_event(drain_events(), TinyCI.Events.RunDiverged)

      assert detail == ~s(tag = "v2")
    end
  end

  describe "stage boundaries" do
    test "before:stage pauses ahead of every step in the stage" do
      path = tmp_path()

      stages = [
        %Stage{
          name: :deploy,
          mode: :serial,
          steps: [%Step{name: :push, cmd: "touch #{path}"}]
        }
      ]

      task = run(stages, ["before:deploy"])
      session = await_pause()

      assert session.scope == :stage
      assert session.step == nil
      refute File.exists?(path)

      command(session, :continue)
      Task.await(task, 5_000)
      assert File.exists?(path)
    end

    test "skip at before:stage runs none of its steps" do
      path = tmp_path()

      stages = [
        %Stage{name: :deploy, mode: :serial, steps: [%Step{name: :push, cmd: "touch #{path}"}]}
      ]

      task = run(stages, ["before:deploy"])
      command(await_pause(), :skip)

      assert {:ok, [%StageResult{name: :deploy, status: :skipped, step_results: []}]} =
               Task.await(task, 5_000)

      refute File.exists?(path)
    end

    test "after:stage sees the store the stage produced" do
      module = marker_action(ControlIntegrationStageStore, "produced")

      stages = [%Stage{name: :test, mode: :serial, steps: [%Step{name: :act, module: module}]}]

      task = run(stages, ["after:test"])
      session = await_pause()

      assert session.result["status"] == "passed"
      assert session.store["seen"] == "produced"

      command(session, :continue)
      Task.await(task, 5_000)
    end

    test "an edit at after:stage lands on the stage's store" do
      stages = [%Stage{name: :test, mode: :serial, steps: [%Step{name: :one, cmd: "true"}]}]

      task = run(stages, ["after:test"])
      session = await_pause()
      edit(session, :late, "edit")
      command(session, :continue)

      assert {:ok, [%StageResult{store: store}]} = Task.await(task, 5_000)
      assert store[:late] == "edit"
    end

    test "retry at after:stage re-runs the whole stage" do
      path = tmp_path()

      stages = [
        %Stage{name: :test, mode: :serial, steps: [%Step{name: :one, cmd: "echo x >> #{path}"}]}
      ]

      task = run(stages, ["after:test"])
      command(await_pause(), :retry)
      command(await_pause(), :continue)

      assert {:ok, [%StageResult{status: :passed}]} = Task.await(task, 5_000)
      assert File.read!(path) |> String.split("\n", trim: true) |> length() == 2
    end
  end

  describe "parallelism" do
    test "pausing one DAG branch does not freeze an independent branch" do
      marker = tmp_path()

      # `needs:` switches the executor into DAG mode; :paused and :independent both
      # depend only on :root, so they occupy the same level and run concurrently.
      stages = [
        %Stage{name: :root, mode: :serial, steps: [%Step{name: :noop, cmd: "true"}]},
        %Stage{
          name: :paused,
          needs: [:root],
          mode: :serial,
          steps: [%Step{name: :wait, cmd: "true"}]
        },
        %Stage{
          name: :independent,
          needs: [:root],
          mode: :serial,
          steps: [%Step{name: :work, cmd: "touch #{marker}"}]
        }
      ]

      task = run(stages, ["before:paused.wait"])
      session = await_pause()

      # While :paused is parked at its breakpoint, :independent must reach completion
      # entirely on its own.
      assert eventually(fn -> File.exists?(marker) end),
             "independent branch did not progress while a sibling was paused"

      command(session, :continue)
      assert {:ok, results} = Task.await(task, 5_000)
      assert Enum.all?(results, &(&1.status == :passed))
    end

    test "a paused parallel step does not block its siblings in the same stage" do
      marker = tmp_path()

      stages = [
        %Stage{
          name: :test,
          mode: :parallel,
          steps: [
            %Step{name: :paused, cmd: "true"},
            %Step{name: :sibling, cmd: "touch #{marker}"}
          ]
        }
      ]

      task = run(stages, ["before:test.paused"])
      session = await_pause()

      assert eventually(fn -> File.exists?(marker) end),
             "sibling step did not run while another step was paused"

      command(session, :continue)
      assert {:ok, [%StageResult{status: :passed}]} = Task.await(task, 5_000)
    end

    test "abort in one branch unblocks the others rather than deadlocking" do
      stages = [
        %Stage{
          name: :test,
          mode: :parallel,
          steps: [
            %Step{name: :a, cmd: "true"},
            %Step{name: :b, cmd: "true"}
          ]
        }
      ]

      task = run(stages, ["before:test.a", "before:test.b"])

      first = await_pause()
      second = await_pause()
      refute first.pause_id == second.pause_id

      command(first, :abort)

      assert {:error, {:aborted, :test}, [%StageResult{status: :aborted}]} =
               Task.await(task, 5_000)
    end
  end

  describe "matrix stages" do
    test "the payload names the combination that paused" do
      stages = [
        %Stage{
          name: :compat,
          mode: :serial,
          matrix: [elixir: ["1.18"], otp: ["27"]],
          steps: [%Step{name: :one, cmd: "true"}]
        }
      ]

      task = run(stages, ["before:compat.one"])
      session = await_pause()

      assert session.matrix_combination == [elixir: "1.18", otp: "27"]
      assert session.store["elixir"] == "1.18"

      command(session, :continue)
      assert {:ok, [%StageResult{status: :passed}]} = Task.await(task, 5_000)
    end

    test "each combination hits the breakpoint independently" do
      stages = [
        %Stage{
          name: :compat,
          mode: :serial,
          matrix: [elixir: ["1.17", "1.18"]],
          steps: [%Step{name: :one, cmd: "true"}]
        }
      ]

      task = run(stages, ["before:compat.one"])

      combos =
        for _ <- 1..2 do
          session = await_pause()
          command(session, :continue)
          session.matrix_combination[:elixir]
        end

      assert Enum.sort(combos) == ["1.17", "1.18"]
      assert {:ok, [%StageResult{status: :passed}]} = Task.await(task, 5_000)
    end
  end

  describe "--debug-serial" do
    test "runs a parallel stage's steps in declaration order" do
      order = tmp_path()

      stages = [
        %Stage{
          name: :test,
          mode: :parallel,
          steps: [
            %Step{name: :a, cmd: "echo a >> #{order}"},
            %Step{name: :b, cmd: "echo b >> #{order}"},
            %Step{name: :c, cmd: "echo c >> #{order}"}
          ]
        }
      ]

      task = run(stages, ["before:test.a"], control: [serial: true])
      command(await_pause(), :continue)

      assert {:ok, [%StageResult{status: :passed}]} = Task.await(task, 5_000)
      assert String.split(File.read!(order), "\n", trim: true) == ["a", "b", "c"]
    end

    test "only one boundary is paused at a time" do
      stages = [
        %Stage{
          name: :test,
          mode: :parallel,
          steps: [
            %Step{name: :a, cmd: "true"},
            %Step{name: :b, cmd: "true"}
          ]
        }
      ]

      task = run(stages, ["before:test.a", "before:test.b"], control: [serial: true])

      first = await_pause()
      assert first.step == :a
      # :b cannot have paused yet — serial scheduling has not started it.
      refute_receive {:tiny_ci_control, :breakpoint_hit, _}, 100

      command(first, :continue)
      second = await_pause()
      assert second.step == :b
      command(second, :continue)

      assert {:ok, [%StageResult{status: :passed}]} = Task.await(task, 5_000)
    end
  end

  describe "timeout" do
    test "auto-continues an unanswered breakpoint when configured to" do
      stages = [%Stage{name: :test, mode: :serial, steps: [%Step{name: :one, cmd: "true"}]}]

      task = run(stages, ["before:test.one"], control: [timeout: 40, timeout_action: :continue])

      assert {:ok, [%StageResult{status: :passed}]} = Task.await(task, 5_000)

      assert %TinyCI.Events.BreakpointResumed{timed_out: true, command: :continue} =
               find_event(drain_events(), TinyCI.Events.BreakpointResumed)
    end

    test "aborts an unanswered breakpoint by default, so CI cannot hang" do
      stages = [
        %Stage{name: :test, mode: :serial, steps: [%Step{name: :one, cmd: "true"}]},
        %Stage{name: :deploy, mode: :serial, steps: [%Step{name: :push, cmd: "true"}]}
      ]

      task = run(stages, ["before:test.one"], control: [timeout: 40])

      assert {:error, {:aborted, :test}, _results} = Task.await(task, 5_000)
    end
  end

  describe "invalid arming" do
    test "raises rather than starting a run with an unparsable break spec" do
      stages = [%Stage{name: :test, mode: :serial, steps: [%Step{name: :one, cmd: "true"}]}]

      assert_raise ArgumentError, ~r/invalid control breakpoints/, fn ->
        Executor.run_pipeline(stages, context(),
          output: :buffered,
          listener: Listener.Silent,
          control: [breakpoints: ["during:test"]]
        )
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp tmp_path do
    path =
      Path.join(
        System.tmp_dir!(),
        "tiny_ci_control_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp drain_events(acc \\ []) do
    receive do
      {:event, _seq, event} -> drain_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp find_event(events, module), do: Enum.find(events, &(&1.__struct__ == module))

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end
end
