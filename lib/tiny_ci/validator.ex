defmodule TinyCI.Validator do
  @moduledoc """
  Validates pipeline definitions at compile time.

  Checks for common mistakes such as duplicate step names within a stage,
  steps missing both `:cmd` and `:module`, and steps that ambiguously
  specify both.
  """

  @doc """
  Validates raw pipeline stage data as accumulated by the DSL.

  Each stage is a tuple `{name, opts, steps}` where steps are keyword
  lists of step options.

  ## Returns

    * `:ok` — pipeline is valid
    * `{:error, [String.t()]}` — list of human-readable error messages
  """
  @spec validate([{atom(), keyword(), [keyword()]}]) :: :ok | {:error, [String.t()]}
  def validate(stages) do
    errors = Enum.flat_map(stages, &validate_stage/1)

    case errors do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp validate_stage({stage_name, _opts, steps}) do
    duplicate_errors(stage_name, steps) ++ step_type_errors(stage_name, steps)
  end

  defp duplicate_errors(stage_name, steps) do
    steps
    |> Enum.map(&Keyword.get(&1, :name))
    |> Enum.frequencies()
    |> Enum.filter(fn {_name, count} -> count > 1 end)
    |> Enum.map(fn {name, _count} ->
      "Stage :#{stage_name} has duplicate step name :#{name}"
    end)
  end

  defp step_type_errors(stage_name, steps) do
    Enum.flat_map(steps, fn step_opts ->
      name = Keyword.get(step_opts, :name)
      cmd = Keyword.get(step_opts, :cmd)
      mod = Keyword.get(step_opts, :module)

      cond do
        is_nil(cmd) and is_nil(mod) ->
          ["Step :#{name} in stage :#{stage_name} must specify either :cmd or :module"]

        not is_nil(cmd) and not is_nil(mod) ->
          ["Step :#{name} in stage :#{stage_name} specifies both :cmd and :module"]

        true ->
          []
      end
    end)
  end
end
