# The backend integration suites are tagged by the OS sandbox they exercise;
# exclude the ones this host can't run so they don't fail (or falsely pass).
backends = [
  seatbelt: TinyCI.Sandbox.Backend.Seatbelt,
  bubblewrap: TinyCI.Sandbox.Backend.Bubblewrap
]

exclude = for {tag, backend} <- backends, not backend.available?(), do: tag

ExUnit.start(exclude: exclude)

# Runs are recorded by default, so any test that runs a pipeline with a root would
# otherwise write into the developer's real data dir. Point the run store at a
# throwaway directory for the whole suite. A test that needs its own location
# redirects it and restores this one (see `TinyCI.RunsFixtures.redirect_runs_dir/1`).
runs_dir = Path.join(System.tmp_dir!(), "tiny_ci_test_runs_#{System.pid()}")
File.rm_rf!(runs_dir)
Application.put_env(:tiny_ci, :runs_base_dir, runs_dir)
ExUnit.after_suite(fn _results -> File.rm_rf(runs_dir) end)
