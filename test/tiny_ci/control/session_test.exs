defmodule TinyCI.Control.SessionTest do
  use ExUnit.Case, async: true

  alias TinyCI.Control.{Breakpoint, Session}
  alias TinyCI.Events.BreakpointHit
  alias TinyCI.StepResult

  doctest TinyCI.Control.Session

  defp context(overrides \\ %{}) do
    Map.merge(
      %{
        run_id: "run_1",
        stage_name: :test,
        branch: "main",
        commit: "0123456789abcdef0123456789abcdef01234567",
        root: "/repo",
        store: %{},
        pipeline_env: %{},
        stage_env: %{}
      },
      overrides
    )
  end

  describe "build/2" do
    test "captures the boundary's identity" do
      session =
        Session.build(context(), phase: :before, scope: :step, step: :unit)

      assert session.phase == :before
      assert session.scope == :step
      assert session.stage == :test
      assert session.step == :unit
      assert session.run_id == "run_1"
      assert session.pause_id =~ ~r/^pause_\d+$/
    end

    test "pause ids are unique across sessions" do
      a = Session.build(context(), phase: :before, scope: :stage)
      b = Session.build(context(), phase: :before, scope: :stage)

      refute a.pause_id == b.pause_id
    end

    test "reports git context, working dir, and matrix combination" do
      ctx = context(%{matrix_combination: [elixir: "1.18"]})

      session = Session.build(ctx, phase: :before, scope: :step, working_dir: "/repo/apps/web")

      assert session.branch == "main"
      assert session.commit =~ "0123456789"
      assert session.working_dir == "/repo/apps/web"
      assert session.matrix_combination == [elixir: "1.18"]
    end

    test "falls back to the project root when the step declares no working dir" do
      session = Session.build(context(), phase: :before, scope: :stage)
      assert session.working_dir == "/repo"
    end

    test "resolves env through the same layering the step will run with" do
      ctx =
        context(%{
          pipeline_env: %{"MIX_ENV" => "dev", "SHARED" => "pipeline"},
          stage_env: %{"SHARED" => "stage"},
          store: %{sha: "abc123"}
        })

      session =
        Session.build(ctx, phase: :before, scope: :step, step_env: %{"SHA" => {:store, :sha}})

      assert session.env["MIX_ENV"] == "dev"
      assert session.env["SHARED"] == "stage"
      assert session.env["SHA"] == "abc123"
    end

    test "snapshots the store with string keys" do
      session = Session.build(context(%{store: %{count: 2}}), phase: :before, scope: :stage)
      assert session.store == %{"count" => 2}
    end

    test "renders store values the event stream could not otherwise carry" do
      ctx = context(%{store: %{ref: {:a, :b}, pid: self(), ok: true, n: 1.5}})

      session = Session.build(ctx, phase: :before, scope: :stage)

      assert session.store["ref"] == "{:a, :b}"
      assert session.store["pid"] == inspect(self())
      assert session.store["ok"] == true
      assert session.store["n"] == 1.5
    end

    test "masks known secret values in the store and env" do
      ctx =
        context(%{
          secrets: ["s3cr3t"],
          store: %{token: "s3cr3t"},
          pipeline_env: %{"TOKEN" => "s3cr3t"}
        })

      session = Session.build(ctx, phase: :before, scope: :stage)

      assert session.store["token"] == "***"
      assert session.env["TOKEN"] == "***"
    end

    test "summarizes the result on an :after boundary" do
      result = %StepResult{name: :unit, status: :failed, duration_ms: 42, output: "boom"}

      session =
        Session.build(context(), phase: :after, scope: :step, step: :unit, result: result)

      assert session.result == %{
               "status" => "failed",
               "duration_ms" => 42,
               "output" => "boom"
             }
    end

    test "has no result on a :before boundary" do
      session = Session.build(context(), phase: :before, scope: :step, step: :unit)
      assert session.result == nil
    end
  end

  describe "to_event/2" do
    test "builds a breakpoint_hit carrying the whole inspectable payload" do
      ts = ~U[2024-01-15 10:30:00.000000Z]
      breakpoint = %Breakpoint{phase: :before, stage: :test, step: :unit}
      ctx = context(%{store: %{count: 1}, pipeline_env: %{"MIX_ENV" => "test"}})

      session =
        Session.build(ctx,
          phase: :before,
          scope: :step,
          step: :unit,
          breakpoint: breakpoint,
          working_dir: "/repo"
        )

      assert %BreakpointHit{} = event = Session.to_event(session, ts)

      assert event.run_id == "run_1"
      assert event.timestamp == ts
      assert event.pause_id == session.pause_id
      assert event.breakpoint == "before:test.unit"
      assert event.stage == :test
      assert event.step == :unit
      assert event.store == %{"count" => 1}
      assert event.env == %{"MIX_ENV" => "test"}
      assert event.working_dir == "/repo"
    end

    test "the event survives JSON encoding" do
      ctx = context(%{store: %{ref: make_ref()}})
      session = Session.build(ctx, phase: :before, scope: :stage)

      decoded =
        session
        |> Session.to_event(DateTime.utc_now())
        |> Jason.encode!()
        |> Jason.decode!()

      assert decoded["stage"] == "test"
      assert decoded["phase"] == "before"
      assert is_binary(decoded["store"]["ref"])
    end
  end

  describe "coerce/1" do
    test "walks nested structures" do
      assert Session.coerce(%{a: [1, {:b, 2}], c: %{d: :e}}) ==
               %{"a" => [1, "{:b, 2}"], "c" => %{"d" => "e"}}
    end

    test "keeps nil rather than stringifying it" do
      assert Session.coerce(%{a: nil}) == %{"a" => nil}
    end

    test "renders structs, which are not JSON-safe by default" do
      assert Session.coerce(%{r: %StepResult{name: :a, status: :passed}}) |> Map.fetch!("r") =~
               "StepResult"
    end
  end
end
