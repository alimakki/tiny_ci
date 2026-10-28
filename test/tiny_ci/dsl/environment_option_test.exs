defmodule TinyCI.DSL.EnvironmentOptionTest do
  @moduledoc """
  `image` and `environment` at pipeline and stage level: the allowlist, the
  validator, and the interpreter's projection onto the spec/structs.
  """

  use ExUnit.Case, async: true

  alias TinyCI.DSL.{Interpreter, Spec, Validator}

  defp interpret(source) do
    Interpreter.interpret_string(source, "pipeline.exs")
  end

  defp stage_with(option) do
    """
    stage :build, #{option} do
      step :test, cmd: "true"
    end
    """
  end

  describe "Spec" do
    test "advertises image and environment as top-level directives" do
      assert %Spec.Entry{kind: :directive, contexts: [:top_level], type: "OCI image reference"} =
               Spec.lookup(:image, :top_level)

      assert %Spec.Entry{kind: :directive, contexts: [:top_level], type: "atom or string"} =
               Spec.lookup(:environment, :top_level)
    end

    test "advertises image and environment as stage options" do
      assert %Spec.Entry{kind: :option, contexts: [:stage], type: "OCI image reference"} =
               Spec.lookup(:image, :stage)

      assert %Spec.Entry{kind: :option, contexts: [:stage], type: "atom or string"} =
               Spec.lookup(:environment, :stage)
    end

    test "keeps image and environment out of step and hook options" do
      refute :image in Spec.option_keys(:step)
      refute :environment in Spec.option_keys(:step)
      refute :image in Spec.option_keys(:hook)
      refute :environment in Spec.option_keys(:hook)
    end
  end

  describe "Interpreter: pipeline scope" do
    test "puts image on the pipeline spec" do
      assert {:ok, %{image: "elixir:1.18", environment: nil}} =
               interpret("""
               image "elixir:1.18"

               stage :build do
                 step :test, cmd: "true"
               end
               """)
    end

    test "puts a string environment on the pipeline spec" do
      assert {:ok, %{environment: "ci", image: nil}} =
               interpret("""
               environment "ci"

               stage :build do
                 step :test, cmd: "true"
               end
               """)
    end

    test "normalizes an atom environment to a string" do
      assert {:ok, %{environment: "ci"}} =
               interpret("""
               environment :ci

               stage :build do
                 step :test, cmd: "true"
               end
               """)
    end

    test "defaults both to nil" do
      assert {:ok, %{image: nil, environment: nil}} =
               interpret("""
               stage :build do
                 step :test, cmd: "true"
               end
               """)
    end
  end

  describe "Interpreter: stage scope" do
    test "puts image on the stage" do
      assert {:ok, %{stages: [%{image: "alpine:3.22", environment: nil}]}} =
               interpret(stage_with(~s(image: "alpine:3.22")))
    end

    test "puts environment on the stage and normalizes atoms" do
      assert {:ok, %{stages: [%{environment: "ci", image: nil}]}} =
               interpret(stage_with("environment: :ci"))
    end

    test "defaults both to nil" do
      assert {:ok, %{stages: [%{image: nil, environment: nil}]}} =
               interpret(stage_with("mode: :serial"))
    end
  end

  describe "Validator: accepted forms" do
    test "accepts an image reference with a digest and a registry port" do
      ast =
        Code.string_to_quoted!("""
        image "registry.example:5000/acme/ci@sha256:#{String.duplicate("a", 64)}"

        stage :build, image: "alpine:3.22" do
          step :test, cmd: "true"
        end
        """)

      assert Validator.validate(ast) == :ok
    end

    test "accepts lowercase environment names with dots, dashes, and underscores" do
      for name <- ["ci", "a", "rust-1.80", "elixir.1", "ci_test"] do
        ast = Code.string_to_quoted!(stage_with(~s(environment: "#{name}")))
        assert Validator.validate(ast) == :ok, "expected #{inspect(name)} to be accepted"
      end
    end
  end

  describe "Validator: mutual exclusion" do
    test "rejects both image and environment at pipeline scope" do
      ast =
        Code.string_to_quoted!("""
        image "alpine:3.22"
        environment "ci"

        stage :build do
          step :test, cmd: "true"
        end
        """)

      assert {:error, messages} = Validator.validate(ast)
      assert Enum.any?(messages, &(&1 =~ "Only one of image or environment"))
    end

    test "rejects both image and environment on one stage" do
      ast =
        Code.string_to_quoted!(stage_with(~s(image: "alpine:3.22", environment: "ci")))

      assert {:error, messages} = Validator.validate(ast)
      assert Enum.any?(messages, &(&1 =~ "mutually exclusive"))
    end

    test "allows a stage declaration alongside a pipeline declaration" do
      ast =
        Code.string_to_quoted!("""
        image "alpine:3.22"

        stage :build, environment: "ci" do
          step :test, cmd: "true"
        end
        """)

      assert Validator.validate(ast) == :ok
    end
  end

  describe "Validator: duplicates" do
    test "rejects a second image directive even with a different reference" do
      ast =
        Code.string_to_quoted!("""
        image "alpine:3.22"
        image "elixir:1.18"

        stage :build do
          step :test, cmd: "true"
        end
        """)

      assert {:error, messages} = Validator.validate(ast)
      assert Enum.any?(messages, &(&1 =~ "Only one image directive"))
    end

    test "rejects a second environment directive" do
      ast =
        Code.string_to_quoted!("""
        environment "ci"
        environment "default"

        stage :build do
          step :test, cmd: "true"
        end
        """)

      assert {:error, messages} = Validator.validate(ast)
      assert Enum.any?(messages, &(&1 =~ "Only one environment directive"))
    end
  end

  describe "Validator: types and values" do
    test "rejects a non-string image" do
      ast = Code.string_to_quoted!("image :elixir")

      assert {:error, [message]} = Validator.validate(ast)
      assert message =~ "image expects a single OCI image reference string"
    end

    test "rejects an empty image reference" do
      ast = Code.string_to_quoted!(stage_with(~s(image: "")))
      assert {:error, [message]} = Validator.validate(ast)
      assert message =~ "non-empty OCI image reference"
    end

    test "rejects an image reference with whitespace" do
      ast = Code.string_to_quoted!(stage_with(~s(image: "alpine 3.22")))
      assert {:error, [message]} = Validator.validate(ast)
      assert message =~ "non-empty OCI image reference"
    end

    test "rejects an image reference that looks like a flag" do
      ast = Code.string_to_quoted!(stage_with(~s(image: "--privileged")))
      assert {:error, [message]} = Validator.validate(ast)
      assert message =~ "must not start with"
    end

    test "rejects a pipeline image that looks like a flag" do
      ast =
        Code.string_to_quoted!("""
        image "--privileged"

        stage :build do
          step :test, cmd: "true"
        end
        """)

      assert {:error, [message]} = Validator.validate(ast)
      assert message =~ "must not start with"
    end

    test "rejects a non-atom/non-string environment" do
      ast = Code.string_to_quoted!(stage_with("environment: 1"))
      assert {:error, [message]} = Validator.validate(ast)
      assert message =~ "must be an atom or string name"
    end

    test "rejects an environment name with uppercase letters" do
      ast = Code.string_to_quoted!(stage_with(~s(environment: "CI")))
      assert {:error, [message]} = Validator.validate(ast)
      assert message =~ "environment name must match"
    end

    test "rejects an environment name starting with a digit" do
      ast = Code.string_to_quoted!(stage_with(~s(environment: "1ci")))
      assert {:error, [message]} = Validator.validate(ast)
      assert message =~ "environment name must match"
    end

    test "rejects an environment name longer than 64 characters" do
      ast = Code.string_to_quoted!(stage_with(~s(environment: "#{String.duplicate("a", 65)}")))
      assert {:error, [message]} = Validator.validate(ast)
      assert message =~ "environment name must match"
    end

    test "rejects a top-level environment that is not a name" do
      ast =
        Code.string_to_quoted!("""
        environment 1

        stage :build do
          step :test, cmd: "true"
        end
        """)

      assert {:error, [message]} = Validator.validate(ast)
      assert message =~ "environment expects a single atom or string name"
    end
  end

  describe "Validator: scope" do
    test "rejects image on a step through the unknown-option path" do
      ast =
        Code.string_to_quoted!("""
        stage :build do
          step :test, cmd: "true", image: "alpine:3.22"
        end
        """)

      assert {:error, messages} = Validator.validate(ast)
      assert Enum.any?(messages, &(&1 =~ "Unknown step option: :image"))
    end

    test "rejects environment on a step through the unknown-option path" do
      ast =
        Code.string_to_quoted!("""
        stage :build do
          step :test, cmd: "true", environment: "ci"
        end
        """)

      assert {:error, messages} = Validator.validate(ast)
      assert Enum.any?(messages, &(&1 =~ "Unknown step option: :environment"))
    end

    test "rejects image on a hook through the unknown-option path" do
      ast = Code.string_to_quoted!("on_success :notify, cmd: \"true\", image: \"alpine:3.22\"")

      assert {:error, messages} = Validator.validate(ast)
      assert Enum.any?(messages, &(&1 =~ "Unknown hook option: :image"))
    end
  end

  describe "Interpreter: invalid declarations are validation errors" do
    test "both scopes together are rejected before interpretation" do
      assert {:error, {:validation_error, messages}} =
               interpret("""
               image "alpine:3.22"
               environment "ci"

               stage :build do
                 step :test, cmd: "true"
               end
               """)

      assert Enum.any?(messages, &(&1 =~ "environment"))
    end

    test "a bad stage image reference is rejected" do
      assert {:error, {:validation_error, messages}} =
               interpret(stage_with(~s(image: "--privileged")))

      assert Enum.any?(messages, &(&1 =~ "image"))
    end
  end
end
