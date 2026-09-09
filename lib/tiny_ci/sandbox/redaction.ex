defmodule TinyCI.Sandbox.Redaction do
  @moduledoc false
  @deprecated "Use TinyCI.Redaction.redact/2"
  defdelegate redact(term, secrets), to: TinyCI.Redaction
end
