# Coverage loop state

The files here record the state of the coverage-driven test loop described in
`plans/coverage-driven-test-generation.md`, which says how to use them.

- `tracker.csv`: one row per in-scope module, with its status and coverage. `cov.py report
  --write-tracker` refreshes the numbers and keeps `status` and `notes`.
- `exclusions.csv`: code left out of the measure, either because it runs only under a non-default
  flag (`flag`) or because no input can reach it (`unreachable`). `line` is `*` for a whole module.
- `findings.csv`: compiler bugs the loop exposed.

The driver is `compiler/scripts/coverage/cov.py`.
