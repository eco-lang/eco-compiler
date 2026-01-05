---
description: Fully automated Elm test–analyze–develop loop with mandatory crag escalation
allowed-tools:
  - Bash(./build/test/test --filter elm)
  - Bash(cmame --build build)
  - Bash(crag -n)
---

You are operating in a fully automated test–analyze–develop loop.
crag (ChatGPT + full index) is your primary source of high-level reasoning and
historical design context.

Global constraints:
- All commands must be run from /work
- Use ONLY serena for semantic code retrieval and editing
- Never modify code without an explicit design
- Prefer consulting crag over extended local reasoning

================================================================

LOOP:

1. Run Elm tests:
   ./build/test/test --filter elm

2. If tests fail:
   a. Perform a root cause analysis.
   b. Group failures by underlying cause (not by test or file).
   c. Produce a structured failure report containing:
      - Failure category
      - Symptoms
      - Hypothesized root cause
      - Evidence from test output

3. Mandatory crag consultation:
   - Construct a report that includes:
     • Root cause analysis
     • Relevant code excerpts
     • Any code changed in this iteration
     • References to related modules or invariants

   - Append the following query verbatim:

     "Pick the most important issue to fix and provide a complete design that an engineer could follow to fix it, making sure to describe all code changes needed."

   - Send everything in ONE echo command from /work:
     echo "<REPORT + CODE CONTEXT>

     Pick the most important issue to fix and provide a complete design that an engineer could follow to fix it, making sure to describe all code changes needed." | crag -n

4. Design validation:
   - Restate the design as a checklist.
   - If unclear, re-query crag with a focused question.

5. Implementation:
   - Implement exactly the approved design using serena.
   - Do not fix secondary issues unless required.

6. Rebuild:
   cmake --build build

7. Re-run tests:
   ./build/test/test --filter elm

================================================================

ESCALATION RULES:

- If the same failure category appears twice:
  → Re-consult crag with updated test output and code diffs.

- If you are unsure why a change failed:
  → Do not guess.
  → Query crag with a specific question and code context.

================================================================

Repeat until:
  ./build/test/test --filter elm
passes with zero failures.
