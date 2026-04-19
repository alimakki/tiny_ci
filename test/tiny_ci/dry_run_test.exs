defmodule TinyCI.DryRunTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias TinyCI.{DryRun, Stage, Step}

  describe "print_plan/2" do
    test "prints stages and their steps" do
      stages = [
        %Stage{
          name: :test,
          mode: :parallel,
          steps: [
            %Step{name: :unit, cmd: "mix test"},
            %Step{name: :lint, cmd: "mix credo"}
          ]
        }
      ]

      output = capture_io(fn -> DryRun.print_plan(stages, %{branch: "main"}) end)

      assert output =~ "Dry Run"
      assert output =~ ":test"
      assert output =~ "parallel"
      assert output =~ ":unit"
      assert output =~ "mix test"
      assert output =~ ":lint"
      assert output =~ "mix credo"
    end

    test "prints module steps" do
      stages = [
        %Stage{
          name: :deploy,
          mode: :serial,
          steps: [
            %Step{name: :release, module: MyApp.DeployStep}
          ]
        }
      ]

      output = capture_io(fn -> DryRun.print_plan(stages, %{branch: "main"}) end)

      assert output =~ ":release"
      assert output =~ "MyApp.DeployStep"
    end

    test "shows skipped stages when condition evaluates to false" do
      stages = [
        %Stage{
          name: :deploy,
          mode: :serial,
          when_condition: fn ctx -> ctx.branch == "main" end,
          steps: [%Step{name: :release, cmd: "make release"}]
        }
      ]

      output = capture_io(fn -> DryRun.print_plan(stages, %{branch: "develop"}) end)

      assert output =~ ":deploy"
      assert output =~ "skip"
    end

    test "shows runnable stages when condition evaluates to true" do
      stages = [
        %Stage{
          name: :deploy,
          mode: :serial,
          when_condition: fn ctx -> ctx.branch == "main" end,
          steps: [%Step{name: :release, cmd: "make release"}]
        }
      ]

      output = capture_io(fn -> DryRun.print_plan(stages, %{branch: "main"}) end)

      assert output =~ ":deploy"
      assert output =~ ":release"
      refute output =~ "skip"
    end

    test "shows timeout when configured on a step" do
      stages = [
        %Stage{
          name: :test,
          mode: :serial,
          steps: [
            %Step{name: :unit, cmd: "mix test", timeout: 60_000}
          ]
        }
      ]

      output = capture_io(fn -> DryRun.print_plan(stages, %{branch: "main"}) end)

      assert output =~ "timeout"
      assert output =~ "60000"
    end

    test "prints context info" do
      stages = [
        %Stage{name: :test, mode: :serial, steps: [%Step{name: :ok, cmd: "true"}]}
      ]

      output =
        capture_io(fn -> DryRun.print_plan(stages, %{branch: "main", commit: "abc123"}) end)

      assert output =~ "main"
      assert output =~ "abc123"
    end

    test "handles empty pipeline" do
      output = capture_io(fn -> DryRun.print_plan([], %{branch: "main"}) end)

      assert output =~ "No stages"
    end

    test "shows allow_failure indicator on steps" do
      stages = [
        %Stage{
          name: :test,
          mode: :serial,
          steps: [
            %Step{name: :flaky, cmd: "echo flaky", allow_failure: true},
            %Step{name: :critical, cmd: "echo critical"}
          ]
        }
      ]

      output = capture_io(fn -> DryRun.print_plan(stages, %{branch: "main"}) end)

      assert output =~ ":flaky"
      assert output =~ "allow_failure"
    end

    test "does not show allow_failure for normal steps" do
      stages = [
        %Stage{
          name: :test,
          mode: :serial,
          steps: [
            %Step{name: :normal, cmd: "echo ok"}
          ]
        }
      ]

      output = capture_io(fn -> DryRun.print_plan(stages, %{branch: "main"}) end)

      refute output =~ "allow_failure"
    end
  end
end
