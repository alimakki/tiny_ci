defmodule TinyCI.DSL.ConditionEval do
  @moduledoc """
  Evaluates condition expressions stored as quoted AST nodes against a pipeline
  context map.

  Condition expressions are produced by the DSL interpreter from the `:when`
  option of a `stage` call. They are restricted to a safe sub-grammar validated
  by `TinyCI.DSL.Validator` — no arbitrary Elixir code can appear here.

  ## Permitted grammar

      condition :=
        | branch()                       -- current git branch string
        | env(string)                    -- env var value or nil
        | file_changed?(string)          -- boolean glob match against changed files
        | literal                        -- string, atom, boolean, nil, integer
        | condition == condition
        | condition != condition
        | condition and condition
        | condition or condition
        | not condition
        | if condition, do: condition, else: condition

  ## Usage

      ast = quote do: branch() == "main" and env("CI") != nil
      TinyCI.DSL.ConditionEval.eval(ast, ctx)
      # => true | false
  """

  alias TinyCI.Context

  @doc """
  Evaluates a condition AST node against the given context map.

  Returns the boolean result of the condition. Raises `ArgumentError` for any
  AST node that falls outside the permitted grammar (should not happen if the
  validator ran first).

  ## Parameters

    * `ast`     — a quoted Elixir expression from the condition grammar
    * `context` — the pipeline context map (must contain `:branch`,
      `:changed_files`, etc.)
  """
  @spec eval(term(), map()) :: term()
  def eval({:branch, _, []}, ctx), do: Map.get(ctx, :branch, "unknown")

  def eval({:env, _, [var]}, _ctx) when is_binary(var), do: System.get_env(var)

  def eval({:file_changed?, _, [glob]}, ctx) when is_binary(glob),
    do: Context.any_file_matches?(Map.get(ctx, :changed_files, []), glob)

  def eval({:==, _, [left, right]}, ctx), do: eval(left, ctx) == eval(right, ctx)
  def eval({:!=, _, [left, right]}, ctx), do: eval(left, ctx) != eval(right, ctx)

  def eval({:and, _, [left, right]}, ctx), do: eval(left, ctx) and eval(right, ctx)
  def eval({:or, _, [left, right]}, ctx), do: eval(left, ctx) or eval(right, ctx)
  def eval({:not, _, [expr]}, ctx), do: not eval(expr, ctx)

  def eval({:if, _, [cond_expr, [do: then_expr, else: else_expr]]}, ctx) do
    if eval(cond_expr, ctx), do: eval(then_expr, ctx), else: eval(else_expr, ctx)
  end

  def eval(literal, _ctx)
      when is_binary(literal) or is_atom(literal) or is_integer(literal),
      do: literal

  def eval(node, _ctx) do
    raise ArgumentError,
          "ConditionEval received an unexpected AST node: #{Macro.to_string(node)}. " <>
            "Ensure the pipeline file passed validation before evaluation."
  end
end
