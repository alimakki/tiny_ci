defmodule TinyCI.ExecutionTest do
  use ExUnit.Case, async: true

  doctest TinyCI.Execution

  alias TinyCI.Execution
  alias TinyCI.Execution.{Command, SessionSpec}
  alias TinyCI.Execution.Backend.Local

  alias TinyCI.ExecutionFixtures.{
    RecordingBackend,
    UnopenableBackend
  }

  @moduletag :tmp_dir

  defp spec(tmp_dir, run_id \\ "run_test") do
    %SessionSpec{workspace: tmp_dir, run_id: run_id}
  end

  defp log(tmp_dir) do
    tmp_dir
    |> Path.join("execution.log")
    |> File.read!()
    |> String.split("\n", trim: true)
  end

  describe "with_session/3" do
    test "opens, yields, and closes around a normal return", %{tmp_dir: tmp_dir} do
      assert :done =
               Execution.with_session(
                 spec(tmp_dir),
                 fn session ->
                   assert %TinyCI.Execution.Session{backend: RecordingBackend} = session
                   :done
                 end,
                 backend: RecordingBackend
               )

      assert log(tmp_dir) == ["open #{tmp_dir} run_test", "close"]
    end

    test "closes when the block raises", %{tmp_dir: tmp_dir} do
      assert_raise RuntimeError, "boom", fn ->
        Execution.with_session(
          spec(tmp_dir),
          fn _session -> raise "boom" end,
          backend: RecordingBackend
        )
      end

      assert log(tmp_dir) == ["open #{tmp_dir} run_test", "close"]
    end

    test "closes when the block exits", %{tmp_dir: tmp_dir} do
      assert catch_exit(
               Execution.with_session(
                 spec(tmp_dir),
                 fn _session -> exit(:boom) end,
                 backend: RecordingBackend
               )
             ) == :boom

      assert log(tmp_dir) == ["open #{tmp_dir} run_test", "close"]
    end

    test "raises without closing when the backend cannot open a session", %{tmp_dir: tmp_dir} do
      assert_raise Execution.Error, ~r/could not open an execution session/, fn ->
        Execution.with_session(spec(tmp_dir), fn _session -> :never end,
          backend: UnopenableBackend
        )
      end

      refute File.exists?(Path.join(tmp_dir, "execution.log"))
    end

    test "dispatches exec/3 to the session's backend", %{tmp_dir: tmp_dir} do
      command = %Command{run: {:shell, "true"}}

      assert {:passed, "recorded\n"} =
               Execution.with_session(
                 spec(tmp_dir),
                 fn session ->
                   Execution.exec(session, command, fn _line -> :ok end)
                 end,
                 backend: RecordingBackend
               )

      assert log(tmp_dir) == [
               "open #{tmp_dir} run_test",
               "exec {:shell, \"true\"}",
               "close"
             ]
    end
  end

  describe "trust and backend selection" do
    test "trust_for_mode/1 maps local to trusted and server to untrusted" do
      assert Execution.trust_for_mode(:local) == :trusted
      assert Execution.trust_for_mode(:server) == :untrusted
    end

    test "put_default_trust/1 keeps an explicit trust" do
      assert Execution.put_default_trust(%{trust: :untrusted}).trust == :untrusted
    end

    test "resolve_backend/2 selects Local for a trusted run" do
      assert {:ok, TinyCI.Execution.Backend.Local} =
               Execution.resolve_backend(%{trust: :trusted})
    end

    test "resolve_backend/2 refuses an untrusted run with no backend" do
      assert {:error, {:isolation_unavailable, :untrusted}} =
               Execution.resolve_backend(%{trust: :untrusted})
    end

    test "resolve_backend/2 honours an explicit backend" do
      assert {:ok, RecordingBackend} =
               Execution.resolve_backend(%{trust: :untrusted}, backend: RecordingBackend)
    end

    test "resolve_backend/2 refuses Local for an untrusted run even when named" do
      assert {:error, {:isolation_unavailable, :untrusted}} =
               Execution.resolve_backend(%{trust: :untrusted},
                 backend: TinyCI.Execution.Backend.Local
               )
    end

    test "ensure_backend!/2 stores the selected backend on the context" do
      ctx = Execution.ensure_backend!(%{trust: :trusted})
      assert ctx.execution_backend == TinyCI.Execution.Backend.Local
      assert Execution.backend(ctx) == TinyCI.Execution.Backend.Local
    end

    test "ensure_backend!/2 raises for an untrusted context with no backend" do
      assert_raise Execution.Error, ~r/refusing to run an untrusted pipeline/, fn ->
        Execution.ensure_backend!(%{trust: :untrusted})
      end
    end

    test "ensure_backend!/2 prefers an explicit backend over a stored one" do
      ctx =
        Execution.ensure_backend!(%{trust: :trusted, execution_backend: Local},
          backend: RecordingBackend
        )

      assert ctx.execution_backend == RecordingBackend
    end

    test "backend/2 resolves when no backend is stored" do
      assert Execution.backend(%{trust: :trusted}) == Local
    end

    test "backend/2 raises for an untrusted context with no backend" do
      assert_raise Execution.Error, fn -> Execution.backend(%{trust: :untrusted}) end
    end

    test "backend/2 re-validates a stored Local backend for an untrusted context" do
      assert_raise Execution.Error, fn ->
        Execution.backend(%{trust: :untrusted, execution_backend: Local})
      end
    end

    test "backend/2 accepts a non-Local stored backend for an untrusted context" do
      assert Execution.backend(%{trust: :untrusted, execution_backend: RecordingBackend}) ==
               RecordingBackend
    end

    test "trust_for_mode/1 rejects an unknown mode instead of failing open" do
      assert_raise ArgumentError, ~r/unknown tiny_ci mode/, fn ->
        Execution.trust_for_mode(:production)
      end
    end

    test "trust/1 rejects an invalid trust value" do
      assert_raise Execution.Error, ~r/invalid trust level/, fn ->
        Execution.trust(%{trust: "untrusted"})
      end
    end

    test "session_spec/1 uses the project root and the run id" do
      assert %SessionSpec{workspace: "/tmp/project", run_id: "run_1"} =
               Execution.session_spec(%{root: "/tmp/project", run_id: "run_1"})
    end
  end

  describe "the execution boundary" do
    test "only the Local backend calls Output for process execution" do
      callers =
        "lib/tiny_ci/**/*.ex"
        |> Path.wildcard()
        |> Enum.filter(fn path ->
          path |> File.read!() |> String.match?(~r/\bOutput\.run_(cmd|executable)\b/)
        end)
        |> Enum.map(&Path.relative_to_cwd/1)

      assert callers == ["lib/tiny_ci/execution/backend/local.ex"]
    end

    test "the executor never reads the runner mode" do
      source = File.read!("lib/tiny_ci/executor.ex")

      refute source =~ "Application.get_env(:tiny_ci, :mode"
      refute source =~ "server?"
    end
  end
end
