defmodule TinyCI.Context do
  @moduledoc """
  The pipeline context — metadata that flows through every stage and step.

  The context carries git metadata (branch name, commit SHA, changed files),
  a `:timestamp`, and the pipeline `:store` (a key-value map accumulated across
  steps). Stages inspect it in their `when_condition`, and module-based actions
  receive it as the second argument to `c:TinyCI.Action.execute/2`.

  ## Guaranteed fields

    * `:branch`        — the current git branch (e.g. `"main"`)
    * `:commit`        — the full 40-character commit SHA
    * `:changed_files` — list of file paths changed since the last commit
    * `:store`         — the pipeline store (defaults to `%{}`)
    * `:timestamp`     — a `DateTime` captured when the context is built

  ## Extra fields

  `Context` is a struct, but `build/1` preserves arbitrary override keys (and
  the executor adds dynamic keys such as `:run_id`, `:artifacts_dir`, `:events`,
  and `:stage_env` as a run progresses). These extra keys are readable via map
  access (`ctx.pr_number`) while the value remains a `%TinyCI.Context{}` struct.
  The guaranteed fields above are the stable, documented surface.

  ## Examples

      iex> ctx = TinyCI.Context.build()
      iex> is_struct(ctx, TinyCI.Context) and is_binary(ctx.branch)
      true

      iex> ctx = TinyCI.Context.build(branch: "custom", pr_number: 42)
      iex> ctx.branch
      "custom"
      iex> ctx.pr_number
      42
  """

  @type t :: %__MODULE__{
          branch: String.t(),
          commit: String.t(),
          changed_files: [String.t()],
          store: map(),
          timestamp: DateTime.t() | nil
        }

  defstruct branch: "unknown",
            commit: "unknown",
            changed_files: [],
            store: %{},
            timestamp: nil

  @doc """
  Builds a context from the current git state.

  Any key-value pairs in `overrides` are merged on top of the detected
  values, so callers can inject test doubles or additional metadata. Override
  keys that are not struct fields are preserved as extra map keys while the
  result stays a `%TinyCI.Context{}`.

  ## Parameters

    * `overrides` — keyword list of values to merge into the context

  ## Returns

  A `%TinyCI.Context{}` with at least `:branch`, `:commit`, `:changed_files`,
  `:store`, and `:timestamp` populated.
  """
  @spec build(keyword()) :: t()
  def build(overrides \\ []) do
    %__MODULE__{
      branch: branch(),
      commit: commit(),
      changed_files: changed_files(),
      store: %{},
      timestamp: DateTime.utc_now()
    }
    |> Map.merge(Map.new(overrides))
  end

  @doc """
  Returns the current git branch name.

  Falls back to `"unknown"` if git is not available or the command fails.

  ## Examples

      iex> is_binary(TinyCI.Context.branch())
      true
  """
  @spec branch() :: String.t()
  def branch do
    case System.cmd("git", ["rev-parse", "--abbrev-ref", "HEAD"], stderr_to_stdout: true) do
      {branch, 0} -> String.trim(branch)
      _ -> "unknown"
    end
  end

  @doc """
  Returns the current git commit SHA (full 40-character hex string).

  Falls back to `"unknown"` if git is not available or the command fails.

  ## Examples

      iex> sha = TinyCI.Context.commit()
      iex> is_binary(sha)
      true
  """
  @spec commit() :: String.t()
  def commit do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end

  @doc """
  Returns the list of files changed since the last commit.

  Uses `git diff --name-only HEAD~1` to detect changes. Falls back to
  an empty list if the command fails (e.g. initial commit or no git).

  ## Examples

      iex> is_list(TinyCI.Context.changed_files())
      true
  """
  @spec changed_files() :: [String.t()]
  def changed_files do
    case System.cmd("git", ["diff", "--name-only", "HEAD~1"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.trim()
        |> String.split("\n", trim: true)

      _ ->
        []
    end
  end

  @doc """
  Returns `true` if any file in `files` matches the given glob `pattern`.

  Supports `*` (matches within a single directory) and `**` (matches across
  directory boundaries). Used by the `when_file_changed/1` DSL macro.

  ## Parameters

    * `files`   — a list of file path strings
    * `pattern` — a glob pattern (e.g. `"lib/**/*.ex"`, `"*.md"`)

  ## Examples

      iex> TinyCI.Context.any_file_matches?(["lib/app.ex", "README.md"], "lib/**/*.ex")
      true

      iex> TinyCI.Context.any_file_matches?(["README.md"], "lib/**/*.ex")
      false
  """
  @spec any_file_matches?([String.t()], String.t()) :: boolean()
  def any_file_matches?(files, pattern) do
    regex = glob_to_regex(pattern)
    Enum.any?(files, &Regex.match?(regex, &1))
  end

  defp glob_to_regex(pattern) do
    pattern
    |> Regex.escape()
    |> String.replace("\\*\\*/", ":DBL_STAR_SLASH:")
    |> String.replace("\\*\\*", ":DBL_STAR:")
    |> String.replace("\\*", "[^/]*")
    |> String.replace(":DBL_STAR_SLASH:", "(.*/)?")
    |> String.replace(":DBL_STAR:", ".*")
    |> then(&Regex.compile!("^#{&1}$"))
  end
end
