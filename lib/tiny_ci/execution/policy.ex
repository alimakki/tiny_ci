defmodule TinyCI.Execution.Policy do
  @moduledoc """
  Chooses *where* a run executes from its trust level and image.

  Trust belongs to the invocation, never to the pipeline file (decision D1 in
  `M1.5-00`). This module is the single pure policy that maps trust plus image
  to an execution backend:

  | trust | image | backend |
  |---|---|---|
  | `:trusted` | none | `TinyCI.Execution.Backend.Local` |
  | `:trusted` | set | `TinyCI.Execution.Backend.Container` |
  | `:untrusted` | set | `TinyCI.Execution.Backend.Container` |
  | `:untrusted` | none, `default_image` set | `TinyCI.Execution.Backend.Container` |
  | `:untrusted` | none, no `default_image` | error |

  An untrusted run never resolves to the host and nothing falls back to the host
  silently. The availability probe is injected so the table can be tested
  without a container runtime.
  """

  alias TinyCI.Execution
  alias TinyCI.Execution.Backend.{Container, Local}

  @typedoc "The selected backend and the image it should run, if any."
  @type decision :: %{backend: module(), image: String.t() | nil}

  @doc """
  Resolves the backend and image for a run.

  ## Options

    * `:default_image` — image for an untrusted run with no explicit image
    * `:available?` — zero-arity probe for the container runtime (defaults to
      `TinyCI.Execution.Backend.Container.available?/0`)

  ## Examples

      iex> TinyCI.Execution.Policy.resolve(%{trust: :trusted}, nil)
      {:ok, %{backend: TinyCI.Execution.Backend.Local, image: nil}}

      iex> TinyCI.Execution.Policy.resolve(%{trust: :untrusted}, nil, default_image: "alpine", available?: fn -> true end)
      {:ok, %{backend: TinyCI.Execution.Backend.Container, image: "alpine"}}
  """
  @spec resolve(map(), String.t() | nil, keyword()) ::
          {:ok, decision()} | {:error, term()}
  def resolve(ctx, image, opts \\ []) do
    case Execution.trust(ctx) do
      :trusted -> resolve_trusted(image, opts)
      :untrusted -> resolve_untrusted(image || Keyword.get(opts, :default_image), opts)
    end
  end

  @doc """
  Returns only the selected backend module.

  See `resolve/3` for the decision that also carries the image.

  ## Examples

      iex> TinyCI.Execution.Policy.backend(%{trust: :trusted}, nil)
      {:ok, TinyCI.Execution.Backend.Local}

      iex> TinyCI.Execution.Policy.backend(%{trust: :untrusted}, nil)
      {:error, :no_default_image}
  """
  @spec backend(map(), String.t() | nil, keyword()) :: {:ok, module()} | {:error, term()}
  def backend(ctx, image, opts \\ []) do
    case resolve(ctx, image, opts) do
      {:ok, %{backend: backend}} -> {:ok, backend}
      {:error, _} = error -> error
    end
  end

  defp resolve_trusted(nil, _opts), do: {:ok, %{backend: Local, image: nil}}

  defp resolve_trusted(image, opts) do
    container_decision(image, opts)
  end

  defp resolve_untrusted(nil, _opts), do: {:error, :no_default_image}

  defp resolve_untrusted(image, opts) do
    container_decision(image, opts)
  end

  defp container_decision(image, opts) do
    if available?(opts) do
      {:ok, %{backend: Container, image: image}}
    else
      {:error, :no_isolation_backend}
    end
  end

  defp available?(opts) do
    Keyword.get(opts, :available?, fn -> Container.available?() end).()
  end
end
