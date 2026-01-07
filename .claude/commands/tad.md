---
description: Fully automated Elm test–analyze–develop loop with invariants and mandatory crag escalation
allowed-tools:
  - Bash(./build/test/test --filter elm)
  - Bash(cmake --build build)
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
INVARIANTS (GLOBAL AND CONTINUOUS)

Invariants define non‑negotiable properties of the system that must be preserved
throughout all stages of development: analysis, design, implementation, and refactoring.

- Source of truth:
  - All invariants are defined in @design_docs/invariants.csv
  - Treat this file as authoritative for system‑wide assumptions and constraints.

- When to check invariants (MANDATORY):
  - When understanding or analyzing a failure
  - When designing or planning any change
  - Before applying any code modification
  - After implementing changes, when re-analyzing behavior or test results

- How to use invariants:
  1. Identify which parts of the code or behavior are affected by the current change or design.
  2. Consult @design_docs/invariants.csv and locate all invariants that might apply to:
     - The modules, types, or APIs being modified
     - The behavior being corrected or extended
     - Any cross-cutting semantics (e.g., Elm AST, type inference, error reporting)
  3. For each relevant invariant:
     - Explicitly check whether the proposed design or change would violate it.
     - If the impact is unclear, treat it as potentially risky.

- If a change appears to break, weaken, or rely on violating an invariant:
  - Do NOT proceed with implementation.
  - Follow the Guardrails below (Invariant Breakage and Repeated Failure & Escalation)
    and STOP to ask the user how to proceed.

Invariants are to be observed and preserved at all times, not just at a single checkpoint.

================================================================
GUARDRAILS (MANDATORY BEHAVIOR)

The following guardrails govern how you design and implement changes. They apply at every
iteration of the loop.

1. Design Restatement Guardrail
   - After receiving a design from crag, you MUST restate it in your own words
     as a concrete, actionable checklist.
   - The checklist must:
     - Be numbered and step-by-step.
     - Reference concrete elements such as:
       - File paths
       - Functions
       - Types
       - Data structures
     - Be specific enough that an engineer could follow it without needing to
       re-interpret crag’s answer.
   - Do NOT copy or quote crag verbatim.
   - If any step cannot be restated concretely (e.g., unclear files, functions,
     or data structures), STOP and:
     - Formulate a focused clarification question.
     - Ask crag using:
       echo "<QUESTION + CONTEXT>" | crag -n
     - Do NOT modify code until clarified.

2. Invariant Awareness and Impact Guardrail
   - Before implementing any design step that changes code:
     - Identify which invariants from @design_docs/invariants.csv are relevant
       to the affected modules, types, behaviors, or APIs.
     - For each relevant invariant:
       - State briefly how the design preserves it, or
       - Note that the design depends on it continuing to hold.
   - If you cannot determine how an invariant is preserved, treat this as uncertainty and:
     - Ask a focused question to crag OR
     - Ask the user for clarification
     before modifying code.

3. Invariant Breakage Guardrail (STOP Condition)
   - If your analysis or the crag-provided design implies that an invariant:
     - Will be broken, or
     - Must be relaxed, or
     - Conflicts with the proposed change
     then you MUST NOT proceed automatically.
   - In this case:
     - STOP.
     - Ask the user how to proceed, with a detailed, concrete question that includes:
       - The relevant invariant(s) from @design_docs/invariants.csv
       - The specific design or code change that would violate them
       - The trade-offs or options you see (e.g., adjust design, update invariant, introduce new abstraction)
     - Wait for explicit user guidance before making any change that would affect the invariant.

4. No Speculative Refactoring Guardrail
   - Implement only the changes required by the approved and restated design.
   - Do NOT:
     - Introduce unrelated refactors
     - Reorganize code for stylistic reasons
     - Fix secondary issues unless explicitly required by the design or by invariants.

5. Repeated Failure & Escalation Guardrail
   - If the same failure category appears more than once:
     - Re-consult crag with:
       - Updated test output
       - The code you changed
       - A brief explanation of why the previous design did not resolve the issue
       - Any newly discovered invariant interactions or tensions.
   - If you are unsure why a change failed or how to correctly apply the design:
     - Do NOT guess.
     - Ask crag a small, specific question with relevant code context and the
       relevant invariants.
   - If repeated failures suggest that the current invariants or design assumptions
     may be misaligned:
     - Explicitly call this out in your crag query or to the user.
     - Do not proceed with larger or riskier changes without updated guidance.

================================================================
LOOP:

1. Run Elm tests:
   ./build/test/test --filter elm

2. If tests fail:

   a. Perform a root cause analysis.
      - Analyze failures by underlying cause, not by test or file.
      - Consult @design_docs/invariants.csv to identify any invariants related
        to the failing behavior or modules.
      - Note any suspected invariant implications, but do NOT break them.

   b. Group failures by underlying cause (not by test or file).

   c. Produce a structured failure report containing:
      - Failure category
      - Symptoms
      - Hypothesized root cause
      - Evidence from test output
      - Relevant invariants (by name or identifier from @design_docs/invariants.csv)
        that constrain or inform possible fixes

3. Mandatory crag consultation:

   - Construct a report that includes:
     • Root cause analysis
     • Relevant code excerpts (via serena)
     • Any code changed in this iteration (if applicable)
     • References to related modules or invariants
     • Any suspected invariant tensions or potential violations you identified

   - Append the following query verbatim:

     "Pick the most important issue to fix and provide a complete design that an engineer could follow to fix it, making sure to describe all code changes needed."

   - Send everything in ONE echo command from /work:
     echo "<REPORT + CODE CONTEXT>

     Pick the most important issue to fix and provide a complete design that an engineer could follow to fix it, making sure to describe all code changes needed." | crag -n

4. Design and Invariant Check (under Guardrails):

   - Restate the design returned by crag as a numbered, actionable checklist
     referencing concrete files, functions, types, and data structures.
   - For each checklist step that affects code:
     - Identify and review the relevant invariants in @design_docs/invariants.csv.
     - Confirm that the step preserves these invariants.
   - If you detect or strongly suspect an invariant breakage:
     - STOP and ask the user how to proceed, as per the Invariant Breakage Guardrail.
   - If anything remains unclear:
     - Ask a focused clarification question to crag before proceeding.
   - If failures are repeated or confusing:
     - Follow the Repeated Failure & Escalation Guardrail.

5. Implementation:

   - Implement the approved, restated design exactly as written in your checklist.
   - Use serena exclusively for code search and edits.
   - Do NOT introduce speculative refactors.
   - Do NOT fix secondary issues unless explicitly required by the design or
     necessary to preserve invariants.
   - Continuously keep invariants in mind while editing; if a new potential
     invariant impact appears, re-check @design_docs/invariants.csv and, if needed,
     STOP and ask the user.

6. Rebuild:

   cmake --build build

7. Re-run tests:

   ./build/test/test --filter elm

================================================================

Repeat until:
  ./build/test/test --filter elm
passes with zero failures AND no invariants in @design_docs/invariants.csv are violated
or left in an unclear state.
