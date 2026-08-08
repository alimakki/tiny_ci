defmodule TinyCI.ProvenanceTest do
  use ExUnit.Case, async: true

  alias TinyCI.Provenance

  alias TinyCI.Events.{
    PipelineCompleted,
    PipelineStarted,
    RunDiverged,
    StepCompleted,
    StepSkipped
  }

  alias TinyCI.{PipelineSpec, Stage, Step}

  @ts ~U[2026-06-28 10:00:00Z]

  defp spec do
    %PipelineSpec{
      name: :release,
      stages: [
        %Stage{
          name: :build,
          steps: [
            %Step{name: :compile, cmd: "mix compile"},
            %Step{name: :tag, module: Acme.Tagger}
          ]
        },
        %Stage{name: :deploy, steps: [%Step{name: :ship, module: Acme.Deploy}]}
      ],
      hooks: %{on_success: [], on_failure: []}
    }
  end

  defp events do
    [
      %PipelineStarted{run_id: "run-123", timestamp: @ts, pipeline_name: :release},
      %StepCompleted{
        run_id: "run-123",
        timestamp: @ts,
        stage: :build,
        step: :compile,
        status: :passed,
        duration_ms: 1200
      },
      %StepCompleted{
        run_id: "run-123",
        timestamp: @ts,
        stage: :build,
        step: :tag,
        status: :passed,
        duration_ms: 300
      },
      %StepSkipped{
        run_id: "run-123",
        timestamp: @ts,
        stage: :deploy,
        step: :ship,
        reason: "when"
      },
      %PipelineCompleted{run_id: "run-123", timestamp: @ts, status: :passed, duration_ms: 1600}
    ]
  end

  defp actions do
    [
      %{module: Acme.Tagger, app: :acme, version: "1.2.0", checksum: "abc", source: :hex},
      %{module: Acme.Deploy, app: :acme, version: "1.2.0", checksum: "abc", source: :hex}
    ]
  end

  defp build(overrides \\ []) do
    Provenance.build(
      Keyword.merge(
        [events: events(), spec: spec(), actions: actions(), commit: "deadbeef", branch: "main"],
        overrides
      )
    )
  end

  describe "statement shape" do
    test "is an in-toto statement naming the pipeline and commit" do
      stmt = build()

      assert stmt["_type"] =~ "in-toto.io/Statement"
      assert stmt["predicateType"] =~ "tiny"
      assert [%{"name" => "release", "digest" => %{"gitCommit" => "deadbeef"}}] = stmt["subject"]
    end

    test "predicate carries run metadata sourced from the event stream" do
      pred = build()["predicate"]

      assert pred["runId"] == "run-123"
      assert pred["branch"] == "main"
      assert pred["commit"] == "deadbeef"
      assert pred["outcome"] == "success"
      assert pred["builder"]["tool"] == "tiny_ci"
    end

    test "outcome reflects a failed run" do
      failed =
        List.replace_at(
          events(),
          -1,
          %PipelineCompleted{run_id: "run-123", timestamp: @ts, status: :failed, duration_ms: 5}
        )

      assert build(events: failed)["predicate"]["outcome"] == "failure"
    end
  end

  describe "steps" do
    test "records per-step outcome and duration from step_finished events" do
      steps = build()["predicate"]["steps"]

      compile = Enum.find(steps, &(&1["step"] == "compile"))
      assert compile["stage"] == "build"
      assert compile["status"] == "passed"
      assert compile["durationMs"] == 1200
      assert compile["action"] == nil
    end

    test "maps a module step to its action" do
      steps = build()["predicate"]["steps"]
      tag = Enum.find(steps, &(&1["step"] == "tag"))
      assert tag["action"] == "Elixir.Acme.Tagger" or tag["action"] == "Acme.Tagger"
    end

    test "includes skipped steps with no duration" do
      steps = build()["predicate"]["steps"]
      ship = Enum.find(steps, &(&1["step"] == "ship"))
      assert ship["status"] == "skipped"
      assert ship["durationMs"] == nil
    end
  end

  describe "actions" do
    test "enumerates only actions that actually executed, with checksums" do
      actions = build()["predicate"]["actions"]

      names = Enum.map(actions, & &1["module"])
      assert Enum.any?(names, &(&1 =~ "Acme.Tagger"))
      # Acme.Deploy was skipped → not an executed action
      refute Enum.any?(names, &(&1 =~ "Acme.Deploy"))

      tagger = Enum.find(actions, &(&1["module"] =~ "Acme.Tagger"))
      assert tagger["version"] == "1.2.0"
      assert tagger["checksum"] == "abc"
      assert tagger["source"] == "hex"
    end

    test "maps each executed action to the steps that used it" do
      actions = build()["predicate"]["actions"]
      tagger = Enum.find(actions, &(&1["module"] =~ "Acme.Tagger"))
      assert [%{"stage" => "build", "step" => "tag"}] = tagger["steps"]
    end
  end

  describe "divergence" do
    test "an untouched run is not divergent" do
      refute Provenance.divergent?(events())
      refute build()["predicate"]["divergent"]
      assert build()["predicate"]["divergences"] == []
    end

    test "a run_diverged event makes the run divergent" do
      assert Provenance.divergent?([diverged(:set_store)])
      assert build(events: events() ++ [diverged(:set_store)])["predicate"]["divergent"]
    end

    test "any divergence reason counts" do
      for reason <- [:set_store, :skip, :retry] do
        assert Provenance.divergent?([diverged(reason)])
      end
    end

    test "each divergence is listed with what changed and where" do
      stmt = build(events: events() ++ [diverged(:set_store)])

      assert [entry] = stmt["predicate"]["divergences"]
      assert entry["reason"] == "set_store"
      assert entry["stage"] == "deploy"
      assert entry["step"] == "ship"
      assert entry["detail"] == ~s(tag = "v2")
      assert entry["at"] == DateTime.to_iso8601(@ts)
    end

    test "every divergence is recorded, not only the first" do
      stmt = build(events: events() ++ [diverged(:set_store), diverged(:retry)])

      assert ["set_store", "retry"] = Enum.map(stmt["predicate"]["divergences"], & &1["reason"])
    end

    test "a divergence with no stage or step reads as null rather than a bare atom" do
      event = %RunDiverged{run_id: "run-123", timestamp: @ts, reason: :skip}
      stmt = build(events: events() ++ [event])

      assert [%{"stage" => nil, "step" => nil, "detail" => nil}] =
               stmt["predicate"]["divergences"]
    end
  end

  test "the statement is JSON-encodable" do
    assert {:ok, json} = Jason.encode(build())
    assert is_binary(json)
  end

  test "a divergent statement is JSON-encodable too" do
    assert {:ok, json} = Jason.encode(build(events: events() ++ [diverged(:set_store)]))
    assert Jason.decode!(json)["predicate"]["divergent"] == true
  end

  defp diverged(reason) do
    %RunDiverged{
      run_id: "run-123",
      timestamp: @ts,
      reason: reason,
      stage: :deploy,
      step: :ship,
      detail: ~s(tag = "v2")
    }
  end
end
