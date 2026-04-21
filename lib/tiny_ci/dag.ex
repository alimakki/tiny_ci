defmodule TinyCI.DAG do
  @moduledoc """
  Computes and validates stage dependency graphs for DAG-mode pipeline execution.

  When one or more stages declare `needs:`, the pipeline switches from
  sequential execution to DAG execution: independent stages run in parallel
  and dependent stages wait for all their prerequisites to complete.

  Uses Kahn's BFS algorithm to topologically sort stages into parallel
  execution levels and to detect cycles.
  """

  alias TinyCI.Stage

  @doc """
  Validates that the stages form a valid DAG.

  Checks for unknown stage references and circular dependencies.

  ## Returns

    * `:ok` — all stages are valid and the graph is acyclic
    * `{:error, {:unknown_stages, [String.t()]}}` — references to undefined stages
    * `{:error, {:circular_dependency, [atom()]}}` — cycle detected; returns the
      names of the stages involved in the cycle
  """
  @spec validate([Stage.t()]) :: :ok | {:error, term()}
  def validate(stages) do
    case build_levels(stages) do
      {:ok, _levels} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  Computes parallel execution levels from a list of stages.

  Each level is a list of stages that may run concurrently because all
  their dependencies belong to earlier levels.

  When no stage has `needs:` set, all stages are placed in a single level
  (preserving their original order) for backward-compatible sequential
  execution by the caller.

  ## Returns

    * `{:ok, [[%Stage{}, ...]]}` — list of parallel levels in execution order
    * `{:error, {:unknown_stages, [String.t()]}}` — references to undefined stages
    * `{:error, {:circular_dependency, [atom()]}}` — cycle detected
  """
  @spec build_levels([Stage.t()]) :: {:ok, [[Stage.t()]]} | {:error, term()}
  def build_levels([]), do: {:ok, []}

  def build_levels(stages) do
    stage_names = MapSet.new(stages, & &1.name)

    unknown_errors =
      for stage <- stages,
          need <- stage.needs,
          not MapSet.member?(stage_names, need),
          do: "Stage :#{stage.name} needs unknown stage :#{need}"

    if unknown_errors != [] do
      {:error, {:unknown_stages, unknown_errors}}
    else
      run_kahn(stages)
    end
  end

  @doc """
  Returns true if any stage in the list has a `needs:` declaration.
  Used by the executor to decide between sequential and DAG execution.
  """
  @spec dag_mode?([Stage.t()]) :: boolean()
  def dag_mode?(stages), do: Enum.any?(stages, fn s -> s.needs != [] end)

  # ---------------------------------------------------------------------------
  # Kahn's BFS topological sort
  # ---------------------------------------------------------------------------

  defp run_kahn(stages) do
    stage_map = Map.new(stages, fn s -> {s.name, s} end)
    in_degree = Map.new(stages, fn s -> {s.name, length(s.needs)} end)
    dependents = build_dependents(stages)

    initial_queue =
      stages
      |> Enum.filter(fn s -> in_degree[s.name] == 0 end)
      |> Enum.map(& &1.name)

    bfs(initial_queue, in_degree, dependents, stage_map, [], length(stages))
  end

  defp build_dependents(stages) do
    Enum.reduce(stages, %{}, fn stage, acc ->
      Enum.reduce(stage.needs, acc, fn dep, a ->
        Map.update(a, dep, [stage.name], &[stage.name | &1])
      end)
    end)
  end

  defp bfs([], _in_degree, _dependents, stage_map, acc, remaining) when remaining > 0 do
    processed_names = acc |> List.flatten() |> MapSet.new(& &1.name)
    cycle_members = stage_map |> Map.keys() |> Enum.reject(&MapSet.member?(processed_names, &1))
    {:error, {:circular_dependency, Enum.sort(cycle_members)}}
  end

  defp bfs([], _in_degree, _dependents, _stage_map, acc, 0) do
    {:ok, Enum.reverse(acc)}
  end

  defp bfs(queue, in_degree, dependents, stage_map, acc, remaining) do
    level = Enum.map(queue, fn name -> stage_map[name] end)
    new_remaining = remaining - length(queue)

    {new_in_degree, next_queue} =
      Enum.reduce(queue, {in_degree, []}, &process_queue_entry(&1, &2, dependents))

    bfs(next_queue, new_in_degree, dependents, stage_map, [level | acc], new_remaining)
  end

  defp process_queue_entry(name, acc, dependents) do
    Enum.reduce(Map.get(dependents, name, []), acc, &decrement_in_degree/2)
  end

  defp decrement_in_degree(dep_name, {d, n}) do
    new_d = Map.update!(d, dep_name, &(&1 - 1))
    if new_d[dep_name] == 0, do: {new_d, [dep_name | n]}, else: {new_d, n}
  end
end
