defmodule TinyCI.Executor.EnvTest do
  use ExUnit.Case, async: true

  alias TinyCI.Executor.Env

  doctest TinyCI.Executor.Env

  describe "base/1" do
    test "merges stage env over pipeline env" do
      ctx = %{pipeline_env: %{"A" => "pipeline", "B" => "pipeline"}, stage_env: %{"B" => "stage"}}
      assert Env.base(ctx) == %{"A" => "pipeline", "B" => "stage"}
    end

    test "tolerates a context with neither layer" do
      assert Env.base(%{}) == %{}
    end
  end

  describe "resolve/2" do
    test "layers pipeline, stage, and step env with the step winning" do
      ctx = %{
        pipeline_env: %{"V" => "pipeline"},
        stage_env: %{"V" => "stage"},
        store: %{}
      }

      assert Env.resolve(ctx, %{"V" => "step"}) == %{"V" => "step"}
    end

    test "resolves store references against the current store" do
      ctx = %{store: %{sha: "abc123"}}
      assert Env.resolve(ctx, %{"SHA" => {:store, :sha}}) == %{"SHA" => "abc123"}
    end

    test "stringifies non-binary store values" do
      ctx = %{store: %{count: 7}}
      assert Env.resolve(ctx, %{"COUNT" => {:store, :count}}) == %{"COUNT" => "7"}
    end

    test "a nil step env leaves the base env untouched" do
      ctx = %{pipeline_env: %{"A" => "1"}, store: %{}}
      assert Env.resolve(ctx, nil) == %{"A" => "1"}
    end

    test "an empty step env leaves the base env untouched" do
      ctx = %{pipeline_env: %{"A" => "1"}, store: %{}}
      assert Env.resolve(ctx, %{}) == %{"A" => "1"}
    end
  end

  describe "resolve_store_refs/2" do
    test "leaves plain values alone" do
      assert Env.resolve_store_refs(%{"A" => "1"}, %{}) == %{"A" => "1"}
    end

    test "an unset store key becomes an empty string, like an unset shell variable" do
      assert Env.resolve_store_refs(%{"A" => {:store, :nope}}, %{}) == %{"A" => ""}
    end
  end
end
