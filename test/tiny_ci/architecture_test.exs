defmodule TinyCI.ArchitectureTest do
  @moduledoc """
  Guards the standalone-binary boundary: `lib/tiny_ci/**` must not call `Mix.`
  at runtime, so the escript works in a directory with no Mix project.

  `Mix.` may only appear in `lib/tiny_ci/project.ex`, behind the
  `Code.ensure_loaded?(Mix.Project)` / `Process.whereis(Mix.ProjectStack)` guard.
  Any other runtime reference — a new file, or a new line in a known file — fails
  here. Mix-dependent code belongs under `lib/mix/` (the Mix tasks and
  `TinyCI.MixDelegate`), which this test does not scan.
  """
  use ExUnit.Case, async: true

  @lib_reference "lib/tiny_ci"

  # The only file allowed to touch Mix, and the code lines (documentation and
  # comments are ignored) that do so. Every one goes through `mix_running?/0`.
  @allowed_file "lib/tiny_ci/project.ex"

  @allowed_code_lines [
    "if mix_running?(), do: Mix.Project.config()[:app]",
    "Code.ensure_loaded?(Mix.Project) and function_exported?(Mix.Project, :config, 0) and",
    "Process.whereis(Mix.ProjectStack) != nil"
  ]

  describe "lib/tiny_ci has no unguarded Mix reference" do
    test "only TinyCI.Project contains Mix." do
      assert mix_files() == [@allowed_file]
    end

    test "every Mix reference in TinyCI.Project is an allowlisted guarded line" do
      assert mix_lines(@allowed_file) == @allowed_code_lines
    end

    test "the guard the allowlist relies on is still present" do
      source = File.read!(@allowed_file)
      assert source =~ "defp mix_running?"
      assert source =~ "Code.ensure_loaded?(Mix.Project)"
      assert source =~ "Process.whereis(Mix.ProjectStack)"
    end
  end

  # Every `lib/tiny_ci/**/*.ex` file whose source references `Mix.`.
  defp mix_files do
    @lib_reference
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to_cwd/1)
    |> Enum.filter(fn rel -> mix_lines(rel) != [] end)
    |> Enum.sort()
  end

  # The code lines of `rel` (documentation/comments removed) that reference `Mix.`.
  defp mix_lines(rel) do
    rel
    |> File.read!()
    |> String.split("\n")
    |> strip_docs_and_comments()
    |> Enum.filter(&Regex.match?(~r/\bMix\./, &1))
  end

  # Drops whole-line comments and every `@moduledoc`/`@doc` line (heredoc or
  # single-line), so prose never has to update the allowlist. A heredoc opens on a
  # line with an odd number of `"""` and closes on the next `"""` line.
  defp strip_docs_and_comments(lines), do: do_strip(lines, false, [])

  defp do_strip([], _in_doc, acc), do: Enum.reverse(acc)

  defp do_strip([line | rest], in_doc, acc) do
    cond do
      in_doc ->
        do_strip(rest, in_doc_after(line, in_doc), acc)

      comment?(line) ->
        do_strip(rest, false, acc)

      doc_attr?(line) ->
        do_strip(rest, in_doc_after(line, in_doc), acc)

      true ->
        do_strip(rest, false, [String.trim(line) | acc])
    end
  end

  # Whether this line is the closing (or an inline) `"""` of a doc heredoc.
  defp in_doc_after(line, in_doc) do
    if odd_quotes?(line), do: not in_doc, else: in_doc
  end

  defp comment?(line), do: String.starts_with?(String.trim_leading(line), "#")

  # A `@moduledoc`/`@doc` attribute line, heredoc or single-line (`@doc "…"`).
  # Even a single-line doc is skipped, so a `Mix.` mention in prose never counts.
  defp doc_attr?(line) do
    Regex.match?(~r/^@(moduledoc|doc)\b/, String.trim_leading(line))
  end

  defp odd_quotes?(line) do
    line |> String.split("\"\"\"") |> length() |> rem(2) == 0
  end
end
