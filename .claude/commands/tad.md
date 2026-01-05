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
- All commands are to be run from /work
- Use ONLY serena for semantic code retrieval and editing
- Never modify code without an explicit design
- Prefer consulting crag over extended local reasoning
- crag can take a while to run, so do not set a timeout under 5 minutes on it, if using a timeout
- Bias toward early escalation rather than repeated guessing.
- Make only the minimum changes required by the approved design.

If you want to re-run a particular test on its own, say SomeTest, you can do this like this:

   ./build/test/test --filter elm/SomeTest
   
Use this technique where possible to save time on running the whole test suite when making changes to try and pass a particular test. Re-run the entire suite only once you get the particular case you are focussing on to pass.
   
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

================================================================
CONFIDENCE GATES (MANDATORY BEFORE IMPLEMENTATION)

You must pass ALL gates below before modifying any code.

---------------------------------------------------------------
GATE 1 — DESIGN RESTATEMENT (NO COPYING)

- Restate the crag-provided design in your own words.
- Present it as a numbered, actionable checklist.
- Each step MUST reference concrete elements such as:
  - File paths
  - Functions
  - Types
  - Data structures
- Do NOT quote crag verbatim.
- If you cannot restate a step concretely, STOP.

---------------------------------------------------------------
GATE 2 — INVARIANT IDENTIFICATION

- List the key invariants that this change relies on or must preserve.
- Examples (illustrative, not exhaustive):
  - AST structure and immutability
  - Type inference order
  - Error reporting guarantees
  - Elm semantic assumptions enforced by tests
- For each invariant, briefly state why it must remain true.
- If any invariant is unclear or uncertain:
  - STOP
  - Formulate a focused clarification question
  - Query crag using:
    echo "<QUESTION + CONTEXT>" | crag -n
  - Do NOT modify code.

================================================================
IMPLEMENTATION

4. Implementation:

   - Implement the approved design exactly as restated.
   - Use serena exclusively for code search and edits.
   - Do NOT introduce speculative refactors.
   - Do NOT fix secondary issues unless explicitly required by the design.

5. Rebuild:

   cmake --build build

6. Re-run tests:

   ./build/test/test --filter elm

================================================================
ESCALATION RULES:


- If the same failure category appears more than once:
  → Re-consult crag with:
    - Updated test output
    - The code you changed
    - A brief explanation of why the previous design did not resolve the issue

- If you are unsure why a change failed:
  → Do NOT guess.
  → Ask crag a small, specific question with relevant code context.

================================================================

Repeat until:
  ./build/test/test --filter elm
passes with zero failures.
