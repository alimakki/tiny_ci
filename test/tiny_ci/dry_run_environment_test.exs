defmodule TinyCI.DryRunEnvironmentTest do
  @moduledoc """
  The dry-run plan shows the environment a stage would run in, without pulling
  an image or requiring a runtime.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias TinyCI.{DryRun, Environment, Stage, Step}

  defp stage(opts \\ []) do
    %Stage{
      name: Keyword.get(opts, :name, :build),
      mode: :serial,
      image: Keyword.get(opts, :image),
      environment: Keyword.get(opts, :environment),
      when_condition: Keyword.get(opts, :when_condition),
      steps: [%Step{name: :one, cmd: "true"}]
    }
  end

  defp plan(stages, opts) do
    Environment.plan(
      stages,
      %{trust: :trusted},
      Keyword.merge([available?: fn -> true end], opts)
    )
  end

  defp print(stages, plan) do
    capture_io(fn -> DryRun.print_plan(stages, %{branch: "main"}, plan) end)
  end

  describe "resolved environments" do
    test "prints a container image and its digest" do
      stages = [stage(image: "alpine:3.22")]
      output = print(stages, plan(stages, digest: "sha256:abc"))

      assert output =~ "Environment: container image=alpine:3.22 digest=sha256:abc"
    end

    test "prints an unresolved digest when the image is not local" do
      stages = [stage(image: "alpine:3.22")]
      output = print(stages, plan(stages, digest: fn _ -> nil end, pull: false))

      assert output =~ "Environment: container image=alpine:3.22 digest=unresolved"
    end

    test "prints a host toolchain and its tools" do
      stages = [stage(environment: "ci")]

      output =
        print(
          stages,
          plan(stages,
            toolchain: fn "ci" ->
              {:ok, %{env: %{}, tools: [{"elixir", "1.20.3"}], fingerprint: "fp"}}
            end
          )
        )

      assert output =~ "Environment: host environment=ci (elixir 1.20.3)"
    end
  end

  describe "inheritance" do
    test "shows the pipeline image on a stage that inherits it" do
      stages = [stage()]
      output = print(stages, plan(stages, pipeline_image: "pipeline:1", digest: "sha256:p"))

      assert output =~ "Environment: container image=pipeline:1 digest=sha256:p"
    end

    test "shows a stage override instead of the pipeline image" do
      stages = [stage(image: "stage:2")]

      output =
        print(
          stages,
          plan(stages,
            pipeline_image: "pipeline:1",
            digest: fn
              "stage:2" -> "sha256:s"
              other -> flunk("unexpected image #{other}")
            end
          )
        )

      assert output =~ "Environment: container image=stage:2 digest=sha256:s"
      refute output =~ "pipeline:1"
    end
  end

  describe "unchanged host output" do
    test "a stage with no declaration prints no Environment line" do
      stages = [stage()]
      output = print(stages, plan(stages, []))

      refute output =~ "Environment:"
      assert output =~ "▶ :build"
      assert output =~ "cmd: \"true\""
    end

    test "a skipped stage prints only its skip line" do
      stages = [stage(image: "alpine:3.22", when_condition: fn _ -> false end)]

      output =
        print(
          stages,
          plan(stages,
            digest: fn _ -> flunk("a skipped stage must not be resolved") end,
            available?: fn -> false end
          )
        )

      assert output =~ "will skip"
      refute output =~ "Environment:"
    end
  end

  describe "unresolved environments" do
    test "names the reason in a warning line" do
      stages = [stage(image: "alpine:3.22")]

      output =
        print(
          stages,
          plan(stages, available?: fn -> false end, digest: :ref)
        )

      assert output =~ "Environment: unresolved —"
      assert output =~ "no isolation backend"
    end

    test "an environment with no toolchain resolver is unresolved" do
      stages = [stage(environment: "ci")]

      output =
        print(
          stages,
          plan(stages, toolchain: fn _ -> {:error, :mise_unavailable} end)
        )

      assert output =~ "Environment: unresolved —"
      assert output =~ "mise"
    end
  end

  describe "print_plan/2" do
    test "builds a plan that never pulls and never requires a runtime" do
      # No runtime is needed for the default plan even with an image: it shows
      # the ref with an unresolved digest rather than failing or pulling.
      stages = [stage(image: "tiny_ci_no_such_image:1")]

      output = capture_io(fn -> DryRun.print_plan(stages, %{branch: "main"}) end)

      assert output =~ "Environment: container image=tiny_ci_no_such_image:1"
      refute output =~ "Error"
    end
  end
end
