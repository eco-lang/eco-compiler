Run the elm-test and E2E tests, take a baseline from the first run.

Run the @bootstrap.md process up to Stage 5, with the heap usage instrumentation
injected into `_Scheduler_step` in eco-boot-2.js (see the `_Mem_log` function that
logs at IO boundaries and every 100k andThen binds). The instrumentation writes
lines to stderr in this format:

    [mem <elapsed>s] <reason> rss=<N>MB heap=<used>/<total>MB ext=<N>MB binds=<N> ios=<N>

Capture the full stderr+stdout output to /tmp/stage5-mem.log for analysis.
Run Stage 5 twice: once cold (delete .ecot caches first) and once warm (caches intact).

Maintain information about memory usage in @mem-hints.md, adding new reports as
you discover them, or marking off old issues as you fix them. Keep a list at the
top of this file with memory issues in the best order to tackle them (highest
peak reduction potential first).

LOOP:
1. Check /usage. If over 90%, run: sleep <seconds until reset + 60>.
   Then continue — do NOT stop or produce a report.

2. Pick the next issue from @mem-hints.md that is not marked FIXED or SKIPPED.
   If there are none, go to step 2b.

2b. Analyse the latest instrumentation output. Look for new issues:
   - Phases where heap used grows by >500MB without a corresponding GC drop
   - RSS jumps that never recede (memory retained permanently)
   - Phases with very few binds/ios but large elapsed time (long pure computation
     building up allocations)
   - External memory growing steadily (Buffer/TypedArray accumulation)
   Add any new issues to @mem-hints.md ranked by peak reduction potential.
   If you found new issues, go back to step 2.
   If no actionable issue remains, or if the last 3 consecutive fix attempts
   (across any issues) all failed to produce measurable improvement, go to DONE.

3. Investigate and reason about the root cause. Read the relevant compiler source
   code (in /work/compiler/src/) to understand what data structures are being
   allocated and why they are retained. Propose a fix.

4. Apply the fix.

5. Re-run elm-test and E2E tests. Compare results to previous run.

6. Re-bootstrap to Stage 5 (re-run build-self.sh and build-verify.sh first if
   compiler source changed, so eco-boot-2.js reflects the fix). Capture the
   instrumentation output. Compare heap/RSS profiles to the previous run.

7. Did the fix reduce peak memory or shorten a high-memory phase?
   - YES -> Mark FIXED in @mem-hints.md with before/after numbers. Go to LOOP.
   - NO -> Revert the fix. Record what you tried and why it did not work
     in @mem-hints.md under that issue's entry.
     Have you already tried 3 different approaches for this issue?
     - YES -> Mark SKIPPED in @mem-hints.md with explanation. Go to LOOP.
     - NO -> Go back to step 3 with a different approach.

DONE:
Produce a detailed report of what was fixed and what was skipped (and why),
including before/after peak RSS and heap numbers for each phase.
Do NOT go to DONE while there are issues that are not FIXED or SKIPPED.
