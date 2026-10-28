defmodule TinyCI.Environment.Image do
  @moduledoc """
  Resolves an OCI image reference to the immutable identity a run can rely on.

  `image: "elixir:1.18"` is a *tag*: it can move. The environment a stage runs
  in, and the cache key derived from it, must not move with it. Resolution
  therefore asks the container runtime for the local image ID (`image inspect
  --format '{{.Id}}'`) and uses that ID as the run reference.

  A reference that already carries a `@sha256:` digest keeps the declared
  digest as its identity even when the local ID differs (for example when
  comparing a registry manifest with a local build).

  A missing image is pulled once when `:pull` is true (the default). With
  `pull: false` — a dry run — a missing image resolves to a `nil` digest and is
  never pulled, so inspecting a plan cannot change the machine.

  References are validated before they reach a runtime command line: a
  reference with whitespace or control characters, or one that starts with
  `-`, would otherwise be read as an option or split into arguments.
  """

  alias TinyCI.Execution.Backend.Container

  @typedoc "The immutable identity and the reference used to start a container."
  @type resolved :: %{digest: String.t() | nil, run_ref: String.t()}

  @doc """
  Validates an OCI reference as an argument, not as an option.

  Returns `:ok` or `{:error, {:invalid_image, ref}}`. Empty references, leading
  `-` references, and references containing whitespace or control characters
  are rejected.

  ## Examples

      iex> TinyCI.Environment.Image.validate_ref("elixir:1.18")
      :ok

      iex> TinyCI.Environment.Image.validate_ref("--privileged")
      {:error, {:invalid_image, "--privileged"}}
  """
  @spec validate_ref(term()) :: :ok | {:error, {:invalid_image, term()}}
  def validate_ref(ref) when is_binary(ref) do
    cond do
      ref == "" -> {:error, {:invalid_image, ref}}
      String.starts_with?(ref, "-") -> {:error, {:invalid_image, ref}}
      Regex.match?(~r/[[:space:][:cntrl:]]/, ref) -> {:error, {:invalid_image, ref}}
      true -> :ok
    end
  end

  def validate_ref(ref), do: {:error, {:invalid_image, ref}}

  @doc "Returns `true` when `validate_ref/1` accepts the reference."
  @spec valid_ref?(term()) :: boolean()
  def valid_ref?(ref), do: validate_ref(ref) == :ok

  @doc """
  Resolves `ref` to `%{digest: ..., run_ref: ...}`.

  ## Options

    * `:pull` — pull a missing image (default `true`); when `false`, a missing
      image resolves with `digest: nil` and no pull is attempted
    * `:runtime` — the runtime description (default:
      `TinyCI.Execution.Backend.Container.runtime/0`)
    * `:run` — a `[String.t()] -> {output, status}` function used instead of
      `System.cmd/3` against the runtime (tests inject this)

  ## Examples

      iex> TinyCI.Environment.Image.resolve("bad ref", [])
      {:error, {:invalid_image, "bad ref"}}
  """
  @spec resolve(String.t(), keyword()) :: {:ok, resolved()} | {:error, term()}
  def resolve(ref, opts \\ []) do
    with :ok <- validate_ref(ref),
         {:ok, runtime} <- runtime(opts) do
      inspect_or_pull(ref, runtime, opts)
    end
  end

  defp runtime(opts) do
    case Keyword.fetch(opts, :runtime) do
      {:ok, %{} = runtime} -> {:ok, runtime}
      {:ok, {:ok, runtime}} -> {:ok, runtime}
      {:ok, {:error, _} = error} -> error
      :error -> Container.runtime()
    end
  end

  defp inspect_or_pull(ref, runtime, opts) do
    run = runner(runtime, opts)
    declared = declared_digest(ref)

    case inspect_image(ref, run) do
      {:ok, id} ->
        {:ok, %{digest: declared || id, run_ref: id}}

      :missing ->
        if Keyword.get(opts, :pull, true) do
          pull_and_inspect(ref, run, declared)
        else
          {:ok, %{digest: declared, run_ref: ref}}
        end
    end
  end

  defp pull_and_inspect(ref, run, declared) do
    case run.(["pull", ref]) do
      {_output, 0} ->
        case inspect_image(ref, run) do
          {:ok, id} -> {:ok, %{digest: declared || id, run_ref: id}}
          :missing -> {:error, {:image_unavailable, ref, :missing_after_pull}}
        end

      {output, status} ->
        {:error, {:image_unavailable, ref, status, String.trim(output)}}
    end
  end

  defp runner(runtime, opts) do
    Keyword.get(opts, :run, fn args ->
      System.cmd(runtime.command, args, stderr_to_stdout: true)
    end)
  end

  defp inspect_image(ref, run) do
    case run.(["image", "inspect", "--format", "{{.Id}}", ref]) do
      {output, 0} ->
        case String.trim(output) do
          "" -> :missing
          id -> {:ok, id}
        end

      {_output, _status} ->
        :missing
    end
  end

  defp declared_digest(ref) do
    case Regex.run(~r/@(sha256:[0-9a-f]{64})$/, ref) do
      [_, digest] -> digest
      nil -> nil
    end
  end
end
