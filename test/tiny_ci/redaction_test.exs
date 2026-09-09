defmodule TinyCI.RedactionTest do
  use ExUnit.Case, async: true

  alias TinyCI.Events.StepOutputLine
  alias TinyCI.Redaction

  doctest Redaction

  describe "redact/2" do
    test "masks a secret in a bare string" do
      assert Redaction.redact("token is abc123", ["abc123"]) == "token is ***"
    end

    test "masks secrets nested in maps, lists, and tuples" do
      data = %{out: ["prefix abc123", {:tag, "abc123"}], keep: "clean"}
      redacted = Redaction.redact(data, ["abc123"])

      assert redacted == %{out: ["prefix ***", {:tag, "***"}], keep: "clean"}
    end

    test "masks multiple distinct secrets" do
      assert Redaction.redact("a=AAAA b=BBBB", ["AAAA", "BBBB"]) == "a=*** b=***"
    end

    test "ignores nil and empty secrets" do
      assert Redaction.redact("unchanged", [nil, "", nil]) == "unchanged"
    end

    test "ignores values shorter than 4 bytes" do
      assert Redaction.redact("a ab abc abcd", ["a", "ab", "abc"]) == "a ab abc abcd"
      assert Redaction.redact("a ab abc abcd", ["abcd"]) == "a ab abc ***"
    end

    test "leaves non-string data untouched" do
      assert Redaction.redact(%{n: 42, flag: true}, ["xxxx"]) == %{n: 42, flag: true}
    end

    test "masks inside an event struct and preserves its shape" do
      event = %StepOutputLine{
        run_id: "r",
        timestamp: DateTime.utc_now(),
        stage: :s,
        step: :echo,
        line: "token=abcd1234"
      }

      assert %StepOutputLine{line: "token=***", stage: :s, timestamp: %DateTime{}} =
               Redaction.redact(event, ["abcd1234"])
    end

    test "survives DateTime values nested in the data" do
      now = DateTime.utc_now()

      assert Redaction.redact(%{at: now, note: "abcd1234"}, ["abcd1234"]) == %{
               at: now,
               note: "***"
             }
    end
  end
end
