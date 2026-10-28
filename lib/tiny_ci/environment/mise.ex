defmodule TinyCI.Environment.Mise do
  @moduledoc """
  Resolves an `environment "name"` declaration through the repository's `mise`
  configuration.

  An `environment:` is the non-container half of a reproducible environment: a
  named toolchain the runner honours on the host, so a laptop and a host
  without containers can use the same pinned versions. It is deliberately not a
  package manager and not an inline YAML block; it points at configuration the
  repository already has.

    * `environment "default"` reads `.mise.toml`, `mise.toml`, or
      `.tool-versions`, with `MISE_ENV` explicitly cleared so an inherited
      `MISE_ENV` cannot silently select a different file.
    * any other name (`environment "ci"`) requires `mise.<name>.toml` or
      `.mise.<name>.toml`. This check is required because `mise env -E typo`
      silently succeeds against the default config; without it a typo would run
      the wrong toolchain.

  `mise` is executed as an argv through the Local backend with a 30-second
  deadline, so a hung install or a slow filesystem cannot wedge a run, and
  `--silent` keeps stdout valid JSON.

  ## Trust

  `mise` reads and trusts repository configuration and the local `mise` install.
  A pipeline file is untrusted input, so an untrusted run never resolves an
  `environment:` through `mise`; it must map the name to an image (see
  `TinyCI.Environment`) or fail. `[env]` values in a mise config are
  configuration, not a secret store.
  """

  alias TinyCI.Execution.Backend.Local
  alias TinyCI.Execution.Command

  @default_timeout 30_000
  @default_configs [".mise.toml", "mise.toml", ".tool-versions"]

  @typedoc "A resolved host toolchain."
  @type resolved :: %{
          env: %{optional(String.t()) => String.t()},
          tools: [{String.t(), String.t()}],
          fingerprint: String.t()
        }

  @doc """
  Resolves a named environment in `root`.

  ## Options

    * `:root` — the project root to resolve against (default: cwd)
    * `:mise` — the `mise` executable (default: found on `PATH`)
    * `:runner` — a `%TinyCI.Execution.Command{} -> outcome` function used
      instead of the Local backend (tests inject this)
    * `:env` — extra environment variables for the mise invocation (for
      example `MISE_TRUSTED_CONFIG_PATHS` in a temporary project). `MISE_ENV`
      is always set by this module and cannot be overridden here.
    * `:timeout` — milliseconds before the command is killed (default 30 000)

  ## Returns

    * `{:ok, %{env: map, tools: [{name, version}], fingerprint: hex}}`
    * `{:error, :no_toolchain_config | :mise_unavailable | :mise_timeout | ...}`
  """
  @spec resolve(String.t(), keyword()) :: {:ok, resolved()} | {:error, term()}
  def resolve(name, opts \\ []) do
    root = Keyword.get(opts, :root) || File.cwd!()

    with :ok <- validate_name(name),
         {:ok, _config} <- config_file(name, root),
         {:ok, mise} <- find_mise(opts),
         {:ok, env} <- run_env(mise, name, root, opts),
         {:ok, raw} <- run_ls(mise, name, root, opts),
         {:ok, tools, fingerprint} <- inspect_tools(raw, name, root) do
      {:ok, %{env: put_mise_env(env, name), tools: tools, fingerprint: fingerprint}}
    end
  end

  defp validate_name(name) do
    if TinyCI.Environment.valid_name?(name),
      do: :ok,
      else: {:error, {:invalid_environment, name}}
  end

  defp config_file("default", root) do
    case Enum.find(@default_configs, &File.regular?(Path.join(root, &1))) do
      nil -> {:error, :no_toolchain_config}
      file -> {:ok, file}
    end
  end

  defp config_file(name, root) do
    candidates = ["mise.#{name}.toml", ".mise.#{name}.toml"]

    case Enum.find(candidates, &File.regular?(Path.join(root, &1))) do
      nil -> {:error, {:unknown_environment, name, candidates}}
      file -> {:ok, file}
    end
  end

  defp find_mise(opts) do
    case Keyword.fetch(opts, :mise) do
      {:ok, nil} ->
        {:error, :mise_unavailable}

      {:ok, path} ->
        {:ok, path}

      :error ->
        case System.find_executable("mise") do
          nil -> {:error, :mise_unavailable}
          path -> {:ok, path}
        end
    end
  end

  defp run_env(mise, name, root, opts) do
    case run(mise, name, root, ["env", "--json"], opts) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, %{} = env} -> {:ok, Map.new(env, fn {k, v} -> {to_string(k), to_string(v)} end)}
          _ -> {:error, {:mise_failed, name, :env_not_json}}
        end

      {:error, _} = error ->
        error
    end
  end

  defp run_ls(mise, name, root, opts) do
    run(mise, name, root, ["ls", "--json", "--current"], opts)
  end

  defp run(mise, name, root, args, opts) do
    command = %Command{
      run: {:argv, mise, global_args(name, root) ++ args},
      env: Map.merge(Keyword.get(opts, :env, %{}), mise_env(name)),
      working_dir: root,
      timeout: Keyword.get(opts, :timeout, @default_timeout)
    }

    case runner(opts).(command) do
      {:passed, output} ->
        {:ok, output}

      {:failed, _output} ->
        # The output of `mise env` can contain configuration values; never echo
        # it in an error message.
        {:error, {:mise_failed, name, :failed}}

      {:timeout, _output} ->
        {:error, {:mise_failed, name, :timeout}}
    end
  end

  defp runner(opts) do
    Keyword.get(opts, :runner, fn command -> Local.exec(%{}, command, fn _line -> :ok end) end)
  end

  defp global_args("default", root), do: ["--silent", "--cd", root]
  defp global_args(name, root), do: ["--silent", "--cd", root, "--env", name]

  defp mise_env("default"), do: %{"MISE_ENV" => ""}
  defp mise_env(name), do: %{"MISE_ENV" => name}

  defp put_mise_env(env, name), do: Map.put(env, "MISE_ENV", mise_env(name)["MISE_ENV"])

  # `ls --json --current` is a map of tool name to a list of selected versions.
  # A tool the repository asked for but mise has not installed is a hard error:
  # running with a silently missing toolchain is the drift this directive exists
  # to prevent. Tools from elsewhere on the machine (a global config) are not
  # this pipeline's request and are left alone.
  defp inspect_tools(raw, name, root) do
    case Jason.decode(raw) do
      {:ok, %{} = map} when is_map(map) ->
        entries =
          for {tool, versions} <- map,
              is_list(versions),
              entry <- versions,
              do: {to_string(tool), version(entry), missing?(entry, root)}

        missing = for {tool, version, true} <- entries, do: {tool, version}
        tools = for {tool, version, _} <- entries, do: {tool, version}

        if missing == [] do
          {:ok, tools, fingerprint(tools)}
        else
          {:error, {:missing_tools, name, missing}}
        end

      _ ->
        # The raw output is still a stable identity for the toolchain, even when
        # this mise version speaks a shape we do not parse.
        {:ok, [], hash(raw)}
    end
  end

  defp version(entry) when is_map(entry),
    do: to_string(entry["version"] || entry["requested_version"] || "unknown")

  defp version(_entry), do: "unknown"

  defp missing?(entry, root) when is_map(entry) do
    entry["installed"] == false and source_under_root?(entry["source"], root)
  end

  defp missing?(_entry, _root), do: false

  defp source_under_root?(%{"path" => path}, root) when is_binary(path) do
    expanded = Path.expand(path)
    root = Path.expand(root)
    expanded == root or String.starts_with?(expanded, root <> "/")
  end

  defp source_under_root?(_source, _root), do: false

  defp fingerprint(tools) do
    tools
    |> Enum.map(fn {tool, version} -> {to_string(tool), to_string(version)} end)
    |> Enum.sort()
    |> :erlang.term_to_binary([:deterministic])
    |> hash()
  end

  defp hash(term) do
    :crypto.hash(:sha256, term) |> Base.encode16(case: :lower)
  end
end
