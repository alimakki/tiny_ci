defmodule TinyCI.DSL.ValueTest do
  use ExUnit.Case, async: true

  alias TinyCI.DSL.{Interpreter, Value}

  doctest Value

  defmodule Action do
    @moduledoc false
    def execute(_config, _ctx), do: :ok
    def run(_config, _ctx), do: :ok
  end

  defp configs(body) do
    source = """
    stage :build do
      step :build, module: #{inspect(Action)} do
        #{body}
      end
    end
    on_success :notify, module: #{inspect(Action)} do
      #{body}
    end
    """

    assert {:ok, spec} = Interpreter.interpret_string(source, "values.exs")
    [stage] = spec.stages
    [step] = stage.steps
    [hook] = spec.hooks.on_success

    for runnable <- [step, hook] do
      assert is_function(runnable.config_block, 0)
      runnable.config_block.()
    end
  end

  describe "config normalization" do
    test "steps and hooks receive recursive literal values rather than AST" do
      for config <-
            configs("""
            set :options, %{nested: [%{"tuple" => {:ok, %{count: -2}, [true, nil, 1.5]}}]}
            set :pair, {:literal, [answer: +42]}
            set :module, String
            set :empty, {{}, %{}, []}
            """) do
        assert config == [
                 options: %{nested: [%{"tuple" => {:ok, %{count: -2}, [true, nil, 1.5]}}]},
                 pair: {:literal, [answer: 42]},
                 module: String,
                 empty: {{}, %{}, []}
               ]
      end
    end

    for expression <- [
          "System.put_env(\"TINY_CI_UNSAFE_CONFIG\", \"bad\")",
          "1 + 2",
          "%{nested: [dangerous()]}",
          "{1, 2, File.read!(\"secret\")}",
          "%{dangerous() => :value}",
          "store(\"not_an_atom\")",
          "store(:key, :fallback)",
          "some_variable",
          "%{existing | value: 1}"
        ] do
      test "rejects unsupported config #{expression} in steps and hooks" do
        for directive <- ["step", "on_failure"] do
          body = """
          #{directive} :run, module: #{inspect(Action)} do
            set :options, #{unquote(expression)}
          end
          """

          source = if directive == "step", do: "stage :build do\n#{body}end", else: body

          assert {:error, {:validation_error, messages}} =
                   Interpreter.interpret_string(source, "unsafe.exs")

          assert Enum.any?(messages, &(&1 =~ "config value"))
          assert Enum.all?(Interpreter.diagnose_string(source), &(&1.severity == :error))
        end
      end
    end
  end

  describe "resolve/2" do
    test "resolves store references recursively using the current store for steps and hooks" do
      for config <-
            configs("""
            set :source, store(:artifact)
            set :options, %{nested: [{store(:key), [value: store(:payload)]}]}
            set :mapping, %{store(:key) => store(:payload)}
            """) do
        assert %{__struct__: TinyCI.DSL.Value.StoreRef, key: :artifact} = config[:source]

        for artifact <- ["first", "second"] do
          assert Value.resolve(config, %{artifact: artifact, key: :resolved, payload: %{ok: true}}) ==
                   [
                     source: artifact,
                     options: %{nested: [{:resolved, [value: %{ok: true}]}]},
                     mapping: %{resolved: %{ok: true}}
                   ]
        end
      end
    end

    test "literal store-shaped tuples and returned store data remain data" do
      for config <-
            configs("""
            set :literal, {:store, :missing}
            set :source, store(:data)
            """) do
        assert Value.resolve(config, %{data: {:store, :also_missing}}) ==
                 [literal: {:store, :missing}, source: {:store, :also_missing}]
      end
    end

    test "missing required references raise a clear error without exposing the store" do
      for config <- configs("set :nested, %{source: store(:missing)}") do
        error =
          assert_raise ArgumentError, ~r/Required store key :missing/, fn ->
            Value.resolve(config, %{secret: "do-not-expose"})
          end

        refute Exception.message(error) =~ "do-not-expose"
      end
    end

    test "present nil and false store values are not missing" do
      for config <- configs("set :source, store(:value)") do
        assert Value.resolve(config, %{value: nil}) == [source: nil]
        assert Value.resolve(config, %{value: false}) == [source: false]
      end
    end
  end
end
