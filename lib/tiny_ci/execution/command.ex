defmodule TinyCI.Execution.Command do
  @moduledoc """
  A process to run through an execution backend.

  The `:run` field says *what* to run: a shell string (`{:shell, cmd}`, run through
  `sh -c` exactly like a `cmd:` step) or an argv (`{:argv, executable, args}`, run
  literally). The remaining fields say how: extra environment, working directory,
  and an optional deadline.

  A shell command is only used by the Local and Container backends; a shell in the
  container image is required for the latter (see `docs/isolation.md`). argv
  commands are what the sandbox backends use to launch `bwrap` / `sandbox-exec`;
  the container backend also accepts them and runs them with literal argument
  quoting through `sh -c`.
  """

  @typedoc "A shell string or a literal executable plus arguments."
  @type run :: {:shell, String.t()} | {:argv, String.t(), [String.t()]}

  @type t :: %__MODULE__{
          run: run(),
          env: %{optional(String.t()) => String.t()},
          working_dir: String.t() | nil,
          timeout: non_neg_integer() | nil
        }

  @enforce_keys [:run]
  defstruct [:run, env: %{}, working_dir: nil, timeout: nil]
end
