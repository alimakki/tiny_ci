# The backend integration suites are tagged by the OS sandbox they exercise;
# exclude the ones this host can't run so they don't fail (or falsely pass).
backends = [
  seatbelt: TinyCI.Sandbox.Backend.Seatbelt,
  bubblewrap: TinyCI.Sandbox.Backend.Bubblewrap
]

exclude = for {tag, backend} <- backends, not backend.available?(), do: tag

# Whether the runner itself may use colours is decided from the terminal the developer
# is in, so read it before the flag is pinned below.
runner_colors = IO.ANSI.enabled?()

# Pin ANSI off for the whole suite, so no test's result depends on whether a terminal
# is attached (`IO.ANSI.enabled?/0` is what makes the control console start, and what
# colours the CLI's own messages). A test that needs colours enables them itself and
# restores the previous value in `on_exit`.
Application.put_env(:elixir, :ansi_enabled, false)

# `assert_receive` waits up to this long (default 100 ms) for a message that a busy
# machine can delay well past that. A passing test returns as soon as the message
# arrives, so a generous deadline costs nothing; only a real failure waits it out.
#
# The per-test timeout (default 60 s) is raised for the tests that run a real `mix`
# subprocess, which can take far longer on a loaded machine.
ExUnit.start(
  exclude: exclude,
  colors: [enabled: runner_colors],
  assert_receive_timeout: 3_000,
  timeout: 180_000
)

# Runs are recorded by default, so any test that runs a pipeline with a root would
# otherwise write into the developer's real data dir. Point the run store at a
# throwaway directory for the whole suite. A test that needs its own location
# redirects it and restores this one (see `TinyCI.RunsFixtures.redirect_runs_dir/1`).
runs_dir = Path.join(System.tmp_dir!(), "tiny_ci_test_runs_#{System.pid()}")
File.rm_rf!(runs_dir)
Application.put_env(:tiny_ci, :runs_base_dir, runs_dir)
ExUnit.after_suite(fn _results -> File.rm_rf(runs_dir) end)
