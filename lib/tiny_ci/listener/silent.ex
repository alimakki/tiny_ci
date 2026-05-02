defmodule TinyCI.Listener.Silent do
  @moduledoc """
  No-op listener. All callbacks return `:ok` without printing anything.

  Used when output is handled by the caller after the pipeline run completes
  (e.g., `--output json` mode where the Mix task serializes results itself).
  """

  @behaviour TinyCI.Listener

  @impl TinyCI.Listener
  def stage_started(_name), do: :ok

  @impl TinyCI.Listener
  def stage_skipped(_name, _reason), do: :ok

  @impl TinyCI.Listener
  def stage_finished(_result), do: :ok

  @impl TinyCI.Listener
  def matrix_stage_finished(_runs), do: :ok

  @impl TinyCI.Listener
  def step_attempt(_attempt, _total), do: :ok
end
