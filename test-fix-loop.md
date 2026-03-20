Run the elm-test and E2E tests, take a baseline from the first run.
Use your test report from above to seed @test-fails.md with failed test cases, sources and
explanations of why they failed including full trace evidence.
Maintain this information in @test-fails.md, adding new reports as you discover them, or
marking off old reports as you fix them. Keep a list at the top of this file with test
failures in the best order to tackle them.

LOOP:
1. Check /usage. If over 90%, run: sleep <seconds until reset + 60>.
   Then continue — do NOT stop or produce a report.

2. Pick the next failure from @test-fails.md that is not marked FIXED or SKIPPED.
   If there are none, go to DONE.

3. Investigate and reason about the root cause. Propose a fix.

4. Apply the fix.

5. Re-run elm-test and E2E tests. Compare results to previous run.

6. Did the fix work?
   - YES → Mark FIXED in @test-fails.md. Go to LOOP.
   - NO → Revert the fix. Record what you tried and why it failed
     in @test-fails.md under that failure's entry.
     Have you already tried 3 different approaches for this failure?
     - YES → Mark SKIPPED in @test-fails.md with explanation. Go to LOOP.
     - NO → Go back to step 3 with a different approach.

DONE:
Produce a detailed report of what was fixed and what was skipped (and why).
Do NOT go to DONE while there are failures that are not FIXED or SKIPPED.
