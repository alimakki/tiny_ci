defmodule TinyCI.ExecutionFixtures.SpecBackend do
  @moduledoc """
  A backend that records each `SessionSpec` it is asked to open.

  Each line in `<workspace>/session_specs.log` is
  `IMAGE|NETWORK|LIMITS`, where `IMAGE` is `-` when nil and `LIMITS` is `-`
  when empty. It otherwise behaves like a passing Local backend.
  """

  @behaviour TinyCI.Execution.Backend

  alias TinyCI.Execution.{Command, SessionSpec}

  @impl true
  def name, do: :spec

  @impl true
  def available?, do: true

  @impl true
  def open(%SessionSpec{} = spec) do
    path = Path.join(spec.workspace, "session_specs.log")

    File.write!(
      path,
      [spec.image || "-", "|", to_string(spec.network), "|", inspect(spec.limits), "\n"],
      [:append]
    )

    {:ok, nil}
  end

  @impl true
  def exec(_session, %Command{}, on_line) do
    on_line.("recorded")
    {:passed, "recorded\n"}
  end

  @impl true
  def close(_session), do: :ok
end
