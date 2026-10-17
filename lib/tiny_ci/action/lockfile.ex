defmodule TinyCI.Action.Lockfile do
  @moduledoc """
  Reads and normalizes a project's `mix.lock` — which, for TinyCI, **is** the
  action lockfile.

  Actions are ordinary Hex dependencies, so the version and checksum that Hex
  resolves and verifies at fetch time are already pinned in `mix.lock`. This
  module parses that file into a uniform map keyed by application name:

      %{"jason" => %{scm: :hex, version: "1.4.5", checksum: "…", repo: "hexpm"}, …}

  `mix.lock` is repository content, so it is treated as data, never as code: it
  is parsed with `Code.string_to_quoted/2` and only literal terms (maps, tuples,
  lists, strings, atoms, numbers) are accepted. A lockfile containing anything
  else — a function call, an interpolation, a variable — is
  `{:error, :not_a_lock_map}` with no side effect.

  Parsing uses a `:static_atoms_encoder`, so source atoms are read as strings and
  no atoms are created from lockfile-controlled names. The only atoms parsing can
  still add are a fixed, bounded set of parser constants (tags, `nil`/`true`/
  `false`, the 52 sigil letters), so application names are **strings** and a
  crafted lockfile cannot exhaust the atom table.

  Git/path dependencies are recorded too, but flagged via `:scm` — they are
  declared, not hash-pinned by Hex.
  """

  @type scm :: :hex | :git | :path | :other

  @type entry :: %{
          scm: scm(),
          version: String.t() | nil,
          checksum: String.t() | nil,
          repo: String.t() | nil
        }

  @type t :: %{optional(String.t()) => entry()}

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

  The content is never evaluated: it must parse to a map literal built only from
  maps, tuples, lists, strings, atoms and numbers.

  ## Examples

      iex> TinyCI.Action.Lockfile.parse(~S|%{"jason": {:hex, :jason, "1.4.5"}}|)
      {:ok, %{"jason" => %{checksum: nil, repo: "hexpm", scm: :hex, version: "1.4.5"}}}

      iex> TinyCI.Action.Lockfile.parse(~S|%{"evil": File.write!("pwned", "")}|)
      {:error, :not_a_lock_map}
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, :not_a_lock_map}
  def parse(content) do
    with {:ok, ast} <- parse_source(content),
         {:ok, term} <- literal(ast),
         true <- is_map(term) do
      normalize_map(term)
    else
      _ -> {:error, :not_a_lock_map}
    end
  end

  # `mix.lock` keys are quoted keywords (`"jason":`), which the parser warns
  # about; capture diagnostics so reading a lockfile is silent. Input that is not
  # valid UTF-8 makes the tokenizer *raise* rather than return an error tuple, so
  # arbitrary lockfile bytes fail closed here.
  defp parse_source(content) do
    {parsed, _diagnostics} =
      Code.with_diagnostics(fn ->
        Code.string_to_quoted(content, static_atoms_encoder: &encode_static_atom/2)
      end)

    parsed
  rescue
    _ -> {:error, :not_a_lock_map}
  end

  # ---------------------------------------------------------------------------
  # Literal-only evaluation
  # ---------------------------------------------------------------------------
  #
  # The parsed AST is walked by hand and only literal shapes are accepted, so
  # nothing in the file can ever be executed (or assembled into something
  # executable). Anything outside this allowlist fails closed.

  defp literal(value) when is_binary(value) or is_number(value) or is_atom(value),
    do: {:ok, value}

  defp literal({:%{}, _meta, pairs}), do: literal_map(pairs)
  defp literal({:{}, _meta, elements}), do: literal_list(elements, &List.to_tuple/1)

  defp literal({left, right}) do
    with {:ok, left} <- literal(left),
         {:ok, right} <- literal(right) do
      {:ok, {left, right}}
    end
  end

  defp literal(list) when is_list(list), do: literal_list(list, & &1)

  # Signed numeric literals arrive as unary calls with a literal number argument.
  # Accept exactly that shape so numbers stay in the grammar, while a real call
  # (`-x`, `1 - 2`, …) still fails closed.
  defp literal({sign, _meta, [number]}) when sign in [:+, :-] and is_number(number),
    do: {:ok, if(sign == :-, do: -number, else: number)}

  defp literal(_other), do: {:error, :not_a_lock_map}

  defp literal_map(pairs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn
      {key, value}, {:ok, map} ->
        with {:ok, key} <- literal(key),
             {:ok, value} <- literal(value) do
          {:cont, {:ok, Map.put(map, key, value)}}
        else
          {:error, _} = error -> {:halt, error}
        end

      # A non-pair entry in a map AST, e.g. map-update syntax `%{m | k: v}`.
      _other, {:ok, _map} ->
        {:halt, {:error, :not_a_lock_map}}
    end)
  end

  defp literal_list(elements, build) do
    elements
    |> Enum.reduce_while([], fn element, acc ->
      case literal(element) do
        {:ok, value} -> {:cont, [value | acc]}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      values when is_list(values) -> {:ok, build.(Enum.reverse(values))}
      {:error, _} = error -> error
    end
  end

  # Source atoms become strings, never atoms: a hostile lockfile must not be able
  # to grow the atom table.
  defp encode_static_atom(name, _meta), do: {:ok, name}

  # ---------------------------------------------------------------------------
  # Normalization
  # ---------------------------------------------------------------------------

  defp normalize_map(map) do
    map
    |> Enum.reduce_while([], fn {key, tuple}, acc ->
      case normalize_pair(key, tuple) do
        {:ok, pair} -> {:cont, [pair | acc]}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      pairs when is_list(pairs) -> {:ok, Map.new(pairs)}
      {:error, _} = error -> error
    end
  end

  defp normalize_pair(key, tuple) when is_binary(key), do: wrap(key, normalize_entry(tuple))

  defp normalize_pair(key, tuple) when is_atom(key),
    do: wrap(Atom.to_string(key), normalize_entry(tuple))

  defp normalize_pair(_key, _tuple), do: {:error, :not_a_lock_map}

  defp wrap(key, {:ok, entry}), do: {:ok, {key, entry}}
  defp wrap(_key, {:error, _} = error), do: error

  # Hex tuples have grown over time:
  #   {:hex, name, version}                                              (3)
  #   {:hex, name, version, inner, managers, deps}                       (6)
  #   {:hex, name, version, inner, managers, deps, repo}                 (7)
  #   {:hex, name, version, inner, managers, deps, repo, outer}          (8)
  # Read by position so every vintage normalizes the same way; prefer the outer
  # (tarball) checksum, falling back to the inner one. The parser encodes source
  # atoms as strings, so the tags arrive as "hex"/"git"/"path".
  defp normalize_entry(tuple)
       when is_tuple(tuple) and tuple_size(tuple) >= 3 and elem(tuple, 0) == "hex" do
    size = tuple_size(tuple)
    version = elem(tuple, 2)
    checksum = hex_checksum(tuple, size)
    repo = if size >= 7, do: elem(tuple, 6), else: "hexpm"

    if is_binary(version) and is_binary(repo) and (is_binary(checksum) or is_nil(checksum)) do
      {:ok, %{scm: :hex, version: version, checksum: checksum, repo: repo}}
    else
      {:error, :not_a_lock_map}
    end
  end

  defp normalize_entry({"git", url, ref, _opts}) when is_binary(url) and is_binary(ref),
    do: {:ok, %{scm: :git, version: ref, checksum: nil, repo: url}}

  defp normalize_entry({"path", path, _opts}) when is_binary(path),
    do: {:ok, %{scm: :path, version: nil, checksum: nil, repo: path}}

  # Unknown (or malformed git/path) tuple shapes stay :other, as before: their
  # fields are never consumed as pinned data, and nil/inspect here keep the entry
  # safe to render. Only hex entries are strict, because their fields *are*
  # consumed (compared, sliced, interpolated).
  defp normalize_entry(tuple) when is_tuple(tuple) and tuple_size(tuple) >= 2,
    do: {:ok, %{scm: :other, version: nil, checksum: nil, repo: tag_name(elem(tuple, 0))}}

  defp normalize_entry(_other),
    do: {:ok, %{scm: :other, version: nil, checksum: nil, repo: nil}}

  defp tag_name(tag) when is_binary(tag), do: tag
  defp tag_name(tag) when is_atom(tag), do: Atom.to_string(tag)
  defp tag_name(tag), do: inspect(tag)

  defp hex_checksum(tuple, size) when size >= 8, do: elem(tuple, 7)
  defp hex_checksum(tuple, size) when size >= 4, do: elem(tuple, 3)
  defp hex_checksum(_tuple, _size), do: nil
end
