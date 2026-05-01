defmodule TinyCI.ResultsTest do
  use ExUnit.Case, async: true

  alias TinyCI.{MatrixRunResult, Results, StageResult, StepResult}

  defp decode(json_string), do: Jason.decode!(json_string)

  describe "to_json/2 — top-level shape" do
    test "passed pipeline has status passed" do
      results = [%StageResult{name: :test, status: :passed, duration_ms: 100}]
      json = decode(Results.to_json(:ok, results))

      assert json["status"] == "passed"
    end

    test "failed pipeline has status failed" do
      results = [%StageResult{name: :test, status: :failed, duration_ms: 50}]
      json = decode(Results.to_json({:error, :some_reason}, results))

      assert json["status"] == "failed"
    end

    test "top-level duration_ms is sum of all stage durations" do
      results = [
        %StageResult{name: :a, status: :passed, duration_ms: 100},
        %StageResult{name: :b, status: :passed, duration_ms: 200}
      ]

      json = decode(Results.to_json(:ok, results))
      assert json["duration_ms"] == 300
    end

    test "stages array is present" do
      results = [
        %StageResult{name: :build, status: :passed, duration_ms: 50},
        %StageResult{name: :test, status: :passed, duration_ms: 75}
      ]

      json = decode(Results.to_json(:ok, results))
      assert length(json["stages"]) == 2
    end

    test "empty pipeline encodes without error" do
      json = decode(Results.to_json(:ok, []))

      assert json["status"] == "passed"
      assert json["stages"] == []
      assert json["duration_ms"] == 0
    end
  end

  describe "to_json/2 — stage shape" do
    test "stage name is a string" do
      results = [%StageResult{name: :build, status: :passed, duration_ms: 10}]
      json = decode(Results.to_json(:ok, results))
      stage = hd(json["stages"])

      assert stage["name"] == "build"
    end

    test "stage status is a string" do
      results = [%StageResult{name: :build, status: :skipped, duration_ms: 0}]
      json = decode(Results.to_json(:ok, results))
      stage = hd(json["stages"])

      assert stage["status"] == "skipped"
    end

    test "stage duration_ms is an integer" do
      results = [%StageResult{name: :build, status: :passed, duration_ms: 123}]
      json = decode(Results.to_json(:ok, results))
      stage = hd(json["stages"])

      assert stage["duration_ms"] == 123
    end

    test "skipped stage appears with skipped status" do
      results = [
        %StageResult{name: :deploy, status: :skipped, duration_ms: 0, step_results: []}
      ]

      json = decode(Results.to_json(:ok, results))
      stage = hd(json["stages"])

      assert stage["status"] == "skipped"
      assert stage["steps"] == []
    end

    test "stage without matrix runs has empty matrix_runs" do
      results = [
        %StageResult{
          name: :test,
          status: :passed,
          duration_ms: 10,
          step_results: [%StepResult{name: :unit, status: :passed, duration_ms: 5}],
          matrix_runs: []
        }
      ]

      json = decode(Results.to_json(:ok, results))
      stage = hd(json["stages"])

      assert stage["matrix_runs"] == []
    end
  end

  describe "to_json/2 — step shape" do
    test "step name is a string" do
      results = [
        %StageResult{
          name: :test,
          status: :passed,
          duration_ms: 10,
          step_results: [%StepResult{name: :unit, status: :passed, duration_ms: 5}]
        }
      ]

      json = decode(Results.to_json(:ok, results))
      step = json["stages"] |> hd() |> Map.get("steps") |> hd()

      assert step["name"] == "unit"
    end

    test "step status is a string" do
      results = [
        %StageResult{
          name: :test,
          status: :failed,
          duration_ms: 10,
          step_results: [%StepResult{name: :unit, status: :failed, duration_ms: 5}]
        }
      ]

      json = decode(Results.to_json(:ok, results))
      step = json["stages"] |> hd() |> Map.get("steps") |> hd()

      assert step["status"] == "failed"
    end

    test "step includes output field" do
      results = [
        %StageResult{
          name: :test,
          status: :passed,
          duration_ms: 10,
          step_results: [
            %StepResult{name: :unit, status: :passed, duration_ms: 5, output: "hello\n"}
          ]
        }
      ]

      json = decode(Results.to_json(:ok, results))
      step = json["stages"] |> hd() |> Map.get("steps") |> hd()

      assert step["output"] == "hello\n"
    end

    test "step includes attempts field" do
      results = [
        %StageResult{
          name: :test,
          status: :passed,
          duration_ms: 10,
          step_results: [
            %StepResult{name: :unit, status: :passed, duration_ms: 5, attempts: 3}
          ]
        }
      ]

      json = decode(Results.to_json(:ok, results))
      step = json["stages"] |> hd() |> Map.get("steps") |> hd()

      assert step["attempts"] == 3
    end

    test "allowed_failure step serializes allowed_failure as true" do
      results = [
        %StageResult{
          name: :test,
          status: :passed,
          duration_ms: 10,
          step_results: [
            %StepResult{
              name: :flaky,
              status: :failed,
              duration_ms: 5,
              allowed_failure: true
            }
          ]
        }
      ]

      json = decode(Results.to_json(:ok, results))
      step = json["stages"] |> hd() |> Map.get("steps") |> hd()

      assert step["allowed_failure"] == true
    end

    test "normal step serializes allowed_failure as false" do
      results = [
        %StageResult{
          name: :test,
          status: :passed,
          duration_ms: 10,
          step_results: [%StepResult{name: :unit, status: :passed, duration_ms: 5}]
        }
      ]

      json = decode(Results.to_json(:ok, results))
      step = json["stages"] |> hd() |> Map.get("steps") |> hd()

      assert step["allowed_failure"] == false
    end
  end

  describe "to_json/2 — matrix stage shape" do
    test "matrix stage has matrix_runs array" do
      results = [
        %StageResult{
          name: :test,
          status: :passed,
          duration_ms: 200,
          step_results: [],
          matrix_runs: [
            %MatrixRunResult{
              combination: [elixir: "1.17", otp: "26"],
              status: :passed,
              duration_ms: 100,
              step_results: [%StepResult{name: :unit, status: :passed, duration_ms: 50}]
            },
            %MatrixRunResult{
              combination: [elixir: "1.18", otp: "27"],
              status: :passed,
              duration_ms: 100,
              step_results: [%StepResult{name: :unit, status: :passed, duration_ms: 50}]
            }
          ]
        }
      ]

      json = decode(Results.to_json(:ok, results))
      stage = hd(json["stages"])

      assert length(stage["matrix_runs"]) == 2
    end

    test "matrix run combination is a map of string keys and values" do
      results = [
        %StageResult{
          name: :test,
          status: :passed,
          duration_ms: 100,
          step_results: [],
          matrix_runs: [
            %MatrixRunResult{
              combination: [elixir: "1.17", otp: "26"],
              status: :passed,
              duration_ms: 50,
              step_results: []
            }
          ]
        }
      ]

      json = decode(Results.to_json(:ok, results))
      run = json["stages"] |> hd() |> Map.get("matrix_runs") |> hd()

      assert run["combination"] == %{"elixir" => "1.17", "otp" => "26"}
    end

    test "matrix run has status and duration_ms" do
      results = [
        %StageResult{
          name: :test,
          status: :passed,
          duration_ms: 100,
          step_results: [],
          matrix_runs: [
            %MatrixRunResult{
              combination: [elixir: "1.17"],
              status: :failed,
              duration_ms: 75,
              step_results: []
            }
          ]
        }
      ]

      json = decode(Results.to_json(:ok, results))
      run = json["stages"] |> hd() |> Map.get("matrix_runs") |> hd()

      assert run["status"] == "failed"
      assert run["duration_ms"] == 75
    end

    test "matrix run includes its steps" do
      results = [
        %StageResult{
          name: :test,
          status: :passed,
          duration_ms: 100,
          step_results: [],
          matrix_runs: [
            %MatrixRunResult{
              combination: [elixir: "1.17"],
              status: :passed,
              duration_ms: 50,
              step_results: [
                %StepResult{name: :unit, status: :passed, duration_ms: 30}
              ]
            }
          ]
        }
      ]

      json = decode(Results.to_json(:ok, results))
      run = json["stages"] |> hd() |> Map.get("matrix_runs") |> hd()

      assert length(run["steps"]) == 1
      assert hd(run["steps"])["name"] == "unit"
    end
  end

  describe "to_json/2 — output is valid JSON string" do
    test "returns a binary string" do
      results = [%StageResult{name: :test, status: :passed, duration_ms: 10}]
      assert is_binary(Results.to_json(:ok, results))
    end

    test "output parses without error" do
      results = [%StageResult{name: :test, status: :passed, duration_ms: 10}]
      assert {:ok, _} = Jason.decode(Results.to_json(:ok, results))
    end

    test "output contains no ANSI escape sequences" do
      results = [%StageResult{name: :test, status: :passed, duration_ms: 10}]
      json = Results.to_json(:ok, results)

      refute json =~ "\e["
    end
  end
end
