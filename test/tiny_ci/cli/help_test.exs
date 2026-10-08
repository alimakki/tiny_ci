defmodule TinyCI.CLI.HelpTest do
  # The help text is the single source for `tiny_ci help <cmd>` and `mix help tiny_ci.<cmd>`,
  # so its layout is checked in both command forms. Markdown renders a bullet indented
  # differently from its siblings as a nested list.
  use ExUnit.Case, async: true

  alias TinyCI.CLI.{Cache, Run, Runs}

  @forms [
    {Run, ["tiny_ci run", "mix tiny_ci.run"]},
    {Runs, ["tiny_ci runs", "mix tiny_ci.runs"]},
    {Cache, ["tiny_ci cache", "mix tiny_ci.cache"]}
  ]

  defp bullet_indents(help) do
    ~r/^( *)\* /m |> Regex.scan(help) |> Enum.map(fn [_, indent] -> String.length(indent) end)
  end

  for {module, commands} <- @forms, command <- commands do
    test "#{command}: every bullet has the same indentation" do
      indents = bullet_indents(unquote(module).help(unquote(command)))

      assert indents != []
      assert indents |> Enum.uniq() |> length() == 1, "bullet indents differ: #{inspect(indents)}"
    end
  end

  for command <- ["tiny_ci run", "mix tiny_ci.run"] do
    test "#{command}: the exit codes section documents 0, 1 and 2" do
      help = Run.help(unquote(command))
      [_before, section] = String.split(help, "## Exit Codes")

      assert section =~ ~r/^ *\* `0`/m
      assert section =~ ~r/^ *\* `1`/m
      assert section =~ ~r/^ *\* `2` — usage error/m
    end
  end

  test "the standalone exit-2 text names exactly what exits 2, and what exits 1 instead" do
    [_before, section] = String.split(Run.help("tiny_ci run"), "## Exit Codes")
    section = section |> String.replace("`", "") |> String.replace(~r/\s+/, " ")

    assert section =~ "unknown flag"
    assert section =~ "wrong type"
    assert section =~ "--break-timeout abc"
    assert section =~ "--events - together with --output json"
    assert section =~ "failed run and exit 1"
    refute section =~ "invalid option"
    refute section =~ "mix tiny_ci"
  end

  test "the Mix exit-2 text says every one of those is a Mix error with exit 1" do
    [_before, section] = String.split(Run.help("mix tiny_ci.run"), "## Exit Codes")
    section = section |> String.replace("`", "") |> String.replace(~r/\s+/, " ")

    assert section =~ "raises a Mix error (exit 1)"
    assert section =~ "standalone tiny_ci run exits 2"
  end
end
