defmodule TinyCI.Events.Sink.Console do
  @moduledoc """
  `TinyCI.EventSink` that renders all human-readable run progress.

  This is the single renderer for the human console: stage headers, skip notices,
  buffered and streaming step output, matrix combination rows, and retry notices
  are all produced here, purely by consuming events. Nothing outside the event
  sinks renders step or stage progress.

  Output mode (streaming vs buffered) is a property of this sink, not a separate
  renderer:

    * **streaming** — each `step_output` line is printed as it arrives, prefixed
      with the step's `[prefix]` when one was assigned (parallel stages). Matrix
      output is still grouped and printed when the stage finishes.
    * **buffered** — per-step output is held until the stage finishes, then printed
      under the step's header so parallel output stays grouped by step rather than
      interleaved. Steps and matrix rows are ordered by the declaration `index`
      the executor stamps on `step_started` / `matrix_run_started`, not by the
      (concurrent) order they arrive in, matching the old `TinyCI.Reporter`.

  Registered automatically for a run unless `console: false` is given, in which
  case no console sink is attached (suppressing progress output).

  ## Options

    * `:mode` — `:streaming` or `:buffered` (default `:buffered`)

  Redaction happens once, in the dispatcher, before any event reaches this sink;
  the sink never masks.
  """

  @behaviour TinyCI.EventSink

  alias TinyCI.Events.{
    MatrixRunStarted,
    StageCompleted,
    StageSkipped,
    StageStarted,
    StepCompleted,
    StepOutputLine,
    StepRetrying,
    StepStarted
  }

  alias TinyCI.Matrix

  @type key :: {atom(), keyword(String.t()) | nil}
  @type t :: %{
          mode: :streaming | :buffered,
          order: %{optional(key()) => [atom()]},
          prefixes: %{optional({atom(), keyword(String.t()) | nil, atom()}) => String.t()},
          outputs: %{optional({atom(), keyword(String.t()) | nil, atom()}) => String.t()},
          indices: %{optional({atom(), keyword(String.t()) | nil, atom()}) => non_neg_integer()},
          combo_order: %{optional(atom()) => [keyword(String.t())]},
          combo_indices: %{optional(atom()) => %{keyword(String.t()) => non_neg_integer()}}
        }

  # Sort key for a unit the executor did not stamp (should not happen for output
  # that is actually rendered); keeps it after every ordered unit.
  @unindexed 1_000_000_000

  @impl TinyCI.EventSink
  def init(opts) do
    {:ok,
     %{
       mode: Keyword.get(opts, :mode, :buffered),
       order: %{},
       prefixes: %{},
       outputs: %{},
       indices: %{},
       combo_order: %{},
       combo_indices: %{}
     }}
  end

  @impl TinyCI.EventSink
  def handle_event(_seq, %StageStarted{stage: stage}, state) do
    IO.puts("Stage: #{stage}")
    {:ok, state}
  end

  def handle_event(_seq, %StageSkipped{reason: reason}, state) do
    IO.puts("  Skipped (#{reason})")
    {:ok, state}
  end

  # A step with retries announces its first attempt here (the rest arrive as
  # `step_retrying`), matching the old listener's `[attempt n/total]` notices.
  def handle_event(_seq, %StepStarted{attempts: attempts} = event, state) do
    if attempts, do: IO.puts("  [attempt 1/#{attempts}]")
    {:ok, remember_step(state, event)}
  end

  def handle_event(_seq, %StepRetrying{attempt: attempt, total: total}, state) do
    IO.puts("  [attempt #{attempt_format(attempt, total)}]")
    {:ok, state}
  end

  def handle_event(_seq, %StepOutputLine{matrix_combination: combo}, state)
      when not is_nil(combo) do
    # Matrix output is grouped and printed when the stage finishes, never live.
    {:ok, state}
  end

  def handle_event(_seq, %StepOutputLine{} = event, %{mode: :streaming} = state) do
    prefix = Map.get(state.prefixes, {event.stage, event.matrix_combination, event.step})
    IO.puts(render_line(prefix, event.line))
    {:ok, state}
  end

  def handle_event(_seq, %StepOutputLine{}, state), do: {:ok, state}

  def handle_event(_seq, %StepCompleted{} = event, state) do
    state = remember_step(state, event)
    key = {event.stage, event.matrix_combination, event.step}
    {:ok, %{state | outputs: Map.put(state.outputs, key, event.output)}}
  end

  def handle_event(_seq, %MatrixRunStarted{} = event, state) do
    combos = Map.get(state.combo_order, event.stage, [])
    combos = if event.combination in combos, do: combos, else: combos ++ [event.combination]

    combo_indices =
      case event.index do
        nil ->
          state.combo_indices

        index ->
          Map.update(
            state.combo_indices,
            event.stage,
            %{event.combination => index},
            &Map.put(&1, event.combination, index)
          )
      end

    {:ok,
     %{
       state
       | combo_order: Map.put(state.combo_order, event.stage, combos),
         combo_indices: combo_indices
     }}
  end

  def handle_event(_seq, %StageCompleted{stage: stage}, state) do
    print_stage_output(stage, state)
    {:ok, state}
  end

  def handle_event(_seq, _event, state), do: {:ok, state}

  @impl TinyCI.EventSink
  def close(_state), do: :ok

  # ---------------------------------------------------------------------------
  # Buffered rendering
  # ---------------------------------------------------------------------------

  defp print_stage_output(stage, state) do
    case ordered_combos(state, stage) do
      # Regular step output was printed live in streaming mode; only buffered
      # mode holds it until the stage finishes.
      [] ->
        if state.mode == :buffered do
          Enum.each(ordered_steps(state, stage, nil), &print_step(&1, stage, nil, state))
        end

      # Matrix output is always grouped, in both modes.
      combos ->
        Enum.each(combos, &print_combo(&1, stage, state))
    end
  end

  defp print_combo(combo, stage, state) do
    label = Matrix.label(combo)

    state
    |> ordered_steps(stage, combo)
    |> Enum.each(fn step ->
      case output(state, stage, combo, step) do
        "" -> :ok
        output -> IO.puts("  [#{label}][#{step}] #{String.trim(output)}")
      end
    end)
  end

  defp print_step(step, stage, combo, state) do
    case output(state, stage, combo, step) do
      "" -> :ok
      output -> IO.puts("  [#{step}] #{String.trim(output)}")
    end
  end

  defp ordered_steps(state, stage, combo) do
    key = {stage, combo}

    state.order
    |> Map.get(key, [])
    |> Enum.sort_by(&Map.get(state.indices, {stage, combo, &1}, @unindexed))
  end

  defp ordered_combos(state, stage) do
    indices = Map.get(state.combo_indices, stage, %{})

    state.combo_order
    |> Map.get(stage, [])
    |> Enum.sort_by(&Map.get(indices, &1, @unindexed))
  end

  defp output(state, stage, combo, step), do: Map.get(state.outputs, {stage, combo, step}, "")

  # ---------------------------------------------------------------------------
  # Streaming rendering
  # ---------------------------------------------------------------------------

  defp render_line(nil, line), do: line
  defp render_line(prefix, line), do: "  [#{prefix}] #{line}"

  defp attempt_format(attempt, nil), do: to_string(attempt)
  defp attempt_format(attempt, total), do: "#{attempt}/#{total}"

  # ---------------------------------------------------------------------------
  # State helpers
  # ---------------------------------------------------------------------------

  # Steps are tracked in first-seen order (a fallback for units without an index),
  # but rendered in the declaration order carried by `index`.
  defp remember_step(state, event) do
    key = {event.stage, event.matrix_combination}
    step_key = {event.stage, event.matrix_combination, event.step}
    steps = Map.get(state.order, key, [])

    state =
      if event.step in steps do
        state
      else
        %{state | order: Map.put(state.order, key, steps ++ [event.step])}
      end

    state =
      case Map.get(event, :prefix) do
        nil -> state
        prefix -> %{state | prefixes: Map.put(state.prefixes, step_key, prefix)}
      end

    case Map.get(event, :index) do
      nil -> state
      index -> %{state | indices: Map.put(state.indices, step_key, index)}
    end
  end
end
