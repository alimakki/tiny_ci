import Config

# gen_lsp stops the VM when its stdio/socket reaches EOF (so the server exits
# when an editor disconnects). During tests the harness opens and closes many
# transports, so disable that behaviour to keep the test VM alive.
if config_env() == :test do
  config :gen_lsp, exit_on_end: false
end
