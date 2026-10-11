name :non_elixir_project

stage :build do
  step :vet, cmd: "echo vet ok"
  step :test, cmd: "echo test ok"
end
