# Stack Reduction Loop

Reduce the Node.js stack size required for a Stage 5 bootstrap build. The goal is to
get as close to the default Node.js stack size (`--stack-size=984`) as possible.

## Prerequisites

- Complete bootstrap Stages 1–4 per @bootstrap.md so that `eco-boot-2-runner.js` is available.
- Clean `.ecot` caches before starting:
  ```bash
  find /work/compiler/build-kernel/eco-stuff -name '*.ecot' -delete
  ```
- Do a warm-up Stage 5 run at `--stack-size=65536` with a 5-minute timeout (no profiling)
  to populate `.ecot` caches:
  ```bash
  cd /work/compiler/build-kernel
  timeout 300 node --max-old-space-size=15000 --stack-size=65536 \
      bin/eco-boot-2-runner.js make \
      --optimize --kernel-package eco/compiler \
      --local-package eco/kernel=/work/eco-kernel-cpp \
      --output=bin/eco-compiler.mlir \
      /work/compiler/src/Terminal/Main.elm
  ```
- Confirm the warm-up run succeeds (or at least populates caches). This is the baseline.

IMPORTANT: Do not run more than one node process at a time — this system has only 16 GB
memory and we set max heap to 15 GB.

## State file

Maintain @stack-hints.md with:
- A table at the top: `| Stack Size | Result | Notes |` tracking every halving attempt.
- A ranked list of stack-depth issues, each with status (OPEN / FIXED / SKIPPED).
- Under each issue: root cause analysis, attempted fixes, and outcomes.

## Variables

- `CURRENT_LIMIT` — the last stack size that succeeded. Starts at **65536**.
- `NEXT_LIMIT` — always `CURRENT_LIMIT / 2`.
- `CONSECUTIVE_FAILURES` — count of consecutive fix attempts that failed to let a
  smaller stack size pass. Reset to 0 whenever `CURRENT_LIMIT` is successfully reduced.

## LOOP

### Step 1 — Check usage
Check /usage. If over 90%, run: `sleep <seconds until reset + 60>`.
Then continue — do NOT stop or produce a report.

### Step 2 — Halve and test
Set `NEXT_LIMIT = CURRENT_LIMIT / 2`. Run Stage 5 under the profiler with the
reduced stack:

```bash
cd /work/compiler/build-kernel
timeout 300 node --max-old-space-size=15000 --stack-size=$NEXT_LIMIT --prof \
    bin/eco-boot-2-runner.js make \
    --optimize --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/eco-compiler.mlir \
    /work/compiler/src/Terminal/Main.elm
```

Process the V8 profiling log:

```bash
node --prof-process isolate-*.log > v8-profile.txt
rm isolate-*.log
```

#### 2a — Success (no stack overflow)
Record the result in @stack-hints.md. Set `CURRENT_LIMIT = NEXT_LIMIT`.
Reset `CONSECUTIVE_FAILURES = 0`.

- If `CURRENT_LIMIT <= 984`, go to **DONE**.
- Otherwise go back to **Step 2** (halve again).

#### 2b — Stack overflow
Record the failure in @stack-hints.md. Go to **Step 3**.

### Step 3 — Diagnose
Examine `v8-profile.txt` and the stack overflow error message. Identify:
- Which function(s) are at the top of the call stack when overflow occurs.
- The call chain leading to deep recursion.
- Whether the recursion is in compiler Elm code (compiled to JS) or in Node/V8 internals.

Add or update an issue in @stack-hints.md with the root cause analysis.

### Step 4 — Fix
Investigate the code at the overflow site and apply a fix. Consider these strategies
**in order of preference**:

1. **Algorithmic improvement** — replace deep recursion with an iterative algorithm
   or reduce recursion depth (e.g. balanced splits instead of linear chains).
2. **Tail-call conversion** — restructure recursive calls into tail position so they
   can be compiled as loops.
3. **Accumulator pattern** — convert non-tail recursion to tail recursion using an
   accumulator parameter.
4. **Continuation-passing style (CPS)** — rewrite to use explicit continuations,
   moving stack frames to the heap.
5. **Trampolining** — as a last resort, since trampolines hurt runtime performance
   and increase heap pressure. Only use if options 1–4 are not feasible.

### Step 5 — Validate the fix
Run elm-test and E2E tests to check correctness:

```bash
cd /work/compiler && npx elm-test-rs --project build-xhr --fuzz 1
cmake --build /work/build --target full
```

If tests fail, revert the fix and try a different approach (go to Step 4).

### Step 6 — Re-test at NEXT_LIMIT
Re-run the Stage 5 build at `NEXT_LIMIT` (same as Step 2, with profiling).

#### 6a — Success
Mark the issue FIXED in @stack-hints.md. Set `CURRENT_LIMIT = NEXT_LIMIT`.
Reset `CONSECUTIVE_FAILURES = 0`. Go to **Step 2** (halve again).

#### 6b — Still overflows at same location
Increment `CONSECUTIVE_FAILURES`. Record the attempt in @stack-hints.md.

- If you have tried **3 different approaches** for this specific issue:
  mark it SKIPPED in @stack-hints.md with explanation. Go to Step 3 to see if
  there is a *different* overflow site now (the stack trace may have changed).
- Otherwise go back to **Step 4** with a different approach.

#### 6c — Overflows at a different location
The fix helped but wasn't enough by itself. Mark the original issue FIXED.
Go to **Step 3** to diagnose the new overflow site.

### Step 7 — Stuck check
If `CONSECUTIVE_FAILURES >= 3` across any issues at the current `NEXT_LIMIT`:
- No more progress can be made at this halving level.
- Go to **DONE**.

## DONE

Produce a final report:
- The starting stack size (65536) and the final achieved `CURRENT_LIMIT`.
- A summary table of all halving attempts and their outcomes.
- Each issue that was FIXED: what the problem was, what fix was applied, and the
  stack depth improvement.
- Each issue that was SKIPPED: what was tried and why it didn't work.
- Recommendations for further stack reduction if `CURRENT_LIMIT > 984`.

Do NOT go to DONE while there are OPEN issues that are not FIXED or SKIPPED,
unless the CONSECUTIVE_FAILURES limit has been reached.
