defmodule TinyCI.Execution.Preflight do
  @moduledoc """
  Refuses repository module code in an untrusted run before anything executes.

  A pipeline file is repository content, so an untrusted invocation may only use
  actions that ship with tiny_ci itself — `:builtin` OTP/Elixir modules. Every
  other `module:` step or hook fails the run up front, naming the stage/step or
  hook and the module.

  Classification uses `TinyCI.Sandbox.Trust.classify/2` with `load: false` by
  default, so pre-flight never loads (and therefore never executes) repository
  code just to ask what it is. A module that is not already loaded classifies as
  `:unknown` and is refused.
  """

  alias TinyCI.{Hook, Stage}
  alias TinyCI.Execution
  alias TinyCI.Execution.Paths
  alias TinyCI.Sandbox.Trust

  @type detail :: %{
          kind: :step | :hook,
          stage: atom() | nil,
          name: atom(),
          module: module(),
          class: atom()
        }

  @doc """
  Checks all module steps and hooks, and the working directories they use, in a
  run.

  Returns `:ok` for a trusted run or when only builtin actions are used and every
  path is inside the workspace. Otherwise it returns
  `{:error, {:untrusted_actions, details}}` or
  `{:error, {:unsafe_pipeline_paths, details}}`.

  ## Options

    * `:classify` — a function `module -> class` (test/extension seam; defaults
      to `Trust.classify(module, load: false, root_app: ...)`)
  """
  @spec check(map(), [Stage.t()], map(), keyword()) ::
          :ok | {:error, {:untrusted_actions, [detail()]} | {:unsafe_pipeline_paths, [map()]}}
  def check(context, stages, hooks, opts \\ []) do
    case Execution.trust(context) do
      :trusted ->
        :ok

      :untrusted ->
        action_details = step_details(stages, opts) ++ hook_details(hooks, opts)
        path_details = path_details(context, stages)

        cond do
          action_details != [] -> {:error, {:untrusted_actions, action_details}}
          path_details != [] -> {:error, {:unsafe_pipeline_paths, path_details}}
          true -> :ok
        end
    end
  end

  defp path_details(context, stages) do
    root = Map.get(context, :root) || File.cwd!()

    Enum.flat_map(stages, fn %Stage{name: stage, steps: steps, working_dir: stage_dir} ->
      stage_paths =
        if safe_path?(root, stage_dir),
          do: [],
          else: [%{kind: :stage, stage: stage, name: stage, path: stage_dir}]

      step_paths =
        for %{name: name, working_dir: dir} <- steps,
            not safe_path?(root, dir) do
          %{kind: :step, stage: stage, name: name, path: dir}
        end

      stage_paths ++ step_paths
    end)
  end

  defp safe_path?(_root, nil), do: true
  defp safe_path?(root, path), do: Paths.inside?(root, path)

  defp step_details(stages, opts) do
    for %Stage{name: stage, steps: steps} <- stages,
        %{module: module, name: name} <- steps,
        not is_nil(module),
        class = classify(module, opts),
        class != :builtin do
      %{kind: :step, stage: stage, name: name, module: module, class: class}
    end
  end

  defp hook_details(hooks, opts) do
    (hooks || %{})
    |> Map.values()
    |> List.flatten()
    |> Enum.flat_map(fn
      %Hook{module: nil} ->
        []

      %Hook{name: name, module: module} ->
        class = classify(module, opts)

        if class == :builtin,
          do: [],
          else: [
            %{kind: :hook, stage: nil, name: name, module: module, class: class}
          ]
    end)
  end

  defp classify(module, opts) do
    case Keyword.fetch(opts, :classify) do
      {:ok, fun} -> fun.(module)
      :error -> Trust.classify(module, load: false, root_app: TinyCI.Project.root_app())
    end
  end
end
