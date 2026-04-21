defmodule TinyCI.DSL.ValidatorTest do
  use ExUnit.Case, async: true

  alias TinyCI.DSL.Validator

  defp parse!(source), do: Code.string_to_quoted!(source)
  defp validate(source), do: source |> parse!() |> Validator.validate()

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
end
