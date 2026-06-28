defmodule TinyCI.Action.Lockfile do
  @moduledoc """
  Reads and normalizes a project's `mix.lock` — which, for TinyCI, **is** the
  action lockfile.

  Actions are ordinary Hex dependencies, so the version and checksum that Hex
  resolves and verifies at fetch time are already pinned in `mix.lock`. This
  module parses that file into a uniform map keyed by application:

      %{jason: %{scm: :hex, version: "1.4.5", checksum: "…", repo: "hexpm"}, …}

  `mix.lock` is a trusted, project-local Elixir map literal (the same file Mix
  evaluates itself), so it is read by evaluation. Git/path dependencies are
  recorded too, but flagged via `:scm` — they are declared, not hash-pinned by
  Hex.
  """

  @type scm :: :hex | :git | :path | :other

  @type entry :: %{
          scm: scm(),
          version: String.t() | nil,
          checksum: String.t() | nil,
          repo: String.t() | nil
        }

  @type t :: %{optional(atom()) => entry()}

  @doc """
  Reads and parses a lockfile at `path`.

  A missing lockfile is treated as empty (`{:ok, %{}}`) rather than an error, so
  the caller's resolution can still flag third-party actions as unpinned.
  """
  @spec read(String.t()) :: {:ok, t()} | {:error, term()}
  def read(path) do
    case File.read(path) do
      {:ok, content} -> parse(content)
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Parses lockfile `content` (an Elixir map literal) into the normalized map.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, term()}
  def parse(content) do
    # `mix.lock` keys are quoted keywords (`"jason":`), which the evaluator warns
    # about; capture diagnostics so reading a lockfile is silent.
    {{result, _binding}, _diagnostics} =
      Code.with_diagnostics(fn -> Code.eval_string(content) end)

    case result do
      map when is_map(map) -> {:ok, Map.new(map, &normalize_pair/1)}
      _other -> {:error, :not_a_lock_map}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp normalize_pair({key, tuple}), do: {to_app(key), normalize_entry(tuple)}

  defp to_app(key) when is_atom(key), do: key
  defp to_app(key) when is_binary(key), do: String.to_atom(key)

  # Hex tuples have grown over time:
  #   {:hex, name, version}                                              (3)
  #   {:hex, name, version, inner, managers, deps}                       (6)
  #   {:hex, name, version, inner, managers, deps, repo}                 (7)
  #   {:hex, name, version, inner, managers, deps, repo, outer}          (8)
  # Read by position so every vintage normalizes the same way; prefer the
  # outer (tarball) checksum, falling back to the inner one.
  defp normalize_entry(tuple)
       when is_tuple(tuple) and tuple_size(tuple) >= 3 and elem(tuple, 0) == :hex do
    size = tuple_size(tuple)

    %{
      scm: :hex,
      version: elem(tuple, 2),
      checksum: hex_checksum(tuple, size),
      repo: if(size >= 7, do: elem(tuple, 6), else: "hexpm")
    }
  end

  defp normalize_entry({:git, url, ref, _opts}),
    do: %{scm: :git, version: ref, checksum: nil, repo: url}

  defp normalize_entry({:path, path, _opts}),
    do: %{scm: :path, version: nil, checksum: nil, repo: path}

  defp normalize_entry(other) when is_tuple(other) and tuple_size(other) >= 2,
    do: %{scm: :other, version: nil, checksum: nil, repo: to_string(elem(other, 0))}

  defp normalize_entry(_other),
    do: %{scm: :other, version: nil, checksum: nil, repo: nil}

  defp hex_checksum(tuple, size) when size >= 8, do: elem(tuple, 7)
  defp hex_checksum(tuple, size) when size >= 4, do: elem(tuple, 3)
  defp hex_checksum(_tuple, _size), do: nil
end
