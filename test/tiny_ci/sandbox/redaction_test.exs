defmodule TinyCI.Sandbox.RedactionTest do
  use ExUnit.Case, async: true

  test "the deprecated delegate still masks" do
    # `apply/3` keeps the deprecation warning out of the test build; the point
    # of the test is that the old name still works.
    assert apply(TinyCI.Sandbox.Redaction, :redact, ["token is abc123", ["abc123"]]) ==
             "token is ***"
  end
end
