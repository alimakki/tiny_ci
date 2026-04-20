defmodule TinyCI.DSL.Validator do
  @moduledoc """
  Validates a quoted pipeline AST against the TinyCI DSL allowlist.

  Called by `TinyCI.DSL.Interpreter` before any interpretation occurs. Every
  node in the AST must match a permitted construct; anything outside the
  allowlist produces a descriptive error message.

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

  @doc """
  Validates a quoted AST and returns `:ok` or `{:error, violations}`.

  ## Parameters

    * `ast` — the result of `Code.string_to_quoted/2`

  ## Returns

    * `:ok` — all constructs are within the allowlist
    * `{:error, [String.t()]}` — list of human-readable violation messages
  """
  @spec validate(term()) :: :ok | {:error, [String.t()]}
  def validate(ast) do
    errors = ast |> unwrap_block() |> Enum.flat_map(&validate_top_level/1)

    case errors do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  # ---------------------------------------------------------------------------
  # Top-level expressions
  # ---------------------------------------------------------------------------

  defp validate_top_level({:name, _, [atom]}) when is_atom(atom), do: []

  defp validate_top_level({:name, _, _}),
    do: ["name/1 requires a single atom argument, e.g. `name :my_pipeline`"]

  defp validate_top_level({:stage, _, [name | rest]}) when is_atom(name),
    do: validate_stage_call(rest)

  defp validate_top_level({:stage, _, _}),
    do: ["stage name must be an atom, e.g. `stage :build do ... end`"]

  defp validate_top_level({:on_success, _, [name | rest]}) when is_atom(name),
    do: validate_hook_call(rest)

  defp validate_top_level({:on_success, _, _}),
    do: ["on_success name must be an atom"]

  defp validate_top_level({:on_failure, _, [name | rest]}) when is_atom(name),
    do: validate_hook_call(rest)

  defp validate_top_level({:on_failure, _, _}),
    do: ["on_failure name must be an atom"]

  defp validate_top_level({:defmodule, _, _}),
    do: [
      "Pipeline files must not use `defmodule`. " <>
        "Remove the module wrapper and `use TinyCI.DSL` line — " <>
        "the runtime provides that context automatically."
    ]

  defp validate_top_level(node),
    do: ["Unexpected top-level expression: #{Macro.to_string(node)}"]

  # ---------------------------------------------------------------------------
  # Stage call
  # ---------------------------------------------------------------------------

  defp validate_stage_call([opts]) when is_list(opts) do
    {block, rest_opts} = Keyword.pop(opts, :do)
    validate_stage_opts(rest_opts) ++ validate_stage_body(block)
  end

  defp validate_stage_call([opts, [do: block]]) when is_list(opts) do
    validate_stage_opts(opts) ++ validate_stage_body(block)
  end

  defp validate_stage_call(_), do: ["stage requires a keyword options list"]

  defp validate_stage_opts(opts) do
    Enum.flat_map(opts, fn
      {:mode, mode} when mode in [:serial, :parallel] ->
        []

      {:mode, _} ->
        ["Stage :mode must be :serial or :parallel"]

      {:when, condition} ->
        validate_condition(condition)

      {key, _} ->
        ["Unknown stage option: :#{key}"]
    end)
  end

  defp validate_stage_body(nil), do: []

  defp validate_stage_body(block),
    do: block |> unwrap_block() |> Enum.flat_map(&validate_stage_expr/1)

  defp validate_stage_expr({:step, _, [name | rest]}) when is_atom(name),
    do: validate_step_call(rest)

  defp validate_stage_expr({:step, _, _}),
    do: ["step name must be an atom, e.g. `step :unit, cmd: \"echo hi\"`"]

  defp validate_stage_expr(node),
    do: ["Unexpected expression in stage body: #{Macro.to_string(node)}"]

  # ---------------------------------------------------------------------------
  # Step call
  # ---------------------------------------------------------------------------

  defp validate_step_call([opts]) when is_list(opts) do
    {block, rest_opts} = Keyword.pop(opts, :do)
    validate_step_opts(rest_opts) ++ validate_step_body(block)
  end

  defp validate_step_call([opts, [do: block]]) when is_list(opts) do
    validate_step_opts(opts) ++ validate_step_body(block)
  end

  defp validate_step_call(_), do: ["step requires a keyword options list"]

  defp validate_step_opts(opts) do
    Enum.flat_map(opts, fn
      {:cmd, v} when is_binary(v) ->
        []

      {:cmd, _} ->
        ["Step :cmd must be a string literal"]

      {:module, {:__aliases__, _, _}} ->
        []

      {:module, m} when is_atom(m) and not is_nil(m) ->
        []

      {:module, _} ->
        ["Step :module must be a module alias (e.g. MyModule)"]

      {:env, {:%{}, _, pairs}} ->
        validate_env_pairs(pairs)

      {:env, _} ->
        ["Step :env must be a map literal with string keys and values"]

      {:timeout, v} when is_integer(v) and v > 0 ->
        []

      {:timeout, _} ->
        ["Step :timeout must be a positive integer (milliseconds)"]

      {:allow_failure, v} when is_boolean(v) ->
        []

      {:allow_failure, _} ->
        ["Step :allow_failure must be true or false"]

      {:when, condition} ->
        validate_condition(condition)

      {key, _} ->
        ["Unknown step option: :#{key}"]
    end)
  end

  defp validate_step_body(nil), do: []

  defp validate_step_body(block),
    do: block |> unwrap_block() |> Enum.flat_map(&validate_set_expr/1)

  defp validate_set_expr({:set, _, [k, _v]}) when is_atom(k), do: []

  defp validate_set_expr({:set, _, _}),
    do: ["set/2 key must be an atom, e.g. `set :app, \"my-app\"`"]

  defp validate_set_expr(node),
    do: ["Unexpected expression in step block: #{Macro.to_string(node)}"]

  # ---------------------------------------------------------------------------
  # Hook call
  # ---------------------------------------------------------------------------

  defp validate_hook_call([opts]) when is_list(opts) do
    {block, rest_opts} = Keyword.pop(opts, :do)
    validate_hook_opts(rest_opts) ++ validate_hook_body(block)
  end

  defp validate_hook_call([opts, [do: block]]) when is_list(opts) do
    validate_hook_opts(opts) ++ validate_hook_body(block)
  end

  defp validate_hook_call(_), do: ["on_success/on_failure requires a keyword options list"]

  defp validate_hook_opts(opts) do
    Enum.flat_map(opts, fn
      {:cmd, v} when is_binary(v) ->
        []

      {:cmd, _} ->
        ["Hook :cmd must be a string literal"]

      {:module, {:__aliases__, _, _}} ->
        []

      {:module, m} when is_atom(m) and not is_nil(m) ->
        []

      {:module, _} ->
        ["Hook :module must be a module alias (e.g. MyNotifier)"]

      {:env, {:%{}, _, pairs}} ->
        validate_env_pairs(pairs)

      {:env, _} ->
        ["Hook :env must be a map literal with string keys and values"]

      {:timeout, v} when is_integer(v) and v > 0 ->
        []

      {:timeout, _} ->
        ["Hook :timeout must be a positive integer (milliseconds)"]

      {key, _} ->
        ["Unknown hook option: :#{key}"]
    end)
  end

  defp validate_hook_body(nil), do: []

  defp validate_hook_body(block),
    do: block |> unwrap_block() |> Enum.flat_map(&validate_set_expr/1)

  # ---------------------------------------------------------------------------
  # Env map
  # ---------------------------------------------------------------------------

  defp validate_env_pairs(pairs) do
    Enum.flat_map(pairs, fn
      {k, v} when is_binary(k) and is_binary(v) ->
        []

      {k, {:store, _, [a]}} when is_binary(k) and is_atom(a) ->
        []

      {k, _} when not is_binary(k) ->
        ["Env map keys must be string literals"]

      {_, _} ->
        ["Env map values must be string literals or store(:key) references"]
    end)
  end

  # ---------------------------------------------------------------------------
  # Condition expression grammar
  # ---------------------------------------------------------------------------

  defp validate_condition({:branch, _, []}), do: []

  defp validate_condition({:env, _, [v]}) when is_binary(v), do: []
  defp validate_condition({:env, _, _}), do: ["env/1 requires a string literal argument"]

  defp validate_condition({:file_changed?, _, [v]}) when is_binary(v), do: []

  defp validate_condition({:file_changed?, _, _}),
    do: ["file_changed?/1 requires a string literal glob pattern"]

  defp validate_condition({op, _, [left, right]}) when op in [:==, :!=],
    do: validate_condition(left) ++ validate_condition(right)

  defp validate_condition({op, _, [left, right]}) when op in [:and, :or],
    do: validate_condition(left) ++ validate_condition(right)

  defp validate_condition({:not, _, [expr]}), do: validate_condition(expr)

  defp validate_condition({:if, _, [cond_expr, [do: then_expr, else: else_expr]]}) do
    validate_condition(cond_expr) ++
      validate_condition(then_expr) ++
      validate_condition(else_expr)
  end

  defp validate_condition(v)
       when is_binary(v) or is_atom(v) or is_integer(v),
       do: []

  defp validate_condition(node),
    do: [
      "Invalid condition expression: #{Macro.to_string(node)}. " <>
        "Only branch(), env/1, file_changed?/1, comparisons, and boolean operators are allowed."
    ]

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unwrap_block({:__block__, _, exprs}), do: exprs
  defp unwrap_block(single), do: [single]
end
