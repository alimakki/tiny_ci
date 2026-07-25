defmodule TinyCI.Executor.Driver do
  @moduledoc """
  The execution driver for a `module:` action step — the seam that decides
  *where* an action's code runs.

  Two drivers implement this behaviour:

    * `TinyCI.Executor.Driver.Inline` — runs the action in the runner's own BEAM.
      Fast, but offers no isolation, so it **refuses third-party actions**.
    * `TinyCI.Executor.Driver.Sandbox` — runs the action in an OS sandbox, with
      only the capabilities it declared (see `TinyCI.Sandbox.Policy`).

  `select/2` picks the driver for a step. By default it routes first-party,
  builtin, and script-local modules inline and third-party (dependency) modules
  to the sandbox — enforcing "never run untrusted code unsandboxed." A run can
  override this via the `:sandbox` context key (`driver: :inline | :sandbox |
  :auto`).
  """

  alias TinyCI.Executor.Driver.{Inline, Sandbox}
  alias TinyCI.Sandbox.Trust

  @typedoc "A driver's normalized result: a store delta on success, or a reason."
  @type outcome :: {:ok, map()} | {:error, term()}

  @doc """
  Runs `module`'s action with `config` and `context`.

  Returns `{:ok, store_delta}` on success (`:ok` from the action normalizes to
  an empty delta) or `{:error, reason}` on failure or refusal.
  """
  @callback run(module(), map(), TinyCI.Context.t(), keyword()) :: outcome()

  @doc "Selects the driver module for `module`, honoring the run's `:sandbox` config."
  @spec select(module(), map()) :: module()
  def select(module, context) do
    opts = sandbox_opts(context)

    case Keyword.get(opts, :driver, :auto) do
      :inline -> Inline
      :sandbox -> Sandbox
      :auto -> if Trust.trusted?(module, opts), do: Inline, else: Sandbox
    end
  end

  @doc "The options a driver receives, read from the run's `:sandbox` context key."
  @spec opts(map()) :: keyword()
  def opts(context), do: sandbox_opts(context)

  defp sandbox_opts(context) do
    case Map.get(context, :sandbox, []) do
      opts when is_list(opts) -> opts
      _ -> []
    end
  end
end
