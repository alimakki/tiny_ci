defmodule TinyCI.ExecutionFixtures.RecordingBackend do
  @moduledoc """
  A Local-shaped backend that records session lifecycle calls in
  `<session workspace>/execution.log`.

  Recording in the workspace keeps the backend free of global state, so tests
  using it stay `async: true`. Shell commands containing `crash` raise from
  `exec/3`; commands containing `fail` return `{:failed, ""}`. Everything else
  passes and reports one line.
  """

  @behaviour TinyCI.Execution.Backend

  alias TinyCI.Execution.{Command, SessionSpec}

  @impl true
  def name, do: :recording

  @impl true
  def available?, do: true

  @impl true
  def open(%SessionSpec{} = spec) do
    path = Path.join(spec.workspace, "execution.log")
    append(path, "open #{spec.workspace} #{spec.run_id || "-"}")
    {:ok, %{path: path}}
  end

  @impl true
  def exec(%{path: path}, %Command{} = command, on_line) do
    append(path, "exec #{inspect(command.run)}")

    cond do
      crash?(command) ->
        raise "recording backend crashed"

      fail?(command) ->
        {:failed, ""}

      true ->
        on_line.("recorded")
        {:passed, "recorded\n"}
    end
  end

  @impl true
  def close(%{path: path}) do
    append(path, "close")
    :ok
  end

  defp crash?(%Command{run: {:shell, cmd}, env: env}) do
    String.contains?(cmd, "crash") or Map.get(env, "V") == "crash"
  end

  defp crash?(_command), do: false

  defp fail?(%Command{run: {:shell, cmd}}), do: String.contains?(cmd, "fail")
  defp fail?(_command), do: false

  defp append(path, line), do: File.write!(path, line <> "\n", [:append])
end

defmodule TinyCI.ExecutionFixtures.UnopenableBackend do
  @moduledoc """
  A backend whose `open/1` always fails, for session-error tests.
  """

  @behaviour TinyCI.Execution.Backend

  @impl true
  def name, do: :unopenable

  @impl true
  def available?, do: false

  @impl true
  def open(_spec), do: {:error, :no_runtime}

  @impl true
  def exec(_session, _command, _on_line), do: {:failed, ""}

  @impl true
  def close(_session), do: :ok
end
