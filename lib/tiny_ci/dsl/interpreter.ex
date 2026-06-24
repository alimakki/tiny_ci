defmodule TinyCI.DSL.Interpreter do
  @moduledoc """
  Parses and interprets a TinyCI pipeline file into a `%TinyCI.PipelineSpec{}`.

  This is the entry point for the new flat DSL format. It replaces
  `Code.compile_file/1` entirely: no Elixir module is compiled, no bytecode
  is produced, and no code runs during loading — only the restricted AST
  grammar permitted by `TinyCI.DSL.Validator` is interpreted.

  ## Pipeline file format

      # optional — defaults to filename stem
      name :my_pipeline

      stage :test, mode: :parallel do
        step :unit, cmd: "mix test"
        step :lint, cmd: "mix credo"
      end

      stage :deploy, when: branch() == "main" do
        step :release, cmd: "make release"
      end

      on_failure :alert, cmd: "curl -X POST $SLACK_WEBHOOK"

  ## Errors

  Returns `{:error, reason}` for:

    * `:file_not_found` — file does not exist
    * `{:parse_error, message}` — file has invalid Elixir syntax
    * `{:validation_error, [String.t()]}` — AST contains disallowed constructs
  """

  alias TinyCI.{DSL.Diagnostic, DSL.FlowAnalysis, DSL.Validator, Hook, PipelineSpec, Stage, Step}

  @doc """
  Reads, validates, and interprets a pipeline file.

  ## Parameters

    * `path` — absolute or relative path to a `.exs` pipeline file

  ## Returns

    * `{:ok, %TinyCI.PipelineSpec{}}` on success
    * `{:error, reason}` on failure
  """
  @spec interpret_file(String.t()) :: {:ok, PipelineSpec.t()} | {:error, term()}
  def interpret_file(path) do
    case File.read(path) do
      {:ok, content} -> interpret_string(content, path)
      {:error, :enoent} -> {:error, :file_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Validates and interprets pipeline source already held in memory.

  Identical to `interpret_file/1` but operates on a string buffer, never
  touching the filesystem to read the source. `path` is used only for naming and
  diagnostics; it does not need to exist.

  ## Returns

    * `{:ok, %TinyCI.PipelineSpec{}}` on success
    * `{:error, reason}` on failure
  """
  @spec interpret_string(String.t(), String.t()) :: {:ok, PipelineSpec.t()} | {:error, term()}
  def interpret_string(content, path) do
    with {:ok, ast} <- parse(content, path),
         :ok <- Validator.validate(ast),
         spec = build_spec(ast, path),
         :ok <- TinyCI.DAG.validate(spec.stages),
         :ok <- TinyCI.Action.validate_spec(spec) do
      {:ok, spec}
    else
      {:error, {:parse_error, _} = e} -> {:error, e}
      {:error, {:validation_error, _} = e} -> {:error, e}
      {:error, {:circular_dependency, _} = e} -> {:error, e}
      {:error, {:unknown_stages, _} = e} -> {:error, e}
      {:error, {:invalid_action, _} = e} -> {:error, e}
      {:error, violations} when is_list(violations) -> {:error, {:validation_error, violations}}
    end
  end

  @doc """
  Analyzes pipeline source and returns a list of diagnostics with source spans.

  Shares the parse + validate + graph-check code path with `interpret_string/2`,
  so messages shown in an editor match what the runner prints at load time. The
  buffer is **never executed** — only the restricted AST grammar is inspected.

  Reports, in order:

    1. a syntax error (parse failure), if any; or
    2. allowlist violations from `TinyCI.DSL.Validator`; or
    3. dependency-graph problems (unknown stage references, cycles) when the
       grammar is otherwise valid.

  An empty list means the buffer is a valid pipeline.

  ## Parameters

    * `content` — the buffer text
    * `path` — used for naming/diagnostics only (defaults to `"nofile"`)

  ## Returns

    * `[%TinyCI.DSL.Diagnostic{}]`
  """
  @spec diagnose_string(String.t(), String.t()) :: [Diagnostic.t()]
  def diagnose_string(content, path \\ "nofile") do
    case Code.string_to_quoted(content, columns: true, file: path) do
      {:ok, ast} -> analyze_ast(ast, path)
      {:error, {location, message, token}} -> [parse_diagnostic(location, message, token)]
    end
  end

  defp analyze_ast(ast, path) do
    case Validator.diagnostics(ast) do
      [] -> graph_diagnostics(ast, path)
      diagnostics -> diagnostics
    end
  end

  # Flow-level checks run only when the grammar is valid. Wrapped defensively:
  # building a spec from a grammatically-valid-but-degenerate buffer should never
  # crash the language server. Module-existence (action) checks are intentionally
  # skipped here — a step's module is often not compiled while editing.
  defp graph_diagnostics(ast, path) do
    FlowAnalysis.diagnostics(ast, build_spec(ast, path))
  rescue
    e -> [Diagnostic.new(Exception.message(e))]
  end

  defp parse_diagnostic(location, message, token) do
    Diagnostic.new(parse_error_message(message, token), normalize_location(location))
  end

  defp parse_error_message(message, token) when is_binary(message), do: "#{message}#{token}"
  defp parse_error_message({pre, post}, token), do: "#{pre}#{token}#{post}"

  defp normalize_location(location) when is_list(location), do: location
  defp normalize_location(line) when is_integer(line), do: [line: line]
  defp normalize_location(_), do: []

  # ---------------------------------------------------------------------------
  # Parse
  # ---------------------------------------------------------------------------

  defp parse(content, path) do
    case Code.string_to_quoted(content, file: path) do
      {:ok, ast} ->
        {:ok, ast}

      {:error, {_meta, message, token}} when is_binary(message) ->
        {:error, {:parse_error, "#{message}#{token}"}}

      {:error, {_meta, {pre, post}, token}} ->
        {:error, {:parse_error, "#{pre}#{token}#{post}"}}
    end
  end

  # ---------------------------------------------------------------------------
  # Build spec from AST
  # ---------------------------------------------------------------------------

  defp build_spec(ast, path) do
    exprs = unwrap_block(ast)
    root = path |> Path.dirname() |> Path.expand()

    {name_exprs, rest} = Enum.split_with(exprs, &match?({:name, _, _}, &1))

    name =
      case name_exprs do
        [{:name, _, [n]}] -> n
        _ -> path |> Path.basename(".exs") |> String.to_atom()
      end

    {stages, pipeline_env, hooks} =
      Enum.reduce(rest, {[], %{}, %{on_success: [], on_failure: []}}, fn expr,
                                                                         {stages, env_acc, hooks} ->
        case expr do
          {:stage, _, [stage_name | rest_args]} ->
            {stages ++ [build_stage(stage_name, rest_args)], env_acc, hooks}

          {:env, _, [kwlist]} when is_list(kwlist) ->
            {stages, Map.merge(env_acc, kwlist_to_env(kwlist)), hooks}

          {:on_success, _, [hook_name | rest_args]} ->
            hook = build_hook(hook_name, rest_args)
            {stages, env_acc, Map.update!(hooks, :on_success, &(&1 ++ [hook]))}

          {:on_failure, _, [hook_name | rest_args]} ->
            hook = build_hook(hook_name, rest_args)
            {stages, env_acc, Map.update!(hooks, :on_failure, &(&1 ++ [hook]))}
        end
      end)

    %PipelineSpec{name: name, stages: stages, hooks: hooks, root: root, env: pipeline_env}
  end

  # ---------------------------------------------------------------------------
  # Stage
  # ---------------------------------------------------------------------------

  defp build_stage(name, [opts]) when is_list(opts) do
    {block, rest_opts} = Keyword.pop(opts, :do)
    build_stage_from_opts(name, rest_opts, block)
  end

  defp build_stage(name, [opts, [do: block]]) when is_list(opts) do
    build_stage_from_opts(name, opts, block)
  end

  defp build_stage_from_opts(name, opts, block) do
    {steps, stage_env} = build_stage_body(block)

    %Stage{
      name: name,
      mode: Keyword.get(opts, :mode, :parallel),
      needs: Keyword.get(opts, :needs, []),
      matrix: Keyword.get(opts, :matrix, []),
      max_parallel: Keyword.get(opts, :max_parallel),
      allow_failure: Keyword.get(opts, :allow_failure, false),
      when_condition: Keyword.get(opts, :when),
      working_dir: Keyword.get(opts, :working_dir),
      env: stage_env,
      steps: steps
    }
  end

  defp build_stage_body(nil), do: {[], %{}}

  defp build_stage_body(block) do
    block
    |> unwrap_block()
    |> Enum.reduce({[], %{}}, fn
      {:step, _, _} = expr, {steps, env_acc} ->
        {steps ++ [build_step(expr)], env_acc}

      {:env, _, [kwlist]}, {steps, env_acc} when is_list(kwlist) ->
        {steps, Map.merge(env_acc, kwlist_to_env(kwlist))}
    end)
  end

  # ---------------------------------------------------------------------------
  # Step
  # ---------------------------------------------------------------------------

  defp build_step({:step, _, [name | rest_args]}) when is_list(rest_args) do
    {opts, block} = extract_opts_and_block(rest_args)

    %Step{
      name: name,
      cmd: Keyword.get(opts, :cmd),
      module: resolve_module(Keyword.get(opts, :module)),
      env: resolve_map(Keyword.get(opts, :env, {:%{}, [], []})),
      timeout: Keyword.get(opts, :timeout),
      allow_failure: Keyword.get(opts, :allow_failure, false),
      when_condition: Keyword.get(opts, :when),
      working_dir: Keyword.get(opts, :working_dir),
      retry: Keyword.get(opts, :retry),
      retry_delay: Keyword.get(opts, :retry_delay),
      cache: resolve_cache(Keyword.get(opts, :cache)),
      artifact: resolve_artifact(Keyword.get(opts, :artifact)),
      config_block: build_config_block(block)
    }
  end

  # ---------------------------------------------------------------------------
  # Hook
  # ---------------------------------------------------------------------------

  defp build_hook(name, rest_args) do
    {opts, block} = extract_opts_and_block(rest_args)

    %Hook{
      name: name,
      cmd: Keyword.get(opts, :cmd),
      module: resolve_module(Keyword.get(opts, :module)),
      env: resolve_map(Keyword.get(opts, :env, {:%{}, [], []})),
      timeout: Keyword.get(opts, :timeout),
      config_block: build_config_block(block)
    }
  end

  # ---------------------------------------------------------------------------
  # config_block (set/2 accumulation)
  # ---------------------------------------------------------------------------

  defp build_config_block(nil), do: nil

  defp build_config_block(block) do
    pairs =
      block
      |> unwrap_block()
      |> Enum.map(fn {:set, _, [k, v]} -> {k, v} end)

    fn -> pairs end
  end

  # ---------------------------------------------------------------------------
  # Literal resolvers
  # ---------------------------------------------------------------------------

  defp kwlist_to_env(kwlist) do
    Map.new(kwlist, fn {k, v} -> {Atom.to_string(k), v} end)
  end

  defp resolve_cache(nil), do: nil

  defp resolve_cache(spec) when is_list(spec) do
    %{paths: Keyword.get(spec, :paths, []), key: Keyword.get(spec, :key)}
  end

  defp resolve_artifact(nil), do: nil

  defp resolve_artifact(spec) when is_list(spec) do
    %{
      name: Keyword.fetch!(spec, :name),
      paths: Keyword.get(spec, :paths, []),
      required: Keyword.get(spec, :required, false)
    }
  end

  defp resolve_module(nil), do: nil
  defp resolve_module({:__aliases__, _, parts}), do: Module.concat(parts)
  defp resolve_module(atom) when is_atom(atom), do: atom

  defp resolve_map({:%{}, _, pairs}) do
    Map.new(pairs, fn
      {k, {:store, _, [key]}} when is_atom(key) -> {k, {:store, key}}
      {k, v} -> {k, v}
    end)
  end

  defp resolve_map(%{} = m), do: m

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Normalizes the trailing args of a stage/step/hook call into {opts, block}.
  # Elixir produces two separate keyword lists when inline opts AND a do block
  # are both present: [opts_list, [do: body]].
  # When only a do block is present it is merged into a single list: [[do: body]].
  defp extract_opts_and_block([opts, [do: block]]) when is_list(opts), do: {opts, block}

  defp extract_opts_and_block([opts]) when is_list(opts) do
    {block, rest_opts} = Keyword.pop(opts, :do)
    {rest_opts, block}
  end

  defp extract_opts_and_block([]), do: {[], nil}

  defp unwrap_block({:__block__, _, exprs}), do: exprs
  defp unwrap_block(single), do: [single]
end
