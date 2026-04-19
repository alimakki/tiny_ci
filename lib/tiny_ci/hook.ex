defmodule TinyCI.Hook do
  @moduledoc """
  Represents a pipeline-level notification hook.

  A hook runs after the pipeline completes — either on success (`:on_success`)
  or on failure (`:on_failure`). Like steps, hooks can be shell commands
  (`:cmd`) or module-based (`:module`) with optional configuration via `set/2`.

  Shell command hooks receive the following environment variables automatically:

    * `TINY_CI_RESULT`  — `"on_success"` or `"on_failure"`
    * `TINY_CI_BRANCH`  — current git branch name
    * `TINY_CI_COMMIT`  — current git commit SHA

  To pass pipeline store values to a shell hook, use `store(:key)` in the
  hook's `env:` option — e.g. `env: %{"TAG" => store(:image_tag)}`.

  Module-based hooks must implement a `run/2` callback:

      def run(config, context) :: :ok | {:error, reason}

  The `context` map includes all standard pipeline context keys plus
  `:pipeline_result` (set to `:on_success` or `:on_failure`).

  Hook failures are logged to stderr but do not affect the pipeline exit code.
  """

  @type t :: %__MODULE__{
          name: atom(),
          cmd: String.t() | nil,
          module: module() | nil,
          env: %{optional(String.t()) => String.t()},
          config_block: (-> keyword()) | nil,
          timeout: pos_integer() | nil
        }

  defstruct name: nil, cmd: nil, module: nil, env: %{}, config_block: nil, timeout: nil
end
