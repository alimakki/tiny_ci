defmodule TinyCI.Control.ServerTest do
  use ExUnit.Case, async: true

  alias TinyCI.Control.{Breakpoint, Server, Session}
  alias TinyCI.Events.{BreakpointResumed, RunDiverged}

  # A sink that forwards every event to the test process, so we can assert on what
  # the control plane put into the T1 stream.
  defmodule Forwarder do
    @behaviour TinyCI.EventSink

    @impl true
    def init(opts), do: {:ok, Keyword.fetch!(opts, :test)}

    @impl true
    def handle_event(_seq, event, test) do
      send(test, {:event, event})
      {:ok, test}
    end

    @impl true
    def close(_test), do: :ok
  end

  setup do
    run_id = "run_#{System.unique_integer([:positive])}"
    {:ok, dispatcher} = TinyCI.Events.Dispatcher.start_link([{Forwarder, test: self()}])
    {:ok, run_id: run_id, dispatcher: dispatcher}
  end

  defp start_server(ctx, opts \\ []) do
    {:ok, server} =
      Server.start_link(
        Keyword.merge(
          [
            run_id: ctx.run_id,
            dispatcher: ctx.dispatcher,
            breakpoints: [%Breakpoint{phase: :before, stage: :test, step: :unit}],
            subscribers: [self()]
          ],
          opts
        )
      )

    server
  end

  defp session(ctx, overrides \\ %{}) do
    Map.merge(
      %Session{
        pause_id: "pause_#{System.unique_integer([:positive])}",
        run_id: ctx.run_id,
        phase: :before,
        scope: :step,
        stage: :test,
        step: :unit
      },
      overrides
    )
  end

  # Pauses in a separate process (the server must never be the one that blocks) and
  # reports the command that eventually released it.
  defp pause_in_task(server, session) do
    test = self()

    Task.async(fn ->
      :ok = Server.pause(server, session)
      send(test, {:paused, session.pause_id})

      receive do
        {:tiny_ci_control_resume, _id, command, overrides} -> {command, overrides}
      after
        1_000 -> :never_released
      end
    end)
  end

  describe "addressing" do
    test "registers under the run id so any process can reach it", ctx do
      server = start_server(ctx)
      assert Server.whereis(ctx.run_id) == {:ok, server}
    end

    test "reports not_found for a run with no control plane" do
      assert Server.whereis("no_such_run") == {:error, :not_found}
    end

    test "whereis passes a pid straight through", ctx do
      server = start_server(ctx)
      assert Server.whereis(server) == {:ok, server}
    end
  end

  describe "check/2" do
    test "pauses at an armed boundary", ctx do
      server = start_server(ctx)

      assert {:pause, %Breakpoint{stage: :test, step: :unit}} =
               Server.check(server, {:before, :step, :test, :unit})
    end

    test "ignores boundaries nothing is armed for", ctx do
      server = start_server(ctx)

      assert Server.check(server, {:after, :step, :test, :unit}) == :none
      assert Server.check(server, {:before, :step, :test, :other}) == :none
      assert Server.check(server, {:before, :stage, :test, nil}) == :none
    end
  end

  describe "continue" do
    test "releases the waiting process and emits breakpoint_resumed", ctx do
      server = start_server(ctx)
      s = session(ctx)
      task = pause_in_task(server, s)

      assert_receive {:paused, _}
      assert_receive {:tiny_ci_control, :breakpoint_hit, ^s}

      assert :ok = Server.resume(server, s.pause_id, :continue)
      assert {:continue, %{}} = Task.await(task)

      assert_receive {:event, %BreakpointResumed{command: :continue, timed_out: false} = event}
      assert event.pause_id == s.pause_id
      assert event.stage == :test
      assert event.step == :unit
      assert event.waited_ms >= 0
    end

    test "does not mark the run divergent", ctx do
      server = start_server(ctx)
      s = session(ctx)
      task = pause_in_task(server, s)

      assert_receive {:paused, _}
      :ok = Server.resume(server, s.pause_id, :continue)
      Task.await(task)

      refute Server.divergent?(server)
      refute_received {:event, %RunDiverged{}}
    end
  end

  describe "skip and retry" do
    for command <- [:skip, :retry] do
      test "#{command} releases with its own command and marks the run divergent", ctx do
        command = unquote(command)
        server = start_server(ctx)
        s = session(ctx)
        task = pause_in_task(server, s)

        assert_receive {:paused, _}
        assert :ok = Server.resume(server, s.pause_id, command)
        assert {^command, %{}} = Task.await(task)

        assert Server.divergent?(server)
        assert_receive {:event, %RunDiverged{reason: ^command, stage: :test, step: :unit}}
      end
    end
  end

  describe "set_store" do
    test "leaves the session paused and accumulates overrides", ctx do
      server = start_server(ctx)
      s = session(ctx)
      task = pause_in_task(server, s)

      assert_receive {:paused, _}

      assert {:ok, :applied} = Server.resume(server, s.pause_id, {:set_store, :a, "1"})
      assert {:ok, :applied} = Server.resume(server, s.pause_id, {:set_store, :b, "2"})

      # Still paused after both edits.
      assert [%Session{pause_id: pause_id}] = Server.paused(server)
      assert pause_id == s.pause_id

      :ok = Server.resume(server, s.pause_id, :retry)
      assert {:retry, %{a: "1", b: "2"}} = Task.await(task)
    end

    test "marks the run divergent and records what changed", ctx do
      server = start_server(ctx)
      s = session(ctx)
      task = pause_in_task(server, s)

      assert_receive {:paused, _}
      {:ok, :applied} = Server.resume(server, s.pause_id, {:set_store, :tag, "v2"})

      assert Server.divergent?(server)
      assert_receive {:event, %RunDiverged{reason: :set_store, detail: detail}}
      assert detail == ~s(tag = "v2")

      :ok = Server.resume(server, s.pause_id, :continue)
      Task.await(task)
    end

    test "emits one run_diverged per edit, not just the first", ctx do
      server = start_server(ctx)
      s = session(ctx)
      task = pause_in_task(server, s)

      assert_receive {:paused, _}
      {:ok, :applied} = Server.resume(server, s.pause_id, {:set_store, :a, "1"})
      {:ok, :applied} = Server.resume(server, s.pause_id, {:set_store, :b, "2"})

      assert_receive {:event, %RunDiverged{detail: ~s(a = "1")}}
      assert_receive {:event, %RunDiverged{detail: ~s(b = "2")}}

      :ok = Server.resume(server, s.pause_id, :continue)
      Task.await(task)
    end

    test "the last write to a key wins", ctx do
      server = start_server(ctx)
      s = session(ctx)
      task = pause_in_task(server, s)

      assert_receive {:paused, _}
      {:ok, :applied} = Server.resume(server, s.pause_id, {:set_store, :a, "first"})
      {:ok, :applied} = Server.resume(server, s.pause_id, {:set_store, :a, "second"})
      :ok = Server.resume(server, s.pause_id, :continue)

      assert {:continue, %{a: "second"}} = Task.await(task)
    end
  end

  describe "abort" do
    test "releases every paused branch, not only the one commanded", ctx do
      server = start_server(ctx)
      a = session(ctx, %{step: :unit})
      b = session(ctx, %{step: :other})

      task_a = pause_in_task(server, a)
      assert_receive {:paused, _}
      task_b = pause_in_task(server, b)
      assert_receive {:paused, _}

      assert :ok = Server.resume(server, a.pause_id, :abort)

      assert {:abort, %{}} = Task.await(task_a)
      assert {:abort, %{}} = Task.await(task_b)
      assert Server.paused(server) == []
    end

    test "makes every later boundary short-circuit instead of pausing", ctx do
      server = start_server(ctx)
      s = session(ctx)
      task = pause_in_task(server, s)

      assert_receive {:paused, _}
      :ok = Server.resume(server, s.pause_id, :abort)
      Task.await(task)

      assert Server.aborted?(server)
      assert Server.check(server, {:before, :step, :test, :unit}) == :aborted
    end

    test "refuses to pause a boundary reached after the abort", ctx do
      server = start_server(ctx)
      first = session(ctx)
      task = pause_in_task(server, first)

      assert_receive {:paused, _}
      :ok = Server.resume(server, first.pause_id, :abort)
      Task.await(task)

      late = session(ctx)
      assert {:aborted, ^late} = Server.pause(server, late)
    end

    test "is not treated as divergence — nothing was altered, it was stopped", ctx do
      server = start_server(ctx)
      s = session(ctx)
      task = pause_in_task(server, s)

      assert_receive {:paused, _}
      :ok = Server.resume(server, s.pause_id, :abort)
      Task.await(task)

      refute Server.divergent?(server)
    end
  end

  describe "timeout" do
    test "auto-resolves with the configured action and flags the event", ctx do
      server = start_server(ctx, timeout: 30, timeout_action: :continue)
      s = session(ctx)
      task = pause_in_task(server, s)

      assert_receive {:paused, _}
      assert {:continue, %{}} = Task.await(task)

      assert_receive {:event, %BreakpointResumed{command: :continue, timed_out: true}}
    end

    test "aborts by default, so a forgotten breakpoint cannot hang CI", ctx do
      server = start_server(ctx, timeout: 30)
      s = session(ctx)
      task = pause_in_task(server, s)

      assert_receive {:paused, _}
      assert {:abort, %{}} = Task.await(task)
      assert Server.aborted?(server)
    end

    test "an operator resume beats the timer and the timer becomes a no-op", ctx do
      server = start_server(ctx, timeout: 200)
      s = session(ctx)
      task = pause_in_task(server, s)

      assert_receive {:paused, _}
      :ok = Server.resume(server, s.pause_id, :skip)
      assert {:skip, %{}} = Task.await(task)

      # Well past the timer: the session is gone, so nothing further is emitted.
      Process.sleep(250)
      refute Server.aborted?(server)
      refute_received {:event, %BreakpointResumed{timed_out: true}}
    end

    test "waits indefinitely when no timeout is configured", ctx do
      server = start_server(ctx)
      s = session(ctx)
      task = pause_in_task(server, s)

      assert_receive {:paused, _}
      Process.sleep(60)
      assert [_still_paused] = Server.paused(server)

      :ok = Server.resume(server, s.pause_id, :continue)
      Task.await(task)
    end
  end

  describe "resume/3 errors" do
    test "reports an unknown pause id", ctx do
      server = start_server(ctx)
      assert Server.resume(server, "pause_nope", :continue) == {:error, :unknown_pause}
    end

    test "reports an unknown command without releasing the session", ctx do
      server = start_server(ctx)
      s = session(ctx)
      task = pause_in_task(server, s)

      assert_receive {:paused, _}
      assert Server.resume(server, s.pause_id, :teleport) == {:error, :unknown_command}
      assert [_still_paused] = Server.paused(server)

      :ok = Server.resume(server, s.pause_id, :continue)
      Task.await(task)
    end
  end

  describe "subscribers" do
    test "a late subscriber sees subsequent notifications", ctx do
      server = start_server(ctx, subscribers: [])
      relay = start_supervised!({Task, fn -> Process.sleep(:infinity) end}, id: :relay)
      assert :ok = Server.subscribe(server, self())

      s = session(ctx)
      task = pause_in_task(server, s)
      assert_receive {:tiny_ci_control, :breakpoint_hit, ^s}

      :ok = Server.resume(server, s.pause_id, :continue)
      assert_receive {:tiny_ci_control, :resumed, _pause_id, :continue}
      Task.await(task)
      assert is_pid(relay)
    end

    test "a dead subscriber is dropped without disturbing the run", ctx do
      subscriber = spawn(fn -> Process.sleep(:infinity) end)
      server = start_server(ctx, subscribers: [subscriber])

      Process.exit(subscriber, :kill)
      # Round-trip a call so the DOWN has certainly been processed.
      refute Server.aborted?(server)

      s = session(ctx)
      task = pause_in_task(server, s)
      assert_receive {:paused, _}
      :ok = Server.resume(server, s.pause_id, :continue)
      assert {:continue, %{}} = Task.await(task)
    end
  end

  describe "paused/1" do
    test "lists paused sessions oldest first", ctx do
      server = start_server(ctx)
      a = session(ctx, %{step: :unit})
      b = session(ctx, %{step: :other})

      task_a = pause_in_task(server, a)
      assert_receive {:paused, _}
      task_b = pause_in_task(server, b)
      assert_receive {:paused, _}

      assert [%Session{step: :unit}, %Session{step: :other}] = Server.paused(server)

      :ok = Server.resume(server, a.pause_id, :abort)
      Task.await(task_a)
      Task.await(task_b)
    end

    test "is empty before anything pauses", ctx do
      assert Server.paused(start_server(ctx)) == []
    end
  end

  describe "without a dispatcher" do
    test "commands still work; there is simply nothing to emit into", ctx do
      server = start_server(ctx, dispatcher: nil)
      s = session(ctx)
      task = pause_in_task(server, s)

      assert_receive {:paused, _}
      :ok = Server.resume(server, s.pause_id, :skip)
      assert {:skip, %{}} = Task.await(task)
      assert Server.divergent?(server)
    end
  end
end
