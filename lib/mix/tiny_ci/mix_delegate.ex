defmodule TinyCI.MixDelegate do
  @moduledoc """
  Glue between the `mix tiny_ci.*` tasks and the `TinyCI.CLI` subcommands.

  The subcommands return `:ok | {:error, reason}` and never raise or halt, which is
  what a standalone binary needs. Each Mix task historically had its own failure
  contract, and tests and scripts depend on them, so every task keeps its own:

    * `raise_on_error/2` — for `tiny_ci.run`, `tiny_ci.runs` and
      `tiny_ci.attest.gen_key`, which raise `Mix.Error`.
    * `halt_unless_test/3` — for the audit, index, search, verify and cache tasks,
      which return `{:error, tag}` and halt the VM with status 1 outside the
      `:test` Mix environment.

  This module lives under `lib/mix/` so that `lib/tiny_ci/**` stays free of Mix.
  """

  @doc """
  Returns `:ok`, or raises `Mix.Error` for an error.

  A `:usage` or `:failed` error raises with its message. Any other error raises
  with `inspect(reason)`, prefixed by `label` when one is given.
  """
  @spec raise_on_error(:ok | {:error, term()}, String.t() | nil) :: :ok
  def raise_on_error(result, label \\ nil)
  def raise_on_error(:ok, _label), do: :ok

  def raise_on_error({:error, {kind, message}}, _label) when kind in [:usage, :failed],
    do: Mix.raise(message)

  def raise_on_error({:error, reason}, nil), do: Mix.raise(inspect(reason))
  def raise_on_error({:error, reason}, label), do: Mix.raise("#{label}: #{inspect(reason)}")

  @doc """
  Halts the VM with the result's status unless Mix is running in the `:test`
  environment, and returns `:ok` or `{:error, tag}`.

  Status is `0` for `:ok` and `1` for any error, whatever its kind: the Mix tasks
  never used `2`. A `:usage` or `:failed` message is printed to stderr first (the
  dispatcher does that for the standalone command).

  Pass `halt_on_ok: false` for a task that never halted on success.
  """
  @spec halt_unless_test(:ok | {:error, term()}, atom(), keyword()) :: :ok | {:error, atom()}
  def halt_unless_test(result, tag, opts \\ []) do
    report(result)
    code = status(result)

    if Mix.env() != :test and (code != 0 or Keyword.get(opts, :halt_on_ok, true)) do
      System.halt(code)
    end

    if code == 0, do: :ok, else: {:error, tag}
  end

  defp status(:ok), do: 0
  defp status({:error, _reason}), do: 1

  defp report({:error, {kind, message}}) when kind in [:usage, :failed] do
    TinyCI.CLI.print_error(message)
  end

  defp report(_result), do: :ok
end
