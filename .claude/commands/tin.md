---
name: /tin
description: "Test + investigate, no implementation."
---

For the test I just described (or the tests in general if none described):

## Step 1: Collect ALL failures

Run the tests ONCE, redirecting stdout and stderr to a temporary file:

```
<test command> 2>&1 | tee /tmp/test_output.txt
```

**MANDATORY:** Do NOT run the tests more than once. Use `grep`, `head`, `tail` on
`/tmp/test_output.txt` to extract failure information. If you need to see different
parts of the output, read the file — do NOT re-run the tests.

Extract EVERY failing test name and its error message verbatim from the saved output.
List them all before proceeding.

You MUST NOT proceed to step 2 until you have a complete list of all failing tests
with their error output.

## Step 2: Categorize and order

Group the failures by likely root cause. Order the groups by compiler phase
(earlier phases first). Present this as a table or list showing:
- Category name
- Which compiler/runtime phase it relates to
- Which test names belong to it

## Step 3: Investigate each category

For each failure category, investigate the root cause:
- Read the failing test code
- Read the production code it exercises
- Read generated artifacts (.mlir files, etc.) where relevant

## Step 4: Trace with concrete values

For each failure category, pick one concrete failing test case and trace its
specific input values through the code step by step. At each step:
- Quote the code (file:line)
- Show the concrete value at that point
- Continue until you reach the point where actual behavior diverges from expected

This is the most important step. Do not skip it. Do not summarize. Show the trace.

## Step 5: Produce the report

For EACH failure category, your report MUST include all of the following:

### Category: [name]
**Phase:** [compiler/runtime phase]
**Failing tests:** [list every test name]
**Error output:** [verbatim error messages]
**Trace evidence:**
[The step-by-step code trace from step 4, with file:line references and concrete values]
**Root cause:** [one-paragraph explanation supported by the trace above]

## Rules

- After the report, STOP. Do not offer to fix. Do not ask questions. Do not continue
  with other tasks. Just stop.
- Do not implement fixes. Investigation and reporting only.
- Do not guess or hypothesize without trace evidence. If you cannot trace it, say so.
- Do not skip failures. Every failing test must appear in the report.
- **NEVER re-run the tests.** All information must come from `/tmp/test_output.txt`.

## Tips

- E2E Elm tests: look at generated .mlir files under test/elm/eco-stuff/mlir/ or
  test/elm-bytes/eco-stuff/mlir/
- Use TEST_FILTER to selectively run smaller groups of tests for faster iteration.
- You can use --seed to reproduce specific failures.
- For elm-test frontend tests: elm-test --fuzz 1 tests/TestLogic/foo.elm
