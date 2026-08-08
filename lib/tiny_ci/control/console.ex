defmodule TinyCI.Control.Console do
  @moduledoc """
  The terminal driver for execution control: prints a paused boundary and reads
  commands from stdin.

  This is an ordinary `TinyCI.Control` subscriber with no privileged access — the
  same protocol a DAP adapter (T18) or web UI (T12) speaks. It exists so `--break`
  is useful from a plain shell on its own.

  ## Commands

      continue | c        resume and run/keep the boundary as normal
      skip | s            do not run it (or force the result to skipped)
      retry | r           re-run the body, bypassing any cache
      abort | a           stop the whole run
      set KEY VALUE       edit a store key, then keep inspecting
      store               re-print the store snapshot
      env                 re-print the resolved environment
      info                re-print the full boundary
      help | ?            list these commands

  `set` marks the run **divergent**; the prompt says so, because a divergent run is
  no longer a CI result and cannot be attested.

  ## One prompt at a time

  Independent branches keep running while one is paused, so several boundaries can
  be paused at once. Only the oldest is prompted for; the rest are reported as
  queued and picked up in turn. Use `--debug-serial` when you want stepping to be
  fully predictable rather than racing live output.
  """

  use GenServer

  alias TinyCI.Control
  alias TinyCI.Control.Session

  @doc """
  Starts the driver.

  Pass its pid to the executor as `control: [subscribers: [pid]]` — starting it
  first is what lets it observe the very first breakpoint, since the control server
  does not exist until the run begins.

  ## Options

    * `:io`    — the IO device to read commands from (default `:stdio`); tests
      inject a `StringIO`
    * `:label` — a prefix for the prompt (default `"tiny_ci"`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       io: Keyword.get(opts, :io, :stdio),
       label: Keyword.get(opts, :label, "tiny_ci"),
       queue: [],
       current: nil
     }}
  end

  @impl GenServer
  def handle_info({:tiny_ci_control, :breakpoint_hit, session}, state) do
    {:noreply, enqueue(state, session)}
  end

  # The server confirms its own resumes too; only clear `current` when the pause we
  # are prompting for is the one that went away (a timeout can beat the operator).
  def handle_info({:tiny_ci_control, :resumed, pause_id, _command}, state) do
    case state.current do
      %Session{pause_id: ^pause_id} -> {:noreply, prompt_next(%{state | current: nil})}
      _other -> {:noreply, state}
    end
  end

  def handle_info({:tiny_ci_control, :diverged, _reason, _session}, state), do: {:noreply, state}

  def handle_info({:prompt, pause_id}, %{current: %Session{pause_id: pause_id}} = state) do
    {:noreply, read_command(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ---------------------------------------------------------------------------
  # Prompting
  # ---------------------------------------------------------------------------

  defp enqueue(%{current: nil} = state, session) do
    print_boundary(state, session, 0)
    schedule_prompt(%{state | current: session})
  end

  defp enqueue(state, session) do
    write(state, [
      "\n",
      IO.ANSI.faint(),
      "⏸  also paused: #{Session.describe(session)} (queued)",
      IO.ANSI.reset(),
      "\n"
    ])

    %{state | queue: state.queue ++ [session]}
  end

  defp prompt_next(state) do
    case state.queue do
      [] ->
        state

      [session | rest] ->
        print_boundary(state, session, length(rest))
        schedule_prompt(%{state | current: session, queue: rest})
    end
  end

  # Prompt from a fresh message rather than inline, so the blocking read never
  # happens while handling the control server's notification.
  defp schedule_prompt(%{current: session} = state) do
    send(self(), {:prompt, session.pause_id})
    state
  end

  defp read_command(%{current: session} = state) do
    case gets(state, "(#{state.label}) ") do
      :eof -> resume(state, session, :abort, "stdin closed — aborting the run")
      line -> dispatch(state, session, parse(line))
    end
  end

  defp dispatch(state, session, {:resume, command}) do
    resume(state, session, command, nil)
  end

  defp dispatch(state, session, {:set, key, value}) do
    Control.resume(session.run_id, session.pause_id, {:set_store, key, value})

    write(state, [
      "   ",
      IO.ANSI.yellow(),
      "store.#{key} = #{inspect(value)} — run marked divergent (not attestable)",
      IO.ANSI.reset(),
      "\n"
    ])

    # Still paused: reflect the edit locally so `store` shows it, then prompt again.
    read_command(%{state | current: put_store(session, key, value)})
  end

  defp dispatch(state, session, {:show, what}) do
    show(state, session, what)
    read_command(state)
  end

  defp dispatch(state, _session, {:error, message}) do
    write(state, ["   ", IO.ANSI.red(), message, IO.ANSI.reset(), "\n"])
    read_command(state)
  end

  defp resume(state, session, command, note) do
    if note, do: write(state, ["   ", IO.ANSI.yellow(), note, IO.ANSI.reset(), "\n"])
    Control.resume(session.run_id, session.pause_id, command)
    # `current` is cleared when the server's :resumed notification arrives, which
    # keeps a single source of truth for what is actually paused.
    state
  end

  defp put_store(session, key, value) do
    %{session | store: Map.put(session.store, to_string(key), value)}
  end

  # ---------------------------------------------------------------------------
  # Parsing
  # ---------------------------------------------------------------------------

  defp parse(line) do
    case line |> to_string() |> String.trim() |> String.split(~r/\s+/, parts: 3) do
      [""] -> {:resume, :continue}
      [word] -> parse_word(word)
      ["set", _key] -> {:error, ~s(usage: set KEY VALUE)}
      ["set", key, value] -> {:set, String.to_atom(key), value}
      [word | _rest] -> parse_word(word)
    end
  end

  defp parse_word(word) when word in ~w(continue c), do: {:resume, :continue}
  defp parse_word(word) when word in ~w(skip s), do: {:resume, :skip}
  defp parse_word(word) when word in ~w(retry r), do: {:resume, :retry}
  defp parse_word(word) when word in ~w(abort a), do: {:resume, :abort}
  defp parse_word(word) when word in ~w(store env info), do: {:show, String.to_atom(word)}
  defp parse_word(word) when word in ~w(help ?), do: {:show, :help}
  defp parse_word("set"), do: {:error, ~s(usage: set KEY VALUE)}

  defp parse_word(word),
    do: {:error, ~s(unknown command "#{word}" — try "help")}

  # ---------------------------------------------------------------------------
  # Rendering
  # ---------------------------------------------------------------------------

  defp print_boundary(state, session, queued) do
    write(state, [
      "\n",
      IO.ANSI.bright(),
      "⏸  breakpoint #{Session.describe(session)}",
      IO.ANSI.reset(),
      queued_suffix(queued),
      "\n"
    ])

    show(state, session, :info)
  end

  defp queued_suffix(0), do: ""
  defp queued_suffix(n), do: IO.ANSI.faint() <> "  (#{n} other paused)" <> IO.ANSI.reset()

  defp show(state, session, :info) do
    write(state, [
      field("stage", session.stage),
      field("step", session.step),
      field("wd", session.working_dir),
      field("git", "#{session.branch} @ #{short(session.commit)}"),
      field("matrix", session.matrix_combination && inspect(session.matrix_combination)),
      field("result", session.result && session.result["status"])
    ])

    show(state, session, :store)
    show(state, session, :env)
  end

  defp show(state, session, :store), do: write(state, table("store", session.store))
  defp show(state, session, :env), do: write(state, table("env", session.env))

  defp show(state, _session, :help) do
    write(state, """
       continue | c      resume normally
       skip | s          do not run it / force the result to skipped
       retry | r         re-run the body, bypassing any cache
       abort | a         stop the whole run
       set KEY VALUE     edit a store key (marks the run divergent)
       store | env       re-print the store / resolved environment
       info              re-print the whole boundary
    """)
  end

  defp field(_name, nil), do: []

  defp field(name, value),
    do: ["   ", String.pad_trailing(name <> ":", 8), to_string(value), "\n"]

  defp table(name, map) when map_size(map) == 0,
    do: [
      "   ",
      String.pad_trailing(name <> ":", 8),
      IO.ANSI.faint(),
      "(empty)",
      IO.ANSI.reset(),
      "\n"
    ]

  defp table(name, map) do
    [
      ["   ", name, ":\n"]
      | for {key, value} <- Enum.sort(map) do
          ["     ", key, " = ", inspect(value), "\n"]
        end
    ]
  end

  defp short(nil), do: "unknown"
  defp short(commit), do: String.slice(commit, 0, 8)

  # ---------------------------------------------------------------------------
  # IO
  # ---------------------------------------------------------------------------

  defp write(%{io: io}, data), do: IO.write(io, data)

  defp gets(%{io: io}, prompt) do
    case IO.gets(io, prompt) do
      :eof -> :eof
      {:error, _reason} -> :eof
      line -> line
    end
  end
end
