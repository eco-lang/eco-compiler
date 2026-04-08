# Bootstrap-Fix Loop

Drive @guides/bootstrap.md to completion by repeatedly running it,
diagnosing the next failure, fixing it, and retrying.

## SETUP (run once)

1. Read @guides/bootstrap.md and make sure you understand all 8 stages and
   the exact commands they use.
2. Run the bootstrap from where it currently is. If unsure where it is, start
   at the earliest stage whose output is missing or known stale. Capture all
   stdout+stderr to `/tmp/bootstrap.log`.
3. Identify the first stage that fails (non-zero exit, missing output file,
   crash, hang, or fixed-point mismatch). Record:
   - the failing stage number,
   - the exact command,
   - the symptom (error message, assertion, abort, silent exit, etc.),
   - any backtrace or relevant log excerpt.
4. Seed @bootstrap-fails.md with this first failure as entry #1.

## LOOP

Execute these steps strictly in order. Do NOT skip or combine steps.

### Step 1 — Check usage

Check /usage. If over 90%, run `sleep <seconds until reset + 60>`.
Then continue — do NOT stop or produce a report.

### Step 2 — Pick the current failure

Pick the next failure from @bootstrap-fails.md that is not FIXED or SKIPPED.
If there are none, go to DONE.

### Step 3 — Investigate (time-boxed)

Form a hypothesis about the root cause. Use whatever investigation tools fit
the symptom — they are all fair game and you should reach for them
proactively rather than guessing:

- **strace / ltrace** — for silent exits, missing IO, or to confirm what
  syscalls a stage actually performs.
- **gdb (batch mode)** — for crashes, aborts, or assertion failures. Get a
  backtrace, inspect locals, set conditional breakpoints. Remember the
  binary is PIE: use symbol-relative addresses and `start <args>` before
  setting breakpoints.
- **Targeted printf/fprintf logging** in runtime / kernel C++ code, gated
  by an env var (e.g. `ECO_*_TRACE`) so it's quiet by default. Use these
  when you need values *during* execution that gdb can't easily reach.
- **Reading the relevant source** (Elm, MLIR codegen, runtime, kernel) to
  understand what the failing call is supposed to do.
- **`Allocator::resolve` / `Header::tag` inspection** — most heap-corruption
  symptoms are easiest to triage by checking that an HPointer resolves to
  the heap tag the consumer expects.
- **`git log` / `git blame`** on the failing file — recent commits often
  explain why a previously-working path broke.

Investigation is not an attempt. Read and probe as much as you need to form
a *concrete* fix. Stop as soon as you have one. Avoid speculative fixes
that aren't backed by direct evidence (a failing assertion, a wrong value
in a register, a clear type mismatch, etc.).

Write a 1–3 sentence hypothesis in @bootstrap-fails.md under the failure
entry, plus a one-line "fix plan".

### Step 4 — Apply the fix

Make the smallest code change that could fix the failure. Note every file
you touched — you will need this list for revert.

If your fix needed temporary debug logging or asserts to confirm the
hypothesis, leave them in for now (they help if the next iteration regresses
into the same area). They will be cleaned up at DONE.

### Step 5 — Re-run the bootstrap

Re-run the bootstrap from the EARLIEST stage that could be affected by your
change. Be conservative — if you touched the runtime or any kernel C++,
that means re-running stage 6 onward at minimum (re-link `eco-boot-native`,
re-link `eco-compiler` from the existing Stage 5 MLIR, then proceed to
Stage 7). If you touched the Elm compiler sources or anything that affects
the Stage 5 MLIR output, re-run from Stage 1 or 2. Capture all output to
`/tmp/bootstrap.log`.

Do NOT regenerate Stage 5 MLIR unnecessarily — it is expensive. The
codegen treats kernel return values structurally; changes to a kernel
function's *return shape* (e.g. raw int → boxed Task) usually do NOT
require regenerating the MLIR, only re-linking.

### Step 6 — Evaluate

Answer THREE yes/no questions:

**Q1: Did the bootstrap make forward progress?** I.e. it now reaches a
later stage than before, OR (if still in the same stage) it now fails on a
different, later code path. "Same crash, same place" is NOT progress.

**Q2: Did your fix introduce no obvious regression?** Earlier stages that
previously succeeded must still succeed. (If you only touched runtime/
kernel code and re-ran from stage 6, you do not need to re-run stages 1–4
— they are independent of your change.)

**Q3: Is the new failure (if any) actually a different bug, not a
re-manifestation of the old one wearing a different mask?**

- If ALL THREE are YES:
  → Mark the previous failure FIXED in @bootstrap-fails.md.
  → If a new failure appeared, add it as the next entry.
  → Go to LOOP step 1.

- If ANY is NO:
  → IMMEDIATELY revert every file you touched in step 4.
  → Re-run the bootstrap from the earliest affected stage to CONFIRM you
    are back to the previous failure.
  → Record in @bootstrap-fails.md: what you tried, what happened, why it
    didn't work.
  → Increment the attempt counter for this failure.
  → If attempts < 3: go to step 3 with a *different* approach (different
    hypothesis, not just a tweak of the same idea).
  → If attempts >= 3: mark SKIPPED with explanation, then STOP and ask
    the user for guidance — do not silently move past an unresolved
    bootstrap blocker.

### Rules

- **Never build on a broken fix.** If Q1/Q2/Q3 are not all YES, revert first.
- **Never skip the revert-and-rerun.** You must confirm you are back to the
  previous failure before trying a different approach.
- **Forward progress is the only success signal.** Reaching a later stage
  or a later code path counts. Cosmetic changes to error messages do not.
- **One fix per loop iteration.** Do not combine fixes for different
  failures even if you think you see two bugs at once. Fix one, prove it
  with a re-run, then move on.
- **Don't fix bugs that aren't blocking the bootstrap.** If you notice an
  unrelated issue, note it in @bootstrap-fails.md as OBSERVED but do not
  fix it in this loop.
- **Investigation is not an attempt.** Reading code, running strace,
  setting gdb breakpoints, and adding diagnostic logging cost zero
  attempts. Only edits to non-debug code that you re-bootstrap with count
  as an attempt.
- **The bootstrap is the only judge.** "I believe this is correct" is not
  evidence. Only forward progress through the stages counts as FIXED.
- **Stage 4 and Stage 8 are fixed-point checks.** A diff between rounds
  there is a real failure, not a flake. Do not retry hoping for a
  different outcome — find the source of nondeterminism.

## DONE

The bootstrap reaches Stage 8 and produces an `eco-compiler-boot-2`
identical to `eco-compiler-boot` (per `cmp`).

Produce a report:
- How many failures were FIXED, SKIPPED, OBSERVED-but-not-fixed.
- For each FIXED: one-line summary of root cause and the fix.
- For each SKIPPED: root cause and why 3 attempts were not enough.
- For each OBSERVED: one-line description and where it lives.
- Final state of the build artifacts (`eco-compiler.mlir`, `eco-compiler`,
  `eco-compiler-boot`, `eco-compiler-boot-2`).
- Any debug logging / asserts left behind in the tree, with a note on
  whether they should be kept or removed.

Do NOT go to DONE while there are failures that are not FIXED or SKIPPED.
