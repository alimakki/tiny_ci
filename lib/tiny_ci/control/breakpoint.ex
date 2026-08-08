defmodule TinyCI.Control.Breakpoint do
  @moduledoc """
  A single armed breakpoint: a boundary in the resolved plan where execution pauses.

  ## Grammar

      SPEC   := ("before" | "after") ":" TARGET
      TARGET := stage | stage "." step

  So `before:deploy` pauses before the `:deploy` stage runs, and `after:test.unit`
  pauses after the `:unit` step of the `:test` stage produced its result.

  A stage-scoped breakpoint (`before:deploy`) fires once for the stage boundary; it
  does **not** implicitly fire for every step inside the stage. Arm a step-scoped
  breakpoint for that.

  ## Conditions

  The `:condition` field is reserved for T11 (conditional breakpoints). It is
  always `nil` today and `match?/2` ignores it — when T11 lands it will hold a
  `when:`-grammar AST evaluated through `TinyCI.DSL.ConditionEval`, so there is
  never a second condition language.
  """

  alias TinyCI.Stage

  @type phase :: :before | :after
  @type scope :: :stage | :step

  @type t :: %__MODULE__{
          phase: phase(),
          stage: atom(),
          step: atom() | nil,
          condition: term() | nil
        }

  @enforce_keys [:phase, :stage]
  defstruct [:phase, :stage, :step, :condition]

  @doc """
  Parses a `--break` spec string into a `%TinyCI.Control.Breakpoint{}`.

  ## Examples

      iex> TinyCI.Control.Breakpoint.parse("before:deploy")
      {:ok, %TinyCI.Control.Breakpoint{phase: :before, stage: :deploy, step: nil, condition: nil}}

      iex> TinyCI.Control.Breakpoint.parse("after:test.unit")
      {:ok, %TinyCI.Control.Breakpoint{phase: :after, stage: :test, step: :unit, condition: nil}}

      iex> TinyCI.Control.Breakpoint.parse("during:test")
      {:error, "unknown breakpoint phase \\"during\\" in \\"during:test\\" — expected \\"before\\" or \\"after\\""}
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, String.t()}
  def parse(spec) when is_binary(spec) do
    case String.split(String.trim(spec), ":", parts: 2) do
      [phase, target] -> build(spec, phase, String.trim(target))
      _ -> {:error, missing_phase_error(spec)}
    end
  end

  defp build(spec, phase, target) do
    with {:ok, phase} <- parse_phase(spec, phase),
         {:ok, stage, step} <- parse_target(spec, target) do
      {:ok, %__MODULE__{phase: phase, stage: stage, step: step}}
    end
  end

  defp parse_phase(_spec, "before"), do: {:ok, :before}
  defp parse_phase(_spec, "after"), do: {:ok, :after}

  defp parse_phase(spec, other) do
    {:error,
     ~s(unknown breakpoint phase "#{String.trim(other)}" in "#{spec}" — ) <>
       ~s(expected "before" or "after")}
  end

  defp parse_target(spec, target) do
    case String.split(target, ".", parts: 2) do
      [""] -> {:error, missing_target_error(spec)}
      [stage] -> named(spec, stage, nil)
      [stage, step] -> named(spec, stage, step)
    end
  end

  defp named(spec, stage, step) do
    cond do
      blank?(stage) -> {:error, missing_target_error(spec)}
      not is_nil(step) and blank?(step) -> {:error, missing_target_error(spec)}
      true -> {:ok, to_name(stage), step && to_name(step)}
    end
  end

  defp blank?(value), do: String.trim(value) == ""

  # Strips the leading colon so both `before:deploy` and `before::deploy` read
  # naturally, matching how `--filter` accepts `:name` or `name`.
  defp to_name(value) do
    value |> String.trim() |> String.trim_leading(":") |> String.to_atom()
  end

  defp missing_phase_error(spec) do
    ~s(invalid breakpoint "#{spec}" — expected "before:STAGE", "after:STAGE", ) <>
      ~s("before:STAGE.STEP", or "after:STAGE.STEP")
  end

  defp missing_target_error(spec) do
    ~s(breakpoint "#{spec}" names no target — expected "STAGE" or "STAGE.STEP" after the phase)
  end

  @doc """
  Renders a breakpoint back to its canonical spec string.

  ## Examples

      iex> bp = %TinyCI.Control.Breakpoint{phase: :after, stage: :test, step: :unit}
      iex> TinyCI.Control.Breakpoint.format(bp)
      "after:test.unit"
  """
  @spec format(t()) :: String.t()
  def format(%__MODULE__{phase: phase, stage: stage, step: nil}), do: "#{phase}:#{stage}"

  def format(%__MODULE__{phase: phase, stage: stage, step: step}),
    do: "#{phase}:#{stage}.#{step}"

  @doc """
  Returns the scope a breakpoint targets — `:stage` when no step is named.

  ## Examples

      iex> TinyCI.Control.Breakpoint.scope(%TinyCI.Control.Breakpoint{phase: :before, stage: :test})
      :stage
  """
  @spec scope(t()) :: scope()
  def scope(%__MODULE__{step: nil}), do: :stage
  def scope(%__MODULE__{}), do: :step

  @doc """
  Returns `true` when the breakpoint targets the given boundary.

  A boundary is `{phase, scope, stage_name, step_name}`; `step_name` is `nil` for
  stage boundaries.

  ## Examples

      iex> bp = %TinyCI.Control.Breakpoint{phase: :before, stage: :test, step: :unit}
      iex> TinyCI.Control.Breakpoint.match?(bp, {:before, :step, :test, :unit})
      true
      iex> TinyCI.Control.Breakpoint.match?(bp, {:before, :stage, :test, nil})
      false
  """
  @spec match?(t(), {phase(), scope(), atom(), atom() | nil}) :: boolean()
  def match?(%__MODULE__{} = bp, {phase, scope, stage, step}) do
    bp.phase == phase and scope(bp) == scope and bp.stage == stage and bp.step == step
  end

  @doc """
  Validates parsed breakpoints against the stages that will actually run.

  Returns `:ok`, or `{:error, messages}` listing every unknown stage or step
  alongside what is available — the same up-front-failure contract as the
  `--filter` validation in `mix tiny_ci.run`, so a typo never costs a whole run.
  """
  @spec validate([t()], [Stage.t()]) :: :ok | {:error, [String.t()]}
  def validate(breakpoints, stages) do
    case Enum.flat_map(breakpoints, &target_errors(&1, stages)) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp target_errors(%__MODULE__{} = bp, stages) do
    case Enum.find(stages, &(&1.name == bp.stage)) do
      nil -> [unknown_stage_error(bp, stages)]
      stage -> unknown_step_errors(bp, stage)
    end
  end

  defp unknown_stage_error(bp, stages) do
    available = Enum.map_join(stages, ", ", fn s -> ":#{s.name}" end)

    ~s(breakpoint "#{format(bp)}" names unknown stage :#{bp.stage}. Available stages: #{available})
  end

  defp unknown_step_errors(%__MODULE__{step: nil}, _stage), do: []

  defp unknown_step_errors(%__MODULE__{step: step} = bp, stage) do
    if Enum.any?(stage.steps, &(&1.name == step)) do
      []
    else
      available = Enum.map_join(stage.steps, ", ", fn s -> ":#{s.name}" end)

      [
        ~s(breakpoint "#{format(bp)}" names unknown step :#{step} in stage :#{stage.name}. ) <>
          ~s(Available steps: #{available})
      ]
    end
  end
end
