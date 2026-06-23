defmodule TinyCI.DSL.Spec do
  @moduledoc """
  The single, machine-readable source of truth for the TinyCI pipeline DSL.

  Every directive (`stage`, `step`, `on_success`, …), every option key (`mode:`,
  `cmd:`, `needs:`, …) with its expected type, and every condition primitive
  (`branch()`, `env/1`, `file_changed?/1`) is described here once, as a list of
  `TinyCI.DSL.Spec.Entry` structs.

  Three consumers read from this module so they can never drift apart:

    * `TinyCI.DSL.Validator` — derives its **allowlist** of permitted option keys
      per context from `option_keys/1` (the per-key *type* checks live in the
      validator; the set of valid keys lives here).
    * the language server — `textDocument/completion` and `textDocument/hover`
      offer and document exactly the symbols described here.
    * documentation — a DSL reference can be rendered from `directives/0`,
      `all_options/0`, and `condition_primitives/0`.

  ## Contexts

    * `:top_level` — file scope (`name`, `env`, `stage`, `on_success`, `on_failure`)
    * `:stage` — inside a `stage do … end` block (`step`, `env`) and stage options
    * `:step` — inside a `step do … end` block (`set`) and step options
    * `:hook` — inside an `on_success`/`on_failure do … end` block and hook options
    * `:condition` — inside a `when:` value (`branch()`, `env/1`, `file_changed?/1`)
  """

  alias TinyCI.DSL.Spec.Entry

  @directives [
    %Entry{
      name: :name,
      kind: :directive,
      contexts: [:top_level],
      type: "atom",
      summary: "Sets the pipeline's name. Optional — defaults to the filename stem.",
      example: "name :my_pipeline"
    },
    %Entry{
      name: :env,
      kind: :directive,
      contexts: [:top_level, :stage],
      type: "keyword list of strings",
      summary: "Declares environment variables shared by the steps in scope.",
      example: ~s|env MIX_ENV: "test", LANG: "en_US.UTF-8"|
    },
    %Entry{
      name: :stage,
      kind: :directive,
      contexts: [:top_level],
      type: "atom name + options + do block",
      summary: "Defines a pipeline stage: a named group of steps with shared options.",
      example: """
      stage :build, mode: :serial do
        step :compile, cmd: "mix compile"
      end\
      """
    },
    %Entry{
      name: :on_success,
      kind: :directive,
      contexts: [:top_level],
      type: "atom name + options",
      summary: "Registers a hook that runs when the whole pipeline succeeds.",
      example: ~s|on_success :notify, cmd: "curl -X POST $SLACK_WEBHOOK"|
    },
    %Entry{
      name: :on_failure,
      kind: :directive,
      contexts: [:top_level],
      type: "atom name + options",
      summary: "Registers a hook that runs when the pipeline fails.",
      example: ~s|on_failure :alert, cmd: "say 'build failed'"|
    },
    %Entry{
      name: :step,
      kind: :directive,
      contexts: [:stage],
      type: "atom name + options + optional do block",
      summary: "Defines a step inside a stage: a shell command or a module callback.",
      example: ~s|step :unit, cmd: "mix test"|
    },
    %Entry{
      name: :set,
      kind: :directive,
      contexts: [:step, :hook],
      type: "atom key + value",
      summary: "Sets a configuration pair passed to a module step/hook's callback.",
      example: ~s|set :app, "my-app"|
    }
  ]

  @stage_options [
    %Entry{
      name: :mode,
      kind: :option,
      contexts: [:stage],
      type: ":serial | :parallel",
      summary: "How the stage's steps run. Defaults to :parallel.",
      example: "mode: :serial"
    },
    %Entry{
      name: :needs,
      kind: :option,
      contexts: [:stage],
      type: "list of stage-name atoms",
      summary: "Stages that must finish before this one starts (builds the DAG).",
      example: "needs: [:build, :test]"
    },
    %Entry{
      name: :when,
      kind: :option,
      contexts: [:stage],
      type: "condition expression",
      summary: "Runs the stage only when the condition is true at pipeline time.",
      example: ~s|when: branch() == "main"|
    },
    %Entry{
      name: :working_dir,
      kind: :option,
      contexts: [:stage],
      type: "string",
      summary: "Directory the stage's steps run in, relative to the repo root.",
      example: ~s|working_dir: "apps/web"|
    },
    %Entry{
      name: :matrix,
      kind: :option,
      contexts: [:stage],
      type: "keyword list of string lists",
      summary: "Fans the stage out over every combination of the given values.",
      example: ~s|matrix: [elixir: ["1.17", "1.18"], otp: ["26", "27"]]|
    },
    %Entry{
      name: :max_parallel,
      kind: :option,
      contexts: [:stage],
      type: "positive integer",
      summary: "Caps how many matrix/parallel jobs run at once.",
      example: "max_parallel: 2"
    },
    %Entry{
      name: :allow_failure,
      kind: :option,
      contexts: [:stage],
      type: "boolean",
      summary: "When true, the stage may fail without failing the pipeline.",
      example: "allow_failure: true"
    }
  ]

  @step_options [
    %Entry{
      name: :cmd,
      kind: :option,
      contexts: [:step],
      type: "string",
      summary: "Shell command to run for this step.",
      example: ~s|cmd: "mix test"|
    },
    %Entry{
      name: :module,
      kind: :option,
      contexts: [:step],
      type: "module alias",
      summary: "A module implementing the step behaviour, instead of a shell command.",
      example: "module: MyApp.DeployStep"
    },
    %Entry{
      name: :env,
      kind: :option,
      contexts: [:step, :hook],
      type: "map of string => string | store(:key)",
      summary: "Environment variables for this step, merged over the stage/pipeline env.",
      example: ~s|env: %{"MIX_ENV" => "test"}|
    },
    %Entry{
      name: :timeout,
      kind: :option,
      contexts: [:step, :hook],
      type: "positive integer (milliseconds)",
      summary: "Fails the step if it runs longer than this.",
      example: "timeout: 60_000"
    },
    %Entry{
      name: :allow_failure,
      kind: :option,
      contexts: [:step],
      type: "boolean",
      summary: "When true, the step may fail without failing its stage.",
      example: "allow_failure: true"
    },
    %Entry{
      name: :when,
      kind: :option,
      contexts: [:step],
      type: "condition expression",
      summary: "Runs the step only when the condition is true at pipeline time.",
      example: ~s|when: file_changed?("lib/**/*.ex")|
    },
    %Entry{
      name: :working_dir,
      kind: :option,
      contexts: [:step],
      type: "string",
      summary: "Directory this step runs in, relative to the repo root.",
      example: ~s|working_dir: "apps/web"|
    },
    %Entry{
      name: :retry,
      kind: :option,
      contexts: [:step],
      type: "positive integer",
      summary: "How many times to retry the step on failure.",
      example: "retry: 3"
    },
    %Entry{
      name: :retry_delay,
      kind: :option,
      contexts: [:step],
      type: "non-negative integer (milliseconds)",
      summary: "Delay between retries.",
      example: "retry_delay: 1_000"
    },
    %Entry{
      name: :cache,
      kind: :option,
      contexts: [:step],
      type: "keyword list — paths: [string], key: string",
      summary: "Restores/saves the given paths keyed by a file's contents.",
      example: ~s|cache: [paths: ["deps", "_build"], key: "mix.lock"]|
    },
    %Entry{
      name: :artifact,
      kind: :option,
      contexts: [:step],
      type: "keyword list — name: string, paths: [string], required: boolean",
      summary: "Persists build outputs for later stages or inspection.",
      example: ~s|artifact: [name: "build", paths: ["_build"]]|
    }
  ]

  @hook_options [
    %Entry{
      name: :cmd,
      kind: :option,
      contexts: [:hook],
      type: "string",
      summary: "Shell command to run for this hook.",
      example: ~s|cmd: "curl -X POST $SLACK_WEBHOOK"|
    },
    %Entry{
      name: :module,
      kind: :option,
      contexts: [:hook],
      type: "module alias",
      summary: "A module implementing the hook callback, instead of a shell command.",
      example: "module: MyApp.Notifier"
    },
    %Entry{
      name: :env,
      kind: :option,
      contexts: [:hook],
      type: "map of string => string | store(:key)",
      summary: "Extra environment variables for the hook command.",
      example: ~s|env: %{"CHANNEL" => "#deploys"}|
    },
    %Entry{
      name: :timeout,
      kind: :option,
      contexts: [:hook],
      type: "positive integer (milliseconds)",
      summary: "Fails the hook if it runs longer than this. Defaults to 30_000.",
      example: "timeout: 30_000"
    }
  ]

  @condition_primitives [
    %Entry{
      name: :branch,
      kind: :primitive,
      contexts: [:condition],
      type: "() :: String.t()",
      summary: "The current git branch name.",
      example: ~s|branch() == "main"|
    },
    %Entry{
      name: :env,
      kind: :primitive,
      contexts: [:condition],
      type: "(String.t()) :: String.t() | nil",
      summary: "The value of an OS environment variable, or nil when unset.",
      example: ~s|env("CI") != nil|
    },
    %Entry{
      name: :file_changed?,
      kind: :primitive,
      contexts: [:condition],
      type: "(String.t()) :: boolean()",
      summary: "True when a changed file matches the glob (supports * and **).",
      example: ~s|file_changed?("lib/**/*.ex")|
    }
  ]

  @options_by_context %{
    stage: @stage_options,
    step: @step_options,
    hook: @hook_options
  }

  @all_options @stage_options ++ @step_options ++ @hook_options

  @doc "All directive entries, across every context."
  @spec directives() :: [Entry.t()]
  def directives, do: @directives

  @doc "Directive entries valid in the given context."
  @spec directives(Entry.context()) :: [Entry.t()]
  def directives(context), do: Enum.filter(@directives, &(context in &1.contexts))

  @doc "Option entries valid in the given option context (`:stage`, `:step`, `:hook`)."
  @spec options(:stage | :step | :hook) :: [Entry.t()]
  def options(context), do: Map.get(@options_by_context, context, [])

  @doc "Every option entry, across all contexts (duplicate names across contexts are kept)."
  @spec all_options() :: [Entry.t()]
  def all_options, do: @all_options

  @doc "The permitted option keys for a context — the validator's allowlist source."
  @spec option_keys(:stage | :step | :hook) :: [atom()]
  def option_keys(context), do: context |> options() |> Enum.map(& &1.name)

  @doc "The condition primitives available inside a `when:` value."
  @spec condition_primitives() :: [Entry.t()]
  def condition_primitives, do: @condition_primitives

  @doc """
  Looks up a single entry by name, preferring one valid in `context`.

  `name` may be an atom or a string. When no entry matches the given context the
  search falls back to any context, so a symbol typed in the "wrong" place still
  resolves for hover. Returns `nil` when the name is unknown.
  """
  @spec lookup(atom() | String.t(), Entry.context()) :: Entry.t() | nil
  def lookup(name, context) when is_binary(name) do
    case safe_to_atom(name) do
      nil -> nil
      atom -> lookup(atom, context)
    end
  end

  def lookup(name, context) when is_atom(name) do
    matches = Enum.filter(all_entries(), &(&1.name == name))

    Enum.find(matches, &(context in &1.contexts)) || List.first(matches)
  end

  defp all_entries, do: @directives ++ @all_options ++ @condition_primitives

  defp safe_to_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end
end
