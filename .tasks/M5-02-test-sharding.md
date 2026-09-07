# M5-02 — `shards:` stage option fans a test suite across runners

**Milestone:** M5 · **Size:** M · **Depends on:** M4-02 · **Status:** ⬜ Not started

> Detail level: design. Expand when M5 opens.

## Summary

`stage :test, shards: 4` runs the stage four times in parallel (locally as tasks, on the
server across runners) with `TINY_CI_SHARD=1..4` and `TINY_CI_SHARDS=4` in the environment.
The result rolls up like a matrix stage. For Elixir projects the pair maps directly onto
`mix test --partitions $TINY_CI_SHARDS` with `MIX_TEST_PARTITION=$TINY_CI_SHARD`; for others
the runner passes the two variables and the test tool does the splitting (Jest `--shard`,
pytest-split, Go by package list).

## Design notes

- Implement as sugar over `matrix:` (`matrix: [shard: ["1", "2", "3", "4"]]` plus the two env
  vars) so the executor, reporter, projection, and UI need no new concepts. Validator: positive
  integer, mutually exclusive with `matrix:`.
- Placement: with runners, each shard is independently placeable (M4-02 treats matrix runs as
  placeable units — verify and adjust).
- Docs: recipes for mix, Jest, pytest, Go.

## Acceptance criteria

- [ ] `shards: N` produces N runs with the two variables set; reporter shows `test [shard=2/4]`.
- [ ] With two runners the shards spread across them.
- [ ] A recipe for `mix test --partitions` is documented and used by the dogfood pipeline.
