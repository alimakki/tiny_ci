# The backend integration suites are tagged by the OS sandbox they exercise;
# exclude the ones this host can't run so they don't fail (or falsely pass).
backends = [
  seatbelt: TinyCI.Sandbox.Backend.Seatbelt,
  bubblewrap: TinyCI.Sandbox.Backend.Bubblewrap
]

exclude = for {tag, backend} <- backends, not backend.available?(), do: tag

ExUnit.start(exclude: exclude)
