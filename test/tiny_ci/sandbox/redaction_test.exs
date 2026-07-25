defmodule TinyCI.Sandbox.RedactionTest do
  use ExUnit.Case, async: true

  alias TinyCI.Sandbox.Redaction

  test "masks a secret in a bare string" do
    assert Redaction.redact("token is abc123", ["abc123"]) == "token is ***"
  end

  test "masks secrets nested in maps, lists, and tuples" do
    data = %{out: ["prefix abc123", {:tag, "abc123"}], keep: "clean"}
    redacted = Redaction.redact(data, ["abc123"])

    assert redacted == %{out: ["prefix ***", {:tag, "***"}], keep: "clean"}
  end

  test "masks multiple distinct secrets" do
    assert Redaction.redact("a=AAA b=BBB", ["AAA", "BBB"]) == "a=*** b=***"
  end

  test "ignores nil and empty secrets" do
    assert Redaction.redact("unchanged", [nil, "", nil]) == "unchanged"
  end

  test "leaves non-string data untouched" do
    assert Redaction.redact(%{n: 42, flag: true}, ["x"]) == %{n: 42, flag: true}
  end
end
