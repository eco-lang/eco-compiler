# Dead Code Elimination Loop

Remove dead code from the Elm compiler sources, guided by test coverage
reports. Restrict efforts to these module trees:

- `Compiler/Generate/MLIR`
- `Compiler/GlobalOpt`
- `Compiler/Monomorphize`
- `Compiler/Type`
- `Compiler/TypedCanonical`

## SETUP (run once)

1. Run elm-test and E2E tests to establish a baseline:

   ```bash
   cd /work/compiler && npx elm-test-rs --project ../build/compiler/build-xhr --fuzz 1 2>&1 \
       | tee /tmp/elm-test-baseline.txt
   cmake --build /work/build --target full 2>&1 \
       | tee /tmp/e2e-baseline.txt
   ```

   Record the pass/fail counts as the baseline.

2. Generate a coverage report per @test-coverage-howto.md:

   ```bash
   cd /work/compiler
   env PATH="$(pwd)/node_modules/.bin:$PATH" \
       node elm-coverage/bin/elm-coverage src/ \
       --tests tests/ --elm-test elm-test-rs \
       -- --workers 8 --fuzz 1
   ```

   The HTML report lands in `compiler/.coverage/coverage.html`.

3. Analyse the coverage report. For each module in the target trees, look
   for functions, branches, and let-bindings with 0% coverage. These are
   dead code *candidates* — the coverage report is a guide, not the
   absolute truth. Some 0% code is reachable only at runtime through
   paths the test suite does not exercise; some is genuinely dead.

4. Seed @dce-hints.md with a table of potential dead code areas:

   ```
   | Module | Symbol / region | Coverage | Status | Notes |
   ```

   Add one row per opportunity. Status starts as OPEN. Include a brief
   write-up of why you believe the code is dead (e.g. "only caller was
   removed in commit X", "unreachable branch behind impossible pattern",
   "helper for a feature that was never wired up").

   Order the table by confidence — highest-confidence dead code first.

## LOOP

Execute these steps strictly in order. Do NOT skip or combine steps.

### Step 1 — Check usage

Check /usage. If over 90%, run `sleep <seconds until reset + 60>`.
Then continue — do NOT stop or produce a report.

### Step 2 — Pick the next candidate

Pick the next OPEN entry from @dce-hints.md.
If there are none, go to **Step 8** (re-scan).

### Step 3 — Verify the code is dead

Before deleting anything, confirm the code is actually unreachable:

- **Grep for callers.** Search the entire `compiler/src/` tree for
  references to the function or type. If it is called, exposed in a
  module header, or used as a record accessor, it is NOT dead — mark
  it NOT_DEAD in @dce-hints.md and go to Step 2.
- **Check exports.** If the function is in an `exposing (..)` clause or
  explicitly exposed, other modules may depend on it. Verify no
  external caller exists.
- **Reason about branches.** A 0%-coverage branch inside a live function
  may be reachable in production but untested. Only remove it if you can
  prove the branch is structurally unreachable (e.g. a pattern that
  cannot match given the type, or a condition that is always false).

This step is investigation — it does not count as an attempt.

### Step 4 — Apply the removal

Delete the dead code. Keep the change minimal and focused:

- Remove entire functions/values if they are unused.
- Remove unreachable branches from case expressions.
- Remove unused let-bindings.
- Remove imports that become unnecessary.
- Do NOT refactor surrounding code. Do NOT rename, reformat, or
  "improve" anything beyond the dead code itself.

Note every file you touched — you will need this for revert.

### Step 5 — Run BOTH test suites

```bash
cd /work/compiler && npx elm-test-rs --project ../build/compiler/build-xhr --fuzz 1 2>&1 \
    | tee /tmp/elm-test-output.txt
cmake --build /work/build --target full 2>&1 \
    | tee /tmp/e2e-output.txt
```

Record the new pass/fail counts.

### Step 6 — Evaluate

Answer TWO yes/no questions:

**Q1: Do all tests that passed before still pass? (zero regressions)**
**Q2: Does the code still compile cleanly?**

- If BOTH are YES:
  → Mark FIXED in @dce-hints.md. Go to Step 1.

- If EITHER is NO:
  → IMMEDIATELY revert every file you touched in Step 4.
  → Run both test suites again to CONFIRM counts match the previous run.
  → Record in @dce-hints.md: what you removed, what broke, why.
  → Mark SKIPPED with explanation. Go to Step 1.

Dead code removal should not need multiple attempts — if removing it
breaks something, the code was not dead. Do not retry.

### Step 7 — (reserved for Step 8 flow)

### Step 8 — Re-scan for more candidates

When all entries in @dce-hints.md are FIXED, SKIPPED, or NOT_DEAD:

1. Regenerate the coverage report (same command as SETUP step 2).
2. Compare to the previous report. Look for newly-exposed dead code —
   removing one function can make its helpers dead too.
3. Add any new candidates to @dce-hints.md as OPEN entries.
4. If new candidates were found, go to Step 1.
5. If no new candidates remain, go to DONE.

### Rules

- **Never build on a broken removal.** If tests regress, revert first.
- **Never skip the revert-and-retest.** Confirm clean state before continuing.
- **One removal per loop iteration.** Do not batch removals across
  different functions or modules. Small, individually-tested deletions
  are safer than large sweeps.
- **The test suite is the only judge.** If removing code causes a
  regression, the code was not dead — mark it NOT_DEAD or SKIPPED and
  move on.
- **Stay in scope.** Only touch modules in the five target trees listed
  at the top. Do not remove dead code in other parts of the compiler.
- **Do not refactor.** This loop is strictly about removal. Do not
  rename, restructure, or "clean up" code that is staying.
- **Coverage is a hint, not a proof.** Always verify with grep and
  reasoning before deleting. Some uncovered code is used at bootstrap
  time or by the runtime, not by the test suite.

## DONE

Produce a report:

- Total lines / functions removed.
- How many candidates were FIXED (removed), SKIPPED (not removable),
  and NOT_DEAD (false positive from coverage).
- For each FIXED: module, symbol, and one-line summary.
- For each SKIPPED: what broke when you tried to remove it.
- Final pass/fail counts for both test suites (must match baseline).
- Final coverage percentages for the target module trees (for comparison
  with the baseline — removing dead code should increase coverage %).

Do NOT go to DONE while there are OPEN entries in @dce-hints.md.
