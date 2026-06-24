defmodule FlowImgA do
  @moduledoc false
  use TinyCI.Action
  @impl true
  def execute(_config, _ctx), do: {:ok, %{image_tag: "x"}}
  @impl true
  def metadata, do: %TinyCI.Action.Metadata{name: "img_a", outputs: [:image_tag]}
end

defmodule FlowImgB do
  @moduledoc false
  use TinyCI.Action
  @impl true
  def execute(_config, _ctx), do: {:ok, %{image_tag: "y"}}
  @impl true
  def metadata, do: %TinyCI.Action.Metadata{name: "img_b", outputs: [:image_tag]}
end

defmodule FlowNoMeta do
  @moduledoc false
  def execute(_config, _ctx), do: :ok
end

defmodule TinyCI.DSL.FlowAnalysisTest do
  use ExUnit.Case, async: true

  alias TinyCI.DSL.{Diagnostic, FlowAnalysis, Interpreter}
  alias TinyCI.{PipelineSpec, Stage}

  # Diagnose a grammatically-valid buffer through the real interpreter path
  # (build a spec, then run flow analysis against it).
  defp diagnose(source) do
    {:ok, ast} = Code.string_to_quoted(source, columns: true)
    {:ok, spec} = Interpreter.interpret_string(source, "buffer.exs")
    FlowAnalysis.diagnostics(ast, spec)
  end

  # For graph-error buffers the interpreter would refuse to build a spec, so we
  # supply one directly alongside the parsed AST.
  defp diagnose_with_spec(source, stages) do
    {:ok, ast} = Code.string_to_quoted(source, columns: true)
    spec = %PipelineSpec{name: :t, stages: stages, hooks: %{on_success: [], on_failure: []}}
    FlowAnalysis.diagnostics(ast, spec)
  end

  describe "needs diagnostics" do
    test "undefined needs target is reported at the offending stage" do
      source = """
      stage :build, needs: [:missing] do
        step :c, cmd: "x"
      end
      """

      stages = [%Stage{name: :build, needs: [:missing], mode: :parallel}]

      assert [%Diagnostic{line: 1, message: msg, severity: :error}] =
               diagnose_with_spec(source, stages)

      assert msg =~ "needs unknown stage :missing"
    end

    test "valid needs produce no diagnostic" do
      source = """
      stage :build do
        step :c, cmd: "x"
      end

      stage :deploy, needs: [:build] do
        step :ship, cmd: "x"
      end
      """

      assert diagnose(source) == []
    end
  end

  describe "cycle diagnostics" do
    test "a cycle is reported inline on each participating stage" do
      source = """
      stage :a, needs: [:b] do
        step :x, cmd: "e"
      end

      stage :b, needs: [:a] do
        step :y, cmd: "e"
      end
      """

      stages = [
        %Stage{name: :a, needs: [:b], mode: :parallel},
        %Stage{name: :b, needs: [:a], mode: :parallel}
      ]

      diags = diagnose_with_spec(source, stages)

      assert length(diags) == 2
      assert Enum.all?(diags, &(&1.message =~ "cycle"))
      assert Enum.sort(Enum.map(diags, & &1.line)) == [1, 5]
    end
  end

  describe "store reader diagnostics" do
    test "no diagnostic when a step writes the read key" do
      source = """
      stage :build do
        step :make, module: FlowImgA
      end

      stage :deploy, needs: [:build] do
        step :ship, cmd: "deploy", env: %{"TAG" => store(:image_tag)}
      end
      """

      assert diagnose(source) == []
    end

    test "warns when a read key has no writer and all writers are known" do
      source = """
      stage :build do
        step :make, module: FlowImgA
      end

      stage :deploy, needs: [:build] do
        step :ship, cmd: "deploy", env: %{"X" => store(:ghost)}
      end
      """

      assert [%Diagnostic{message: msg, severity: :warning}] = diagnose(source)
      assert msg =~ "store key :ghost" or msg =~ "Store key :ghost"
      assert msg =~ "ghost"
    end

    test "downgrades to an info hint when a module step's outputs are unknown" do
      source = """
      stage :build do
        step :make, module: FlowNoMeta
      end

      stage :deploy, needs: [:build] do
        step :ship, cmd: "deploy", env: %{"X" => store(:ghost)}
      end
      """

      assert [%Diagnostic{message: msg, severity: :information}] = diagnose(source)
      assert msg =~ "ghost"
    end

    test "points the diagnostic at the store(...) call" do
      source = """
      stage :deploy do
        step :ship, cmd: "deploy", env: %{"X" => store(:ghost)}
      end
      """

      assert [%Diagnostic{line: 2, column: col}] = diagnose(source)
      # store( begins partway through line 2.
      assert col > 1
    end
  end

  describe "parallel writer diagnostics" do
    test "two parallel steps in one stage writing the same key warn on both" do
      source = """
      stage :build, mode: :parallel do
        step :a, module: FlowImgA
        step :b, module: FlowImgB
      end
      """

      diags = diagnose(source)
      assert length(diags) == 2
      assert Enum.all?(diags, &(&1.severity == :warning))
      assert Enum.all?(diags, &(&1.message =~ "image_tag"))
      assert Enum.sort(Enum.map(diags, & &1.line)) == [2, 3]
    end

    test "two concurrent stages writing the same key warn on both" do
      source = """
      stage :a do
        step :x, module: FlowImgA
      end

      stage :b do
        step :y, module: FlowImgB
      end

      stage :c, needs: [:a, :b] do
        step :z, cmd: "echo"
      end
      """

      diags = diagnose(source)
      assert length(diags) == 2
      assert Enum.all?(diags, &(&1.message =~ "image_tag"))
    end

    test "serial steps in one stage do not conflict" do
      source = """
      stage :build, mode: :serial do
        step :a, module: FlowImgA
        step :b, module: FlowImgB
      end
      """

      assert diagnose(source) == []
    end

    test "dependency-ordered stages do not conflict" do
      source = """
      stage :a do
        step :x, module: FlowImgA
      end

      stage :b, needs: [:a] do
        step :y, module: FlowImgB
      end
      """

      assert diagnose(source) == []
    end
  end
end
