defmodule TinyCI.DSL.FlowAnalysis do
  @moduledoc """
  Flow-aware, semantic diagnostics over a resolved pipeline — the wiring
  mistakes the syntactic validator can't see.

  Runs only when the buffer is grammatically valid (the caller gates on this),
  and reports, with accurate source spans:

    * **undefined `needs:` targets** — a stage depends on a stage that doesn't
      exist (message matches `TinyCI.DAG`'s);
    * **dependency cycles** — reported inline on each participating stage
      (cycle detection reuses `TinyCI.DAG`);
    * **store reads with no writer** — a `store(:k)` read where no module step
      writes `:k`; a warning when every writer's outputs are statically known,
      downgraded to an info hint when some module step doesn't declare `outputs`;
    * **conflicting parallel writers** — two steps that may run concurrently
      both write the same store key, making the value nondeterministic.

  Positions come from the AST (`stage`/`step` calls and `store(...)` calls all
  carry `line`/`column`); `needs:` atoms are bare in the AST, so those
  diagnostics anchor to the enclosing `stage` call. Store *writers* are read from
  each `module:` action's `c:TinyCI.Action.metadata/0` `:outputs`.
  """

  alias TinyCI.{Action, DAG, DSL.Diagnostic, PipelineSpec, Stage}

  @doc """
  Returns flow diagnostics for the given AST and its resolved spec.

  Graph problems (undefined needs, cycles) are reported first; store dataflow is
  analyzed only when the graph is sound, to avoid cascading noise.
  """
  @spec diagnostics(Macro.t(), PipelineSpec.t()) :: [Diagnostic.t()]
  def diagnostics(ast, %PipelineSpec{} = spec) do
    metas = stage_meta_map(ast)

    case graph_diagnostics(spec, metas) do
      [] -> store_diagnostics(ast, spec)
      graph_diags -> graph_diags
    end
  end

  # ---------------------------------------------------------------------------
  # Graph: undefined needs + cycles
  # ---------------------------------------------------------------------------

  defp graph_diagnostics(%PipelineSpec{stages: stages}, metas) do
    case unknown_needs(stages, metas) do
      [] -> cycle_diagnostics(stages, metas)
      unknown -> unknown
    end
  end

  defp unknown_needs(stages, metas) do
    names = MapSet.new(stages, & &1.name)

    for %Stage{name: name, needs: needs} <- stages,
        need <- needs,
        not MapSet.member?(names, need) do
      Diagnostic.new("Stage :#{name} needs unknown stage :#{need}", meta_for(metas, name))
    end
  end

  defp cycle_diagnostics(stages, metas) do
    case DAG.build_levels(stages) do
      {:ok, _levels} ->
        []

      {:error, {:circular_dependency, members}} ->
        listed = Enum.map_join(members, ", ", &":#{&1}")

        Enum.map(members, fn name ->
          Diagnostic.new(
            "Stage :#{name} is part of a dependency cycle (stages: #{listed})",
            meta_for(metas, name)
          )
        end)

      {:error, _other} ->
        []
    end
  end

  # ---------------------------------------------------------------------------
  # Store dataflow
  # ---------------------------------------------------------------------------

  defp store_diagnostics(ast, spec) do
    readers = store_readers(ast)
    {writers, unknown_writers?} = store_writers(ast)

    reader_diagnostics(readers, writers, unknown_writers?) ++
      conflict_diagnostics(writers, spec)
  end

  # Every `store(:k)` node, with its position. These are reads from the store.
  defp store_readers(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {:store, meta, [key]} = node, acc when is_atom(key) -> {node, [{key, meta} | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(acc)
  end

  # Writers keyed by store key: %{key => [{stage_name, step_meta}]}, plus whether
  # any module step's outputs could not be determined statically.
  defp store_writers(ast) do
    Enum.reduce(top_level_stages(ast), {%{}, false}, fn {stage_name, steps}, acc ->
      Enum.reduce(steps, acc, &writers_for_step(&1, stage_name, &2))
    end)
  end

  defp writers_for_step({:step, meta, [_name | rest]}, stage_name, {writers, unknown?}) do
    case step_module(rest) do
      nil ->
        {writers, unknown?}

      module ->
        case Action.metadata(module) do
          %{outputs: outputs} when is_list(outputs) ->
            {record_writers(writers, outputs, stage_name, meta), unknown?}

          _ ->
            {writers, true}
        end
    end
  end

  defp record_writers(writers, outputs, stage_name, meta) do
    Enum.reduce(outputs, writers, fn key, acc ->
      Map.update(acc, key, [{stage_name, meta}], &[{stage_name, meta} | &1])
    end)
  end

  defp reader_diagnostics(readers, writers, unknown_writers?) do
    Enum.flat_map(readers, fn {key, meta} ->
      cond do
        Map.has_key?(writers, key) ->
          []

        unknown_writers? ->
          [
            Diagnostic.new(
              "Store key :#{key} is read here but no step is known to write it. " <>
                "Some module steps don't declare `outputs` in their metadata, so a " <>
                "writer can't be confirmed.",
              meta,
              severity: :information
            )
          ]

        true ->
          [
            Diagnostic.new(
              "Store key :#{key} is read here but no step writes it.",
              meta,
              severity: :warning
            )
          ]
      end
    end)
  end

  defp conflict_diagnostics(writers, spec) do
    ancestors = ancestors_map(spec.stages)
    dag_mode? = DAG.dag_mode?(spec.stages)

    Enum.flat_map(writers, fn {key, key_writers} ->
      conflicting = concurrent_writers(key_writers, spec, ancestors, dag_mode?)
      conflict_diagnostics_for(key, conflicting)
    end)
  end

  defp conflict_diagnostics_for(_key, conflicting) when length(conflicting) < 2, do: []

  defp conflict_diagnostics_for(key, conflicting) do
    stages = conflicting |> Enum.map(fn {name, _meta} -> ":#{name}" end) |> Enum.uniq()
    listed = Enum.join(stages, ", ")

    Enum.map(conflicting, fn {_name, meta} ->
      Diagnostic.new(
        "Store key :#{key} is written by multiple steps that may run in parallel " <>
          "(stages: #{listed}); the final value is nondeterministic.",
        meta,
        severity: :warning
      )
    end)
  end

  # Writers that can run concurrently with at least one other writer of the key.
  defp concurrent_writers(key_writers, spec, ancestors, dag_mode?) do
    Enum.filter(key_writers, fn writer ->
      Enum.any?(key_writers, fn other ->
        other != writer and concurrent?(writer, other, spec, ancestors, dag_mode?)
      end)
    end)
  end

  defp concurrent?({stage, _}, {stage, _}, spec, _ancestors, _dag_mode?) do
    stage_mode(spec, stage) == :parallel
  end

  defp concurrent?({a, _}, {b, _}, _spec, ancestors, dag_mode?) do
    dag_mode? and not ordered?(a, b, ancestors)
  end

  defp ordered?(a, b, ancestors) do
    MapSet.member?(Map.get(ancestors, a, MapSet.new()), b) or
      MapSet.member?(Map.get(ancestors, b, MapSet.new()), a)
  end

  # ---------------------------------------------------------------------------
  # Stage/step extraction from the AST
  # ---------------------------------------------------------------------------

  defp stage_meta_map(ast) do
    ast
    |> unwrap_block()
    |> Enum.flat_map(fn
      {:stage, meta, [name | _]} when is_atom(name) -> [{name, meta}]
      _ -> []
    end)
    |> Map.new()
  end

  defp top_level_stages(ast) do
    ast
    |> unwrap_block()
    |> Enum.flat_map(fn
      {:stage, _meta, [name | rest]} when is_atom(name) -> [{name, stage_steps(rest)}]
      _ -> []
    end)
  end

  defp stage_steps(rest) do
    rest
    |> stage_block()
    |> unwrap_block()
    |> Enum.filter(&match?({:step, _, _}, &1))
  end

  defp stage_block([opts, [do: block]]) when is_list(opts), do: block
  defp stage_block([opts]) when is_list(opts), do: Keyword.get(opts, :do)
  defp stage_block(_), do: nil

  defp step_module(rest) do
    rest
    |> step_opts()
    |> Keyword.get(:module)
    |> resolve_module()
  end

  defp step_opts([opts | _]) when is_list(opts), do: opts
  defp step_opts(_), do: []

  defp resolve_module({:__aliases__, _meta, parts}), do: Module.concat(parts)
  defp resolve_module(module) when is_atom(module) and not is_nil(module), do: module
  defp resolve_module(_), do: nil

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp stage_mode(spec, name) do
    case Enum.find(spec.stages, &(&1.name == name)) do
      %Stage{mode: mode} -> mode
      _ -> :parallel
    end
  end

  defp ancestors_map(stages) do
    needs = Map.new(stages, fn %Stage{name: name, needs: needs} -> {name, needs} end)
    Map.new(Map.keys(needs), fn name -> {name, ancestors(name, needs, MapSet.new())} end)
  end

  defp ancestors(name, needs, acc) do
    Enum.reduce(Map.get(needs, name, []), acc, fn dep, seen ->
      if MapSet.member?(seen, dep),
        do: seen,
        else: ancestors(dep, needs, MapSet.put(seen, dep))
    end)
  end

  defp meta_for(metas, name), do: Map.get(metas, name, [])

  defp unwrap_block(nil), do: []
  defp unwrap_block({:__block__, _meta, exprs}), do: exprs
  defp unwrap_block(single), do: [single]
end
