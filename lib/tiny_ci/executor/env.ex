defmodule TinyCI.Executor.Env do
  @moduledoc """
  Resolves the environment a step actually runs with.

  Three layers merge, later winning over earlier:

    1. `context.pipeline_env` — declared once for the whole pipeline
    2. `context.stage_env`    — the stage's `env:` (plus the matrix combination's vars)
    3. the step's own `env:`  — where `{:store, key}` references are replaced with
       the current pipeline store value

  This lives in its own module because two callers need the *same* answer: the
  executor, when it launches the command, and `TinyCI.Control.Session`, when it
  reports the resolved env at a breakpoint (T10). A breakpoint that showed a
  different env than the step received would be worse than showing none.
  """

  @type env :: %{optional(String.t()) => String.t()}

  @doc """
  Returns the pipeline+stage environment, before any step-level `env:` is applied.

  ## Examples

      iex> TinyCI.Executor.Env.base(%{pipeline_env: %{"A" => "1"}, stage_env: %{"A" => "2"}})
      %{"A" => "2"}
  """
  @spec base(map()) :: env()
  def base(context) do
    context
    |> Map.get(:pipeline_env, %{})
    |> Map.merge(Map.get(context, :stage_env, %{}))
  end

  @doc """
  Returns the fully resolved environment for a step.

  ## Examples

      iex> ctx = %{pipeline_env: %{"MIX_ENV" => "test"}, store: %{sha: "abc"}}
      iex> TinyCI.Executor.Env.resolve(ctx, %{"SHA" => {:store, :sha}})
      %{"MIX_ENV" => "test", "SHA" => "abc"}
  """
  @spec resolve(map(), map() | nil) :: env()
  def resolve(context, step_env) do
    Map.merge(base(context), resolve_store_refs(step_env, Map.get(context, :store, %{})))
  end

  @doc """
  Replaces `{:store, key}` values in a step's `env:` with the store's current value.

  A missing key resolves to `""` rather than raising — a step reading an unset
  store key sees an empty variable, the same as an unset shell variable.

  ## Examples

      iex> TinyCI.Executor.Env.resolve_store_refs(%{"V" => {:store, :missing}}, %{})
      %{"V" => ""}
  """
  @spec resolve_store_refs(map() | nil, map()) :: env()
  def resolve_store_refs(nil, _store), do: %{}

  def resolve_store_refs(env, store) do
    Map.new(env, fn
      {key, {:store, store_key}} -> {key, to_string(Map.get(store, store_key, ""))}
      {key, value} -> {key, value}
    end)
  end
end
