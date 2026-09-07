defmodule TinyCI.Executor.DriverTest do
  use ExUnit.Case, async: true

  alias TinyCI.Context
  alias TinyCI.Executor.Driver
  alias TinyCI.Executor.Driver.{Inline, Sandbox}
  alias TinyCI.SandboxFixtures.{Boom, Echo, Exits, Throws}

  # A backend that runs the real Runner in-process (no OS isolation) so the
  # Sandbox driver's glue — policy, context sanitizing, serialization, redaction
  # — can be exercised without Seatbelt.
  defmodule LocalBackend do
    @behaviour TinyCI.Sandbox.Backend

    @impl true
    def available?, do: true

    @impl true
    def run(request, _policy, _opts) do
      dir = Path.join(System.tmp_dir!(), "drv-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      req = Path.join(dir, "req")
      resp = Path.join(dir, "resp")

      try do
        File.write!(req, request)
        :ok = TinyCI.Sandbox.Runner.run(req, resp)
        {:ok, File.read!(resp)}
      after
        File.rm_rf(dir)
      end
    end
  end

  defmodule UnavailableBackend do
    @behaviour TinyCI.Sandbox.Backend
    @impl true
    def available?, do: false
    @impl true
    def run(_request, _policy, _opts), do: {:error, :should_not_be_called}
  end

  defp ctx(sandbox_opts) do
    Context.build(branch: "main", store: %{seed: 7})
    |> Map.put(:events, self())
    |> Map.put(:sandbox, sandbox_opts)
  end

  describe "select/2" do
    test "routes first-party modules inline and third-party modules to the sandbox" do
      assert Driver.select(Echo, ctx(root_app: :tiny_ci)) == Inline
      assert Driver.select(Echo, ctx(root_app: :other_app)) == Sandbox
    end

    test "honors an explicit driver override" do
      assert Driver.select(Echo, ctx(driver: :inline, root_app: :other_app)) == Inline
      assert Driver.select(Echo, ctx(driver: :sandbox, root_app: :tiny_ci)) == Sandbox
    end
  end

  describe "Inline" do
    test "runs a trusted action and returns its store delta" do
      assert {:ok, %{echoed: "hi"}} =
               Inline.run(Echo, %{msg: "hi"}, ctx(root_app: :tiny_ci), root_app: :tiny_ci)
    end

    test "refuses an untrusted (third-party) action" do
      assert {:error, {:untrusted_action, Echo}} =
               Inline.run(Echo, %{msg: "hi"}, ctx(root_app: :other), root_app: :other)
    end
  end

  describe "Inline.run/4 crash handling" do
    test "a raising action is reported as a crashed step, with the stack trace" do
      assert {:error, {:crashed, text}} = Inline.run(Boom, %{}, ctx(root_app: :tiny_ci), [])
      assert text =~ "Step crashed: ** (RuntimeError) kaboom"
      assert text =~ "Boom.execute/2"
    end

    test "an exiting action is reported as a crashed step" do
      assert {:error, {:crashed, text}} = Inline.run(Exits, %{}, ctx(root_app: :tiny_ci), [])
      assert text =~ "(exit) :kaboom"
    end

    test "a throwing action is reported as a crashed step" do
      assert {:error, {:crashed, text}} = Inline.run(Throws, %{}, ctx(root_app: :tiny_ci), [])
      assert text =~ "(throw) :ball"
    end
  end

  describe "Sandbox" do
    test "runs an action through a backend and strips executor handles from context" do
      context = ctx([])
      assert {:ok, delta} = Sandbox.run(Echo, %{msg: "hi"}, context, backend: LocalBackend)

      assert delta.echoed == "hi"
      assert delta.branch == "main"
      assert delta.seed == 7
    end

    test "redacts granted secrets appearing in the result" do
      opts = [backend: LocalBackend, secrets: ["s3cr3t"]]
      assert {:ok, delta} = Sandbox.run(Echo, %{msg: "s3cr3t"}, ctx([]), opts)
      assert delta.echoed == "***"
    end

    test "fails closed when no backend is available" do
      assert {:error, {:sandbox_unavailable, UnavailableBackend}} =
               Sandbox.run(Echo, %{msg: "hi"}, ctx([]), backend: UnavailableBackend)
    end
  end
end
