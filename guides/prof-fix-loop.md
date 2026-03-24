Run the elm-test and E2E tests, take a baseline from the first run.

Run the @bootstrap.md process up to Stage 5, but with @profiling_command.txt instructions
applied to profile the run under NodeJS.

Maintain information about performance and memory in @prof-hints.md, adding new reports as
you discover them, or marking off old issues as you fix them. Keep a list at the top of this
file with performance bottlenecks in memory or CPU in the best order to tackle them.

LOOP:
1. Check /usage. If over 90%, run: sleep <seconds until reset + 60>.
   Then continue — do NOT stop or produce a report.

2. Pick the next issue from @prof-hints.md that is not marked FIXED or SKIPPED.
   If there are none, go to step 2b.

2b. Analyse the latest profiling data. Look for new bottlenecks — functions or
   builtins above 1% of nonlib time, or GC patterns that suggest a specific
   allocation source. Add any new issues to @prof-hints.md ranked by impact.
   If you found new issues, go back to step 2.
   If no actionable bottleneck above 1% remains, or if the last 3 consecutive
   fix attempts (across any issues) all failed to produce measurable improvement,
   go to DONE.

3. Investigate and reason about the root cause. Propose a fix.

4. Apply the fix.

5. Re-run elm-test and E2E tests. Compare results to previous run.

6. Try bootstrapping to Stage 5 again, under @profiling_command.txt instructions.

7. Did the fix improve things?
   - YES → Mark FIXED in @prof-hints.md. Go to LOOP.
   - NO → Revert the fix. Record what you tried and why it did not work
     in @prof-hints.md under that issues's entry.
     Have you already tried 3 different approaches for this issue?
     - YES → Mark SKIPPED in @prof-hints.md with explanation. Go to LOOP.
     - NO → Go back to step 3 with a different approach.

DONE:
Produce a detailed report of what was fixed and what was skipped (and why).
Do NOT go to DONE while there are failures that are not FIXED or SKIPPED.
