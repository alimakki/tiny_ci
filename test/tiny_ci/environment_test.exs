defmodule TinyCI.EnvironmentTest do
  @moduledoc """
  The environment plan: precedence, defaults, trust policy, and cache identity.

  Container and mise resolution are injected (`:digest`, `:toolchain`,
  `:available?`), so these tests need neither a runtime nor `mise`.
  """

  use ExUnit.Case, async: true

  doctest TinyCI.Environment

  alias TinyCI.Environment
  alias TinyCI.Execution.Backend.{Container, Local}
  alias TinyCI.ExecutionFixtures.RecordingBackend
  alias TinyCI.{Hook, Stage, Step}

  defp stage(name, opts \\ []) do
    %Stage{
      name: name,
      mode: :serial,
      image: Keyword.get(opts, :image),
      environment: Keyword.get(opts, :environment),
      steps: [%Step{name: :test, cmd: "true"}]
    }
  end

  defp toolchain(version \\ "1.20.3") do
    %{
      env: %{"PATH" => "/tools/bin", "MIX_HOME" => "/tools/mix"},
      tools: [{"elixir", version}],
      fingerprint: "fp-" <> version
    }
  end

  defp resolved(plan, name) do
    plan.stages |> Map.fetch!(name) |> elem(1)
  end

  defp plan(stages, ctx \\ %{trust: :trusted}, opts \\ []) do
    Environment.plan(stages, ctx, Keyword.merge([available?: fn -> true end], opts))
  end

  describe "resolve/3: defaults" do
    test "a trusted run with nothing declared stays on the host" do
      assert %Environment{backend: Local, image: nil, toolchain: nil, env: %{}} =
               Environment.resolve(%{}, %{trust: :trusted}, [])
    end

    test "a trusted run ignores the operator default image" do
      assert %Environment{backend: Local, image: nil} =
               Environment.resolve(%{}, %{trust: :trusted}, default_image: "alpine:3.22")
    end

    test "an untrusted run with nothing declared uses the operator default image" do
      assert %Environment{
               backend: Container,
               image: "alpine:3.22",
               digest: "sha256:default",
               run_ref: "alpine:3.22"
             } =
               Environment.resolve(%{}, %{trust: :untrusted},
                 available?: fn -> true end,
                 digest: "sha256:default",
                 default_image: "alpine:3.22"
               )
    end

    test "an untrusted run with no image and no default fails explicitly" do
      assert {:error, :no_default_image} =
               Environment.resolve(%{}, %{trust: :untrusted},
                 available?: fn -> true end,
                 default_image: nil
               )
    end

    test "an untrusted run with an injected backend needs no default image" do
      assert %Environment{backend: RecordingBackend, image: nil} =
               Environment.resolve(%{}, %{trust: :untrusted}, backend: RecordingBackend)
    end
  end

  describe "resolve/3: image" do
    test "resolves a declared image to the container backend and its digest" do
      assert %Environment{
               backend: Container,
               image: "elixir:1.18",
               digest: "sha256:abc",
               run_ref: "elixir:1.18",
               toolchain: nil
             } =
               Environment.resolve(%{image: "elixir:1.18"}, %{trust: :trusted},
                 available?: fn -> true end,
                 digest: "sha256:abc"
               )
    end

    test "a trusted image selects the container backend" do
      env = Environment.resolve(%{image: "elixir:1.18"}, %{trust: :trusted}, digest: :ref)
      assert env.backend == Container
    end

    test "a declared image with no runtime fails closed" do
      assert {:error, :no_isolation_backend} =
               Environment.resolve(%{image: "elixir:1.18"}, %{trust: :trusted},
                 available?: fn -> false end,
                 digest: :ref
               )
    end

    test "a dry run skips the availability check" do
      assert %Environment{backend: Container} =
               Environment.resolve(%{image: "elixir:1.18"}, %{trust: :trusted},
                 available?: fn -> false end,
                 check_availability: false,
                 digest: :ref
               )
    end

    test "an unresolved image keeps the ref as the run reference" do
      env =
        Environment.resolve(%{image: "elixir:1.18"}, %{trust: :trusted},
          digest: fn _ref -> nil end
        )

      assert env.digest == nil
      assert env.run_ref == "elixir:1.18"

      assert Environment.cache_identity(env) == %{
               image: "elixir:1.18",
               toolchain: nil,
               fingerprint: nil,
               env: nil
             }
    end

    test "an invalid reference is rejected before a runtime is touched" do
      for ref <- ["", "--privileged", "alpine 3.22", "alpine\n3.22"] do
        assert {:error, {:invalid_image, ^ref}} =
                 Environment.resolve(%{image: ref}, %{trust: :trusted}, digest: :ref)
      end
    end

    test "an explicitly injected Local backend is refused for an image" do
      assert {:error, {:image_requires_container, "alpine:3.22"}} =
               Environment.resolve(%{image: "alpine:3.22"}, %{trust: :trusted},
                 backend: Local,
                 digest: :ref
               )
    end
  end

  describe "resolve/3: environment" do
    test "a trusted run resolves the toolchain on the host" do
      assert %Environment{
               backend: Local,
               image: nil,
               toolchain: "ci",
               tools: [{"elixir", "1.20.3"}],
               fingerprint: "fp-1.20.3",
               env: %{"PATH" => "/tools/bin"}
             } =
               Environment.resolve(%{environment: "ci"}, %{trust: :trusted},
                 toolchain: fn "ci" -> {:ok, toolchain()} end
               )
    end

    test "does not fall back to the default image" do
      assert %Environment{backend: Local, image: nil, toolchain: "ci"} =
               Environment.resolve(%{environment: "ci"}, %{trust: :trusted},
                 default_image: "alpine:3.22",
                 toolchain: fn "ci" -> {:ok, toolchain()} end
               )
    end

    test "a missing toolchain is an error, not a host fallback" do
      assert {:error, :mise_unavailable} =
               Environment.resolve(%{environment: "ci"}, %{trust: :trusted},
                 toolchain: fn "ci" -> {:error, :mise_unavailable} end
               )
    end

    test "an invalid name is rejected" do
      assert {:error, {:invalid_environment, "CI"}} =
               Environment.resolve(%{environment: "CI"}, %{trust: :trusted}, [])
    end

    test "an untrusted run maps the environment to an image" do
      assert %Environment{
               backend: Container,
               image: "ghcr.io/acme/ci:24.04",
               digest: "sha256:ci",
               toolchain: "ci"
             } =
               Environment.resolve(%{environment: "ci"}, %{trust: :untrusted},
                 available?: fn -> true end,
                 digest: "sha256:ci",
                 environments: %{"ci" => "ghcr.io/acme/ci:24.04"}
               )
    end

    test "an untrusted run without a mapping refuses the environment" do
      assert {:error, {:environment_requires_image, "ci"}} =
               Environment.resolve(%{environment: "ci"}, %{trust: :untrusted},
                 available?: fn -> true end,
                 digest: :ref,
                 default_image: "alpine:3.22",
                 environments: %{}
               )
    end

    test "an untrusted run never resolves mise" do
      parent = self()

      result =
        Environment.resolve(%{environment: "ci"}, %{trust: :untrusted},
          available?: fn -> true end,
          digest: :ref,
          environments: %{},
          toolchain: fn name ->
            send(parent, {:toolchain, name})
            {:ok, toolchain()}
          end
        )

      assert {:error, {:environment_requires_image, "ci"}} = result
      refute_received {:toolchain, _}
    end
  end

  describe "plan/3: precedence" do
    test "an empty declaration gives every stage the host environment" do
      plan = plan([stage(:build)])

      assert plan.run == nil
      assert %Environment{backend: Local, image: nil, toolchain: nil} = resolved(plan, :build)
    end

    test "stages inherit the pipeline image" do
      plan =
        plan([stage(:build)], %{trust: :trusted}, pipeline_image: "alpine:3.22", digest: :ref)

      assert %Environment{image: "alpine:3.22", backend: Container} = resolved(plan, :build)
    end

    test "stages inherit the pipeline environment" do
      plan =
        plan([stage(:build)], %{trust: :trusted},
          pipeline_environment: "ci",
          toolchain: fn _ -> {:ok, toolchain()} end
        )

      assert %Environment{toolchain: "ci", backend: Local} = resolved(plan, :build)
    end

    test "a stage image replaces the pipeline environment" do
      plan =
        plan([stage(:build, image: "alpine:3.22")], %{trust: :trusted},
          pipeline_environment: "ci",
          digest: :ref,
          toolchain: fn _ -> {:ok, toolchain()} end
        )

      assert %Environment{image: "alpine:3.22", toolchain: nil, backend: Container} =
               resolved(plan, :build)
    end

    test "a stage environment replaces the pipeline image" do
      plan =
        plan([stage(:build, environment: "ci")], %{trust: :trusted},
          pipeline_image: "alpine:3.22",
          digest: :ref,
          toolchain: fn _ -> {:ok, toolchain()} end
        )

      assert %Environment{image: nil, toolchain: "ci", backend: Local} = resolved(plan, :build)
    end

    test "a stage declaration is a whole replacement across stages" do
      stages = [
        stage(:host, environment: "ci"),
        stage(:container, image: "alpine:3.22"),
        stage(:inherited)
      ]

      plan =
        plan(stages, %{trust: :trusted},
          pipeline_image: "elixir:1.18",
          digest: :ref,
          toolchain: fn _ -> {:ok, toolchain()} end
        )

      assert %Environment{backend: Local, toolchain: "ci", image: nil} = resolved(plan, :host)
      assert %Environment{backend: Container, image: "alpine:3.22"} = resolved(plan, :container)
      assert %Environment{backend: Container, image: "elixir:1.18"} = resolved(plan, :inherited)
    end
  end

  describe "plan/3: runnable stages only" do
    test "a stage skipped by when: is not resolved and pulls nothing" do
      skipped = %{stage(:skipped, image: "never:1") | when_condition: fn _ -> false end}

      plan =
        plan([skipped], %{trust: :trusted},
          digest: fn ref ->
            send(self(), {:digest, ref})
            "sha256:x"
          end
        )

      assert plan.stages == %{}
      refute_received {:digest, _}
    end

    test "an unresolvable skipped stage does not fail the plan" do
      skipped = %{stage(:skipped, image: "--privileged") | when_condition: fn _ -> false end}
      plan = plan([skipped])

      assert Environment.strict(plan) == {:ok, %{run: nil, stages: %{}}}
    end
  end

  describe "plan/3: hooks" do
    test "no run entry when there are no hooks" do
      assert plan([stage(:build)]).run == nil
    end

    test "no run entry when every hook is a module hook" do
      hooks = %{on_success: [%Hook{name: :notify, module: MyApp.Notify}], on_failure: []}
      assert plan([stage(:build)], %{trust: :trusted}, hooks: hooks).run == nil
    end

    test "shell hooks resolve the pipeline declaration" do
      hooks = %{on_success: [%Hook{name: :notify, cmd: "true"}], on_failure: []}

      plan =
        plan([stage(:build, image: "alpine:3.22")], %{trust: :trusted},
          hooks: hooks,
          pipeline_image: "elixir:1.18",
          digest: :ref
        )

      assert {:ok, %Environment{image: "elixir:1.18"}} = plan.run
      assert %Environment{image: "alpine:3.22"} = resolved(plan, :build)
    end

    test "shell hooks in an untrusted run need an image" do
      hooks = %{on_success: [%Hook{name: :notify, cmd: "true"}], on_failure: []}

      plan =
        plan([stage(:build, image: "alpine:3.22")], %{trust: :untrusted},
          hooks: hooks,
          digest: :ref,
          default_image: nil
        )

      assert {:error, :no_default_image} = plan.run
      assert %Environment{image: "alpine:3.22"} = resolved(plan, :build)
      assert {:error, {:hooks, :no_default_image}} = Environment.strict(plan)
    end
  end

  describe "plan/3: memoization" do
    test "one digest per unique image per run" do
      parent = self()

      plan =
        plan(
          [stage(:a, image: "alpine:3.22"), stage(:b, image: "alpine:3.22")],
          %{trust: :trusted},
          digest: fn ref ->
            send(parent, {:digest, ref})
            "sha256:a"
          end
        )

      assert %Environment{digest: "sha256:a"} = resolved(plan, :a)
      assert %Environment{digest: "sha256:a"} = resolved(plan, :b)
      assert_received {:digest, "alpine:3.22"}
      refute_received {:digest, _}
    end

    test "different images resolve separately" do
      parent = self()

      plan =
        plan(
          [stage(:a, image: "alpine:3.22"), stage(:b, image: "alpine:3.21")],
          %{trust: :trusted},
          digest: fn ref ->
            send(parent, {:digest, ref})
            "sha256:" <> ref
          end
        )

      assert %Environment{digest: "sha256:alpine:3.22"} = resolved(plan, :a)
      assert %Environment{digest: "sha256:alpine:3.21"} = resolved(plan, :b)
      assert_received {:digest, "alpine:3.22"}
      assert_received {:digest, "alpine:3.21"}
    end

    test "one toolchain resolution per environment name per run" do
      parent = self()

      plan =
        plan(
          [stage(:a, environment: "ci"), stage(:b, environment: "ci")],
          %{trust: :trusted},
          toolchain: fn name ->
            send(parent, {:toolchain, name})
            {:ok, toolchain()}
          end
        )

      assert %Environment{toolchain: "ci"} = resolved(plan, :a)
      assert %Environment{toolchain: "ci"} = resolved(plan, :b)
      assert_received {:toolchain, "ci"}
      refute_received {:toolchain, _}
    end
  end

  describe "strict/1" do
    test "returns the resolved environments" do
      plan = plan([stage(:build, image: "alpine:3.22")], %{trust: :trusted}, digest: :ref)

      assert {:ok, %{run: nil, stages: %{build: %Environment{image: "alpine:3.22"}}}} =
               Environment.strict(plan)
    end

    test "tags the first stage error with its name" do
      plan =
        plan([stage(:build)], %{trust: :untrusted},
          available?: fn -> true end,
          default_image: nil
        )

      assert {:error, {:stage, :build, :no_default_image}} = Environment.strict(plan)
    end

    test "returns the run error first" do
      hooks = %{on_success: [%Hook{name: :notify, cmd: "true"}], on_failure: []}

      plan =
        plan([stage(:build)], %{trust: :untrusted},
          hooks: hooks,
          available?: fn -> true end,
          default_image: nil
        )

      assert {:error, {:hooks, :no_default_image}} = Environment.strict(plan)
    end
  end

  describe "conflicting declarations" do
    test "an image and an environment in one declaration is an error" do
      assert {:error, {:conflicting_declaration, "alpine:3.22", "ci"}} =
               Environment.resolve(%{image: "alpine:3.22", environment: "ci"}, %{trust: :trusted},
                 digest: :ref
               )
    end
  end

  describe "cache_identity/1" do
    test "is nil for a plain host run, so existing host keys do not change" do
      assert Environment.cache_identity(%Environment{backend: Local}) == nil
      assert Environment.cache_identity(nil) == nil
    end

    test "is nil for the operator default host environment" do
      env = Environment.resolve(%{}, %{trust: :trusted}, default_image: "alpine:3.22")
      assert Environment.cache_identity(env) == nil
    end

    test "includes the image digest, toolchain, fingerprint, and env hash" do
      env =
        Environment.resolve(%{environment: "ci"}, %{trust: :trusted},
          toolchain: fn _ -> {:ok, toolchain()} end
        )

      identity = Environment.cache_identity(env)
      assert identity.image == nil
      assert identity.toolchain == "ci"
      assert identity.fingerprint == "fp-1.20.3"
      assert identity.env =~ ~r/^[0-9a-f]{64}$/
    end

    test "changing a resolved toolchain env value changes the identity" do
      resolve = fn env ->
        Environment.resolve(%{environment: "ci"}, %{trust: :trusted},
          toolchain: fn _ -> {:ok, %{toolchain() | env: env}} end
        )
      end

      dev = Environment.cache_identity(resolve.(%{"MIX_ENV" => "dev"}))
      prod = Environment.cache_identity(resolve.(%{"MIX_ENV" => "prod"}))

      refute dev == prod
      assert dev.toolchain == prod.toolchain
      assert dev.fingerprint == prod.fingerprint
    end

    test "falls back to the ref when no digest was resolved" do
      env =
        Environment.resolve(%{image: "alpine:3.22"}, %{trust: :trusted}, digest: fn _ -> nil end)

      assert Environment.cache_identity(env) == %{
               image: "alpine:3.22",
               toolchain: nil,
               fingerprint: nil,
               env: nil
             }
    end
  end
end
