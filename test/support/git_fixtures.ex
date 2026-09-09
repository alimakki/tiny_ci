defmodule TinyCI.GitFixtures do
  @moduledoc """
  Builds throwaway git repositories for tests that need real history.

  Every git call carries its own identity and disables commit signing, so the
  fixtures never depend on, or mutate, the developer's global git config.
  """

  @config ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]

  @doc "Runs `git` with `args` in `dir`; raises on a non-zero exit. Returns trimmed stdout."
  @spec git!(String.t(), [String.t()]) :: String.t()
  def git!(dir, args) do
    case System.cmd("git", @config ++ args, cd: dir, stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {out, status} -> raise "git #{Enum.join(args, " ")} exited #{status} in #{dir}: #{out}"
    end
  end

  @doc "Initialises an empty repository on branch `main` in `dir` and returns `dir`."
  @spec init_repo(String.t()) :: String.t()
  def init_repo(dir) do
    File.mkdir_p!(dir)
    git!(dir, ["init", "-q", "-b", "main"])
    dir
  end

  @doc """
  Writes `files` (`%{"path" => "content"}`), stages everything, commits, and
  returns the new commit's SHA.
  """
  @spec commit(String.t(), %{String.t() => String.t()}, String.t()) :: String.t()
  def commit(dir, files, msg \\ "c") do
    write_files(dir, files)
    git!(dir, ["add", "-A"])
    git!(dir, ["commit", "-q", "-m", msg])
    git!(dir, ["rev-parse", "HEAD"])
  end

  @doc "Writes `files` into `dir` without staging them."
  @spec write_files(String.t(), %{String.t() => String.t()}) :: :ok
  def write_files(dir, files) do
    Enum.each(files, fn {path, content} ->
      full = Path.join(dir, path)
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
    end)
  end

  @doc "Clones `src` (a repository or bare repository) into `dest` and returns `dest`."
  @spec clone(String.t(), String.t()) :: String.t()
  def clone(src, dest) do
    File.mkdir_p!(Path.dirname(dest))
    git!(Path.dirname(dest), ["clone", "-q", src, dest])
    dest
  end

  @doc "Creates a bare clone of `src` at `dest` (an `origin` for upstream tests)."
  @spec bare_clone(String.t(), String.t()) :: String.t()
  def bare_clone(src, dest) do
    File.mkdir_p!(Path.dirname(dest))
    git!(Path.dirname(dest), ["clone", "-q", "--bare", src, dest])
    dest
  end
end
