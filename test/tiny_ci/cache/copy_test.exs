defmodule TinyCI.Cache.CopyTest do
  use ExUnit.Case, async: true

  alias TinyCI.Cache.Copy

  @moduletag :tmp_dir

  describe "copy_tree/2" do
    test "copies a nested tree and preserves a symlink as a link", %{tmp_dir: dir} do
      src = Path.join(dir, "src")
      dst = Path.join(dir, "dst")
      File.mkdir_p!(Path.join(src, "a/b"))
      File.write!(Path.join(src, "a/b/file.txt"), "content")
      File.write!(Path.join(src, "top.txt"), "top")
      File.ln_s!("a/b/file.txt", Path.join(src, "link"))

      assert :ok = Copy.copy_tree(src, dst)

      assert File.read!(Path.join(dst, "a/b/file.txt")) == "content"
      assert File.read!(Path.join(dst, "top.txt")) == "top"
      assert {:ok, "a/b/file.txt"} = File.read_link(Path.join(dst, "link"))
    end

    test "copies a single file", %{tmp_dir: dir} do
      src = Path.join(dir, "file.bin")
      dst = Path.join(dir, "nested/copy.bin")
      File.write!(src, <<0, 1, 2>>)

      assert :ok = Copy.copy_tree(src, dst)
      assert File.read!(dst) == <<0, 1, 2>>
    end

    test "returns an error for a missing source", %{tmp_dir: dir} do
      assert {:error, _} = Copy.copy_tree(Path.join(dir, "nope"), Path.join(dir, "dst"))
    end
  end
end
