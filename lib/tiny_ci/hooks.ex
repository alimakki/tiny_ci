defmodule TinyCI.Hooks do
  @moduledoc """
  Executes pipeline-level notification hooks after a pipeline completes.

  Hooks are run sequentially after `Executor.run_pipeline/3` returns.
  Shell command hooks (`:cmd`) are executed via the system shell with
  automatically injected environment variables. Module hooks (`:module`)
  call `module.run/2` with the hook config and an enriched context.

  Hook failures — including a module hook that raises, exits, or throws —
  are logged to stderr but do not raise an exception, do not stop the
  remaining hooks, and do not change the pipeline exit code.

  ## Environment variables for shell command hooks

    * `TINY_CI_RESULT`  — atom name of the event (e.g., `"on_success"`)
    * `TINY_CI_BRANCH`  — current git branch from the pipeline context
    * `TINY_CI_COMMIT`  — current git commit SHA from the pipeline context
  ## Module hook contract

  A module hook must export:

      @spec run(keyword(), map()) :: :ok | {:error, reason :: term()}
  """

  alias TinyCI.Executor.Crash
  alias TinyCI.Hook
  alias TinyCI.Output

  @default_timeout 30_000

  @doc """
  Runs the list of hooks registered for the given `event` from a hooks map.

  The `event` atom (e.g., `:on_success` or `:on_failure`) is used to look up
  the relevant hooks in the map and is also set as `context.pipeline_result`
  so hooks can inspect the overall pipeline outcome.

  Hook failures are caught and logged; they do not interrupt subsequent hooks
  or affect the return value.

  ## Parameters

    * `hooks`   — a map with `:on_success` and `:on_failure` keys, each
      containing a list of `%TinyCI.Hook{}` structs (the `:hooks` field of a
      `%TinyCI.PipelineSpec{}`)
    * `event`   — `:on_success` or `:on_failure`
    * `context` — the pipeline context map (branch, commit, store, etc.)

  ## Returns

  Always returns `:ok`.
  """
  @spec run_hooks(map(), :on_success | :on_failure, map()) :: :ok
  def run_hooks(hooks, event, context) when is_map(hooks) do
    hooks_list = Map.get(hooks, event, [])
    ctx = Map.put(context, :pipeline_result, event)
    Enum.each(hooks_list, &run_hook(&1, ctx))
  end

  defp run_hook(%Hook{name: name, cmd: cmd, env: env, timeout: timeout}, context)
       when not is_nil(cmd) do
    IO.puts("Hook: #{name}")
    store = Map.get(context, :store, %{})
    pipeline_env = Map.get(context, :pipeline_env, %{})
    hook_env = build_hook_env(context)
    resolved_env = resolve_env(env, store)
    merged_env = pipeline_env |> Map.merge(hook_env) |> Map.merge(resolved_env)
    actual_timeout = timeout || @default_timeout

    # Buffered so hook output does not interleave with pipeline output, and with a
    # timeout that kills the hook's process subtree rather than orphaning it.
    case Output.run_cmd(cmd, mode: :buffered, env: merged_env, timeout: actual_timeout) do
      {:passed, _output} ->
        :ok

      {:failed, output} ->
        IO.puts(:stderr, "Hook #{name} failed: #{String.trim(output)}")
        :ok

      {:timeout, _output} ->
        IO.puts(:stderr, "Hook #{name} timed out after #{actual_timeout}ms")
        :ok
    end
  end

  defp run_hook(%Hook{name: name, module: module, config_block: block}, context)
       when not is_nil(module) do
    IO.puts("Hook: #{name}")
    config = if block, do: block.(), else: []

    case invoke_module_hook(module, config, context) do
      :ok ->
        :ok

      {:error, {:crashed, text}} ->
        IO.puts(:stderr, "Hook #{name} failed: #{text}")
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "Hook #{name} failed: #{inspect(reason)}")
        :ok
    end
  end

  # A raising hook is reported like a hook that returned `{:error, _}`: it must
  # not abort the remaining hooks, and hooks never affect the exit code.
  defp invoke_module_hook(module, config, context) do
    apply(module, :run, [config, context])
  rescue
    e -> {:error, {:crashed, Crash.format(:error, e, __STACKTRACE__)}}
  catch
    kind, reason -> {:error, {:crashed, Crash.format(kind, reason, __STACKTRACE__)}}
  end

  defp build_hook_env(context) do
    result_str = context |> Map.get(:pipeline_result, :unknown) |> to_string()

    %{
      "TINY_CI_RESULT" => result_str,
      "TINY_CI_BRANCH" => to_string(Map.get(context, :branch, "")),
      "TINY_CI_COMMIT" => to_string(Map.get(context, :commit, ""))
    }
  end

  defp resolve_env(env, store) do
    Map.new(env, fn
      {k, {:store, key}} -> {k, to_string(Map.get(store, key, ""))}
      {k, v} -> {k, v}
    end)
  end
end
