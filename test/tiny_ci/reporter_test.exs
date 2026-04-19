defmodule TinyCI.ReporterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias TinyCI.{Reporter, StageResult, StepResult}

  describe "print_summary/1" do
    test "prints passed pipeline with stage and step details" do
      stage_results = [
        %StageResult{
          name: :test,
          status: :passed,
          duration_ms: 1200,
          step_results: [
            %StepResult{name: :unit, status: :passed, duration_ms: 800},
            %StepResult{name: :lint, status: :passed, duration_ms: 400}
          ]
        }
      ]

      output = capture_io(fn -> Reporter.print_summary(stage_results) end)

      assert output =~ "Pipeline Summary"
      assert output =~ "test"
      assert output =~ "unit"
      assert output =~ "lint"
      assert output =~ "passed"
      assert output =~ "1.2s"
    end

    test "prints failed stage with failing step" do
      stage_results = [
        %StageResult{
          name: :build,
          status: :failed,
          duration_ms: 500,
          step_results: [
            %StepResult{name: :compile, status: :passed, duration_ms: 300},
            %StepResult{name: :typecheck, status: :failed, duration_ms: 200}
          ]
        }
      ]

      output = capture_io(fn -> Reporter.print_summary(stage_results) end)

      assert output =~ "build"
      assert output =~ "compile"
      assert output =~ "typecheck"
      assert output =~ "failed"
    end

    test "prints skipped stage" do
      stage_results = [
        %StageResult{
          name: :deploy,
          status: :skipped,
          duration_ms: 0,
          step_results: []
        }
      ]

      output = capture_io(fn -> Reporter.print_summary(stage_results) end)

      assert output =~ "deploy"
      assert output =~ "skipped"
    end

    test "prints multiple stages" do
      stage_results = [
        %StageResult{
          name: :test,
          status: :passed,
          duration_ms: 1000,
          step_results: [
            %StepResult{name: :unit, status: :passed, duration_ms: 1000}
          ]
        },
        %StageResult{
          name: :deploy,
          status: :skipped,
          duration_ms: 0,
          step_results: []
        }
      ]

      output = capture_io(fn -> Reporter.print_summary(stage_results) end)

      assert output =~ "test"
      assert output =~ "deploy"
    end

    test "prints empty pipeline summary" do
      output = capture_io(fn -> Reporter.print_summary([]) end)

      assert output =~ "Pipeline Summary"
      assert output =~ "No stages executed"
    end

    test "formats duration in seconds when over 1000ms" do
      stage_results = [
        %StageResult{
          name: :test,
          status: :passed,
          duration_ms: 2500,
          step_results: [
            %StepResult{name: :unit, status: :passed, duration_ms: 2500}
          ]
        }
      ]

      output = capture_io(fn -> Reporter.print_summary(stage_results) end)

      assert output =~ "2.5s"
    end
  end

  describe "print_summary/1 with allowed failures" do
    test "shows allowed failure with warning icon" do
      stage_results = [
        %StageResult{
          name: :test,
          status: :passed,
          duration_ms: 500,
          step_results: [
            %StepResult{
              name: :flaky,
              status: :failed,
              duration_ms: 200,
              allowed_failure: true
            },
            %StepResult{name: :unit, status: :passed, duration_ms: 300}
          ]
        }
      ]

      output = capture_io(fn -> Reporter.print_summary(stage_results) end)

      assert output =~ "flaky"
      assert output =~ "allowed"
    end
  end

  describe "format_duration/1" do
    test "formats milliseconds under 1000 as ms" do
      assert Reporter.format_duration(500) == "500ms"
    end

    test "formats milliseconds at or over 1000 as seconds" do
      assert Reporter.format_duration(1000) == "1.0s"
      assert Reporter.format_duration(2500) == "2.5s"
    end

    test "formats zero duration" do
      assert Reporter.format_duration(0) == "0ms"
    end
  end

  describe "pipeline_status/1" do
    test "returns :passed when all stages passed or skipped" do
      results = [
        %StageResult{name: :a, status: :passed},
        %StageResult{name: :b, status: :skipped}
      ]

      assert Reporter.pipeline_status(results) == :passed
    end

    test "returns :failed when any stage failed" do
      results = [
        %StageResult{name: :a, status: :passed},
        %StageResult{name: :b, status: :failed}
      ]

      assert Reporter.pipeline_status(results) == :failed
    end

    test "returns :passed for empty results" do
      assert Reporter.pipeline_status([]) == :passed
    end
  end
end
