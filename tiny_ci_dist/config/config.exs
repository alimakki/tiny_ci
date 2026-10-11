import Config

# Extra CLI subcommands contributed by sibling apps (the server in M2-07, the
# runner in M4-01). The core never depends on them: the release registers them
# here and `TinyCI.CLI` dispatches to whatever is configured.
config :tiny_ci, cli_subcommands: []
