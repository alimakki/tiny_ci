defmodule TinyCI.Environment.MiseTest do
  @moduledoc """
  Host toolchain resolution through `mise`: which config is required, the argv
  and environment mise receives, missing tools, and the cache fingerprint.

  A fake runner covers every behaviour; one `:mise` integration test uses this
  repository's own `.mise.toml` in a temp project.
  """

  use ExUnit.Case, async: true

  alias TinyCI.Environment.Mise
  alias TinyCI.Execution.Command

  defp write(root, name, contents \\ "[tools]\n") do
    path = Path.join(root, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  defp tools_json(root, tools) do
    map =
      Map.new(tools, fn {name, opts} ->
        installed = Keyword.get(opts, :installed, true)
        version = Keyword.get(opts, :version, "1.0.0")
        source = Keyword.get(opts, :source, Path.join(root, "mise.toml"))

        {name,
         [
           %{
             "version" => version,
             "requested_version" => Keyword.get(opts, :requested, version),
             "installed" => installed,
             "source" => %{"type" => "mise.toml", "path" => source}
           }
         ]}
      end)

    Jason.encode!(map)
  end

  defp env_json(map \\ %{"PATH" => "/tools/bin"}), do: Jason.encode!(map)

  # A runner that answers `env` and `ls` from a map and records every command.
  defp runner(responses) do
    parent = self()

    fn %Command{run: {:argv, _mise, args}} = command ->
      send(parent, {:command, command})
      respond(args, responses)
    end
  end

  defp respond(args, responses) do
    cond do
      "env" in args -> responses[:env] || {:passed, env_json()}
      "ls" in args -> responses[:ls] || {:passed, tools_json(File.cwd!(), [])}
      true -> flunk("unexpected mise arguments: #{inspect(args)}")
    end
  end

  describe "config selection" do
    @tag :tmp_dir
    test "default needs a config file", %{tmp_dir: tmp} do
      assert {:error, :no_toolchain_config} =
               Mise.resolve("default", root: tmp, runner: runner(%{}), mise: "mise")
    end

    @tag :tmp_dir
    test "default accepts .mise.toml, mise.toml, or .tool-versions", %{tmp_dir: tmp} do
      for name <- [".mise.toml", "mise.toml", ".tool-versions"] do
        root = Path.join(tmp, String.trim_leading(name, "."))
        File.mkdir_p!(root)
        write(root, name)

        assert {:ok, %{tools: []}} =
                 Mise.resolve("default", root: root, runner: runner(%{}), mise: "mise")
      end
    end

    @tag :tmp_dir
    test "a named environment requires its own config file", %{tmp_dir: tmp} do
      write(tmp, ".mise.toml")

      assert {:error, {:unknown_environment, "ci", ["mise.ci.toml", ".mise.ci.toml"]}} =
               Mise.resolve("ci", root: tmp, runner: runner(%{}), mise: "mise")
    end

    @tag :tmp_dir
    test "a named environment accepts mise.ci.toml", %{tmp_dir: tmp} do
      write(tmp, "mise.ci.toml")

      assert {:ok, _} = Mise.resolve("ci", root: tmp, runner: runner(%{}), mise: "mise")
    end

    @tag :tmp_dir
    test "an invalid name is rejected before any file is read", %{tmp_dir: tmp} do
      assert {:error, {:invalid_environment, "CI"}} =
               Mise.resolve("CI", root: tmp, runner: runner(%{}), mise: "mise")
    end

    @tag :tmp_dir
    test "mise absent is an explicit error", %{tmp_dir: tmp} do
      write(tmp, ".mise.toml")

      assert {:error, :mise_unavailable} =
               Mise.resolve("default", root: tmp, runner: runner(%{}), mise: nil)
    end
  end

  describe "the mise invocation" do
    @tag :tmp_dir
    test "default clears MISE_ENV and omits --env", %{tmp_dir: tmp} do
      write(tmp, ".mise.toml")

      assert {:ok, %{env: env}} =
               Mise.resolve("default", root: tmp, runner: runner(%{}), mise: "mise")

      assert_received {:command, %Command{run: {:argv, "mise", args}, env: command_env} = command}
      assert args == ["--silent", "--cd", tmp, "env", "--json"]
      assert command_env == %{"MISE_ENV" => ""}
      assert command.working_dir == tmp
      assert command.timeout == 30_000
      assert env["MISE_ENV"] == ""
    end

    @tag :tmp_dir
    test "a named environment passes --env and sets MISE_ENV", %{tmp_dir: tmp} do
      write(tmp, "mise.ci.toml")

      assert {:ok, %{env: env}} = Mise.resolve("ci", root: tmp, runner: runner(%{}), mise: "mise")

      assert_received {:command, %Command{run: {:argv, "mise", args}, env: command_env}}
      assert args == ["--silent", "--cd", tmp, "--env", "ci", "env", "--json"]
      assert command_env == %{"MISE_ENV" => "ci"}
      assert env["MISE_ENV"] == "ci"
    end

    @tag :tmp_dir
    test "uses ls --json --current for the tool list", %{tmp_dir: tmp} do
      write(tmp, ".mise.toml")

      Mise.resolve("default", root: tmp, runner: runner(%{}), mise: "mise")

      assert_received {:command, %Command{run: {:argv, "mise", _args}}}
      assert_received {:command, %Command{run: {:argv, "mise", args}}}
      assert args == ["--silent", "--cd", tmp, "ls", "--json", "--current"]
    end
  end

  describe "tool list and fingerprint" do
    @tag :tmp_dir
    test "returns resolved versions and a stable fingerprint", %{tmp_dir: tmp} do
      write(tmp, ".mise.toml")

      ls =
        tools_json(tmp, [
          {"elixir", version: "1.20.3", requested: "1.20"},
          {"erlang", version: "29.0.5"}
        ])

      assert {:ok, %{tools: tools, fingerprint: fingerprint}} =
               Mise.resolve("default",
                 root: tmp,
                 runner: runner(%{ls: {:passed, ls}}),
                 mise: "mise"
               )

      assert {:ok, %{fingerprint: again}} =
               Mise.resolve("default",
                 root: tmp,
                 runner: runner(%{ls: {:passed, ls}}),
                 mise: "mise"
               )

      assert Enum.sort(tools) == [{"elixir", "1.20.3"}, {"erlang", "29.0.5"}]
      assert fingerprint == again
      assert fingerprint =~ ~r/^[0-9a-f]{64}$/
    end

    @tag :tmp_dir
    test "a prefix pin resolving to a different version changes the fingerprint", %{
      tmp_dir: tmp
    } do
      write(tmp, ".mise.toml")
      before = tools_json(tmp, [{"elixir", version: "1.18.3", requested: "1.18"}])
      after_install = tools_json(tmp, [{"elixir", version: "1.18.4", requested: "1.18"}])

      assert {:ok, %{tools: [{"elixir", "1.18.3"}], fingerprint: a}} =
               Mise.resolve("default",
                 root: tmp,
                 runner: runner(%{ls: {:passed, before}}),
                 mise: "mise"
               )

      assert {:ok, %{tools: [{"elixir", "1.18.4"}], fingerprint: b}} =
               Mise.resolve("default",
                 root: tmp,
                 runner: runner(%{ls: {:passed, after_install}}),
                 mise: "mise"
               )

      refute a == b
    end

    @tag :tmp_dir
    test "the fingerprint changes when a tool version changes", %{tmp_dir: tmp} do
      write(tmp, ".mise.toml")
      first = tools_json(tmp, [{"elixir", version: "1.19.0"}])
      second = tools_json(tmp, [{"elixir", version: "1.20.0"}])

      assert {:ok, %{fingerprint: a}} =
               Mise.resolve("default",
                 root: tmp,
                 runner: runner(%{ls: {:passed, first}}),
                 mise: "mise"
               )

      assert {:ok, %{fingerprint: b}} =
               Mise.resolve("default",
                 root: tmp,
                 runner: runner(%{ls: {:passed, second}}),
                 mise: "mise"
               )

      refute a == b
    end

    @tag :tmp_dir
    test "falls back to hashing the raw ls output when it does not parse", %{tmp_dir: tmp} do
      write(tmp, ".mise.toml")

      assert {:ok, %{tools: [], fingerprint: fingerprint}} =
               Mise.resolve("default",
                 root: tmp,
                 runner: runner(%{ls: {:passed, "not json"}}),
                 mise: "mise"
               )

      assert fingerprint == :crypto.hash(:sha256, "not json") |> Base.encode16(case: :lower)
    end
  end

  describe "missing tools" do
    @tag :tmp_dir
    test "a tool requested by the project but not installed is an error", %{tmp_dir: tmp} do
      write(tmp, ".mise.toml")

      ls =
        tools_json(tmp, [
          {"elixir", version: "1.20.3", installed: false},
          {"erlang", version: "29.0.5"}
        ])

      assert {:error, {:missing_tools, "default", [{"elixir", "1.20.3"}]}} =
               Mise.resolve("default",
                 root: tmp,
                 runner: runner(%{ls: {:passed, ls}}),
                 mise: "mise"
               )
    end

    @tag :tmp_dir
    test "an uninstalled tool from outside the project is not this project's request", %{
      tmp_dir: tmp
    } do
      write(tmp, ".mise.toml")

      ls =
        tools_json(tmp, [
          {"global_tool", installed: false, source: "/opt/global/mise.toml"}
        ])

      assert {:ok, %{tools: [{"global_tool", "1.0.0"}]}} =
               Mise.resolve("default",
                 root: tmp,
                 runner: runner(%{ls: {:passed, ls}}),
                 mise: "mise"
               )
    end
  end

  describe "failures" do
    @tag :tmp_dir
    test "a failed env command hides its output", %{tmp_dir: tmp} do
      write(tmp, ".mise.toml")

      assert {:error, {:mise_failed, "default", :failed}} =
               Mise.resolve("default",
                 root: tmp,
                 runner: runner(%{env: {:failed, "SECRET=hunter2"}}),
                 mise: "mise"
               )
    end

    @tag :tmp_dir
    test "a timeout is reported", %{tmp_dir: tmp} do
      write(tmp, ".mise.toml")

      assert {:error, {:mise_failed, "default", :timeout}} =
               Mise.resolve("default",
                 root: tmp,
                 runner: runner(%{env: {:timeout, ""}}),
                 mise: "mise"
               )
    end
  end

  # One real invocation: this repository pins its own toolchain in .mise.toml,
  # so copying it into a temp project proves the argv/mise contract works
  # against the installed mise, not just the fake runner. The temp project is
  # not in mise's trust store, so the test trusts just this copied file.
  @tag :mise
  @tag :tmp_dir
  test "resolves this repository's own toolchain in a temp project", %{tmp_dir: tmp} do
    config = Path.join(tmp, ".mise.toml")
    File.cp!(Path.join(File.cwd!(), ".mise.toml"), config)

    assert {:ok, %{tools: tools, env: env, fingerprint: fingerprint}} =
             Mise.resolve("default",
               root: tmp,
               env: %{"MISE_TRUSTED_CONFIG_PATHS" => config}
             )

    names = Enum.map(tools, fn {name, _version} -> name end)
    assert "elixir" in names
    assert "erlang" in names
    assert is_binary(env["PATH"]) and env["PATH"] =~ "/bin"
    assert fingerprint =~ ~r/^[0-9a-f]{64}$/
  end
end
