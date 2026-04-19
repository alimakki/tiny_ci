defmodule TinyCI.Pipeline do
  @moduledoc """
  Converts raw DSL-accumulated data into normalized `%TinyCI.Stage{}`
  and `%TinyCI.Step{}` structs.

  The DSL macros accumulate stages as `{name, opts, steps}` tuples with
  steps stored in reverse order. This module reverses the steps back to
  declaration order and maps all options onto their corresponding struct
  fields, filling in defaults where needed.
  """

  alias TinyCI.{Hook, Stage, Step}

  @doc """
  Normalizes a raw stage tuple into a `%TinyCI.Stage{}` struct.

  Steps are reversed to restore declaration order (the DSL accumulates
  them via prepend) and each step keyword list is converted to a
  `%TinyCI.Step{}` struct.

  ## Parameters

    * `{name, opts, steps}` — a tuple where:
      * `name` is the stage atom
      * `opts` is a keyword list (`:mode`, `:when`, etc.)
      * `steps` is a list of step keyword lists in reverse order

  ## Returns

  A `%TinyCI.Stage{}` with normalized steps.
  """
  @spec normalize_stage({atom(), keyword(), [keyword()]}) :: Stage.t()
  def normalize_stage({name, opts, steps}) do
    %Stage{
      name: name,
      mode: Keyword.get(opts, :mode, :parallel),
      when_condition: Keyword.get(opts, :when),
      steps: steps |> Enum.reverse() |> Enum.map(&normalize_step/1)
    }
  end

  defp normalize_step(step_opts) do
    %Step{
      name: step_opts[:name],
      cmd: step_opts[:cmd],
      module: step_opts[:module],
      mode: Keyword.get(step_opts, :mode, :inherit),
      requires: Keyword.get(step_opts, :requires, []),
      env: Keyword.get(step_opts, :env, %{}),
      config_block: step_opts[:config_block],
      timeout: step_opts[:timeout],
      allow_failure: Keyword.get(step_opts, :allow_failure, false)
    }
  end

  @doc """
  Normalizes a raw hook keyword list into a `%TinyCI.Hook{}` struct.

  Called by the DSL's `__hooks__/0` generated function to convert the
  accumulated keyword lists into structured hook data.

  ## Parameters

    * `hook_opts` — a keyword list with at minimum `:name` and either `:cmd`
      or `:module`

  ## Returns

  A `%TinyCI.Hook{}` struct with all recognized fields populated and defaults
  applied for missing optional fields.
  """
  @spec normalize_hook(keyword()) :: Hook.t()
  def normalize_hook(hook_opts) do
    %TinyCI.Hook{
      name: hook_opts[:name],
      cmd: hook_opts[:cmd],
      module: hook_opts[:module],
      env: Keyword.get(hook_opts, :env, %{}),
      config_block: hook_opts[:config_block],
      timeout: hook_opts[:timeout]
    }
  end
end
