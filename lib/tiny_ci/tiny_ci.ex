defmodule TinyCI.Step do
  @moduledoc """
  Represents a single step within a pipeline stage.

  A step is either a shell command (`:cmd`) or a module-based step (`:module`)
  with optional configuration provided via `set/2` in the DSL.

  An optional `:timeout` (in milliseconds) causes the step to fail if it
  exceeds the given duration.

  When `:allow_failure` is `true`, the step's failure does not cause the
  containing stage to fail. This is useful for non-critical checks like
  linters or experimental tests.
  """

  @type t :: %__MODULE__{
          name: atom(),
          cmd: String.t() | nil,
          module: module() | nil,
          mode: :inherit | :serial | :parallel,
          requires: [atom()],
          config_block: (-> keyword()) | nil,
          env: %{optional(String.t()) => String.t()},
          timeout: pos_integer() | nil,
          allow_failure: boolean(),
          when_condition: term() | nil,
          working_dir: String.t() | nil
        }

  defstruct name: nil,
            cmd: nil,
            module: nil,
            mode: :inherit,
            requires: [],
            config_block: nil,
            env: %{},
            timeout: nil,
            allow_failure: false,
            when_condition: nil,
            working_dir: nil
end

defmodule TinyCI.Stage do
  @moduledoc """
  Represents a pipeline stage containing one or more steps.

  Stages run sequentially within a pipeline. Steps within a stage run
  according to the stage's `:mode` — either `:serial` or `:parallel`.
  """

  @type t :: %__MODULE__{
          name: atom(),
          steps: [TinyCI.Step.t()],
          mode: :serial | :parallel,
          when_condition: (map() -> boolean()) | nil,
          working_dir: String.t() | nil
        }

  defstruct name: nil, steps: [], mode: :parallel, when_condition: nil, working_dir: nil
end
