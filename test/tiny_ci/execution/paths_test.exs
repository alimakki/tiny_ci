defmodule TinyCI.Execution.PathsTest do
  use ExUnit.Case, async: true

  alias TinyCI.Execution.Paths

  @moduletag :tmp_dir

  test "accepts paths inside the root, including missing trailing components", %{tmp_dir: tmp} do
    root = Path.join(tmp, "repo")
    File.mkdir_p!(root)

    assert Paths.inside?(root, root)
    assert Paths.inside?(root, Path.join(root, "apps/web"))
    assert Paths.inside?(root, "apps/web")
    assert Paths.inside?(root, nil)
  end

  test "rejects lexical escapes", %{tmp_dir: tmp} do
    root = Path.join(tmp, "repo")
    File.mkdir_p!(root)

    refute Paths.inside?(root, "../outside")
    refute Paths.inside?(root, Path.join(tmp, "outside"))
  end

  test "rejects a symlink that points outside the root", %{tmp_dir: tmp} do
    root = Path.join(tmp, "repo")
    outside = Path.join(tmp, "outside")
    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(root, "link"))

    refute Paths.inside?(root, Path.join(root, "link/file"))
    refute Paths.inside?(root, "link/file")
  end

  test "does not hang on a symlink loop", %{tmp_dir: tmp} do
    root = Path.join(tmp, "repo")
    File.mkdir_p!(root)
    File.ln_s!("loop", Path.join(root, "loop"))

    refute Paths.inside?(root, "loop/x")
  end

  test "accepts a symlink that stays inside the root", %{tmp_dir: tmp} do
    root = Path.join(tmp, "repo")
    target = Path.join(root, "real")
    File.mkdir_p!(target)
    File.ln_s!(target, Path.join(root, "link"))

    assert Paths.inside?(root, Path.join(root, "link/file"))
  end
end
