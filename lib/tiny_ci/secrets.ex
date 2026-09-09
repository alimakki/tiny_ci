defmodule TinyCI.Secrets do
  @moduledoc """
  Resolves the secrets a pipeline declares with `secret :NAME` before a run starts.

  A pipeline names the secrets it needs; this module finds their values and
  refuses to start the run when any is missing, so a step never runs with an
  empty token. Values come from three sources, first hit per name winning:

    1. an explicit **provider** map (what a server-side store plugs into),
    2. the process **environment**,
    3. the file `.tiny_ci/secrets` under the project root, which must be
       gitignored.

  A secret value is never logged by this module, and the full environment is
  never copied onto the context — only the declared names are looked up.

  ## File format

  One `KEY=value` per line. A `#` as the first non-blank character starts a
  comment; blank lines are ignored; a leading `export ` is stripped; matching
  single or double quotes around the value are removed (no escapes, no
  interpolation). A line without `=` is a parse error.
  """

  @file_name ".tiny_ci/secrets"
  @min_value_bytes 4

  @typedoc "A name → value map consulted before the environment and the file."
  @type provider :: %{optional(String.t()) => String.t()}

  @typedoc "Resolved secrets, keyed by declared name."
  @type resolved :: %{optional(String.t()) => String.t()}

  @doc """
  Resolves every declared `name` from the provider, the environment, then the file.

  ## Options

    * `:root` — project root; the file is read from `root/#{@file_name}`
    * `:provider` — a `t:provider/0` map checked first (default `%{}`)
    * `:env` — the environment map (default `System.get_env/0`)

  ## Returns

    * `{:ok, %{name => value}}` when every name resolved
    * `{:error, {:missing_secrets, names}}` with the unresolved names in
      declaration order
    * `{:error, {:secrets_file, path, {:line, n, reason}}}` when the file is malformed
  """
  @spec resolve([String.t()], keyword()) ::
          {:ok, resolved()}
          | {:error, {:missing_secrets, [String.t()]}}
          | {:error, {:secrets_file, String.t(), {:line, pos_integer(), String.t()}}}
  def resolve([], _opts), do: {:ok, %{}}

  def resolve(names, opts) when is_list(names) do
    provider = Keyword.get(opts, :provider, %{})
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
    root = Keyword.get(opts, :root, File.cwd!())

    with {:ok, from_file} <- read_file(Path.join(root, @file_name)) do
      lookup = fn name -> provider[name] || env[name] || from_file[name] end
      resolved = for name <- names, value = lookup.(name), do: {name, value}, into: %{}

      case Enum.reject(names, &Map.has_key?(resolved, &1)) do
        [] -> {:ok, resolved}
        missing -> {:error, {:missing_secrets, missing}}
      end
    end
  end

  @doc """
  Parses the contents of a secrets file.

  ## Examples

      iex> TinyCI.Secrets.parse_file("# token\\nexport TOKEN='abcd'\\nURL=\\"https://x/?a=1\\"\\n")
      {:ok, %{"TOKEN" => "abcd", "URL" => "https://x/?a=1"}}

      iex> TinyCI.Secrets.parse_file("oops")
      {:error, {:line, 1, "expected KEY=value"}}
  """
  @spec parse_file(String.t()) ::
          {:ok, resolved()} | {:error, {:line, pos_integer(), String.t()}}
  def parse_file(content) when is_binary(content) do
    content
    |> String.split(["\r\n", "\n"])
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, %{}}, fn {line, number}, {:ok, acc} ->
      case parse_line(String.trim(line)) do
        :skip -> {:cont, {:ok, acc}}
        {:ok, key, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, reason} -> {:halt, {:error, {:line, number, reason}}}
      end
    end)
  end

  @doc """
  The distinct values worth masking: blanks and values shorter than
  #{@min_value_bytes} bytes are dropped (see `TinyCI.Redaction`).

  ## Examples

      iex> TinyCI.Secrets.values(%{"A" => "abcd", "B" => "abcd", "C" => "ab"})
      ["abcd"]
  """
  @spec values(resolved()) :: [String.t()]
  def values(secrets) when is_map(secrets) do
    secrets
    |> Map.values()
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) >= @min_value_bytes))
    |> Enum.uniq()
  end

  @doc """
  Puts resolved secrets on a run context as `:secrets` (name → value) and
  `:secret_values` (the maskable values, see `values/1`).

  Both the executor and the hooks runner read these keys; the second is what
  every masking choke point uses.

  ## Examples

      iex> TinyCI.Secrets.attach(%{}, %{"T" => "abcd"})
      %{secrets: %{"T" => "abcd"}, secret_values: ["abcd"]}
  """
  @spec attach(map(), resolved()) :: map()
  def attach(context, secrets) when is_map(context) and is_map(secrets) do
    context
    |> Map.put(:secrets, secrets)
    |> Map.put(:secret_values, values(secrets))
  end

  @doc "The path of the secrets file for a project root."
  @spec file_path(String.t()) :: String.t()
  def file_path(root), do: Path.join(root, @file_name)

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> wrap_parse(parse_file(content), path)
      {:error, _} -> {:ok, %{}}
    end
  end

  defp wrap_parse({:ok, map}, _path), do: {:ok, map}
  defp wrap_parse({:error, reason}, path), do: {:error, {:secrets_file, path, reason}}

  defp parse_line(""), do: :skip
  defp parse_line("#" <> _), do: :skip

  defp parse_line(line) do
    line = strip_export(line)

    case String.split(line, "=", parts: 2) do
      [key, value] when key != "" -> {:ok, String.trim(key), unquote_value(String.trim(value))}
      _ -> {:error, "expected KEY=value"}
    end
  end

  defp strip_export("export " <> rest), do: String.trim_leading(rest)
  defp strip_export(line), do: line

  defp unquote_value(<<q, rest::binary>> = value) when q in [?", ?'] do
    if byte_size(rest) >= 1 and String.ends_with?(rest, <<q>>) do
      binary_part(rest, 0, byte_size(rest) - 1)
    else
      value
    end
  end

  defp unquote_value(value), do: value
end
