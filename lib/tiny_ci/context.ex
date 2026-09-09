defmodule TinyCI.Context do
  @moduledoc """
  The pipeline context — metadata that flows through every stage and step.

  The context carries git metadata (branch name, commit SHA, changed files,
  the base ref the changed files were computed against), a `:timestamp`, and
  the pipeline `:store` (a key-value map accumulated across steps). Stages
  inspect it in their `when_condition`, and module-based actions receive it as
  the second argument to `c:TinyCI.Action.execute/2`.

  ## Guaranteed fields

    * `:branch`        — the current git branch (e.g. `"main"`)
    * `:commit`        — the full 40-character commit SHA
    * `:changed_files` — sorted list of paths changed on this branch since it
      diverged from `:base_ref`, plus the dirty tree (see `changed_files/2`)
    * `:base_ref`      — the ref or SHA the changed files were computed against,
      or `nil` when none could be found (initial commit with no remote)
    * `:store`         — the pipeline store (defaults to `%{}`)
    * `:timestamp`     — a `DateTime` captured when the context is built

  ## Extra fields

  `Context` is a struct, but `build/1` preserves arbitrary override keys (and
  the executor adds dynamic keys such as `:run_id`, `:artifacts_dir`, `:events`,
  and `:stage_env` as a run progresses). These extra keys are readable via map
  access (`ctx.pr_number`) while the value remains a `%TinyCI.Context{}` struct.
  The guaranteed fields above are the stable, documented surface.

  ## Where git runs

  Every git call takes a `root` directory and runs there, so a server can build
  a context for a workspace it checked out without changing its own working
  directory. The arity-0 conveniences (`branch/0`, `commit/0`, `changed_files/0`)
  use `File.cwd!/0`.

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
          base_ref: String.t() | nil,
          store: map(),
          timestamp: DateTime.t() | nil
        }

  defstruct branch: "unknown",
            commit: "unknown",
            changed_files: [],
            base_ref: nil,
            store: %{},
            timestamp: nil

  # git's well-known hash of the empty tree: diffing against it lists every
  # tracked file, which is the right answer when there is no base at all.
  @empty_tree "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

  @base_env_var "TINY_CI_BASE_REF"

  @doc """
  Builds a context from the git state of a project root.

  ## Options (consumed, not stored)

    * `:base`          — a ref or SHA to diff against; skips `detect_base/2`
      (still subject to the equals-HEAD rule described there)
    * `:include_dirty` — whether uncommitted changes count (default `true`)

  ## Overrides (stored)

  Any other key-value pair is merged on top of the detected values, so callers
  can inject test doubles or additional metadata. `:root` is the directory git
  runs in (default `File.cwd!/0`) and is preserved as an extra key. Override keys
  that are not struct fields are preserved as extra map keys while the result
  stays a `%TinyCI.Context{}`.

  ## Returns

  A `%TinyCI.Context{}` with at least `:branch`, `:commit`, `:changed_files`,
  `:base_ref`, `:store`, and `:timestamp` populated.
  """
  @spec build(keyword()) :: t()
  def build(overrides \\ []) do
    root = Keyword.get(overrides, :root, File.cwd!())
    base = resolve_base(root, Keyword.get(overrides, :base))
    include_dirty = Keyword.get(overrides, :include_dirty, true)

    %__MODULE__{
      branch: branch(root),
      commit: commit(root),
      changed_files: changed_files(root, base: base, include_dirty: include_dirty),
      base_ref: base,
      store: %{},
      timestamp: DateTime.utc_now()
    }
    |> Map.merge(Map.new(Keyword.drop(overrides, [:base, :include_dirty])))
  end

  defp resolve_base(root, nil), do: detect_base(root)
  defp resolve_base(root, base), do: adjust_equals_head(base, root, [])

  @doc """
  Returns the current git branch name of the repository at `root`.

  Falls back to `"unknown"` if git is not available or the command fails.
  Returns `"HEAD"` in a detached checkout.

  ## Examples

      iex> is_binary(TinyCI.Context.branch())
      true
  """
  @spec branch(String.t()) :: String.t()
  def branch(root \\ File.cwd!()) do
    case git(root, ["rev-parse", "--abbrev-ref", "HEAD"]) do
      {:ok, branch} -> branch
      :error -> "unknown"
    end
  end

  @doc """
  Returns the current commit SHA (full 40-character hex string) at `root`.

  Falls back to `"unknown"` if git is not available or the command fails.

  ## Examples

      iex> sha = TinyCI.Context.commit()
      iex> is_binary(sha)
      true
  """
  @spec commit(String.t()) :: String.t()
  def commit(root \\ File.cwd!()) do
    case git(root, ["rev-parse", "HEAD"]) do
      {:ok, sha} -> sha
      :error -> "unknown"
    end
  end

  @doc """
  Returns the sorted, de-duplicated list of files changed at `root`.

  The list is the union of:

    * files changed between `merge-base(base, HEAD)` and `HEAD` — everything
      committed on this branch since it diverged from the base;
    * unstaged edits, staged changes, and untracked files that are not ignored
      (skipped with `include_dirty: false`).

  Renames contribute both the old and the new path. Paths are relative to the
  repository root and are read NUL-separated, so spaces survive.

  ## Options

    * `:base`          — ref or SHA to diff against; `nil` means the empty tree
      (every tracked file counts). Defaults to `detect_base/2`.
    * `:include_dirty` — include uncommitted changes (default `true`)
    * `:git_env`       — extra environment for the git processes, e.g.
      `[{"GIT_CEILING_DIRECTORIES", dir}]`

  Returns `[]` when `root` is not inside a git repository or git is missing.

  ## Examples

      iex> is_list(TinyCI.Context.changed_files())
      true
  """
  @spec changed_files(String.t(), keyword()) :: [String.t()]
  def changed_files(root \\ File.cwd!(), opts \\ []) do
    git_opts = Keyword.take(opts, [:git_env])

    base =
      if Keyword.has_key?(opts, :base),
        do: Keyword.fetch!(opts, :base),
        else: detect_base(root, git_opts)

    from = merge_base(root, base, git_opts) || @empty_tree
    committed = git_paths(root, ["diff", "--name-only", "-z", from, "HEAD"], git_opts)

    dirty =
      if Keyword.get(opts, :include_dirty, true),
        do: dirty_paths(root, git_opts),
        else: []

    (committed ++ dirty)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp dirty_paths(root, git_opts) do
    git_paths(root, ["diff", "--name-only", "-z"], git_opts) ++
      git_paths(root, ["diff", "--name-only", "-z", "--cached"], git_opts) ++
      git_paths(root, ["ls-files", "--others", "--exclude-standard", "-z"], git_opts)
  end

  defp git_paths(root, args, git_opts) do
    case git(root, args, git_opts) do
      {:ok, output} -> String.split(output, <<0>>, trim: true)
      :error -> []
    end
  end

  @doc """
  Finds the ref `changed_files/2` should diff against for the repository at `root`.

  The first of these that resolves to a commit wins:

    1. `TINY_CI_BASE_REF`, when set and non-empty
    2. `@{upstream}` — the current branch's tracking ref
    3. the remote's default branch (`refs/remotes/origin/HEAD`)
    4. the first existing of `origin/main`, `origin/master`, `main`, `master`
    5. `HEAD~1`

  Returns `nil` when none resolves (an initial commit with no remote); callers
  then diff against the empty tree so every tracked file counts as changed.

  **Equals-HEAD rule:** if the resolved base is the same commit as `HEAD` (you
  are on `main` with everything pushed, or picked `main` while on `main`), the
  base falls back to `HEAD~1` when that exists. Without this, a clean tree on the
  base branch would report nothing changed and skip every `file_changed?` stage.

  ## Options

    * `:env`     — a map to read `TINY_CI_BASE_REF` from instead of the process
      environment (for tests)
    * `:git_env` — extra environment for the git processes
  """
  @spec detect_base(String.t(), keyword()) :: String.t() | nil
  def detect_base(root, opts \\ []) do
    git_opts = Keyword.take(opts, [:git_env])

    [env_ref(opts), :upstream, :remote_default, "origin/main", "origin/master", "main", "master"]
    |> Enum.find_value(&resolve_candidate(root, &1, git_opts))
    |> adjust_equals_head(root, git_opts)
  end

  defp env_ref(opts) do
    case Keyword.fetch(opts, :env) do
      {:ok, env} -> Map.get(env, @base_env_var)
      :error -> System.get_env(@base_env_var)
    end
  end

  defp resolve_candidate(_root, nil, _git_opts), do: nil
  defp resolve_candidate(_root, "", _git_opts), do: nil

  defp resolve_candidate(root, :upstream, git_opts) do
    case git(root, ["rev-parse", "--abbrev-ref", "@{upstream}"], git_opts) do
      {:ok, name} -> resolve_candidate(root, name, git_opts)
      :error -> nil
    end
  end

  defp resolve_candidate(root, :remote_default, git_opts) do
    case git(root, ["symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"], git_opts) do
      {:ok, "refs/remotes/" <> name} -> resolve_candidate(root, name, git_opts)
      _ -> nil
    end
  end

  defp resolve_candidate(root, ref, git_opts) when is_binary(ref) do
    if commit?(root, ref, git_opts), do: ref, else: nil
  end

  # An explicit or detected base is dropped when it does not name a commit, so
  # a typo in `--base` reads as "no base" rather than crashing the run.
  defp adjust_equals_head(nil, root, git_opts), do: head_parent(root, git_opts)

  defp adjust_equals_head(base, root, git_opts) do
    cond do
      not commit?(root, base, git_opts) -> head_parent(root, git_opts)
      rev(root, base, git_opts) == rev(root, "HEAD", git_opts) -> head_parent(root, git_opts)
      true -> base
    end
  end

  defp head_parent(root, git_opts) do
    if commit?(root, "HEAD~1", git_opts), do: "HEAD~1", else: nil
  end

  defp commit?(root, ref, git_opts) do
    match?(
      {:ok, _},
      git(root, ["rev-parse", "--verify", "--quiet", ref <> "^{commit}"], git_opts)
    )
  end

  defp rev(root, ref, git_opts) do
    case git(root, ["rev-parse", "--verify", "--quiet", ref <> "^{commit}"], git_opts) do
      {:ok, sha} -> sha
      :error -> nil
    end
  end

  @doc """
  Returns the SHA of the merge base of `base` and `HEAD` at `root`.

  A `nil` base yields the empty tree's hash; a base that cannot be resolved
  yields `nil`.
  """
  @spec merge_base(String.t(), String.t() | nil, keyword()) :: String.t() | nil
  def merge_base(root, base, opts \\ [])
  def merge_base(_root, nil, _opts), do: @empty_tree

  def merge_base(root, base, opts) do
    case git(root, ["merge-base", base, "HEAD"], Keyword.take(opts, [:git_env])) do
      {:ok, sha} -> sha
      :error -> nil
    end
  end

  @doc """
  Returns `true` if any file in `files` matches the given glob `pattern`.

  Supports `*` (matches within a single directory) and `**` (matches across
  directory boundaries). Used by the `file_changed?/1` condition.

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

  # Every git invocation goes through here so it always runs in `root`. A
  # missing `git` binary or a missing `root` is an `:error`, not a crash.
  defp git(root, args, opts \\ []) do
    cmd_opts = [cd: root, stderr_to_stdout: true, env: Keyword.get(opts, :git_env, [])]

    case System.cmd("git", args, cmd_opts) do
      {output, 0} -> {:ok, String.trim(output)}
      _ -> :error
    end
  rescue
    ErlangError -> :error
  end
end
