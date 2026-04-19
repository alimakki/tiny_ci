name :self_build

on_success :done, cmd: "echo 'tiny_ci build passed'"
on_failure :done, cmd: "echo 'tiny_ci build FAILED'"

stage :check, mode: :parallel do
  step :format, cmd: "mix format --check-formatted"
  step :compile, cmd: "mix compile --warnings-as-errors"
end

stage :test, mode: :serial do
  step :unit, cmd: "mix test", timeout: 120_000
end

stage :lint, mode: :serial do
  step :credo, cmd: "mix credo"
end
