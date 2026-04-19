defmodule TinyCI.DSL.ConditionEvalTest do
  use ExUnit.Case, async: true

  alias TinyCI.DSL.ConditionEval

  @ctx %{
    branch: "main",
    changed_files: ["lib/app.ex", "README.md"],
    store: %{}
  }

  describe "branch/0" do
    test "returns the branch from context" do
      ast = quote do: branch()
      assert ConditionEval.eval(ast, @ctx) == "main"
    end

    test "returns unknown when branch key is absent" do
      ast = quote do: branch()
      assert ConditionEval.eval(ast, %{}) == "unknown"
    end
  end

  describe "env/1" do
    test "returns the env var value when set" do
      System.put_env("TINY_CI_COND_TEST", "yes")
      ast = quote do: env("TINY_CI_COND_TEST")
      assert ConditionEval.eval(ast, @ctx) == "yes"
    after
      System.delete_env("TINY_CI_COND_TEST")
    end

    test "returns nil when env var is not set" do
      System.delete_env("TINY_CI_COND_MISSING")
      ast = quote do: env("TINY_CI_COND_MISSING")
      assert ConditionEval.eval(ast, @ctx) == nil
    end
  end

  describe "file_changed?/1" do
    test "returns true when a changed file matches the glob" do
      ast = quote do: file_changed?("lib/**/*.ex")
      assert ConditionEval.eval(ast, @ctx) == true
    end

    test "returns false when no changed file matches the glob" do
      ast = quote do: file_changed?("test/**/*.exs")
      assert ConditionEval.eval(ast, @ctx) == false
    end

    test "returns false when changed_files is empty" do
      ast = quote do: file_changed?("lib/**/*.ex")
      assert ConditionEval.eval(ast, %{changed_files: []}) == false
    end
  end

  describe "== and !=" do
    test "== returns true for equal values" do
      ast = quote do: branch() == "main"
      assert ConditionEval.eval(ast, @ctx) == true
    end

    test "== returns false for unequal values" do
      ast = quote do: branch() == "develop"
      assert ConditionEval.eval(ast, @ctx) == false
    end

    test "!= returns true for unequal values" do
      ast = quote do: branch() != "develop"
      assert ConditionEval.eval(ast, @ctx) == true
    end

    test "!= returns false for equal values" do
      ast = quote do: branch() != "main"
      assert ConditionEval.eval(ast, @ctx) == false
    end
  end

  describe "and / or" do
    test "and returns true when both sides are true" do
      ast = quote do: branch() == "main" and file_changed?("lib/**/*.ex")
      assert ConditionEval.eval(ast, @ctx) == true
    end

    test "and returns false when one side is false" do
      ast = quote do: branch() == "main" and file_changed?("test/**/*.exs")
      assert ConditionEval.eval(ast, @ctx) == false
    end

    test "or returns true when one side is true" do
      ast = quote do: branch() == "develop" or file_changed?("lib/**/*.ex")
      assert ConditionEval.eval(ast, @ctx) == true
    end

    test "or returns false when both sides are false" do
      ast = quote do: branch() == "develop" or file_changed?("test/**/*.exs")
      assert ConditionEval.eval(ast, @ctx) == false
    end
  end

  describe "not" do
    test "not inverts a true condition" do
      ast = quote do: not (branch() == "main")
      assert ConditionEval.eval(ast, @ctx) == false
    end

    test "not inverts a false condition" do
      ast = quote do: not (branch() == "develop")
      assert ConditionEval.eval(ast, @ctx) == true
    end
  end

  describe "if expression" do
    test "evaluates then branch when condition is true" do
      ast = quote do: if(branch() == "main", do: true, else: false)
      assert ConditionEval.eval(ast, @ctx) == true
    end

    test "evaluates else branch when condition is false" do
      ast = quote do: if(branch() == "develop", do: true, else: false)
      assert ConditionEval.eval(ast, @ctx) == false
    end
  end

  describe "literals" do
    test "string literal evaluates to itself" do
      assert ConditionEval.eval("main", @ctx) == "main"
    end

    test "atom literal evaluates to itself" do
      assert ConditionEval.eval(:ok, @ctx) == :ok
    end

    test "boolean true evaluates to itself" do
      assert ConditionEval.eval(true, @ctx) == true
    end

    test "boolean false evaluates to itself" do
      assert ConditionEval.eval(false, @ctx) == false
    end

    test "nil evaluates to itself" do
      assert ConditionEval.eval(nil, @ctx) == nil
    end
  end

  describe "composed conditions" do
    test "branch check combined with env check" do
      System.put_env("TINY_CI_COND_DEPLOY", "1")
      ast = quote do: branch() == "main" and env("TINY_CI_COND_DEPLOY") != nil
      assert ConditionEval.eval(ast, @ctx) == true
    after
      System.delete_env("TINY_CI_COND_DEPLOY")
    end

    test "multiple file globs with or" do
      ast = quote do: file_changed?("lib/**") or file_changed?("test/**")
      assert ConditionEval.eval(ast, @ctx) == true
    end
  end

  describe "error handling" do
    test "raises ArgumentError for unknown AST nodes" do
      ast = {:unknown_node, [], []}

      assert_raise ArgumentError, ~r/unexpected AST node/i, fn ->
        ConditionEval.eval(ast, @ctx)
      end
    end
  end
end
