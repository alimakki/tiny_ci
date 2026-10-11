defmodule TinyCI.Integration.EscriptTest do
  @moduledoc """
  End-to-end proof that the built escript runs a shell-only pipeline in a
  directory with no Mix project, and fails a `module:` step with the documented
  "module steps need your Elixir project" message.

  Tagged `:escript` and excluded unless `TINY_CI_ESCRIPT=1` (see
  `test/test_helper.exs`); the dogfood build's `:smoke` stage runs it. Building
  the escript in `:prod` keeps dev-only deps (tidewave, bandit) out — the same
  reason `mix.exs` pins `escript.build` to `:prod`.
  """
  # async: false — a shared `./tiny_ci` build (setup_all) and real subprocesses.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduletag :escript
  @moduletag :tmp_dir

  @ansi ~r/\e\[[0-9;]*m/

  setup_all do
    root = File.cwd!()

    {output, status} =
      System.cmd("mix", ["escript.build"],
        cd: root,
        env: [{"MIX_ENV", "prod"}],
        stderr_to_stdout: true
      )

    assert status == 0, "mix escript.build failed:\n#{output}"

    escript = Path.join(root, "tiny_ci")
    assert File.exists?(escript), "escript not written to #{escript}"
    {:ok, escript_path: escript}
  end

  setup %{tmp_dir: tmp} do
    File.write!(Path.join(tmp, "go.mod"), "module example.com/go_ci\n\ngo 1.22\n")
    File.write!(Path.join(tmp, "main.go"), "package main\n\nfunc main() {}\n")

    File.write!(Path.join(tmp, "tiny_ci.exs"), """
    name :go_ci

    stage :build do
      step :vet, cmd: "echo vet ok"
      step :test, cmd: "echo test ok"
    end
    """)

    {:ok, tmp: tmp, pipeline: Path.join(tmp, "tiny_ci.exs")}
  end

  test "runs a shell-only pipeline in a directory with no mix.exs", ctx do
    {out, 0} = escript_cmd(ctx, ["run", "--no-color", "--no-record"])

    assert out =~ "vet ok"
    assert out =~ "test ok"
    refute File.exists?(Path.join(ctx.tmp, "mix.exs"))
  end

  test "a --dry-run prints the same plan as `mix tiny_ci.run --dry-run`", ctx do
    args = ["--file", ctx.pipeline, "--root", ctx.tmp, "--dry-run", "--no-color"]

    {escript_out, 0} = escript_cmd(ctx, ["run" | args])

    # Both front ends share `TinyCI.CLI.Run`, so this proves the built binary
    # reaches the same code path as the Mix task (run in-process to avoid a nested
    # `mix` compile inside the test VM).
    mix_out =
      capture_io(fn ->
        assert :ok = Mix.Tasks.TinyCi.Run.run(args)
      end)

    assert strip_ansi(escript_out) == strip_ansi(mix_out)
    assert escript_out =~ "vet"
  end

  test "a module: step fails with the module-steps message", ctx do
    File.write!(ctx.pipeline, """
    stage :deploy do
      step :push, module: MyApp.Deploy
    end
    """)

    {out, status} = escript_cmd(ctx, ["run", "--no-color", "--no-record"], merge_stderr: true)

    assert status == 1
    assert out =~ "could not be loaded"
    assert out =~ "Module steps run inside your Elixir project"
    assert out =~ "mix tiny_ci.run"
  end

  # Runs the escript in the fixture directory, keeping any run artifacts inside it.
  defp escript_cmd(%{escript_path: escript, tmp: tmp}, args, opts \\ []) do
    env = [{"XDG_DATA_HOME", Path.join(tmp, ".xdg-data")}]

    System.cmd(escript, args,
      cd: tmp,
      env: env,
      stderr_to_stdout: Keyword.get(opts, :merge_stderr, false)
    )
  end

  defp strip_ansi(text), do: String.replace(text, @ansi, "")
end
