defmodule TinyCI.Execution.Paths do
  @moduledoc """
  Lexical and symlink-aware containment checks for untrusted runs.

  A lexical `Path.expand/2` check is not enough: a repository can contain a
  symlink (`link -> /`) and a path like `link/etc/passwd` looks inside the
  workspace while resolving to a host path outside it. This module resolves the
  existing components of a path and compares the result with the resolved project
  root. Components that do not exist yet are appended lexically; `..` is rejected
  outright so the check cannot be fooled by lexical collapsing before symlink
  resolution.
  """

  @doc """
  Returns true when `path` resolves inside `root`.

  Both are absolute after resolution. Missing trailing components are allowed,
  so a step can name a directory it will create later.
  """
  @spec inside?(String.t(), String.t() | nil) :: boolean()
  def inside?(_root, nil), do: true

  def inside?(root, path) when is_binary(root) and is_binary(path) do
    if ".." in Path.split(path) do
      false
    else
      root = Path.expand(root)
      expanded = Path.expand(path, root)

      lexical_inside?(expanded, root) and
        real_inside?(realpath(expanded, 0), realpath(root, 0))
    end
  end

  def inside?(_root, _path), do: false

  defp lexical_inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp real_inside?(_path, "/"), do: true
  defp real_inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  # Resolve every existing path component, following symlinks (including
  # relative targets) while leaving missing trailing components in place. `..`
  # is applied to the *resolved* accumulator, matching the OS rather than
  # collapsing it lexically before a symlink is followed.
  defp realpath(_path, hops) when hops > 40, do: "/__tiny_ci_symlink_loop__"

  defp realpath(path, hops) do
    path
    |> Path.split()
    |> Enum.reduce("", fn
      "/", "" -> "/"
      ".", acc -> acc
      "..", acc -> Path.dirname(acc)
      part, acc -> resolve_component(Path.join(acc, part), hops)
    end)
  end

  defp resolve_component(path, hops) do
    case :file.read_link_all(String.to_charlist(path)) do
      {:ok, target} -> resolve_target(path, List.to_string(target), hops + 1)
      {:error, _} -> path
    end
  end

  defp resolve_target(path, "", _hops) do
    path
  end

  defp resolve_target(path, target, hops) do
    resolved =
      if Path.type(target) == :absolute, do: target, else: Path.join(Path.dirname(path), target)

    realpath(resolved, hops)
  end
end
