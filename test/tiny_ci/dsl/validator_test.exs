defmodule TinyCI.DSL.ValidatorTest do
  use ExUnit.Case, async: true

  alias TinyCI.DSL.{Diagnostic, Validator}

  defp parse!(source), do: Code.string_to_quoted!(source)
  defp validate(source), do: source |> parse!() |> Validator.validate()

  defp diagnostics(source) do
    source
    |> Code.string_to_quoted!(columns: true)
    |> Validator.diagnostics()
  end

  describe "valid pipelines" do
    test "minimal pipeline with one stage and one step" do
      assert :ok =
               validate("""
               stage :test do
                 step :unit, cmd: "mix test"
               end
               """)
    end

    test "name directive" do
      assert :ok =
               validate("""
               name :my_pipeline

               stage :test do
                 step :unit, cmd: "mix test"
               end
               """)
    end

    test "parallel and serial modes" do
      assert :ok =
               validate("""
               stage :test, mode: :parallel do
                 step :unit, cmd: "mix test"
               end

               stage :deploy, mode: :serial do
                 step :release, cmd: "make release"
               end
               """)
    end

    test "step with timeout and allow_failure" do
      assert :ok =
               validate("""
               stage :test do
                 step :flaky, cmd: "mix test", timeout: 5000, allow_failure: true
               end
               """)
    end

    test "step with env map" do
      assert :ok =
               validate("""
               stage :check do
                 step :env_test, cmd: "echo $FOO", env: %{"FOO" => "bar"}
               end
               """)
    end

    test "step with module and set block" do
      assert :ok =
               validate("""
               stage :deploy do
                 step :push, module: MyDeployer do
                   set :app, "my-app"
                   set :region, "us-east-1"
                 end
               end
               """)
    end

    test "on_success hook with cmd" do
      assert :ok =
               validate("""
               on_success :notify, cmd: "echo passed"

               stage :test do
                 step :unit, cmd: "mix test"
               end
               """)
    end

    test "on_failure hook with module and set block" do
      assert :ok =
               validate("""
               on_failure :alert, module: MyAlerter do
                 set :severity, "critical"
               end

               stage :test do
                 step :unit, cmd: "mix test"
               end
               """)
    end

    test "when condition with branch equality" do
      assert :ok =
               validate("""
               stage :deploy, when: branch() == "main" do
                 step :release, cmd: "make release"
               end
               """)
    end

    test "when condition with env check" do
      assert :ok =
               validate("""
               stage :deploy, when: env("CI") != nil do
                 step :release, cmd: "make release"
               end
               """)
    end

    test "when condition with file_changed?" do
      assert :ok =
               validate("""
               stage :test, when: file_changed?("lib/**/*.ex") do
                 step :unit, cmd: "mix test"
               end
               """)
    end

    test "when condition with and combinator" do
      assert :ok =
               validate("""
               stage :deploy, when: branch() == "main" and env("CI") != nil do
                 step :release, cmd: "make release"
               end
               """)
    end

    test "when condition with or combinator" do
      assert :ok =
               validate("""
               stage :test, when: file_changed?("lib/**") or file_changed?("test/**") do
                 step :unit, cmd: "mix test"
               end
               """)
    end

    test "when condition with not" do
      assert :ok =
               validate("""
               stage :deploy, when: not (branch() == "main") do
                 step :skip, cmd: "echo skipping"
               end
               """)
    end

    test "when condition with if expression" do
      assert :ok =
               validate("""
               stage :deploy, when: if(branch() == "main", do: true, else: false) do
                 step :release, cmd: "make release"
               end
               """)
    end
  end

  describe "rejected top-level constructs" do
    test "rejects defmodule with a descriptive message" do
      assert {:error, [msg]} =
               validate("""
               defmodule MyPipeline do
                 stage :test do
                   step :unit, cmd: "mix test"
                 end
               end
               """)

      assert msg =~ "defmodule"
      assert msg =~ "Remove the module wrapper"
    end

    test "rejects unknown top-level expressions" do
      assert {:error, [msg]} =
               validate("""
               IO.puts("hello")
               """)

      assert msg =~ "Unexpected top-level expression"
    end

    test "rejects top-level variable binding" do
      assert {:error, _} =
               validate("""
               x = 42
               stage :test do
                 step :unit, cmd: "echo hi"
               end
               """)
    end
  end

  describe "rejected stage options" do
    test "rejects unknown stage option" do
      assert {:error, [msg]} =
               validate("""
               stage :test, unknown_opt: true do
                 step :unit, cmd: "mix test"
               end
               """)

      assert msg =~ "Unknown stage option"
    end

    test "rejects invalid mode value" do
      assert {:error, [msg]} =
               validate("""
               stage :test, mode: :concurrent do
                 step :unit, cmd: "mix test"
               end
               """)

      assert msg =~ ":mode"
    end
  end

  describe "rejected condition expressions" do
    test "rejects System.get_env in when condition" do
      assert {:error, [msg]} =
               validate("""
               stage :deploy, when: System.get_env("SECRET") == "yes" do
                 step :release, cmd: "make release"
               end
               """)

      assert msg =~ "Invalid condition expression"
    end

    test "rejects arbitrary function calls in when condition" do
      assert {:error, [msg]} =
               validate("""
               stage :deploy, when: File.exists?("/etc/secret") do
                 step :release, cmd: "make release"
               end
               """)

      assert msg =~ "Invalid condition expression"
    end
  end

  describe "rejected step options" do
    test "rejects non-string cmd" do
      assert {:error, [msg]} =
               validate("""
               stage :test do
                 step :unit, cmd: :not_a_string
               end
               """)

      assert msg =~ ":cmd"
    end

    test "rejects non-integer timeout" do
      assert {:error, [msg]} =
               validate("""
               stage :test do
                 step :unit, cmd: "mix test", timeout: "five_seconds"
               end
               """)

      assert msg =~ ":timeout"
    end

    test "rejects unknown step option" do
      assert {:error, [msg]} =
               validate("""
               stage :test do
                 step :unit, cmd: "mix test", foo: "bar"
               end
               """)

      assert msg =~ "Unknown step option"
    end

    test "rejects non-map env" do
      assert {:error, _} =
               validate("""
               stage :test do
                 step :unit, cmd: "mix test", env: "FOO=bar"
               end
               """)
    end
  end

  describe "rejected stage body" do
    test "rejects arbitrary expressions in stage block" do
      assert {:error, [msg]} =
               validate("""
               stage :test do
                 IO.puts("bad")
               end
               """)

      assert msg =~ "Unexpected expression in stage body"
    end
  end

  describe "rejected step body" do
    test "rejects arbitrary expressions in step block" do
      assert {:error, [msg]} =
               validate("""
               stage :deploy do
                 step :push, module: MyMod do
                   IO.puts("bad")
                 end
               end
               """)

      assert msg =~ "Unexpected expression in step block"
    end
  end

  describe "cache option on step" do
    test "accepts valid cache spec" do
      assert :ok =
               validate("""
               stage :install do
                 step :deps, cmd: "mix deps.get", cache: [paths: ["deps", "_build"], key: "mix.lock"]
               end
               """)
    end

    test "accepts cache with single path" do
      assert :ok =
               validate("""
               stage :install do
                 step :deps, cmd: "mix deps.get", cache: [paths: ["deps"], key: "mix.lock"]
               end
               """)
    end

    test "rejects cache with non-list paths" do
      assert {:error, violations} =
               validate("""
               stage :install do
                 step :deps, cmd: "mix deps.get", cache: [paths: "deps", key: "mix.lock"]
               end
               """)

      assert Enum.any?(violations, &String.contains?(&1, "paths"))
    end

    test "rejects cache with non-string path entries" do
      assert {:error, violations} =
               validate("""
               stage :install do
                 step :deps, cmd: "mix deps.get", cache: [paths: [:deps], key: "mix.lock"]
               end
               """)

      assert Enum.any?(violations, &String.contains?(&1, "paths"))
    end

    test "rejects cache with non-string key" do
      assert {:error, violations} =
               validate("""
               stage :install do
                 step :deps, cmd: "mix deps.get", cache: [paths: ["deps"], key: :mix_lock]
               end
               """)

      assert Enum.any?(violations, &String.contains?(&1, "key"))
    end

    test "rejects cache that is not a keyword list" do
      assert {:error, violations} =
               validate("""
               stage :install do
                 step :deps, cmd: "mix deps.get", cache: "mix.lock"
               end
               """)

      assert Enum.any?(violations, &String.contains?(&1, "cache"))
    end
  end

  describe "artifact option on step" do
    test "accepts valid artifact spec with name and paths" do
      assert :ok =
               validate("""
               stage :build do
                 step :compile, cmd: "mix release", artifact: [name: "release", paths: ["_build/prod/rel"]]
               end
               """)
    end

    test "accepts artifact spec with required: true" do
      assert :ok =
               validate("""
               stage :build do
                 step :compile, cmd: "mix release", artifact: [name: "build", paths: ["_build"], required: true]
               end
               """)
    end

    test "accepts artifact spec with required: false" do
      assert :ok =
               validate("""
               stage :build do
                 step :compile, cmd: "mix release", artifact: [name: "build", paths: ["_build"], required: false]
               end
               """)
    end

    test "rejects artifact with non-string name" do
      assert {:error, violations} =
               validate("""
               stage :build do
                 step :compile, cmd: "mix release", artifact: [name: :build, paths: ["_build"]]
               end
               """)

      assert Enum.any?(violations, &String.contains?(&1, "name"))
    end

    test "rejects artifact with non-list paths" do
      assert {:error, violations} =
               validate("""
               stage :build do
                 step :compile, cmd: "mix release", artifact: [name: "build", paths: "_build"]
               end
               """)

      assert Enum.any?(violations, &String.contains?(&1, "paths"))
    end

    test "rejects artifact with non-string path entries" do
      assert {:error, violations} =
               validate("""
               stage :build do
                 step :compile, cmd: "mix release", artifact: [name: "build", paths: [:_build]]
               end
               """)

      assert Enum.any?(violations, &String.contains?(&1, "paths"))
    end

    test "rejects artifact with non-boolean required" do
      assert {:error, violations} =
               validate("""
               stage :build do
                 step :compile, cmd: "mix release", artifact: [name: "build", paths: ["_build"], required: :yes]
               end
               """)

      assert Enum.any?(violations, &String.contains?(&1, "required"))
    end

    test "rejects artifact that is not a keyword list" do
      assert {:error, violations} =
               validate("""
               stage :build do
                 step :compile, cmd: "mix release", artifact: "build"
               end
               """)

      assert Enum.any?(violations, &String.contains?(&1, "artifact"))
    end
  end

  describe "multiple violations" do
    test "returns all violations at once" do
      assert {:error, violations} =
               validate("""
               stage :test, mode: :concurrent do
                 step :unit, cmd: :not_a_string
                 IO.puts("bad")
               end
               """)

      assert length(violations) >= 2
    end
  end

  describe "diagnostics/1" do
    test "returns an empty list for a valid pipeline" do
      assert [] =
               diagnostics("""
               stage :test do
                 step :unit, cmd: "mix test"
               end
               """)
    end

    test "returns Diagnostic structs carrying the violation message" do
      assert [%Diagnostic{message: msg, severity: :error}] =
               diagnostics("""
               stage :test, unknown_opt: true do
                 step :unit, cmd: "mix test"
               end
               """)

      assert msg =~ "Unknown stage option"
    end

    test "points a disallowed condition construct at its source column" do
      assert [%Diagnostic{line: 1, column: col, message: msg}] =
               diagnostics(~S"""
               stage :deploy, when: dangerous() == 0 do
                 step :release, cmd: "make release"
               end
               """)

      assert msg =~ "Invalid condition expression"
      # `dangerous()` begins right after `when: ` on the first line.
      assert col == 22
    end

    test "points an unknown step option at the offending step line" do
      assert [%Diagnostic{line: 3, message: msg}] =
               diagnostics("""
               stage :test do
                 step :unit, cmd: "mix test"
                 step :lint, bogus: true
               end
               """)

      assert msg =~ "Unknown step option"
    end

    test "reports every violation with its own span" do
      diags =
        diagnostics("""
        stage :test, mode: :concurrent do
          step :unit, cmd: :not_a_string
        end
        """)

      assert length(diags) == 2
      assert Enum.all?(diags, &match?(%Diagnostic{}, &1))
      lines = Enum.map(diags, & &1.line)
      assert 1 in lines
      assert 2 in lines
    end
  end
end
