defmodule TinyCI.ExecutorEnvironmentFixtures.EnvBackend do
  @moduledoc false
  # A backend that records the environment of every shell command it is asked
  # to run, so a test can prove what a step actually received.

  @behaviour TinyCI.Execution.Backend

  alias TinyCI.Execution.{Command, SessionSpec}

  @impl true
  def name, do: :env

  @impl true
  def available?, do: true

  @impl true
  def open(%SessionSpec{workspace: workspace}), do: {:ok, Path.join(workspace, "env.log")}

  @impl true
  def exec(path, %Command{} = command, on_line) do
    File.write!(path, Jason.encode!(command.env) <> "\n", [:append])
    on_line.("recorded")
    {:passed, "recorded\n"}
  end

  @impl true
  def close(_path), do: :ok
end

defmodule TinyCI.ExecutorEnvironmentFixtures.FlipBackend do
  @moduledoc false
  # A fake backend whose `exec/3` creates a marker in the workspace. A stage
  # whose `when:` reads the marker is therefore false at plan time and true at
  # its own boundary — the "condition flips after planning" regression.

  @behaviour TinyCI.Execution.Backend

  alias TinyCI.Execution.{Command, SessionSpec}

  @impl true
  def name, do: :flip

  @impl true
  def available?, do: true

  @impl true
  def open(%SessionSpec{workspace: workspace} = spec) do
    File.write!(Path.join(workspace, "flip_sessions.log"), "#{spec.image || "-"}\n", [:append])
    {:ok, %{workspace: workspace}}
  end

  @impl true
  def exec(%{workspace: workspace}, %Command{}, _on_line) do
    File.write!(Path.join(workspace, "flip.marker"), "yes")
    {:passed, "recorded\n"}
  end

  @impl true
  def close(_session), do: :ok
end

defmodule TinyCI.ExecutorEnvironmentTest do
  @moduledoc """
  Environment resolution through the executor: per-stage backends, mixed
  host/container stages, hook inheritance, and the environment a shell step
  receives. Docker and mise are injected away with a fake backend and digest.
  """

  use ExUnit.Case, async: true

  alias TinyCI.{Executor, RegressionActions, Stage, Step}
  alias TinyCI.Execution.Backend.Local
  alias TinyCI.ExecutionFixtures.SpecBackend
  alias TinyCI.ExecutorEnvironmentFixtures.{EnvBackend, FlipBackend}

  alias TinyCI.Events.{PipelineCompleted, PipelineStarted, StageStarted}

  @moduletag :tmp_dir

  @silent [console: false, output: :buffered, record: false]

  defp session_specs(root) do
    root
    |> Path.join("session_specs.log")
    |> File.read!()
    |> String.split("\n", trim: true)
  end

  defp env_log(root) do
    root
    |> Path.join("env.log")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp flip_sessions(root) do
    root
    |> Path.join("flip_sessions.log")
    |> File.read!()
    |> String.split("\n", trim: true)
  end

  defp run(stages, context, opts) do
    Executor.run_pipeline(stages, context, @silent ++ opts ++ [available?: fn -> true end])
  end

  describe "pipeline image" do
    test "stages inherit the pipeline image", %{tmp_dir: tmp} do
      stage = %Stage{name: :build, mode: :serial, steps: [%Step{name: :one, cmd: "true"}]}

      assert {:ok, [%{status: :passed}]} =
               run([stage], %{root: tmp},
                 backend: SpecBackend,
                 pipeline_image: "alpine:3.22",
                 digest: :ref
               )

      assert session_specs(tmp) == ["alpine:3.22|true|%{}"]
    end

    test "legacy opts[:image] is still a pipeline image", %{tmp_dir: tmp} do
      stage = %Stage{name: :build, mode: :serial, steps: [%Step{name: :one, cmd: "true"}]}

      assert {:ok, [%{status: :passed}]} =
               run([stage], %{root: tmp},
                 backend: SpecBackend,
                 image: "alpine:3.22",
                 digest: :ref
               )

      assert session_specs(tmp) == ["alpine:3.22|true|%{}"]
    end

    test "a stage image replaces the pipeline image", %{tmp_dir: tmp} do
      stage = %Stage{
        name: :build,
        mode: :serial,
        image: "stage:1",
        steps: [%Step{name: :one, cmd: "true"}]
      }

      assert {:ok, [%{status: :passed}]} =
               run([stage], %{root: tmp},
                 backend: SpecBackend,
                 pipeline_image: "pipeline:1",
                 digest: :ref
               )

      assert session_specs(tmp) == ["stage:1|true|%{}"]
    end

    test "the resolved run reference (image ID), not the tag, reaches the session", %{
      tmp_dir: tmp
    } do
      stage = %Stage{name: :build, mode: :serial, steps: [%Step{name: :one, cmd: "true"}]}

      digest = fn "alpine:3.22" -> {:ok, "sha256:digest", "sha256:imageid"} end

      assert {:ok, [%{status: :passed}]} =
               run([stage], %{root: tmp},
                 backend: SpecBackend,
                 pipeline_image: "alpine:3.22",
                 digest: digest
               )

      assert session_specs(tmp) == ["sha256:imageid|true|%{}"]
    end
  end

  describe "mixed host and container stages" do
    test "a stage environment runs on the host while its siblings inherit the image", %{
      tmp_dir: tmp
    } do
      host = %Stage{
        name: :host,
        mode: :serial,
        environment: "ci",
        steps: [%Step{name: :one, cmd: "true"}]
      }

      container = %Stage{name: :container, mode: :serial, steps: [%Step{name: :two, cmd: "true"}]}

      assert {:ok, [%{status: :passed}, %{status: :passed}]} =
               run([host, container], %{root: tmp},
                 backend: SpecBackend,
                 pipeline_image: "alpine:3.22",
                 digest: :ref,
                 toolchain: fn "ci" ->
                   {:ok, %{env: %{"PATH" => "/tools/bin"}, tools: [], fingerprint: "fp"}}
                 end
               )

      assert session_specs(tmp) == ["-|true|%{}", "alpine:3.22|true|%{}"]
    end
  end

  describe "sessions" do
    test "one session per stage and per matrix combination, all on the same digest", %{
      tmp_dir: tmp
    } do
      plain = %Stage{name: :plain, mode: :serial, steps: [%Step{name: :one, cmd: "true"}]}

      matrix = %Stage{
        name: :compat,
        mode: :serial,
        matrix: [v: ["a", "b"]],
        steps: [%Step{name: :two, cmd: "true"}]
      }

      digest = fn _ -> {:ok, "sha256:digest", "sha256:imageid"} end

      assert {:ok, [%{status: :passed}, %{status: :passed, matrix_runs: runs}]} =
               run([plain, matrix], %{root: tmp},
                 backend: SpecBackend,
                 pipeline_image: "alpine:3.22",
                 digest: digest
               )

      assert length(runs) == 2
      assert session_specs(tmp) == List.duplicate("sha256:imageid|true|%{}", 3)
    end
  end

  describe "no runtime" do
    test "an image with no runtime fails before any stage starts", %{tmp_dir: tmp} do
      stage = %Stage{name: :build, mode: :serial, steps: [%Step{name: :one, cmd: "true"}]}

      opts =
        @silent ++
          [
            backend: SpecBackend,
            pipeline_image: "alpine:3.22",
            available?: fn -> false end,
            extra_sinks: [{TinyCI.TestSink, pid: self()}]
          ]

      assert {:error, {:execution_unavailable, {:stage, :build, :no_isolation_backend}}, []} =
               Executor.run_pipeline([stage], %{root: tmp}, opts)

      assert_receive {:event, %PipelineStarted{}}
      assert_receive {:event, %PipelineCompleted{status: :failed}}
      refute_received {:event, %StageStarted{}}
      refute File.exists?(Path.join(tmp, "session_specs.log"))
    end

    test "a skipped stage with an image needs no runtime and is not resolved", %{tmp_dir: tmp} do
      stage = %Stage{
        name: :build,
        mode: :serial,
        image: "alpine:3.22",
        when_condition: fn _ -> false end,
        steps: [%Step{name: :one, cmd: "true"}]
      }

      assert {:ok, [%{status: :skipped}]} =
               run([stage], %{root: tmp},
                 backend: SpecBackend,
                 available?: fn -> false end,
                 extra_sinks: [{TinyCI.TestSink, pid: self()}]
               )

      assert_receive {:event, %StageStarted{}}
      refute File.exists?(Path.join(tmp, "session_specs.log"))
    end
  end

  describe "environment:" do
    test "the toolchain environment reaches shell steps but not module steps", %{tmp_dir: tmp} do
      stage = %Stage{
        name: :build,
        mode: :serial,
        environment: "ci",
        env: %{"SHARED" => "stage"},
        steps: [
          %Step{name: :shell, cmd: "true"},
          %Step{
            name: :module,
            module: RegressionActions,
            config_block: fn -> [operation: :config] end
          }
        ]
      }

      toolchain = fn "ci" ->
        {:ok,
         %{
           env: %{"TOOLCHAIN_ONLY" => "yes", "SHARED" => "toolchain"},
           tools: [{"elixir", "1.20.3"}],
           fingerprint: "fp"
         }}
      end

      assert {:ok, [%{status: :passed, store: store}]} =
               Executor.run_pipeline(
                 [stage],
                 %{root: tmp, pipeline_env: %{"PIPE" => "pipeline"}},
                 @silent ++ [backend: EnvBackend, toolchain: toolchain]
               )

      assert [shell_env] = env_log(tmp)
      assert shell_env["TOOLCHAIN_ONLY"] == "yes"
      assert shell_env["PIPE"] == "pipeline"
      # toolchain < pipeline < stage
      assert shell_env["SHARED"] == "stage"

      # A module step runs in the runner's VM: its context env stays
      # toolchain-free (conditions, cache inputs, and control payloads do too).
      module_env = store.env
      refute Map.has_key?(module_env, "TOOLCHAIN_ONLY")
      assert module_env["SHARED"] == "stage"
    end
  end

  describe "standalone execute/4" do
    test "a stage image selects the container backend", %{tmp_dir: tmp} do
      stage = %Stage{
        name: :build,
        mode: :serial,
        image: "alpine:3.22",
        steps: [%Step{name: :one, cmd: "true"}]
      }

      assert %{status: :passed} =
               Executor.execute(stage, %{root: tmp}, :buffered,
                 console: false,
                 backend: SpecBackend,
                 digest: :ref
               )

      assert session_specs(tmp) == ["alpine:3.22|true|%{}"]
    end

    test "an explicit Local backend is refused when an image is set", %{tmp_dir: tmp} do
      stage = %Stage{
        name: :build,
        mode: :serial,
        image: "alpine:3.22",
        steps: [%Step{name: :one, cmd: "true"}]
      }

      error =
        assert_raise TinyCI.Execution.Error, fn ->
          Executor.execute(stage, %{root: tmp}, :buffered,
            console: false,
            backend: Local,
            digest: :ref,
            available?: fn -> true end
          )
        end

      assert error.reason == {:stage, :build, {:image_requires_container, "alpine:3.22"}}
      assert Exception.message(error) =~ "container backend"
    end

    test "a stage environment selects the host backend", %{tmp_dir: tmp} do
      stage = %Stage{
        name: :build,
        mode: :serial,
        environment: "ci",
        steps: [%Step{name: :one, cmd: "true"}]
      }

      assert %{status: :passed} =
               Executor.execute(stage, %{root: tmp}, :buffered,
                 console: false,
                 backend: SpecBackend,
                 toolchain: fn "ci" -> {:ok, %{env: %{}, tools: [], fingerprint: "fp"}} end
               )

      assert session_specs(tmp) == ["-|true|%{}"]
    end
  end

  describe "condition flips after planning" do
    test "a stage that becomes runnable resolves its own image instead of the host", %{
      tmp_dir: tmp
    } do
      writer = %Stage{
        name: :writer,
        mode: :serial,
        steps: [
          %Step{
            name: :write,
            module: RegressionActions,
            config_block: fn -> [operation: :write, tag: "yes"] end
          }
        ]
      }

      deployer = %Stage{
        name: :deployer,
        mode: :serial,
        image: "stage-image:2",
        when_condition: fn ctx -> ctx.store[:tag] == "yes" end,
        steps: [%Step{name: :deploy, cmd: "echo ON_HOST"}]
      }

      assert {:ok, [%{status: :passed}, %{status: :passed}]} =
               run([writer, deployer], %{root: tmp},
                 backend: SpecBackend,
                 pipeline_image: "pipeline:1",
                 digest: fn
                   "pipeline:1" -> {:ok, "sha256:pipeline", "sha256:pipeline-id"}
                   "stage-image:2" -> {:ok, "sha256:deploy", "sha256:resolved-id"}
                   other -> flunk("unexpected image resolution: #{inspect(other)}")
                 end
               )

      # The writer inherited the pipeline image; the deployer was omitted from
      # the plan and still opened a session for its own resolved image — never
      # Local, and not the inherited one.
      assert session_specs(tmp) == [
               "sha256:pipeline-id|true|%{}",
               "sha256:resolved-id|true|%{}"
             ]
    end

    test "an untrusted stage that becomes runnable uses its mapped environment, not the default",
         %{tmp_dir: tmp} do
      marker = Path.join(tmp, "flip.marker")

      first = %Stage{
        name: :first,
        mode: :serial,
        steps: [%Step{name: :tick, cmd: "true"}]
      }

      second = %Stage{
        name: :second,
        mode: :serial,
        environment: "ci",
        when_condition: fn _ctx -> File.exists?(marker) end,
        steps: [%Step{name: :deploy, cmd: "true"}]
      }

      assert {:ok, [%{status: :passed}, %{status: :passed}]} =
               run([first, second], %{root: tmp, trust: :untrusted},
                 backend: FlipBackend,
                 digest: :ref,
                 default_image: "default:1",
                 environments: %{"ci" => "ghcr.io/acme/ci:24.04"}
               )

      # The first stage used the operator default; the flipped stage used the
      # mapped environment image, never the default and never the host.
      assert flip_sessions(tmp) == ["default:1", "ghcr.io/acme/ci:24.04"]
    end
  end

  describe "trust" do
    test "an untrusted all-imaged run needs no default image", %{tmp_dir: tmp} do
      stage = %Stage{
        name: :build,
        mode: :serial,
        image: "alpine:3.22",
        steps: [%Step{name: :one, cmd: "true"}]
      }

      assert {:ok, [%{status: :passed}]} =
               run([stage], %{root: tmp, trust: :untrusted},
                 backend: SpecBackend,
                 digest: :ref
               )

      assert session_specs(tmp) == ["alpine:3.22|true|%{}"]
    end

    test "an untrusted host environment becomes an image", %{tmp_dir: tmp} do
      stage = %Stage{
        name: :build,
        mode: :serial,
        environment: "ci",
        steps: [%Step{name: :one, cmd: "true"}]
      }

      assert {:ok, [%{status: :passed}]} =
               run([stage], %{root: tmp, trust: :untrusted},
                 backend: SpecBackend,
                 digest: :ref,
                 environments: %{"ci" => "ghcr.io/acme/ci:24.04"}
               )

      assert session_specs(tmp) == ["ghcr.io/acme/ci:24.04|true|%{}"]
    end
  end
end
