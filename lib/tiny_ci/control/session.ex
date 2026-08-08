defmodule TinyCI.Control.Session do
  @moduledoc """
  A paused boundary: everything a driver needs to reason about the stop, and the
  handle used to release it.

  A session is created by the process that hit the breakpoint, handed to
  `TinyCI.Control.Server` (which broadcasts it to subscribers and turns it into a
  `breakpoint_hit` event), and released by `TinyCI.Control.resume/3` quoting its
  `pause_id`.

  ## Inspectable state

  The session reports the boundary's resolved environment (via
  `TinyCI.Executor.Env`), working directory, pipeline store snapshot, git context,
  and — inside a matrix stage — the combination being run. On an `:after` boundary
  it also carries a summary of the result about to be recorded.

  ## Safety of the payload

  Store values are arbitrary Elixir terms, and the payload is serialized into the
  NDJSON event stream. `coerce/1` keeps JSON-native scalars as they are and renders
  everything else with `inspect/1`, so a pid or a struct in the store can never
  break the stream. The whole payload then passes through
  `TinyCI.Sandbox.Redaction.redact/2` with the run's known secret values, so a
  secret cannot leak into an event or the console via a breakpoint.
  """

  alias TinyCI.Control.Breakpoint
  alias TinyCI.Events.BreakpointHit
  alias TinyCI.Executor.Env
  alias TinyCI.Sandbox.Redaction

  @type t :: %__MODULE__{
          pause_id: String.t(),
          run_id: String.t(),
          phase: Breakpoint.phase(),
          scope: Breakpoint.scope(),
          stage: atom(),
          step: atom() | nil,
          breakpoint: Breakpoint.t() | nil,
          env: Env.env(),
          working_dir: String.t() | nil,
          store: map(),
          branch: String.t() | nil,
          commit: String.t() | nil,
          matrix_combination: keyword(String.t()) | nil,
          result: map() | nil
        }

  @enforce_keys [:pause_id, :run_id, :phase, :scope, :stage]
  defstruct [
    :pause_id,
    :run_id,
    :phase,
    :scope,
    :stage,
    :step,
    :breakpoint,
    :working_dir,
    :branch,
    :commit,
    :matrix_combination,
    :result,
    env: %{},
    store: %{}
  ]

  @doc """
  Builds a session for a boundary the executor is about to pause at.

  ## Options

    * `:phase`       — `:before` or `:after` (required)
    * `:scope`       — `:stage` or `:step` (required)
    * `:breakpoint`  — the `%Breakpoint{}` that matched
    * `:step_env`    — the step's declared `env:`, resolved against the store
    * `:working_dir` — the step's effective working directory
    * `:result`      — a `%StepResult{}` or `%StageResult{}` for `:after` boundaries
  """
  @spec build(map(), keyword()) :: t()
  def build(context, opts) do
    secrets = Map.get(context, :secrets, [])

    %__MODULE__{
      pause_id: generate_pause_id(),
      run_id: Map.get(context, :run_id),
      phase: Keyword.fetch!(opts, :phase),
      scope: Keyword.fetch!(opts, :scope),
      stage: Map.get(context, :stage_name),
      step: Keyword.get(opts, :step),
      breakpoint: Keyword.get(opts, :breakpoint),
      env: redact(coerce(Env.resolve(context, Keyword.get(opts, :step_env))), secrets),
      working_dir: Keyword.get(opts, :working_dir) || Map.get(context, :root),
      store: redact(coerce(Map.get(context, :store, %{})), secrets),
      branch: Map.get(context, :branch),
      commit: Map.get(context, :commit),
      matrix_combination: Map.get(context, :matrix_combination),
      result: redact(summarize_result(Keyword.get(opts, :result)), secrets)
    }
  end

  @doc "Builds the `breakpoint_hit` event describing this session."
  @spec to_event(t(), DateTime.t()) :: BreakpointHit.t()
  def to_event(%__MODULE__{} = session, timestamp) do
    %BreakpointHit{
      run_id: session.run_id,
      timestamp: timestamp,
      pause_id: session.pause_id,
      phase: session.phase,
      scope: session.scope,
      stage: session.stage,
      step: session.step,
      breakpoint: session.breakpoint && Breakpoint.format(session.breakpoint),
      env: session.env,
      working_dir: session.working_dir,
      store: session.store,
      branch: session.branch,
      commit: session.commit,
      matrix_combination: session.matrix_combination,
      result: session.result
    }
  end

  @doc """
  A one-line human description of the boundary, e.g. `"before test.unit"`.

  ## Examples

      iex> session = %TinyCI.Control.Session{
      ...>   pause_id: "p1", run_id: "r1", phase: :before, scope: :step,
      ...>   stage: :test, step: :unit
      ...> }
      iex> TinyCI.Control.Session.describe(session)
      "before test.unit"
  """
  @spec describe(t()) :: String.t()
  def describe(%__MODULE__{phase: phase, stage: stage, step: nil}), do: "#{phase} #{stage}"

  def describe(%__MODULE__{phase: phase, stage: stage, step: step}),
    do: "#{phase} #{stage}.#{step}"

  @doc """
  Coerces a term into something the JSON event stream can carry.

  JSON-native scalars pass through; maps and lists are walked; anything else
  (tuples, pids, structs, functions) is rendered with `inspect/1`. Map keys always
  become strings.

  ## Examples

      iex> TinyCI.Control.Session.coerce(%{count: 2, ok: true, ref: {:a, :b}})
      %{"count" => 2, "ok" => true, "ref" => "{:a, :b}"}
  """
  @spec coerce(term()) :: term()
  def coerce(term) when is_binary(term) or is_number(term) or is_boolean(term) or is_nil(term),
    do: term

  def coerce(term) when is_atom(term), do: to_string(term)
  def coerce(term) when is_list(term), do: Enum.map(term, &coerce/1)

  def coerce(term) when is_map(term) and not is_struct(term) do
    Map.new(term, fn {key, value} -> {to_string(key), coerce(value)} end)
  end

  def coerce(term), do: inspect(term)

  defp redact(nil, _secrets), do: nil
  defp redact(term, secrets), do: Redaction.redact(term, secrets)

  defp summarize_result(nil), do: nil

  defp summarize_result(result) do
    %{
      "status" => to_string(result.status),
      "duration_ms" => Map.get(result, :duration_ms),
      "output" => Map.get(result, :output)
    }
  end

  defp generate_pause_id do
    "pause_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end
end
