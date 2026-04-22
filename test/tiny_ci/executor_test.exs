defmodule TinyCI.ExecutorTest do
  use ExUnit.Case, async: true

  alias TinyCI.{Executor, Stage, Step, StageResult, StepResult}

  describe "execute/2 with serial mode" do
    test "returns a passed StageResult on success" do
      stage = %Stage{
        name: :test,
        mode: :serial,
        steps: [
          %Step{name: :one, cmd: "true"},
          %Step{name: :two, cmd: "true"}
        ]
      }

      assert %StageResult{name: :test, status: :passed, step_results: step_results} =
               Executor.execute(stage)

      assert length(step_results) == 2
      assert Enum.all?(step_results, &(&1.status == :passed))
    end

    test "halts on first failure in serial mode" do
      stage = %Stage{
        name: :test,
        mode: :serial,
        steps: [
          %Step{name: :fail, cmd: "false"},
          %Step{name: :never, cmd: "true"}
        ]
      }

      assert %StageResult{name: :test, status: :failed, step_results: step_results} =
               Executor.execute(stage)

      assert [%StepResult{name: :fail, status: :failed}] = step_results
    end

    test "captures step duration" do
      stage = %Stage{
        name: :test,
        mode: :serial,
        steps: [%Step{name: :sleep, cmd: "sleep 0.1"}]
      }

      %StageResult{step_results: [step_result], duration_ms: stage_duration} =
        Executor.execute(stage)

      assert step_result.duration_ms >= 50
      assert stage_duration >= 50
    end

    test "captures command output in step result" do
      stage = %Stage{
        name: :test,
        mode: :serial,
        steps: [%Step{name: :echo, cmd: "echo hello_world"}]
      }

      %StageResult{step_results: [step_result]} = Executor.execute(stage)

      assert step_result.output =~ "hello_world"
    end
  end

  describe "execute/2 with parallel mode" do
    test "returns a passed StageResult on success" do
      stage = %Stage{
        name: :test,
        mode: :parallel,
        steps: [
          %Step{name: :one, cmd: "true"},
          %Step{name: :two, cmd: "true"}
        ]
      }

      assert %StageResult{name: :test, status: :passed, step_results: step_results} =
               Executor.execute(stage)

      assert length(step_results) == 2
      assert Enum.all?(step_results, &(&1.status == :passed))
    end

    test "returns failed StageResult when any parallel step fails" do
      stage = %Stage{
        name: :test,
        mode: :parallel,
        steps: [
          %Step{name: :pass, cmd: "true"},
          %Step{name: :fail, cmd: "false"}
        ]
      }

      assert %StageResult{name: :test, status: :failed, step_results: step_results} =
               Executor.execute(stage)

      statuses = Map.new(step_results, &{&1.name, &1.status})
      assert statuses[:pass] == :passed
      assert statuses[:fail] == :failed
    end

    test "preserves step order in results regardless of completion time" do
      stage = %Stage{
        name: :test,
        mode: :parallel,
        steps: [
          %Step{name: :first, cmd: "sleep 0.1 && echo first"},
          %Step{name: :second, cmd: "echo second"}
        ]
      }

      %StageResult{step_results: step_results} = Executor.execute(stage)

      names = Enum.map(step_results, & &1.name)
      assert names == [:first, :second]
    end

    test "buffers output so parallel steps don't interleave" do
      stage = %Stage{
        name: :test,
        mode: :parallel,
        steps: [
          %Step{name: :a, cmd: "echo output_a"},
          %Step{name: :b, cmd: "echo output_b"}
        ]
      }

      %StageResult{step_results: step_results} = Executor.execute(stage)

      a_result = Enum.find(step_results, &(&1.name == :a))
      b_result = Enum.find(step_results, &(&1.name == :b))

      assert a_result.output =~ "output_a"
      assert b_result.output =~ "output_b"
    end
  end

  describe "execute/2 with when_condition" do
    test "skips stage when condition returns false" do
      stage = %Stage{
        name: :deploy,
        mode: :serial,
        when_condition: fn _ctx -> false end,
        steps: [%Step{name: :should_not_run, cmd: "false"}]
      }

      assert %StageResult{name: :deploy, status: :skipped, step_results: []} =
               Executor.execute(stage)
    end

    test "runs stage when condition returns true" do
      stage = %Stage{
        name: :deploy,
        mode: :serial,
        when_condition: fn _ctx -> true end,
        steps: [%Step{name: :one, cmd: "true"}]
      }

      assert %StageResult{name: :deploy, status: :passed} = Executor.execute(stage)
    end

    test "runs stage when no condition is set" do
      stage = %Stage{
        name: :test,
        mode: :serial,
        when_condition: nil,
        steps: [%Step{name: :one, cmd: "true"}]
      }

      assert %StageResult{name: :test, status: :passed} = Executor.execute(stage)
    end

    test "skips stage in parallel mode when condition returns false" do
      stage = %Stage{
        name: :deploy,
        mode: :parallel,
        when_condition: fn _ctx -> false end,
        steps: [%Step{name: :should_not_run, cmd: "false"}]
      }

      assert %StageResult{name: :deploy, status: :skipped} = Executor.execute(stage)
    end

    test "condition receives the context map" do
      context = %{branch: "feature/test", commit: "abc123"}

      stage = %Stage{
        name: :deploy,
        mode: :serial,
        when_condition: fn ctx -> ctx.branch == "main" end,
        steps: [%Step{name: :should_not_run, cmd: "false"}]
      }

      assert %StageResult{status: :skipped} = Executor.execute(stage, context)
    end

    test "condition can use context to allow execution" do
      context = %{branch: "main", commit: "abc123"}

      stage = %Stage{
        name: :deploy,
        mode: :serial,
        when_condition: fn ctx -> ctx.branch == "main" end,
        steps: [%Step{name: :one, cmd: "true"}]
      }

      assert %StageResult{status: :passed} = Executor.execute(stage, context)
    end
  end

  describe "run_pipeline/2" do
    test "runs all stages in order and returns ok with results" do
      stages = [
        %Stage{name: :first, mode: :serial, steps: [%Step{name: :a, cmd: "true"}]},
        %Stage{name: :second, mode: :serial, steps: [%Step{name: :b, cmd: "true"}]}
      ]

      assert {:ok, results} = Executor.run_pipeline(stages)
      assert length(results) == 2
      assert Enum.all?(results, &(&1.status == :passed))
    end

    test "stops pipeline on first stage failure and returns accumulated results" do
      stages = [
        %Stage{name: :first, mode: :serial, steps: [%Step{name: :fail, cmd: "false"}]},
        %Stage{
          name: :second,
          mode: :serial,
          steps: [%Step{name: :should_not_run, cmd: "true"}]
        }
      ]

      assert {:error, {:stage_failed, :first, _reason}, results} =
               Executor.run_pipeline(stages)

      assert length(results) == 1
      assert [%StageResult{name: :first, status: :failed}] = results
    end

    test "continues pipeline when a stage is skipped" do
      stages = [
        %Stage{
          name: :skipped_stage,
          mode: :serial,
          when_condition: fn _ctx -> false end,
          steps: [%Step{name: :nope, cmd: "false"}]
        },
        %Stage{name: :runs, mode: :serial, steps: [%Step{name: :yes, cmd: "true"}]}
      ]

      assert {:ok, results} = Executor.run_pipeline(stages)
      assert [%StageResult{status: :skipped}, %StageResult{status: :passed}] = results
    end

    test "returns ok with empty list for an empty pipeline" do
      assert {:ok, []} = Executor.run_pipeline([])
    end

    test "stops on parallel stage failure" do
      stages = [
        %Stage{
          name: :parallel_fail,
          mode: :parallel,
          steps: [
            %Step{name: :pass, cmd: "true"},
            %Step{name: :fail, cmd: "false"}
          ]
        },
        %Stage{name: :never, mode: :serial, steps: [%Step{name: :nope, cmd: "true"}]}
      ]

      assert {:error, {:stage_failed, :parallel_fail, _reason}, results} =
               Executor.run_pipeline(stages)

      assert [%StageResult{name: :parallel_fail, status: :failed}] = results
    end
  end

  describe "run_pipeline/2 with context" do
    test "accepts a context map and passes it to when_conditions" do
      context = %{branch: "develop", commit: "def456"}

      stages = [
        %Stage{
          name: :deploy,
          mode: :serial,
          when_condition: fn ctx -> ctx.branch == "main" end,
          steps: [%Step{name: :should_skip, cmd: "false"}]
        },
        %Stage{name: :test, mode: :serial, steps: [%Step{name: :ok, cmd: "true"}]}
      ]

      assert {:ok, results} = Executor.run_pipeline(stages, context)
      assert [%StageResult{status: :skipped}, %StageResult{status: :passed}] = results
    end

    test "defaults to TinyCI.Context.build/0 when no context given" do
      stages = [
        %Stage{name: :test, mode: :serial, steps: [%Step{name: :ok, cmd: "true"}]}
      ]

      assert {:ok, _results} = Executor.run_pipeline(stages)
    end
  end

  describe "context passed to module steps" do
    defmodule ContextCapture do
      @moduledoc false
      def execute(_config, ctx) do
        send(self(), {:context_received, ctx})
        :ok
      end
    end

    test "module step receives the pipeline context" do
      context = %{branch: "main", commit: "abc123", custom: "value"}

      stage = %Stage{
        name: :deploy,
        mode: :serial,
        steps: [%Step{name: :capture, module: ContextCapture}]
      }

      Executor.execute(stage, context)
      assert_received {:context_received, received_ctx}
      assert received_ctx.branch == "main"
      assert received_ctx.commit == "abc123"
      assert received_ctx.custom == "value"
    end
  end

  describe "execute/2 with env option" do
    test "passes environment variables to shell command" do
      stage = %Stage{
        name: :env_test,
        mode: :serial,
        steps: [
          %Step{
            name: :check_env,
            cmd: ~s(test "$TINY_CI_FOO" = "bar"),
            env: %{"TINY_CI_FOO" => "bar"}
          }
        ]
      }

      assert %StageResult{status: :passed} = Executor.execute(stage)
    end

    test "passes multiple environment variables" do
      stage = %Stage{
        name: :env_test,
        mode: :serial,
        steps: [
          %Step{
            name: :check_multi,
            cmd: ~s(test "$TINY_CI_A" = "1" && test "$TINY_CI_B" = "2"),
            env: %{"TINY_CI_A" => "1", "TINY_CI_B" => "2"}
          }
        ]
      }

      assert %StageResult{status: :passed} = Executor.execute(stage)
    end

    test "works with empty env map" do
      stage = %Stage{
        name: :env_test,
        mode: :serial,
        steps: [%Step{name: :no_env, cmd: "true", env: %{}}]
      }

      assert %StageResult{status: :passed} = Executor.execute(stage)
    end

    test "passes env in parallel mode" do
      stage = %Stage{
        name: :env_test,
        mode: :parallel,
        steps: [
          %Step{
            name: :check_env,
            cmd: ~s(test "$TINY_CI_PAR" = "yes"),
            env: %{"TINY_CI_PAR" => "yes"}
          }
        ]
      }

      assert %StageResult{status: :passed} = Executor.execute(stage)
    end
  end

  describe "execute/2 with module steps" do
    defmodule SuccessStep do
      @moduledoc false
      def execute(_config, _ctx), do: :ok
    end

    defmodule FailStep do
      @moduledoc false
      def execute(_config, _ctx), do: {:error, :boom}
    end

    test "runs a module step with no config block" do
      stage = %Stage{
        name: :deploy,
        mode: :serial,
        steps: [%Step{name: :go, module: SuccessStep}]
      }

      assert %StageResult{status: :passed} = Executor.execute(stage)
    end

    test "returns failed result for failing module step" do
      stage = %Stage{
        name: :deploy,
        mode: :serial,
        steps: [%Step{name: :go, module: FailStep}]
      }

      assert %StageResult{status: :failed} = Executor.execute(stage)
    end

    test "passes config from config_block to module step" do
      stage = %Stage{
        name: :deploy,
        mode: :serial,
        steps: [
          %Step{
            name: :go,
            module: SuccessStep,
            config_block: fn -> [app: "my-app", strategy: :heroku] end
          }
        ]
      }

      assert %StageResult{status: :passed} = Executor.execute(stage)
    end
  end

  describe "execute/2 with step timeouts" do
    test "step passes when completing within timeout" do
      stage = %Stage{
        name: :test,
        mode: :serial,
        steps: [%Step{name: :fast, cmd: "echo fast", timeout: 5_000}]
      }

      assert %StageResult{status: :passed, step_results: [step]} = Executor.execute(stage)
      assert step.status == :passed
    end

    test "step fails when exceeding timeout" do
      stage = %Stage{
        name: :test,
        mode: :serial,
        steps: [%Step{name: :slow, cmd: "sleep 10", timeout: 100}]
      }

      assert %StageResult{status: :failed, step_results: [step]} = Executor.execute(stage)
      assert step.status == :failed
      assert step.output =~ "timed out"
    end

    test "step without timeout runs indefinitely (no timeout enforced)" do
      stage = %Stage{
        name: :test,
        mode: :serial,
        steps: [%Step{name: :no_timeout, cmd: "echo ok"}]
      }

      assert %StageResult{status: :passed} = Executor.execute(stage)
    end

    test "timeout works in parallel mode" do
      stage = %Stage{
        name: :test,
        mode: :parallel,
        steps: [
          %Step{name: :fast, cmd: "echo fast", timeout: 5_000},
          %Step{name: :slow, cmd: "sleep 10", timeout: 100}
        ]
      }

      assert %StageResult{status: :failed, step_results: step_results} =
               Executor.execute(stage)

      statuses = Map.new(step_results, &{&1.name, &1.status})
      assert statuses[:fast] == :passed
      assert statuses[:slow] == :failed
    end

    test "timed out step records duration close to timeout value" do
      stage = %Stage{
        name: :test,
        mode: :serial,
        steps: [%Step{name: :slow, cmd: "sleep 10", timeout: 200}]
      }

      %StageResult{step_results: [step]} = Executor.execute(stage)
      # Duration should be roughly around the timeout, not the full sleep
      assert step.duration_ms < 2_000
    end
  end

  describe "execute/2 with generic set config" do
    defmodule ConfigCapture do
      @moduledoc false
      def execute(config, _ctx) do
        send(self(), {:config_received, config})
        :ok
      end
    end

    test "module step receives arbitrary config from config_block" do
      stage = %Stage{
        name: :deploy,
        mode: :serial,
        steps: [
          %Step{
            name: :go,
            module: ConfigCapture,
            config_block: fn -> [app: "my-app", region: "us-east-1", replicas: 3] end
          }
        ]
      }

      Executor.execute(stage)
      assert_received {:config_received, config}
      assert config == [app: "my-app", region: "us-east-1", replicas: 3]
    end

    test "module step receives empty config when no config_block" do
      stage = %Stage{
        name: :deploy,
        mode: :serial,
        steps: [%Step{name: :go, module: ConfigCapture}]
      }

      Executor.execute(stage)
      assert_received {:config_received, config}
      assert config == %{}
    end
  end

  describe "run_pipeline/2 with all stages skipped" do
    test "returns ok when every stage is skipped" do
      stages = [
        %Stage{
          name: :a,
          mode: :serial,
          when_condition: fn _ctx -> false end,
          steps: [%Step{name: :nope, cmd: "false"}]
        },
        %Stage{
          name: :b,
          mode: :serial,
          when_condition: fn _ctx -> false end,
          steps: [%Step{name: :nope2, cmd: "false"}]
        }
      ]

      assert {:ok, results} = Executor.run_pipeline(stages)
      assert length(results) == 2
      assert Enum.all?(results, &(&1.status == :skipped))
    end

    test "skipped stages have zero duration" do
      stages = [
        %Stage{
          name: :skip_me,
          mode: :serial,
          when_condition: fn _ctx -> false end,
          steps: [%Step{name: :nope, cmd: "sleep 10"}]
        }
      ]

      assert {:ok, [result]} = Executor.run_pipeline(stages)
      assert result.duration_ms == 0
      assert result.step_results == []
    end
  end

  describe "run_pipeline/2 with mixed mode stages" do
    test "serial stage followed by parallel stage both pass" do
      stages = [
        %Stage{
          name: :serial_stage,
          mode: :serial,
          steps: [
            %Step{name: :a, cmd: "echo serial_a"},
            %Step{name: :b, cmd: "echo serial_b"}
          ]
        },
        %Stage{
          name: :parallel_stage,
          mode: :parallel,
          steps: [
            %Step{name: :c, cmd: "echo parallel_c"},
            %Step{name: :d, cmd: "echo parallel_d"}
          ]
        }
      ]

      assert {:ok, results} = Executor.run_pipeline(stages)

      assert [
               %StageResult{name: :serial_stage, status: :passed},
               %StageResult{name: :parallel_stage, status: :passed}
             ] = results
    end

    test "failure in first serial stage prevents parallel stage from running" do
      stages = [
        %Stage{
          name: :serial_stage,
          mode: :serial,
          steps: [
            %Step{name: :pass, cmd: "true"},
            %Step{name: :fail, cmd: "false"}
          ]
        },
        %Stage{
          name: :parallel_stage,
          mode: :parallel,
          steps: [%Step{name: :should_not_run, cmd: "true"}]
        }
      ]

      assert {:error, {:stage_failed, :serial_stage, _reason}, results} =
               Executor.run_pipeline(stages)

      assert length(results) == 1
      assert [%StageResult{name: :serial_stage, status: :failed}] = results
    end
  end

  describe "run_pipeline/2 failure propagation" do
    test "collects passed stages before the failing one" do
      stages = [
        %Stage{name: :first, mode: :serial, steps: [%Step{name: :ok1, cmd: "true"}]},
        %Stage{name: :second, mode: :serial, steps: [%Step{name: :ok2, cmd: "true"}]},
        %Stage{name: :third, mode: :serial, steps: [%Step{name: :fail, cmd: "false"}]},
        %Stage{name: :fourth, mode: :serial, steps: [%Step{name: :ok3, cmd: "true"}]}
      ]

      assert {:error, {:stage_failed, :third, _reason}, results} =
               Executor.run_pipeline(stages)

      assert length(results) == 3

      assert [
               %StageResult{name: :first, status: :passed},
               %StageResult{name: :second, status: :passed},
               %StageResult{name: :third, status: :failed}
             ] = results
    end

    test "skipped stage before failure is included in results" do
      context = %{branch: "develop"}

      stages = [
        %Stage{
          name: :deploy,
          mode: :serial,
          when_condition: fn ctx -> ctx.branch == "main" end,
          steps: [%Step{name: :nope, cmd: "false"}]
        },
        %Stage{name: :test, mode: :serial, steps: [%Step{name: :fail, cmd: "false"}]}
      ]

      assert {:error, {:stage_failed, :test, _reason}, results} =
               Executor.run_pipeline(stages, context)

      assert [
               %StageResult{name: :deploy, status: :skipped},
               %StageResult{name: :test, status: :failed}
             ] = results
    end
  end

  describe "execute/2 serial mode halts correctly" do
    test "only runs steps up to and including the first failure" do
      stage = %Stage{
        name: :test,
        mode: :serial,
        steps: [
          %Step{name: :pass1, cmd: "true"},
          %Step{name: :pass2, cmd: "true"},
          %Step{name: :fail, cmd: "false"},
          %Step{name: :never1, cmd: "true"},
          %Step{name: :never2, cmd: "true"}
        ]
      }

      assert %StageResult{status: :failed, step_results: step_results} = Executor.execute(stage)

      names = Enum.map(step_results, & &1.name)
      assert names == [:pass1, :pass2, :fail]
      assert Enum.at(step_results, 0).status == :passed
      assert Enum.at(step_results, 1).status == :passed
      assert Enum.at(step_results, 2).status == :failed
    end
  end

  describe "execute/2 parallel mode runs all steps" do
    test "all parallel steps run even when some fail" do
      stage = %Stage{
        name: :test,
        mode: :parallel,
        steps: [
          %Step{name: :fail1, cmd: "false"},
          %Step{name: :pass, cmd: "echo ok"},
          %Step{name: :fail2, cmd: "false"}
        ]
      }

      assert %StageResult{status: :failed, step_results: step_results} = Executor.execute(stage)

      assert length(step_results) == 3
      statuses = Map.new(step_results, &{&1.name, &1.status})
      assert statuses[:fail1] == :failed
      assert statuses[:pass] == :passed
      assert statuses[:fail2] == :failed
    end

    test "parallel step output is captured independently" do
      stage = %Stage{
        name: :test,
        mode: :parallel,
        steps: [
          %Step{name: :hello, cmd: "echo hello_from_step_a"},
          %Step{name: :world, cmd: "echo hello_from_step_b"}
        ]
      }

      %StageResult{step_results: step_results} = Executor.execute(stage)

      hello = Enum.find(step_results, &(&1.name == :hello))
      world = Enum.find(step_results, &(&1.name == :world))

      assert hello.output =~ "hello_from_step_a"
      refute hello.output =~ "hello_from_step_b"
      assert world.output =~ "hello_from_step_b"
      refute world.output =~ "hello_from_step_a"
    end
  end

  describe "execute/2 with module steps in parallel" do
    defmodule ParallelModuleStep do
      @moduledoc false
      def execute(config, _ctx) do
        send(config[:caller], {:executed, config[:id]})
        :ok
      end
    end

    test "module steps run in parallel mode" do
      caller = self()

      stage = %Stage{
        name: :deploy,
        mode: :parallel,
        steps: [
          %Step{
            name: :step_a,
            module: ParallelModuleStep,
            config_block: fn -> [caller: caller, id: :a] end
          },
          %Step{
            name: :step_b,
            module: ParallelModuleStep,
            config_block: fn -> [caller: caller, id: :b] end
          }
        ]
      }

      assert %StageResult{status: :passed} = Executor.execute(stage)

      assert_received {:executed, :a}
      assert_received {:executed, :b}
    end
  end

  describe "execute/2 with allow_failure steps" do
    test "allow_failure step failure does not halt serial execution" do
      stage = %Stage{
        name: :test,
        mode: :serial,
        steps: [
          %Step{name: :flaky, cmd: "false", allow_failure: true},
          %Step{name: :important, cmd: "true"}
        ]
      }

      assert %StageResult{status: :passed, step_results: step_results} = Executor.execute(stage)

      assert length(step_results) == 2
      assert Enum.at(step_results, 0).name == :flaky
      assert Enum.at(step_results, 0).status == :failed
      assert Enum.at(step_results, 0).allowed_failure == true
      assert Enum.at(step_results, 1).name == :important
      assert Enum.at(step_results, 1).status == :passed
    end

    test "stage passes when only allow_failure steps fail" do
      stage = %Stage{
        name: :test,
        mode: :serial,
        steps: [
          %Step{name: :ok, cmd: "true"},
          %Step{name: :flaky, cmd: "false", allow_failure: true},
          %Step{name: :also_ok, cmd: "true"}
        ]
      }

      assert %StageResult{status: :passed} = Executor.execute(stage)
    end

    test "stage fails when a non-allow_failure step fails" do
      stage = %Stage{
        name: :test,
        mode: :serial,
        steps: [
          %Step{name: :flaky, cmd: "false", allow_failure: true},
          %Step{name: :critical, cmd: "false"}
        ]
      }

      assert %StageResult{status: :failed, step_results: step_results} = Executor.execute(stage)

      assert length(step_results) == 2
      assert Enum.at(step_results, 0).allowed_failure == true
      assert Enum.at(step_results, 1).allowed_failure == false
    end

    test "allow_failure works in parallel mode" do
      stage = %Stage{
        name: :test,
        mode: :parallel,
        steps: [
          %Step{name: :pass, cmd: "true"},
          %Step{name: :flaky, cmd: "false", allow_failure: true}
        ]
      }

      assert %StageResult{status: :passed, step_results: step_results} = Executor.execute(stage)

      statuses = Map.new(step_results, &{&1.name, &1.status})
      assert statuses[:pass] == :passed
      assert statuses[:flaky] == :failed

      flaky = Enum.find(step_results, &(&1.name == :flaky))
      assert flaky.allowed_failure == true
    end

    test "parallel stage fails when non-allow_failure step fails" do
      stage = %Stage{
        name: :test,
        mode: :parallel,
        steps: [
          %Step{name: :flaky, cmd: "false", allow_failure: true},
          %Step{name: :critical, cmd: "false"}
        ]
      }

      assert %StageResult{status: :failed} = Executor.execute(stage)
    end

    test "allow_failure defaults to false" do
      stage = %Stage{
        name: :test,
        mode: :serial,
        steps: [%Step{name: :normal, cmd: "true"}]
      }

      assert %StageResult{step_results: [step_result]} = Executor.execute(stage)
      assert step_result.allowed_failure == false
    end

    test "allow_failure step with module that returns error" do
      stage = %Stage{
        name: :deploy,
        mode: :serial,
        steps: [
          %Step{name: :flaky_mod, module: TinyCI.ExecutorTest.FailStep, allow_failure: true},
          %Step{name: :next, cmd: "true"}
        ]
      }

      assert %StageResult{status: :passed, step_results: step_results} = Executor.execute(stage)

      assert length(step_results) == 2
      assert Enum.at(step_results, 0).status == :failed
      assert Enum.at(step_results, 0).allowed_failure == true
      assert Enum.at(step_results, 1).status == :passed
    end
  end

  describe "run_pipeline/3 with output: :buffered" do
    test "behaves identically to default (buffered output not printed during execution)" do
      stages = [
        %Stage{
          name: :test,
          mode: :serial,
          steps: [%Step{name: :echo, cmd: "echo buffered_pipeline"}]
        }
      ]

      assert {:ok, [%StageResult{status: :passed}]} =
               Executor.run_pipeline(stages, %{branch: "main"}, output: :buffered)
    end
  end

  describe "execute/2 with store data from module steps" do
    defmodule StoreProducer do
      @moduledoc false
      def execute(_config, _ctx), do: {:ok, %{image_tag: "v1.2.3"}}
    end

    defmodule StoreProducerMulti do
      @moduledoc false
      def execute(_config, _ctx), do: {:ok, %{region: "us-east-1", replicas: 3}}
    end

    defmodule StoreReader do
      @moduledoc false
      def execute(_config, ctx) do
        send(self(), {:store_snapshot, ctx.store})
        :ok
      end
    end

    test "module step returning {:ok, map} sets store_data on step result" do
      stage = %Stage{
        name: :build,
        mode: :serial,
        steps: [%Step{name: :docker, module: StoreProducer}]
      }

      %StageResult{step_results: [step]} = Executor.execute(stage)
      assert step.status == :passed
      assert step.store_data == %{image_tag: "v1.2.3"}
    end

    test "module step returning :ok has empty store_data" do
      stage = %Stage{
        name: :deploy,
        mode: :serial,
        steps: [%Step{name: :go, module: TinyCI.ExecutorTest.SuccessStep}]
      }

      %StageResult{step_results: [step]} = Executor.execute(stage)
      assert step.store_data == %{}
    end

    test "serial steps see accumulated store in context" do
      context = %{branch: "main", store: %{}}

      stage = %Stage{
        name: :build,
        mode: :serial,
        steps: [
          %Step{name: :docker, module: StoreProducer},
          %Step{name: :reader, module: StoreReader}
        ]
      }

      Executor.execute(stage, context)
      assert_received {:store_snapshot, %{image_tag: "v1.2.3"}}
    end

    test "parallel steps all see the same initial store" do
      context = %{branch: "main", store: %{existing: "data"}}

      defmodule ParallelStoreReader do
        @moduledoc false
        def execute(_config, ctx) do
          send(ctx[:test_pid], {:par_store, ctx.store})
          :ok
        end
      end

      stage = %Stage{
        name: :check,
        mode: :parallel,
        steps: [
          %Step{
            name: :reader_a,
            module: ParallelStoreReader,
            config_block: fn -> [] end
          },
          %Step{
            name: :reader_b,
            module: ParallelStoreReader,
            config_block: fn -> [] end
          }
        ]
      }

      Executor.execute(stage, Map.put(context, :test_pid, self()))
      assert_received {:par_store, %{existing: "data"}}
      assert_received {:par_store, %{existing: "data"}}
    end

    test "stage result carries accumulated store" do
      context = %{branch: "main", store: %{prior: "value"}}

      stage = %Stage{
        name: :build,
        mode: :serial,
        steps: [%Step{name: :docker, module: StoreProducer}]
      }

      result = Executor.execute(stage, context)
      assert result.store == %{prior: "value", image_tag: "v1.2.3"}
    end

    test "parallel step store_data is merged into stage store" do
      context = %{branch: "main", store: %{}}

      stage = %Stage{
        name: :build,
        mode: :parallel,
        steps: [
          %Step{name: :docker, module: StoreProducer},
          %Step{name: :config, module: StoreProducerMulti}
        ]
      }

      result = Executor.execute(stage, context)
      assert result.store == %{image_tag: "v1.2.3", region: "us-east-1", replicas: 3}
    end

    test "skipped stage preserves existing store" do
      context = %{branch: "main", store: %{existing: "data"}}

      stage = %Stage{
        name: :deploy,
        mode: :serial,
        when_condition: fn _ctx -> false end,
        steps: [%Step{name: :nope, cmd: "false"}]
      }

      result = Executor.execute(stage, context)
      assert result.status == :skipped
      assert result.store == %{existing: "data"}
    end

    test "cmd step has empty store_data" do
      stage = %Stage{
        name: :test,
        mode: :serial,
        steps: [%Step{name: :echo, cmd: "echo hello"}]
      }

      %StageResult{step_results: [step]} = Executor.execute(stage)
      assert step.store_data == %{}
    end
  end

  describe "run_pipeline/2 with store accumulation across stages" do
    defmodule PipelineStoreProducer do
      @moduledoc false
      def execute(_config, _ctx), do: {:ok, %{image_tag: "v2.0"}}
    end

    defmodule PipelineStoreConsumer do
      @moduledoc false
      def execute(_config, ctx) do
        send(self(), {:pipeline_store, ctx.store})
        :ok
      end
    end

    test "store accumulates across stages" do
      stages = [
        %Stage{
          name: :build,
          mode: :serial,
          steps: [%Step{name: :docker, module: PipelineStoreProducer}]
        },
        %Stage{
          name: :deploy,
          mode: :serial,
          steps: [%Step{name: :reader, module: PipelineStoreConsumer}]
        }
      ]

      context = %{branch: "main", store: %{}}
      assert {:ok, results} = Executor.run_pipeline(stages, context)

      assert_received {:pipeline_store, %{image_tag: "v2.0"}}

      [build_result, deploy_result] = results
      assert build_result.store == %{image_tag: "v2.0"}
      assert deploy_result.store == %{image_tag: "v2.0"}
    end

    test "store defaults to empty map when context has no store" do
      stages = [
        %Stage{
          name: :build,
          mode: :serial,
          steps: [%Step{name: :docker, module: PipelineStoreProducer}]
        }
      ]

      assert {:ok, [result]} = Executor.run_pipeline(stages, %{branch: "main"})
      assert result.store == %{image_tag: "v2.0"}
    end

    test "skipped stage does not lose store data" do
      stages = [
        %Stage{
          name: :build,
          mode: :serial,
          steps: [%Step{name: :docker, module: PipelineStoreProducer}]
        },
        %Stage{
          name: :skipped,
          mode: :serial,
          when_condition: fn _ctx -> false end,
          steps: [%Step{name: :nope, cmd: "false"}]
        },
        %Stage{
          name: :deploy,
          mode: :serial,
          steps: [%Step{name: :reader, module: PipelineStoreConsumer}]
        }
      ]

      context = %{branch: "main", store: %{}}
      assert {:ok, results} = Executor.run_pipeline(stages, context)

      assert_received {:pipeline_store, %{image_tag: "v2.0"}}

      skipped_result = Enum.find(results, &(&1.name == :skipped))
      assert skipped_result.store == %{image_tag: "v2.0"}
    end
  end

  describe "store-to-env interpolation for shell commands" do
    defmodule EnvStoreProducer do
      @moduledoc false
      def execute(_config, _ctx), do: {:ok, %{image_tag: "v3.0", deploy_env: "staging"}}
    end

    test "store(:key) in env map resolves to store value for shell steps" do
      context = %{branch: "main", store: %{image_tag: "v1.0"}}

      stage = %Stage{
        name: :test,
        mode: :serial,
        steps: [
          %Step{name: :check, cmd: ~s(echo "$TAG"), env: %{"TAG" => {:store, :image_tag}}}
        ]
      }

      %StageResult{step_results: [step]} = Executor.execute(stage, context)
      assert step.output =~ "v1.0"
    end

    test "store references accumulate through serial steps across stages" do
      stages = [
        %Stage{
          name: :build,
          mode: :serial,
          steps: [%Step{name: :docker, module: EnvStoreProducer}]
        },
        %Stage{
          name: :verify,
          mode: :serial,
          steps: [
            %Step{
              name: :check,
              cmd: ~s(echo "$IMAGE_TAG-$DEPLOY_ENV"),
              env: %{"IMAGE_TAG" => {:store, :image_tag}, "DEPLOY_ENV" => {:store, :deploy_env}}
            }
          ]
        }
      ]

      context = %{branch: "main", store: %{}}
      assert {:ok, [_build, verify]} = Executor.run_pipeline(stages, context)

      [step] = verify.step_results
      assert step.output =~ "v3.0-staging"
    end

    test "store reference missing from store resolves to empty string" do
      context = %{branch: "main", store: %{}}

      stage = %Stage{
        name: :test,
        mode: :serial,
        steps: [
          %Step{name: :check, cmd: ~s(echo "tag=$TAG"), env: %{"TAG" => {:store, :missing_key}}}
        ]
      }

      %StageResult{step_results: [step]} = Executor.execute(stage, context)
      assert step.output =~ "tag="
    end

    test "store is not automatically injected into shell step env" do
      context = %{branch: "main", store: %{secret_token: "s3cr3t"}}

      stage = %Stage{
        name: :test,
        mode: :serial,
        steps: [
          %Step{name: :check, cmd: ~s(env | grep TINY_CI_STORE || true)}
        ]
      }

      %StageResult{step_results: [step]} = Executor.execute(stage, context)
      refute step.output =~ "TINY_CI_STORE"
    end
  end

  describe "run_pipeline/3 with output: :streaming" do
    test "streams serial step output to stdout during execution" do
      stages = [
        %Stage{
          name: :test,
          mode: :serial,
          steps: [%Step{name: :echo, cmd: "echo streamed_serial"}]
        }
      ]

      io_output =
        ExUnit.CaptureIO.capture_io(fn ->
          {:ok, _results} =
            Executor.run_pipeline(stages, %{branch: "main"}, output: :streaming)
        end)

      assert io_output =~ "streamed_serial"
    end

    test "streams parallel step output with step name prefix" do
      stages = [
        %Stage{
          name: :test,
          mode: :parallel,
          steps: [
            %Step{name: :alpha, cmd: "echo alpha_output"},
            %Step{name: :beta, cmd: "echo beta_output"}
          ]
        }
      ]

      io_output =
        ExUnit.CaptureIO.capture_io(fn ->
          {:ok, _results} =
            Executor.run_pipeline(stages, %{branch: "main"}, output: :streaming)
        end)

      assert io_output =~ "[alpha]"
      assert io_output =~ "alpha_output"
      assert io_output =~ "[beta]"
      assert io_output =~ "beta_output"
    end

    test "still captures output in StepResult" do
      stages = [
        %Stage{
          name: :test,
          mode: :serial,
          steps: [%Step{name: :echo, cmd: "echo captured_in_result"}]
        }
      ]

      {result, _io} =
        ExUnit.CaptureIO.with_io(fn ->
          Executor.run_pipeline(stages, %{branch: "main"}, output: :streaming)
        end)

      assert {:ok, [%StageResult{step_results: [step]}]} = result
      assert step.output =~ "captured_in_result"
    end

    test "does not print buffered output after stage in streaming mode" do
      stages = [
        %Stage{
          name: :test,
          mode: :serial,
          steps: [%Step{name: :echo, cmd: "echo unique_marker_xyz"}]
        }
      ]

      io_output =
        ExUnit.CaptureIO.capture_io(fn ->
          {:ok, _results} =
            Executor.run_pipeline(stages, %{branch: "main"}, output: :streaming)
        end)

      # The output should appear exactly once (streamed), not twice (streamed + buffered)
      occurrences =
        io_output
        |> String.split("unique_marker_xyz")
        |> length()
        |> Kernel.-(1)

      assert occurrences == 1
    end

    test "serial steps stream without prefix" do
      stages = [
        %Stage{
          name: :test,
          mode: :serial,
          steps: [%Step{name: :echo, cmd: "echo serial_no_prefix"}]
        }
      ]

      io_output =
        ExUnit.CaptureIO.capture_io(fn ->
          {:ok, _results} =
            Executor.run_pipeline(stages, %{branch: "main"}, output: :streaming)
        end)

      assert io_output =~ "serial_no_prefix"
      refute io_output =~ "[echo]"
    end

    test "timeout still works in streaming mode" do
      stages = [
        %Stage{
          name: :test,
          mode: :serial,
          steps: [%Step{name: :slow, cmd: "sleep 10", timeout: 100}]
        }
      ]

      {result, _io} =
        ExUnit.CaptureIO.with_io(fn ->
          Executor.run_pipeline(stages, %{branch: "main"}, output: :streaming)
        end)

      assert {:error, {:stage_failed, :test, _reason}, [%StageResult{status: :failed}]} = result
    end
  end

  describe "run_pipeline/2 with DAG (needs:)" do
    test "independent stages run and all pass" do
      stages = [
        %Stage{name: :build, needs: [], mode: :serial, steps: [%Step{name: :b, cmd: "true"}]},
        %Stage{name: :lint, needs: [], mode: :serial, steps: [%Step{name: :l, cmd: "true"}]}
      ]

      assert {:ok, results} = Executor.run_pipeline(stages)
      assert length(results) == 2
      assert Enum.all?(results, &(&1.status == :passed))
    end

    test "dependent stage runs after its dependency" do
      stages = [
        %Stage{name: :build, needs: [], mode: :serial, steps: [%Step{name: :b, cmd: "true"}]},
        %Stage{
          name: :deploy,
          needs: [:build],
          mode: :serial,
          steps: [%Step{name: :d, cmd: "true"}]
        }
      ]

      assert {:ok, results} = Executor.run_pipeline(stages)
      names = Enum.map(results, & &1.name)
      assert :build in names
      assert :deploy in names
      assert Enum.all?(results, &(&1.status == :passed))
    end

    test "dependent stage is skipped when its dependency fails" do
      stages = [
        %Stage{name: :build, needs: [], mode: :serial, steps: [%Step{name: :b, cmd: "false"}]},
        %Stage{
          name: :deploy,
          needs: [:build],
          mode: :serial,
          steps: [%Step{name: :d, cmd: "true"}]
        }
      ]

      assert {:error, {:stage_failed, :build, _}, results} = Executor.run_pipeline(stages)
      build_result = Enum.find(results, &(&1.name == :build))
      deploy_result = Enum.find(results, &(&1.name == :deploy))
      assert build_result.status == :failed
      assert deploy_result.status == :skipped
    end

    test "independent stage still runs when unrelated stage fails" do
      stages = [
        %Stage{name: :build, needs: [], mode: :serial, steps: [%Step{name: :b, cmd: "false"}]},
        %Stage{name: :lint, needs: [], mode: :serial, steps: [%Step{name: :l, cmd: "true"}]},
        %Stage{
          name: :deploy,
          needs: [:build],
          mode: :serial,
          steps: [%Step{name: :d, cmd: "true"}]
        }
      ]

      assert {:error, {:stage_failed, :build, _}, results} = Executor.run_pipeline(stages)
      lint_result = Enum.find(results, &(&1.name == :lint))
      assert lint_result.status == :passed
    end

    test "transitive skip: grandchild is skipped when grandparent fails" do
      stages = [
        %Stage{name: :a, needs: [], mode: :serial, steps: [%Step{name: :s, cmd: "false"}]},
        %Stage{name: :b, needs: [:a], mode: :serial, steps: [%Step{name: :s, cmd: "true"}]},
        %Stage{name: :c, needs: [:b], mode: :serial, steps: [%Step{name: :s, cmd: "true"}]}
      ]

      assert {:error, {:stage_failed, :a, _}, results} = Executor.run_pipeline(stages)
      b_result = Enum.find(results, &(&1.name == :b))
      c_result = Enum.find(results, &(&1.name == :c))
      assert b_result.status == :skipped
      assert c_result.status == :skipped
    end

    test "returns ok when all stages pass in a linear DAG" do
      stages = [
        %Stage{name: :a, needs: [], mode: :serial, steps: [%Step{name: :s, cmd: "true"}]},
        %Stage{name: :b, needs: [:a], mode: :serial, steps: [%Step{name: :s, cmd: "true"}]},
        %Stage{name: :c, needs: [:b], mode: :serial, steps: [%Step{name: :s, cmd: "true"}]}
      ]

      assert {:ok, results} = Executor.run_pipeline(stages)
      assert Enum.all?(results, &(&1.status == :passed))
    end
  end

  describe "execute/2 with matrix stages" do
    test "produces one MatrixRunResult per combination" do
      stage = %Stage{
        name: :test,
        mode: :serial,
        matrix: [elixir: ["1.17", "1.18"], otp: ["26", "27"]],
        steps: [%Step{name: :unit, cmd: "true"}]
      }

      assert %StageResult{matrix_runs: runs} = Executor.execute(stage)
      assert length(runs) == 4
    end

    test "matrix stage passes when all combinations pass" do
      stage = %Stage{
        name: :test,
        mode: :serial,
        matrix: [elixir: ["1.17", "1.18"]],
        steps: [%Step{name: :unit, cmd: "true"}]
      }

      assert %StageResult{status: :passed} = Executor.execute(stage)
    end

    test "matrix stage fails when any combination fails" do
      stage = %Stage{
        name: :test,
        mode: :serial,
        matrix: [result: ["pass", "fail"]],
        steps: [%Step{name: :unit, cmd: "test \"$RESULT\" = pass"}]
      }

      assert %StageResult{status: :failed, matrix_runs: runs} = Executor.execute(stage)
      statuses = Map.new(runs, fn r -> {Keyword.fetch!(r.combination, :result), r.status} end)
      assert statuses["pass"] == :passed
      assert statuses["fail"] == :failed
    end

    test "matrix stage passes with allow_failure: true even when a combination fails" do
      stage = %Stage{
        name: :test,
        mode: :serial,
        matrix: [result: ["pass", "fail"]],
        allow_failure: true,
        steps: [%Step{name: :unit, cmd: "test \"$RESULT\" = pass"}]
      }

      assert %StageResult{status: :passed} = Executor.execute(stage)
    end

    test "each combination receives uppercased env vars" do
      stage = %Stage{
        name: :test,
        mode: :serial,
        matrix: [lang: ["elixir"]],
        steps: [%Step{name: :check, cmd: ~s(test "$LANG" = "elixir")}]
      }

      assert %StageResult{status: :passed} = Executor.execute(stage)
    end

    test "combination values are added to the store for module steps" do
      defmodule StoreCheck do
        @moduledoc false
        def execute(_config, ctx) do
          send(ctx[:test_pid], {:store, ctx.store})
          :ok
        end
      end

      stage = %Stage{
        name: :test,
        mode: :serial,
        matrix: [version: ["1.0"]],
        steps: [%Step{name: :check, module: StoreCheck}]
      }

      Executor.execute(stage, %{test_pid: self()})
      assert_received {:store, store}
      assert store[:version] == "1.0"
    end

    test "max_parallel limits concurrency" do
      stage = %Stage{
        name: :test,
        mode: :serial,
        matrix: [n: ["1", "2", "3", "4"]],
        max_parallel: 2,
        steps: [%Step{name: :unit, cmd: "true"}]
      }

      assert %StageResult{status: :passed, matrix_runs: runs} = Executor.execute(stage)
      assert length(runs) == 4
    end

    test "matrix stage skips when when_condition is false" do
      stage = %Stage{
        name: :test,
        mode: :serial,
        matrix: [elixir: ["1.17", "1.18"]],
        when_condition: fn _ctx -> false end,
        steps: [%Step{name: :unit, cmd: "false"}]
      }

      assert %StageResult{status: :skipped, matrix_runs: []} = Executor.execute(stage)
    end
  end

  describe "run_pipeline/2 with matrix stages" do
    test "matrix stage integrates into pipeline results" do
      stages = [
        %Stage{
          name: :test,
          mode: :serial,
          matrix: [elixir: ["1.17", "1.18"]],
          steps: [%Step{name: :unit, cmd: "true"}]
        }
      ]

      assert {:ok, [result]} = Executor.run_pipeline(stages)
      assert result.status == :passed
      assert length(result.matrix_runs) == 2
    end

    test "failing matrix stage halts the pipeline" do
      stages = [
        %Stage{
          name: :test,
          mode: :serial,
          matrix: [result: ["fail"]],
          steps: [%Step{name: :unit, cmd: "false"}]
        },
        %Stage{name: :deploy, mode: :serial, steps: [%Step{name: :d, cmd: "true"}]}
      ]

      assert {:error, {:stage_failed, :test, _}, results} = Executor.run_pipeline(stages)
      assert length(results) == 1
    end
  end
end
