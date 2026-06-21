defmodule TinyCI.DSL.Validator do
  @moduledoc """
  Validates a quoted pipeline AST against the TinyCI DSL allowlist.

  Called by `TinyCI.DSL.Interpreter` before any interpretation occurs. Every
  node in the AST must match a permitted construct; anything outside the
  allowlist produces a descriptive diagnostic.

  Two entry points share the same traversal:

    * `diagnostics/1` — returns a list of `%TinyCI.DSL.Diagnostic{}` with source
      spans (used by the language server and the runner; an empty list means the
      file is valid).
    * `validate/1` — the legacy `:ok | {:error, [message]}` shape, kept for the
      runner's existing call site. It is a thin wrapper over `diagnostics/1`.

  ## Allowlisted constructs

  **Top-level (file scope):**
  - `name :atom`
  - `stage :name, opts do ... end`
  - `on_success :name, opts` / `on_success :name, opts do ... end`
  - `on_failure :name, opts` / `on_failure :name, opts do ... end`

  **Inside a stage block:** `step :name, opts` / `step :name, opts do ... end`

  **Inside a step block:** `set :key, value`

  **Condition expression (`:when` option value):**
  `branch()`, `env/1`, `file_changed?/1`, `==`, `!=`, `and`, `or`, `not`,
  `if/else`, and literal values.

  **Explicitly rejected:** `defmodule`, `use`, `import`, `require`, `alias`,
  `def`, `defp`, `System`, `File`, `Node`, `Code`, `:os`, and anything else
  not in the allowlist.
  """

  alias TinyCI.DSL.Diagnostic

  @doc """
  Validates a quoted AST and returns `:ok` or `{:error, messages}`.

  A thin compatibility wrapper over `diagnostics/1` for the runner's existing
  call site.

  ## Parameters

    * `ast` — the result of `Code.string_to_quoted/2`

  ## Returns

    * `:ok` — all constructs are within the allowlist
    * `{:error, [String.t()]}` — list of human-readable violation messages
  """
  @spec validate(term()) :: :ok | {:error, [String.t()]}
  def validate(ast) do
    case diagnostics(ast) do
      [] -> :ok
      diags -> {:error, Enum.map(diags, & &1.message)}
    end
  end

  @doc """
  Validates a quoted AST and returns a list of diagnostics with source spans.

  An empty list means the file is valid. Spans are most precise when the AST was
  parsed with `columns: true`; otherwise diagnostics carry line information only.

  ## Parameters

    * `ast` — the result of `Code.string_to_quoted/2`

  ## Returns

    * `[%TinyCI.DSL.Diagnostic{}]` — one diagnostic per allowlist violation
  """
  @spec diagnostics(term()) :: [Diagnostic.t()]
  def diagnostics(ast) do
    ast |> unwrap_block() |> Enum.flat_map(&validate_top_level/1)
  end

  # ---------------------------------------------------------------------------
  # Top-level expressions
  # ---------------------------------------------------------------------------

  defp validate_top_level({:name, _, [atom]}) when is_atom(atom), do: []

  defp validate_top_level({:name, meta, _}),
    do: [diag("name/1 requires a single atom argument, e.g. `name :my_pipeline`", meta)]

  defp validate_top_level({:stage, meta, [name | rest]}) when is_atom(name),
    do: validate_stage_call(rest, meta)

  defp validate_top_level({:stage, meta, _}),
    do: [diag("stage name must be an atom, e.g. `stage :build do ... end`", meta)]

  defp validate_top_level({:on_success, meta, [name | rest]}) when is_atom(name),
    do: validate_hook_call(rest, meta)

  defp validate_top_level({:on_success, meta, _}),
    do: [diag("on_success name must be an atom", meta)]

  defp validate_top_level({:on_failure, meta, [name | rest]}) when is_atom(name),
    do: validate_hook_call(rest, meta)

  defp validate_top_level({:on_failure, meta, _}),
    do: [diag("on_failure name must be an atom", meta)]

  defp validate_top_level({:env, _, [kwlist]}) when is_list(kwlist),
    do: validate_env_keyword_list(kwlist, [])

  defp validate_top_level({:env, meta, _}),
    do: [diag("env requires a keyword list, e.g. env MIX_ENV: \"test\"", meta)]

  defp validate_top_level({:defmodule, meta, _}),
    do: [
      diag(
        "Pipeline files must not use `defmodule`. " <>
          "Remove the module wrapper and `use TinyCI.DSL` line — " <>
          "the runtime provides that context automatically.",
        meta
      )
    ]

  defp validate_top_level(node),
    do: [diag("Unexpected top-level expression: #{Macro.to_string(node)}", meta_of(node))]

  # ---------------------------------------------------------------------------
  # Stage call
  # ---------------------------------------------------------------------------

  defp validate_stage_call([opts], meta) when is_list(opts) do
    {block, rest_opts} = Keyword.pop(opts, :do)
    validate_stage_opts(rest_opts, meta) ++ validate_stage_body(block)
  end

  defp validate_stage_call([opts, [do: block]], meta) when is_list(opts) do
    validate_stage_opts(opts, meta) ++ validate_stage_body(block)
  end

  defp validate_stage_call(_, meta), do: [diag("stage requires a keyword options list", meta)]

  defp validate_stage_opts(opts, meta) do
    Enum.flat_map(opts, fn
      {:mode, mode} when mode in [:serial, :parallel] ->
        []

      {:mode, _} ->
        [diag("Stage :mode must be :serial or :parallel", meta)]

      {:when, condition} ->
        validate_condition(condition, meta)

      {:working_dir, v} when is_binary(v) ->
        []

      {:working_dir, _} ->
        [diag("Stage :working_dir must be a string literal", meta)]

      {:needs, v} when is_list(v) ->
        validate_needs_list(v, meta)

      {:needs, _} ->
        [
          diag(
            "Stage :needs must be a list of stage name atoms, e.g. needs: [:build, :test]",
            meta
          )
        ]

      {:matrix, v} when is_list(v) ->
        validate_matrix_spec(v, meta)

      {:matrix, _} ->
        [
          diag(
            "Stage :matrix must be a keyword list, e.g. matrix: [elixir: [\"1.17\", \"1.18\"]]",
            meta
          )
        ]

      {:max_parallel, v} when is_integer(v) and v > 0 ->
        []

      {:max_parallel, _} ->
        [diag("Stage :max_parallel must be a positive integer", meta)]

      {:allow_failure, v} when is_boolean(v) ->
        []

      {:allow_failure, _} ->
        [diag("Stage :allow_failure must be true or false", meta)]

      {key, _} ->
        [diag("Unknown stage option: :#{key}", meta)]
    end)
  end

  defp validate_needs_list(items, meta) do
    Enum.flat_map(items, fn
      a when is_atom(a) ->
        []

      _ ->
        [diag("Stage :needs items must be atom stage names, e.g. needs: [:build, :test]", meta)]
    end)
  end

  defp validate_matrix_spec(pairs, meta) do
    Enum.flat_map(pairs, fn
      {k, vals} when is_atom(k) and is_list(vals) ->
        validate_matrix_values(k, vals, meta)

      {k, _} when is_atom(k) ->
        [
          diag(
            "Matrix key :#{k} must have a list of string values, e.g. #{k}: [\"a\", \"b\"]",
            meta
          )
        ]

      _ ->
        [diag("Matrix entries must be keyword pairs, e.g. elixir: [\"1.17\", \"1.18\"]", meta)]
    end)
  end

  defp validate_matrix_values(key, values, meta) do
    Enum.flat_map(values, fn
      v when is_binary(v) -> []
      _ -> [diag("Matrix values for :#{key} must be string literals", meta)]
    end)
  end

  defp validate_stage_body(nil), do: []

  defp validate_stage_body(block),
    do: block |> unwrap_block() |> Enum.flat_map(&validate_stage_expr/1)

  defp validate_stage_expr({:step, meta, [name | rest]}) when is_atom(name),
    do: validate_step_call(rest, meta)

  defp validate_stage_expr({:step, meta, _}),
    do: [diag("step name must be an atom, e.g. `step :unit, cmd: \"echo hi\"`", meta)]

  defp validate_stage_expr({:env, _, [kwlist]}) when is_list(kwlist),
    do: validate_env_keyword_list(kwlist, [])

  defp validate_stage_expr({:env, meta, _}),
    do: [diag("env requires a keyword list, e.g. env MIX_ENV: \"test\"", meta)]

  defp validate_stage_expr(node),
    do: [diag("Unexpected expression in stage body: #{Macro.to_string(node)}", meta_of(node))]

  # ---------------------------------------------------------------------------
  # Step call
  # ---------------------------------------------------------------------------

  defp validate_step_call([opts], meta) when is_list(opts) do
    {block, rest_opts} = Keyword.pop(opts, :do)
    validate_step_opts(rest_opts, meta) ++ validate_step_body(block)
  end

  defp validate_step_call([opts, [do: block]], meta) when is_list(opts) do
    validate_step_opts(opts, meta) ++ validate_step_body(block)
  end

  defp validate_step_call(_, meta), do: [diag("step requires a keyword options list", meta)]

  defp validate_step_opts(opts, meta) do
    Enum.flat_map(opts, fn
      {:cmd, v} when is_binary(v) ->
        []

      {:cmd, _} ->
        [diag("Step :cmd must be a string literal", meta)]

      {:module, {:__aliases__, _, _}} ->
        []

      {:module, m} when is_atom(m) and not is_nil(m) ->
        []

      {:module, _} ->
        [diag("Step :module must be a module alias (e.g. MyModule)", meta)]

      {:env, {:%{}, _, pairs}} ->
        validate_env_pairs(pairs, meta)

      {:env, _} ->
        [diag("Step :env must be a map literal with string keys and values", meta)]

      {:timeout, v} when is_integer(v) and v > 0 ->
        []

      {:timeout, _} ->
        [diag("Step :timeout must be a positive integer (milliseconds)", meta)]

      {:allow_failure, v} when is_boolean(v) ->
        []

      {:allow_failure, _} ->
        [diag("Step :allow_failure must be true or false", meta)]

      {:when, condition} ->
        validate_condition(condition, meta)

      {:working_dir, v} when is_binary(v) ->
        []

      {:working_dir, _} ->
        [diag("Step :working_dir must be a string literal", meta)]

      {:retry, v} when is_integer(v) and v > 0 ->
        []

      {:retry, _} ->
        [diag("Step :retry must be a positive integer (number of retries)", meta)]

      {:retry_delay, v} when is_integer(v) and v >= 0 ->
        []

      {:retry_delay, _} ->
        [diag("Step :retry_delay must be a non-negative integer (milliseconds)", meta)]

      {:cache, spec} when is_list(spec) ->
        validate_cache_spec(spec, meta)

      {:cache, _} ->
        [
          diag(
            "Step :cache must be a keyword list, e.g. cache: [paths: [\"deps\"], key: \"mix.lock\"]",
            meta
          )
        ]

      {:artifact, spec} when is_list(spec) ->
        validate_artifact_spec(spec, meta)

      {:artifact, _} ->
        [
          diag(
            "Step :artifact must be a keyword list, e.g. artifact: [name: \"build\", paths: [\"_build\"]]",
            meta
          )
        ]

      {key, _} ->
        [diag("Unknown step option: :#{key}", meta)]
    end)
  end

  defp validate_cache_spec(spec, meta) do
    Enum.flat_map(spec, fn
      {:paths, paths} when is_list(paths) ->
        Enum.flat_map(paths, fn
          p when is_binary(p) -> []
          _ -> [diag("cache :paths entries must be string literals", meta)]
        end)

      {:paths, _} ->
        [diag("cache :paths must be a list of string paths", meta)]

      {:key, key} when is_binary(key) ->
        []

      {:key, _} ->
        [diag("cache :key must be a string file path, e.g. key: \"mix.lock\"", meta)]

      {k, _} ->
        [diag("Unknown cache option: :#{k}", meta)]
    end)
  end

  defp validate_artifact_spec(spec, meta) do
    Enum.flat_map(spec, fn
      {:name, name} when is_binary(name) ->
        []

      {:name, _} ->
        [diag("artifact :name must be a string literal, e.g. name: \"build\"", meta)]

      {:paths, paths} when is_list(paths) ->
        Enum.flat_map(paths, fn
          p when is_binary(p) -> []
          _ -> [diag("artifact :paths entries must be string literals", meta)]
        end)

      {:paths, _} ->
        [diag("artifact :paths must be a list of string paths", meta)]

      {:required, v} when is_boolean(v) ->
        []

      {:required, _} ->
        [diag("artifact :required must be true or false", meta)]

      {k, _} ->
        [diag("Unknown artifact option: :#{k}", meta)]
    end)
  end

  defp validate_step_body(nil), do: []

  defp validate_step_body(block),
    do: block |> unwrap_block() |> Enum.flat_map(&validate_set_expr/1)

  defp validate_set_expr({:set, _, [k, _v]}) when is_atom(k), do: []

  defp validate_set_expr({:set, meta, _}),
    do: [diag("set/2 key must be an atom, e.g. `set :app, \"my-app\"`", meta)]

  defp validate_set_expr(node),
    do: [diag("Unexpected expression in step block: #{Macro.to_string(node)}", meta_of(node))]

  # ---------------------------------------------------------------------------
  # Hook call
  # ---------------------------------------------------------------------------

  defp validate_hook_call([opts], meta) when is_list(opts) do
    {block, rest_opts} = Keyword.pop(opts, :do)
    validate_hook_opts(rest_opts, meta) ++ validate_hook_body(block)
  end

  defp validate_hook_call([opts, [do: block]], meta) when is_list(opts) do
    validate_hook_opts(opts, meta) ++ validate_hook_body(block)
  end

  defp validate_hook_call(_, meta),
    do: [diag("on_success/on_failure requires a keyword options list", meta)]

  defp validate_hook_opts(opts, meta) do
    Enum.flat_map(opts, fn
      {:cmd, v} when is_binary(v) ->
        []

      {:cmd, _} ->
        [diag("Hook :cmd must be a string literal", meta)]

      {:module, {:__aliases__, _, _}} ->
        []

      {:module, m} when is_atom(m) and not is_nil(m) ->
        []

      {:module, _} ->
        [diag("Hook :module must be a module alias (e.g. MyNotifier)", meta)]

      {:env, {:%{}, _, pairs}} ->
        validate_env_pairs(pairs, meta)

      {:env, _} ->
        [diag("Hook :env must be a map literal with string keys and values", meta)]

      {:timeout, v} when is_integer(v) and v > 0 ->
        []

      {:timeout, _} ->
        [diag("Hook :timeout must be a positive integer (milliseconds)", meta)]

      {key, _} ->
        [diag("Unknown hook option: :#{key}", meta)]
    end)
  end

  defp validate_hook_body(nil), do: []

  defp validate_hook_body(block),
    do: block |> unwrap_block() |> Enum.flat_map(&validate_set_expr/1)

  # ---------------------------------------------------------------------------
  # Env map
  # ---------------------------------------------------------------------------

  defp validate_env_pairs(pairs, meta) do
    Enum.flat_map(pairs, fn
      {k, v} when is_binary(k) and is_binary(v) ->
        []

      {k, {:store, _, [a]}} when is_binary(k) and is_atom(a) ->
        []

      {k, _} when not is_binary(k) ->
        [diag("Env map keys must be string literals", meta)]

      {_, _} ->
        [diag("Env map values must be string literals or store(:key) references", meta)]
    end)
  end

  # ---------------------------------------------------------------------------
  # Env keyword list
  # ---------------------------------------------------------------------------

  defp validate_env_keyword_list(pairs, meta) do
    Enum.flat_map(pairs, fn
      {k, v} when is_atom(k) and is_binary(v) ->
        []

      {k, _} when is_atom(k) ->
        [diag("env values must be string literals (key: :#{k})", meta)]

      _ ->
        [diag("env keys must be atom literals, e.g. env MIX_ENV: \"test\"", meta)]
    end)
  end

  # ---------------------------------------------------------------------------
  # Condition expression grammar
  # ---------------------------------------------------------------------------

  defp validate_condition({:branch, _, []}, _fb), do: []

  defp validate_condition({:env, _, [v]}, _fb) when is_binary(v), do: []

  defp validate_condition({:env, meta, _}, fb),
    do: [diag("env/1 requires a string literal argument", meta_or(meta, fb))]

  defp validate_condition({:file_changed?, _, [v]}, _fb) when is_binary(v), do: []

  defp validate_condition({:file_changed?, meta, _}, fb),
    do: [diag("file_changed?/1 requires a string literal glob pattern", meta_or(meta, fb))]

  defp validate_condition({op, meta, [left, right]}, _fb) when op in [:==, :!=],
    do: validate_condition(left, meta) ++ validate_condition(right, meta)

  defp validate_condition({op, meta, [left, right]}, _fb) when op in [:and, :or],
    do: validate_condition(left, meta) ++ validate_condition(right, meta)

  defp validate_condition({:not, meta, [expr]}, _fb), do: validate_condition(expr, meta)

  defp validate_condition({:if, meta, [cond_expr, [do: then_expr, else: else_expr]]}, _fb) do
    validate_condition(cond_expr, meta) ++
      validate_condition(then_expr, meta) ++
      validate_condition(else_expr, meta)
  end

  defp validate_condition(v, _fb)
       when is_binary(v) or is_atom(v) or is_integer(v),
       do: []

  defp validate_condition(node, fb),
    do: [
      diag(
        "Invalid condition expression: #{Macro.to_string(node)}. " <>
          "Only branch(), env/1, file_changed?/1, comparisons, and boolean operators are allowed.",
        meta_or(meta_of(node), fb)
      )
    ]

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp diag(message, meta), do: Diagnostic.new(message, meta)

  defp meta_of({_, meta, _}) when is_list(meta), do: meta
  defp meta_of(_), do: []

  defp meta_or([], fallback), do: fallback
  defp meta_or(meta, _fallback), do: meta

  defp unwrap_block({:__block__, _, exprs}), do: exprs
  defp unwrap_block(single), do: [single]
end
