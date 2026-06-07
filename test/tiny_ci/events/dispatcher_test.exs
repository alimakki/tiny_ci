defmodule TinyCI.Events.DispatcherTest.ForwardSink do
  @moduledoc false
  @behaviour TinyCI.EventSink

  @impl true
  def init(opts), do: {:ok, %{pid: Keyword.fetch!(opts, :pid), tag: Keyword.fetch!(opts, :tag)}}

  @impl true
  def handle_event(seq, event, %{pid: pid, tag: tag} = state) do
    send(pid, {:event, tag, seq, event})
    {:ok, state}
  end

  @impl true
  def close(%{pid: pid, tag: tag}) do
    send(pid, {:closed, tag})
    :ok
  end
end

defmodule TinyCI.Events.DispatcherTest.RaiseSink do
  @moduledoc false
  @behaviour TinyCI.EventSink

  @impl true
  def init(_opts), do: {:ok, nil}

  @impl true
  def handle_event(_seq, _event, _state), do: raise("boom")

  @impl true
  def close(_state), do: :ok
end

defmodule TinyCI.Events.DispatcherTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias TinyCI.Events.Dispatcher
  alias TinyCI.Events.DispatcherTest.{ForwardSink, RaiseSink}
  alias TinyCI.Events.StageStarted

  defp event, do: %StageStarted{run_id: "r", timestamp: DateTime.utc_now(), stage: :s}

  test "emit assigns a monotonic seq starting at 1" do
    {:ok, d} = Dispatcher.start_link([{ForwardSink, pid: self(), tag: :a}])

    assert :ok = Dispatcher.emit(d, event())
    assert :ok = Dispatcher.emit(d, event())
    assert :ok = Dispatcher.emit(d, event())

    assert_receive {:event, :a, 1, _}
    assert_receive {:event, :a, 2, _}
    assert_receive {:event, :a, 3, _}

    Dispatcher.stop(d)
  end

  test "seq is unique and contiguous across concurrent emitters" do
    {:ok, d} = Dispatcher.start_link([{ForwardSink, pid: self(), tag: :a}])
    n = 50

    for _ <- 1..n, do: spawn(fn -> Dispatcher.emit(d, event()) end)

    seqs =
      for _ <- 1..n do
        assert_receive {:event, :a, seq, _}, 2000
        seq
      end

    assert Enum.sort(seqs) == Enum.to_list(1..n)

    Dispatcher.stop(d)
  end

  test "fans out each event to every registered sink" do
    {:ok, d} =
      Dispatcher.start_link([
        {ForwardSink, pid: self(), tag: :a},
        {ForwardSink, pid: self(), tag: :b}
      ])

    Dispatcher.emit(d, event())

    assert_receive {:event, :a, 1, _}
    assert_receive {:event, :b, 1, _}

    Dispatcher.stop(d)
  end

  test "stop closes every sink" do
    {:ok, d} =
      Dispatcher.start_link([
        {ForwardSink, pid: self(), tag: :a},
        {ForwardSink, pid: self(), tag: :b}
      ])

    Dispatcher.stop(d)

    assert_receive {:closed, :a}
    assert_receive {:closed, :b}
  end

  test "a raising sink does not crash the dispatcher or other sinks" do
    {:ok, d} =
      Dispatcher.start_link([
        {RaiseSink, []},
        {ForwardSink, pid: self(), tag: :a}
      ])

    log =
      capture_log(fn ->
        assert :ok = Dispatcher.emit(d, event())
        assert_receive {:event, :a, 1, _}
        assert Process.alive?(d)

        # A second event still flows after the raise.
        assert :ok = Dispatcher.emit(d, event())
        assert_receive {:event, :a, 2, _}
      end)

    assert log =~ "RaiseSink raised: boom"

    Dispatcher.stop(d)
  end
end
