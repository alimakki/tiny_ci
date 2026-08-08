defmodule TinyCI.Control do
  @moduledoc """
  Execution control: pause a run at a step/stage boundary, inspect it, then
  continue / skip / retry / abort — or edit the store and retry.

  This module is the whole public surface. The executor calls `checkpoint/2` at
  every boundary; drivers call `subscribe/1` and `resume/3`. Nothing else reaches
  into the control plane, which is what lets one protocol serve the terminal REPL
  (`TinyCI.Control.Console`), the future DAP adapter (T18), and a hosted web UI
  (T12) unchanged. See `docs/execution-control.md`.

  ## Cost when unarmed

  `checkpoint/2` is a single `Map.get(context, :control)` when no breakpoints are
  armed — the same shape as `TinyCI.Events.emit/2`. `:control` is only ever placed
  on the context by `TinyCI.Executor.run_pipeline/3` when the caller passes
  `control:`, so an ordinary run pays one map lookup per boundary and takes no
  different code path.

  ## Arming breakpoints

  Via the CLI:

      mix tiny_ci.run --break before:deploy --break after:test.unit

  Or programmatically, which is also how a driver or a test drives a run:

      {:ok, breakpoint} = TinyCI.Control.Breakpoint.parse("before:deploy")

      TinyCI.Executor.run_pipeline(stages, context,
        control: [breakpoints: [breakpoint], subscribers: [self()]]
      )

  ## Driving a paused run

  A subscriber receives:

    * `{:tiny_ci_control, :breakpoint_hit, %TinyCI.Control.Session{}}`
    * `{:tiny_ci_control, :resumed, pause_id, command}`
    * `{:tiny_ci_control, :diverged, reason, session}`

  and answers with `resume/3`:

      receive do
        {:tiny_ci_control, :breakpoint_hit, session} ->
          TinyCI.Control.resume(session.run_id, session.pause_id, {:set_store, :tag, "v2"})
          TinyCI.Control.resume(session.run_id, session.pause_id, :retry)
      end

  Pass `subscribers:` at arm time rather than calling `subscribe/1` when you need
  to observe the *first* breakpoint: the control server does not exist until the
  run starts, so an early `subscribe/1` would race it. `subscribe/1` is for
  attaching to a run already in flight.

  ## Divergence

  `set_store`, a forced `skip`, and a forced `retry` each change what the run
  would otherwise have done, so each emits `TinyCI.Events.RunDiverged`. A diverged
  run is not a CI result: `TinyCI.Provenance` flags it and attestation refuses to
  sign it (cross-cutting invariant 5).
  """

  alias TinyCI.Control.{Breakpoint, Server, Session}
  alias TinyCI.Events

  @type command :: Server.command()
  @type outcome :: :continue | :skip | :retry | :abort

  @doc """
  A boundary in the executor. Returns the command to obey, the (possibly
  store-edited) context to obey it with, and the store keys the operator edited.

  Blocks the calling process for as long as the boundary stays paused — which is
  the point: each step and each DAG stage runs in its own process, so a pause here
  never freezes an independent branch.

  The overrides are returned separately from the context because the step path
  needs them as a *delta*: it folds them into the `%StepResult{}`'s `store_data`,
  which is how a hand-edited value propagates out of a parallel step through the
  existing store-merge logic rather than around it.

  ## Options

    * `:phase`       — `:before` or `:after` (required)
    * `:step`        — the step name; omit or `nil` for a stage boundary
    * `:step_env`    — the step's declared `env:`, for the payload
    * `:working_dir` — the step's effective working directory, for the payload
    * `:result`      — the `%StepResult{}`/`%StageResult{}` about to be recorded,
      on `:after` boundaries

  ## Returns

  `{command, context, store_overrides}` where command is:

    * `:continue` — run/keep as normal
    * `:skip`     — do not run it, or force the result to `:skipped`
    * `:retry`    — re-run the body (the caller bypasses any cache)
    * `:abort`    — unwind the run
  """
  @spec checkpoint(map(), keyword()) :: {outcome(), map(), map()}
  def checkpoint(context, opts) do
    case Map.get(context, :control) do
      nil -> {:continue, context, %{}}
      server -> at_boundary(server, context, opts)
    end
  end

  defp at_boundary(server, context, opts) do
    step = Keyword.get(opts, :step)
    scope = if is_nil(step), do: :stage, else: :step
    boundary = {Keyword.fetch!(opts, :phase), scope, Map.get(context, :stage_name), step}

    case Server.check(server, boundary) do
      :none -> {:continue, context, %{}}
      :aborted -> {:abort, context, %{}}
      {:pause, breakpoint} -> pause(server, context, opts, scope, breakpoint)
    end
  end

  defp pause(server, context, opts, scope, breakpoint) do
    session =
      Session.build(
        context,
        opts |> Keyword.put(:scope, scope) |> Keyword.put(:breakpoint, breakpoint)
      )

    Events.emit(context, Session.to_event(session, DateTime.utc_now()))

    case Server.pause(server, session) do
      {:aborted, _session} -> {:abort, context, %{}}
      :ok -> await(session, context)
    end
  end

  defp await(%Session{pause_id: pause_id}, context) do
    receive do
      {:tiny_ci_control_resume, ^pause_id, command, overrides} ->
        {command, apply_overrides(context, overrides), overrides}
    end
  end

  defp apply_overrides(context, overrides) when map_size(overrides) == 0, do: context

  defp apply_overrides(context, overrides) do
    Map.put(context, :store, Map.merge(Map.get(context, :store, %{}), overrides))
  end

  @doc """
  Issues a control command against a paused boundary.

  Terminal commands (`:continue`, `:skip`, `:retry`, `:abort`) return `:ok` and
  release the paused process. `{:set_store, key, value}` returns `{:ok, :applied}`
  and leaves it paused, so several keys can be edited before resuming — this plus
  `:retry` is the primitive T17's "re-run with edited inputs" is built on.
  """
  @spec resume(String.t() | pid(), String.t(), command()) ::
          :ok | {:ok, :applied} | {:error, :not_found | :unknown_pause | :unknown_command}
  def resume(run, pause_id, command) do
    with {:ok, server} <- Server.whereis(run) do
      Server.resume(server, pause_id, command)
    end
  end

  @doc "Subscribes the calling process to a live run's control notifications."
  @spec subscribe(String.t() | pid()) :: :ok | {:error, :not_found}
  def subscribe(run), do: subscribe(run, self())

  @doc "Subscribes `pid` to a live run's control notifications."
  @spec subscribe(String.t() | pid(), pid()) :: :ok | {:error, :not_found}
  def subscribe(run, pid) do
    with {:ok, server} <- Server.whereis(run) do
      Server.subscribe(server, pid)
    end
  end

  @doc "Returns the run's currently paused sessions, oldest pause first."
  @spec paused(String.t() | pid()) :: [Session.t()] | {:error, :not_found}
  def paused(run) do
    with {:ok, server} <- Server.whereis(run) do
      Server.paused(server)
    end
  end

  @doc "Returns true when a run has a control plane, i.e. it armed breakpoints."
  @spec armed?(String.t() | pid()) :: boolean()
  def armed?(run), do: match?({:ok, _}, Server.whereis(run))

  @doc "Returns true when manual control has altered the run."
  @spec divergent?(String.t() | pid()) :: boolean() | {:error, :not_found}
  def divergent?(run) do
    with {:ok, server} <- Server.whereis(run) do
      Server.divergent?(server)
    end
  end

  @doc """
  Normalizes the executor's `control:` option into `TinyCI.Control.Server` options.

  Accepts already-parsed `%TinyCI.Control.Breakpoint{}` structs or raw `--break`
  spec strings, so callers do not have to parse twice.
  """
  @spec server_opts(keyword(), String.t(), pid()) :: {:ok, keyword()} | {:error, [String.t()]}
  def server_opts(control, run_id, dispatcher) do
    with {:ok, breakpoints} <- parse_all(Keyword.get(control, :breakpoints, [])) do
      {:ok,
       [
         run_id: run_id,
         dispatcher: dispatcher,
         breakpoints: breakpoints,
         timeout: Keyword.get(control, :timeout, :infinity),
         timeout_action: Keyword.get(control, :timeout_action, :abort),
         subscribers: Keyword.get(control, :subscribers, [])
       ]}
    end
  end

  defp parse_all(specs) do
    {parsed, errors} =
      Enum.reduce(specs, {[], []}, fn spec, {ok, errors} ->
        case parse_one(spec) do
          {:ok, breakpoint} -> {[breakpoint | ok], errors}
          {:error, message} -> {ok, [message | errors]}
        end
      end)

    if errors == [], do: {:ok, Enum.reverse(parsed)}, else: {:error, Enum.reverse(errors)}
  end

  defp parse_one(%Breakpoint{} = breakpoint), do: {:ok, breakpoint}
  defp parse_one(spec) when is_binary(spec), do: Breakpoint.parse(spec)
end
