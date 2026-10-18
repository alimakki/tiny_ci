defmodule TinyCI.SecretsTest do
  use ExUnit.Case, async: true

  alias TinyCI.Secrets

  doctest Secrets

  describe "parse_file/1" do
    test "parses KEY=value lines" do
      assert {:ok, %{"A" => "1", "B" => "two"}} = Secrets.parse_file("A=1\nB=two\n")
    end

    test "ignores blank lines and comment lines" do
      assert {:ok, %{"A" => "1"}} =
               Secrets.parse_file("\n# comment\n   # indented comment\nA=1\n\n")
    end

    test "strips a leading export" do
      assert {:ok, %{"TOKEN" => "abcd"}} = Secrets.parse_file("export TOKEN=abcd\n")
    end

    test "strips single or double quotes around the value" do
      assert {:ok, %{"A" => "with space", "B" => "x=y", "C" => "#notacomment"}} =
               Secrets.parse_file(~s|A="with space"\nB='x=y'\nC=#notacomment\n|)
    end

    test "keeps everything after the first =" do
      assert {:ok, %{"URL" => "https://h/?a=1&b=2"}} =
               Secrets.parse_file("URL=https://h/?a=1&b=2")
    end

    test "reports a line without = as a parse error with its line number" do
      assert {:error, {:line, 3, "expected KEY=value"}} =
               Secrets.parse_file("A=1\n\nnot a pair\n")
    end
  end

  describe "resolve/2" do
    @tag :tmp_dir
    test "provider wins over env, env wins over file", %{tmp_dir: root} do
      File.mkdir_p!(Path.join(root, ".tiny_ci"))
      File.write!(Path.join(root, ".tiny_ci/secrets"), "A=file\nB=file\nC=file\n")

      assert {:ok, %{"A" => "provider", "B" => "env", "C" => "file"}} =
               Secrets.resolve(["A", "B", "C"],
                 root: root,
                 provider: %{"A" => "provider"},
                 env: %{"A" => "env", "B" => "env"}
               )
    end

    @tag :tmp_dir
    test "a missing file is not an error", %{tmp_dir: root} do
      assert {:ok, %{"A" => "env"}} = Secrets.resolve(["A"], root: root, env: %{"A" => "env"})
    end

    @tag :tmp_dir
    test "reports missing names in declaration order", %{tmp_dir: root} do
      assert {:error, {:missing_secrets, ["Z", "A"]}} =
               Secrets.resolve(["Z", "B", "A"], root: root, env: %{"B" => "1"})
    end

    @tag :tmp_dir
    test "a malformed file is reported with its line", %{tmp_dir: root} do
      File.mkdir_p!(Path.join(root, ".tiny_ci"))
      File.write!(Path.join(root, ".tiny_ci/secrets"), "garbage\n")

      assert {:error, {:secrets_file, _path, {:line, 1, _}}} =
               Secrets.resolve(["A"], root: root, env: %{})
    end

    @tag :tmp_dir
    test "refuses a symlinked secrets file when allow_symlink is false", %{tmp_dir: root} do
      File.mkdir_p!(Path.join(root, ".tiny_ci"))

      outside =
        Path.join(Path.dirname(root), "outside-secrets-#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.dirname(outside))
      File.write!(outside, "TOKEN=leaked\n")
      on_exit(fn -> File.rm_rf(outside) end)
      File.ln_s!(outside, Path.join(root, ".tiny_ci/secrets"))

      assert {:error, {:secrets_file, _path, :symlink}} =
               Secrets.resolve(["TOKEN"], root: root, env: %{}, allow_symlink: false)

      assert {:ok, %{"TOKEN" => "leaked"}} =
               Secrets.resolve(["TOKEN"], root: root, env: %{}, allow_symlink: true)
    end

    @tag :tmp_dir
    test "refuses a symlinked parent directory when allow_symlink is false", %{tmp_dir: root} do
      outside = Path.join(Path.dirname(root), "outside-#{System.unique_integer([:positive])}")
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secrets"), "TOKEN=leaked\n")
      on_exit(fn -> File.rm_rf(outside) end)
      File.ln_s!(outside, Path.join(root, ".tiny_ci"))

      assert {:error, {:secrets_file, _path, :symlink}} =
               Secrets.resolve(["TOKEN"], root: root, env: %{}, allow_symlink: false)
    end

    test "no declared secrets resolves to an empty map without touching anything" do
      assert {:ok, %{}} = Secrets.resolve([], root: "/nonexistent", env: %{})
    end
  end

  describe "values/1" do
    test "returns unique values, dropping blanks and values shorter than 4 bytes" do
      secrets = %{"A" => "abcd", "B" => "abcd", "C" => "", "D" => "abc", "E" => "efghi"}
      assert Enum.sort(Secrets.values(secrets)) == ["abcd", "efghi"]
    end
  end
end
