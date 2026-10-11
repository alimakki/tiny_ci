defmodule TinyCI.Dist do
  @moduledoc """
  Packaging-only project: it owns the Burrito release configuration for the
  standalone `tiny_ci` binary and contributes no runtime code.

  The release starts `:tiny_ci` (a runtime dependency), whose
  `TinyCI.Application` runs the CLI when the Burrito wrapper reports a standalone
  launch. See `tiny_ci_dist/mix.exs` for the targets.
  """
end
