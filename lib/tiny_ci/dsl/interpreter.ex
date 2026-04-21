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

  alias TinyCI.{DSL.Validator, Hook, PipelineSpec, Stage, Step}

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
    with {:ok, content} <- File.read(path),
         {:ok, ast} <- parse(content, path),
         :ok <- Validator.validate(ast) do
      {:ok, build_spec(ast, path)}
    else
      {:error, :enoent} -> {:error, :file_not_found}
      {:error, {:parse_error, _} = e} -> {:error, e}
      {:error, {:validation_error, _} = e} -> {:error, e}
      {:error, violations} when is_list(violations) -> {:error, {:validation_error, violations}}
    end
  end

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
