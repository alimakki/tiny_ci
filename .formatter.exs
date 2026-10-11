# Used by "mix format"
#
# `test/fixtures/` holds example projects (pipelines written in the tiny_ci DSL)
# that are inputs to integration tests and the release smoke job, not source.
# They are excluded so their style matches what a user would write.
inputs =
  Path.wildcard("{mix,.formatter}.exs") ++
    (Path.wildcard("{config,lib,test}/**/*.{ex,exs}") --
       Path.wildcard("test/fixtures/**/*.{ex,exs}"))

[inputs: inputs]
