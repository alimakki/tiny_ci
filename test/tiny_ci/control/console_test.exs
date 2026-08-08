defmodule TinyCI.Control.ConsoleTest do
  use ExUnit.Case, async: true

  alias TinyCI.Control.{Breakpoint, Console, Server, Session}

  setup do
    run_id = "run_#{System.unique_integer([:positive])}"

    {:ok, server} =
      Server.start_link(
        run_id: run_id,
        breakpoints: [%Breakpoint{phase: :before, stage: :test, step: :unit}],
        subscribers: []
      )

    {:ok, run_id: run_id, server: server}
  end

  defp session(ctx, overrides \\ %{}) do
    Map.merge(
      %Session{
        pause_id: "pause_#{System.unique_integer([:positive])}",
        run_id: ctx.run_id,
        phase: :before,
        scope: :step,
        stage: :test,
        step: :unit,
        working_dir: "/repo",
        branch: "main",
        commit: "0123456789abcdef",
        store: %{"tag" => "v1"},
        env: %{"MIX_ENV" => "test"}
      },
      overrides
    )
  end

  # Boots a driver reading from `input`, pauses a session in a task, and returns
  # both the command that released it and everything the driver printed.
  defp drive(ctx, input, session) do
    {:ok, io} = StringIO.open(input)
    {:ok, driver} = Console.start_link(io: io)
    :ok = Server.subscribe(ctx.server, driver)

    test = self()

    task =
      Task.async(fn ->
        :ok = Server.pause(ctx.server, session)

        receive do
          {:tiny_ci_control_resume, _id, command, overrides} ->
            send(test, :released)
            {command, overrides}
        after
          2_000 -> :never_released
        end
      end)

    result = Task.await(task, 3_000)
    # Let the driver drain its own :resumed notification before we read the buffer.
    Process.sleep(20)
    {_in, output} = StringIO.contents(io)
    {result, output}
  end

  describe "commands" do
    for {input, command} <- [
          {"continue\n", :continue},
          {"c\n", :continue},
          {"skip\n", :skip},
          {"s\n", :skip},
          {"retry\n", :retry},
          {"r\n", :retry},
          {"abort\n", :abort},
          {"a\n", :abort}
        ] do
      test "#{String.trim(input)} issues #{command}", ctx do
        assert {{unquote(command), %{}}, _output} = drive(ctx, unquote(input), session(ctx))
      end
    end

    test "a bare newline continues, so tapping enter is safe", ctx do
      assert {{:continue, %{}}, _output} = drive(ctx, "\n", session(ctx))
    end

    test "an unknown command is reported and re-prompts rather than resuming", ctx do
      {{command, _}, output} = drive(ctx, "teleport\ncontinue\n", session(ctx))

      assert command == :continue
      assert output =~ ~s(unknown command "teleport")
      assert output =~ "help"
    end
  end

  describe "set" do
    test "records the edit, keeps prompting, and resumes with it", ctx do
      {{command, overrides}, output} = drive(ctx, "set tag v2\ncontinue\n", session(ctx))

      assert command == :continue
      assert overrides == %{tag: "v2"}
      assert output =~ ~s(store.tag = "v2")
    end

    test "warns that the run is now divergent and unattestable", ctx do
      {_result, output} = drive(ctx, "set tag v2\ncontinue\n", session(ctx))

      assert output =~ "divergent"
      assert output =~ "not attestable"
    end

    test "several edits accumulate before a single resume", ctx do
      {{:retry, overrides}, _output} = drive(ctx, "set a 1\nset b 2\nretry\n", session(ctx))
      assert overrides == %{a: "1", b: "2"}
    end

    test "an edited value shows up in a subsequent store listing", ctx do
      {_result, output} = drive(ctx, "set tag v2\nstore\ncontinue\n", session(ctx))

      # The pre-edit value and the post-edit value both appear, in that order.
      assert output =~ ~s("v1")
      assert [_before, after_edit] = String.split(output, "store.tag")
      assert after_edit =~ ~s(tag = "v2")
    end

    test "reports usage when the value is missing", ctx do
      {{:continue, overrides}, output} = drive(ctx, "set tag\ncontinue\n", session(ctx))

      assert overrides == %{}
      assert output =~ "usage: set KEY VALUE"
    end

    test "reports usage for a bare set", ctx do
      {_result, output} = drive(ctx, "set\ncontinue\n", session(ctx))
      assert output =~ "usage: set KEY VALUE"
    end

    test "keeps a value containing spaces intact", ctx do
      {{:continue, overrides}, _output} =
        drive(ctx, "set message hello there world\ncontinue\n", session(ctx))

      assert overrides == %{message: "hello there world"}
    end
  end

  describe "inspection" do
    test "prints the boundary, store, env, and git context on arrival", ctx do
      {_result, output} = drive(ctx, "continue\n", session(ctx))

      assert output =~ "breakpoint before test.unit"
      assert output =~ "stage:"
      assert output =~ "step:"
      assert output =~ "/repo"
      assert output =~ "main @ 01234567"
      assert output =~ ~s(tag = "v1")
      assert output =~ ~s(MIX_ENV = "test")
    end

    test "store and env can be re-printed on demand", ctx do
      {_result, output} = drive(ctx, "store\nenv\ncontinue\n", session(ctx))

      assert output |> String.split("store:") |> length() >= 3
      assert output |> String.split("env:") |> length() >= 3
    end

    test "info re-prints the whole boundary", ctx do
      {_result, output} = drive(ctx, "info\ncontinue\n", session(ctx))
      assert output |> String.split("git:") |> length() >= 3
    end

    test "help lists every command", ctx do
      {_result, output} = drive(ctx, "help\ncontinue\n", session(ctx))

      for command <- ~w(continue skip retry abort set store info) do
        assert output =~ command
      end
    end

    test "? is an alias for help", ctx do
      {_result, output} = drive(ctx, "?\ncontinue\n", session(ctx))
      assert output =~ "re-run the body"
    end

    test "an empty store reads as (empty) rather than as nothing", ctx do
      {_result, output} = drive(ctx, "continue\n", session(ctx, %{store: %{}}))
      assert output =~ "(empty)"
    end

    test "reports the matrix combination when there is one", ctx do
      combo = [elixir: "1.18"]
      {_result, output} = drive(ctx, "continue\n", session(ctx, %{matrix_combination: combo}))

      assert output =~ "matrix:"
      assert output =~ "elixir"
    end

    test "reports the result on an :after boundary", ctx do
      after_session =
        session(ctx, %{phase: :after, result: %{"status" => "failed", "duration_ms" => 3}})

      {_result, output} = drive(ctx, "continue\n", after_session)

      assert output =~ "breakpoint after test.unit"
      assert output =~ "failed"
    end

    test "omits an unknown commit rather than printing a blank", ctx do
      {_result, output} = drive(ctx, "continue\n", session(ctx, %{commit: nil}))
      assert output =~ "main @ unknown"
    end
  end

  describe "closed stdin" do
    test "aborts rather than blocking forever on a dead terminal", ctx do
      {{command, _overrides}, output} = drive(ctx, "", session(ctx))

      assert command == :abort
      assert output =~ "stdin closed"
    end
  end

  describe "several boundaries paused at once" do
    test "prompts for one and reports the other as queued", ctx do
      {:ok, io} = StringIO.open("continue\ncontinue\n")
      {:ok, driver} = Console.start_link(io: io)
      :ok = Server.subscribe(ctx.server, driver)

      first = session(ctx, %{step: :unit})
      second = session(ctx, %{step: :other})

      task_a = pause_task(ctx.server, first)
      assert_receive {:paused, _}
      task_b = pause_task(ctx.server, second)
      assert_receive {:paused, _}

      assert {:continue, _} = Task.await(task_a, 3_000)
      assert {:continue, _} = Task.await(task_b, 3_000)

      Process.sleep(20)
      {_in, output} = StringIO.contents(io)
      assert output =~ "also paused"
      assert output =~ "breakpoint before test.other"
    end
  end

  defp pause_task(server, session) do
    test = self()

    Task.async(fn ->
      :ok = Server.pause(server, session)
      send(test, {:paused, session.pause_id})

      receive do
        {:tiny_ci_control_resume, _id, command, overrides} -> {command, overrides}
      after
        3_000 -> :never_released
      end
    end)
  end
end
