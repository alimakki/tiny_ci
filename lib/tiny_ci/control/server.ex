defmodule TinyCI.Control.Server do
  @moduledoc """
  The control plane for one run: which breakpoints are armed, which boundaries are
  currently paused, and whether the run has diverged or been aborted.

  One server per run, registered under the run's id in `TinyCI.Control.Registry`
  (an Elixir `Registry` — **not** `TinyCI.Registry`, which is the T9 curated action
  index). Any process that knows the `run_id` can therefore reach the control plane
  without the executor handing it a pid, which is what makes the surface
  transport-agnostic: a stdin REPL, a DAP adapter, and a web socket are all just
  subscribers issuing commands.

  ## Who blocks

  The server never blocks. The process that reached the breakpoint registers a
  session here and then waits in its own `receive`, so pausing one step or one DAG
  branch leaves every independent branch running. Releasing a session is a `send/2`
  to that waiting process.

  ## Timeouts

  `pause/2` arms a `Process.send_after/3` timer owned by *this* server, so a
  forgotten breakpoint resolves itself with the configured `:timeout_action`
  (`:abort` by default) instead of hanging CI. The server owning the timer — rather
  than each waiter using `receive ... after` — makes resume-versus-timeout races
  impossible: whichever the server handles first deletes the session, and the other
  becomes a no-op.
  """

  use GenServer

  alias TinyCI.Control.{Breakpoint, Session}
  alias TinyCI.Events
  alias TinyCI.Events.{BreakpointResumed, RunDiverged}

  @typedoc "A terminal control command: releases the paused process."
  @type terminal :: :continue | :skip | :retry | :abort

  @typedoc "Any control command. `{:set_store, key, value}` is non-terminal."
  @type command :: terminal() | {:set_store, atom(), term()}

  @typedoc "A boundary the executor can pause at."
  @type boundary :: {Breakpoint.phase(), Breakpoint.scope(), atom(), atom() | nil}

  # ---------------------------------------------------------------------------
  # Start / addressing
  # ---------------------------------------------------------------------------

  @doc """
  Starts the control server for a run.

  ## Options

    * `:run_id`         — the run's id; also its `Registry` key (required)
    * `:breakpoints`    — `[%TinyCI.Control.Breakpoint{}]` to arm (required)
    * `:dispatcher`     — the run's `TinyCI.Events.Dispatcher` pid, for emitting
      `breakpoint_resumed` and `run_diverged`
    * `:timeout`        — ms to wait at a breakpoint before auto-resolving; `:infinity`
      to wait forever (the default)
    * `:timeout_action` — `:abort` (default) or `:continue` when the timeout fires
    * `:subscribers`    — pids to notify from the start, before the run emits anything
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    run_id = Keyword.fetch!(opts, :run_id)
    GenServer.start_link(__MODULE__, opts, name: via(run_id))
  end

  @doc "The `:via` tuple addressing the control server for `run_id`."
  @spec via(String.t()) :: {:via, Registry, {module(), String.t()}}
  def via(run_id), do: {:via, Registry, {TinyCI.Control.Registry, run_id}}

  @doc """
  Looks up the control server for a run.

  Returns `{:error, :not_found}` when the run has no control plane — either it
  armed no breakpoints or it has already finished.
  """
  @spec whereis(String.t() | pid()) :: {:ok, pid()} | {:error, :not_found}
  def whereis(server) when is_pid(server), do: {:ok, server}

  def whereis(run_id) when is_binary(run_id) do
    case Registry.lookup(TinyCI.Control.Registry, run_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  # ---------------------------------------------------------------------------
  # Executor-facing API
  # ---------------------------------------------------------------------------

  @doc """
  Asks whether a boundary should pause.

  Returns `{:pause, breakpoint}` when one is armed for it, `:aborted` once the run
  has been aborted (so the caller unwinds without pausing again), or `:none`.
  """
  @spec check(pid(), boundary()) :: {:pause, Breakpoint.t()} | :aborted | :none
  def check(server, boundary), do: GenServer.call(server, {:check, boundary})

  @doc """
  Registers a paused session; the calling process must then wait for
  `{:tiny_ci_control_resume, pause_id, command, store_overrides}`.

  Returns `{:aborted, session}` if the run was aborted between `check/2` and here,
  in which case the caller should not wait at all.
  """
  @spec pause(pid(), Session.t()) :: :ok | {:aborted, Session.t()}
  def pause(server, %Session{} = session), do: GenServer.call(server, {:pause, session})

  @doc "Returns true once the run has been aborted through the control plane."
  @spec aborted?(pid()) :: boolean()
  def aborted?(server), do: GenServer.call(server, :aborted?)

  # ---------------------------------------------------------------------------
  # Driver-facing API
  # ---------------------------------------------------------------------------

  @doc """
  Issues a control command against a paused session.

  Terminal commands (`:continue`, `:skip`, `:retry`, `:abort`) release the paused
  process and return `:ok`. `{:set_store, key, value}` records a store override,
  marks the run divergent, and returns `{:ok, :applied}` with the session still
  paused, so several keys can be edited before resuming.
  """
  @spec resume(pid(), String.t(), command()) ::
          :ok | {:ok, :applied} | {:error, :unknown_pause | :unknown_command}
  def resume(server, pause_id, command),
    do: GenServer.call(server, {:resume, pause_id, command})

  @doc "Registers `pid` for control notifications; it is unsubscribed when it dies."
  @spec subscribe(pid(), pid()) :: :ok
  def subscribe(server, pid), do: GenServer.call(server, {:subscribe, pid})

  @doc "Returns the currently paused sessions, oldest pause first."
  @spec paused(pid()) :: [Session.t()]
  def paused(server), do: GenServer.call(server, :paused)

  @doc "Returns true when manual control has altered this run (see `TinyCI.Events.RunDiverged`)."
  @spec divergent?(pid()) :: boolean()
  def divergent?(server), do: GenServer.call(server, :divergent?)

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    subscribers =
      opts
      |> Keyword.get(:subscribers, [])
      |> Map.new(fn pid -> {Process.monitor(pid), pid} end)

    {:ok,
     %{
       run_id: Keyword.fetch!(opts, :run_id),
       breakpoints: Keyword.fetch!(opts, :breakpoints),
       dispatcher: Keyword.get(opts, :dispatcher),
       timeout: Keyword.get(opts, :timeout, :infinity),
       timeout_action: Keyword.get(opts, :timeout_action, :abort),
       subscribers: subscribers,
       sessions: %{},
       order: [],
       divergent: false,
       aborted: false
     }}
  end

  @impl GenServer
  def handle_call({:check, _boundary}, _from, %{aborted: true} = state),
    do: {:reply, :aborted, state}

  def handle_call({:check, boundary}, _from, state) do
    case Enum.find(state.breakpoints, &Breakpoint.match?(&1, boundary)) do
      nil -> {:reply, :none, state}
      breakpoint -> {:reply, {:pause, breakpoint}, state}
    end
  end

  def handle_call({:pause, session}, _from, %{aborted: true} = state),
    do: {:reply, {:aborted, session}, state}

  def handle_call({:pause, session}, {waiter, _tag}, state) do
    entry = %{
      session: session,
      waiter: waiter,
      overrides: %{},
      paused_at: System.monotonic_time(:millisecond),
      timer: start_timer(session.pause_id, state.timeout)
    }

    state = %{
      state
      | sessions: Map.put(state.sessions, session.pause_id, entry),
        order: state.order ++ [session.pause_id]
    }

    notify(state, {:tiny_ci_control, :breakpoint_hit, session})
    {:reply, :ok, state}
  end

  def handle_call(:aborted?, _from, state), do: {:reply, state.aborted, state}
  def handle_call(:divergent?, _from, state), do: {:reply, state.divergent, state}

  def handle_call(:paused, _from, state) do
    {:reply, Enum.map(state.order, &state.sessions[&1].session), state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, ref, pid)}}
  end

  def handle_call({:resume, pause_id, command}, _from, state) do
    case Map.fetch(state.sessions, pause_id) do
      {:ok, entry} -> apply_command(command, pause_id, entry, state)
      :error -> {:reply, {:error, :unknown_pause}, state}
    end
  end

  @impl GenServer
  def handle_info({:pause_timeout, pause_id}, state) do
    case Map.fetch(state.sessions, pause_id) do
      {:ok, entry} -> {:noreply, on_timeout(state.timeout_action, pause_id, entry, state)}
      # Already resumed by an operator; the timer simply lost the race.
      :error -> {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Commands
  # ---------------------------------------------------------------------------

  defp apply_command({:set_store, key, value}, pause_id, entry, state) do
    entry = %{entry | overrides: Map.put(entry.overrides, key, value)}
    state = %{state | sessions: Map.put(state.sessions, pause_id, entry)}
    state = diverge(state, :set_store, entry.session, "#{key} = #{inspect(value)}")
    {:reply, {:ok, :applied}, state}
  end

  defp apply_command(:abort, pause_id, entry, state) do
    {:reply, :ok, abort_run(pause_id, entry, state, false)}
  end

  defp apply_command(command, pause_id, entry, state) when command in [:skip, :retry] do
    state = diverge(state, command, entry.session, nil)
    {:reply, :ok, release(pause_id, entry, command, state, false)}
  end

  defp apply_command(:continue, pause_id, entry, state) do
    {:reply, :ok, release(pause_id, entry, :continue, state, false)}
  end

  defp apply_command(_unknown, _pause_id, _entry, state),
    do: {:reply, {:error, :unknown_command}, state}

  # A timeout is not a lesser abort: whichever action is configured must behave
  # exactly as if an operator had typed it, or `--break-timeout abort` would leave
  # the rest of the run going in CI.
  defp on_timeout(:abort, pause_id, entry, state), do: abort_run(pause_id, entry, state, true)

  defp on_timeout(:continue, pause_id, entry, state),
    do: release(pause_id, entry, :continue, state, true)

  # Abort is run-wide and cooperative: release this session, release every other
  # paused branch, and make every later `check/2` short-circuit. Steps already
  # running are left to finish rather than being killed mid-write.
  defp abort_run(pause_id, entry, state, timed_out?) do
    pause_id
    |> release(entry, :abort, %{state | aborted: true}, timed_out?)
    |> release_all()
  end

  defp release(pause_id, entry, command, state, timed_out?) do
    cancel_timer(entry.timer)
    send(entry.waiter, {:tiny_ci_control_resume, pause_id, command, entry.overrides})

    emit(state, %BreakpointResumed{
      run_id: state.run_id,
      timestamp: DateTime.utc_now(),
      pause_id: pause_id,
      command: command,
      waited_ms: System.monotonic_time(:millisecond) - entry.paused_at,
      stage: entry.session.stage,
      step: entry.session.step,
      timed_out: timed_out?
    })

    state = %{
      state
      | sessions: Map.delete(state.sessions, pause_id),
        order: List.delete(state.order, pause_id)
    }

    notify(state, {:tiny_ci_control, :resumed, pause_id, command})
    state
  end

  defp release_all(state) do
    Enum.reduce(state.order, state, fn pause_id, acc ->
      release(pause_id, acc.sessions[pause_id], :abort, acc, false)
    end)
  end

  defp diverge(state, reason, session, detail) do
    emit(state, %RunDiverged{
      run_id: state.run_id,
      timestamp: DateTime.utc_now(),
      reason: reason,
      stage: session.stage,
      step: session.step,
      detail: detail
    })

    notify(state, {:tiny_ci_control, :diverged, reason, session})
    %{state | divergent: true}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp start_timer(_pause_id, :infinity), do: nil

  defp start_timer(pause_id, timeout) when is_integer(timeout),
    do: Process.send_after(self(), {:pause_timeout, pause_id}, timeout)

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp emit(%{dispatcher: nil}, _event), do: :ok
  defp emit(%{dispatcher: dispatcher}, event), do: Events.emit(%{events: dispatcher}, event)

  defp notify(%{subscribers: subscribers}, message) do
    Enum.each(subscribers, fn {_ref, pid} -> send(pid, message) end)
  end
end
