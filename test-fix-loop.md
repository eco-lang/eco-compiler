# Test-Fix Loop

## SETUP (run once)

1. Run elm-test: `cd compiler && npx elm-test-rs --project build-xhr --fuzz 1`
2. Run E2E: `cmake --build build --target full`
3. Record pass/fail counts as baseline.
4. Seed @test-fails.md with every failing test: name, error message, full trace.
5. Order the failures in @test-fails.md by best-to-tackle-first.

## LOOP

Execute these steps strictly in order. Do NOT skip or combine steps.

### Step 1 — Check usage

Check /usage. If over 90%, run `sleep <seconds until reset + 60>`.
Then continue — do NOT stop or produce a report.

### Step 2 — Pick a failure

Pick the next failure from @test-fails.md that is not FIXED or SKIPPED.
If there are none, go to DONE.

### Step 3 — Investigate (time-boxed)

Investigate the root cause. Keep investigation SHORT — read only what you
need to form a hypothesis and propose a concrete fix. Do NOT exhaustively
trace the entire pipeline. Stop as soon as you have a plausible fix.

Write a 1–3 sentence hypothesis in @test-fails.md under the failure entry.

### Step 4 — Apply the fix

Make the smallest code change that could fix the failure.
Note every file you touched — you will need this for revert.

### Step 5 — Run BOTH test suites

Run elm-test AND E2E. Wait for results. Record the new pass/fail counts.

CRITICAL CHECK — compare to the PREVIOUS run (not just baseline):
- Did the target failure change from FAIL to PASS?
- Did any previously-passing test become FAIL? (regression)

### Step 6 — Evaluate

Answer THREE yes/no questions:

**Q1: Does the target test now pass?**
**Q2: Are there zero regressions (no new failures)?**
**Q3: Is the elm-test count the same or better than baseline?**

- If ALL THREE are YES:
  → Mark FIXED in @test-fails.md. Go to LOOP step 1.

- If ANY is NO:
  → IMMEDIATELY revert every file you touched in step 4.
  → Run both test suites again to CONFIRM counts match the previous run.
  → Record in @test-fails.md: what you tried, what happened, why it failed.
  → Increment the attempt counter for this failure.
  → If attempts < 3: go to step 3 with a different approach.
  → If attempts >= 3: mark SKIPPED with explanation. Go to LOOP step 1.

### Rules

- **Never build on a broken fix.** If Q1/Q2/Q3 are not all YES, revert first.
- **Never skip the revert-and-retest.** You must confirm clean state before continuing.
- **One fix per loop iteration.** Do not combine fixes for different failures.
- **Investigation is not an attempt.** Reading code and forming a hypothesis costs
  zero attempts. Only applying code changes and running tests counts as an attempt.
- **The test suite is the only judge.** "I believe this is correct" is not evidence.
  Only a passing test with zero regressions counts as FIXED.

## DONE

Produce a report:
- How many failures were FIXED, SKIPPED, and still OPEN.
- For each FIXED: one-line summary of the fix.
- For each SKIPPED: root cause and why 3 attempts were not enough.
- Final pass/fail counts for both suites.

Do NOT go to DONE while there are failures that are not FIXED or SKIPPED.
