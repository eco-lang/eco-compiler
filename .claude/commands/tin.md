---
name: /tin
description: "Test + investigate, no implementation."
---

For the test I just described (or the tests in general if none desribed):

1. Categorize all the test failures by reason for failure.
2. Order them by compiler phase, earlier categories for earlier compiler phases.
3. Investigate the root cause of each kind of test failure.
4. Use failing test cases as a source of examples to trace through the code with in order to gather evidence for how it behaves.
5. Use this evidence to support your reasoning about why the tests fail.
6. Produce a details analysis report on the test failure, ensuring that you include actual evidence from the code.

TIPS:
If running the E2E Elm tests, you can look at the generated .mlir files under @test/elm/eco-stuff/mlir or @test/elm-bytes/eco-stuff/mlir/
With the E2E tests you can also use TEST_FILTER to selectively run smaller groups of tests for faster runs.
With the elm-test tests you can also target individual tests like, elm-test --fuzz 1 tests/TestLogic/andosoon.elm to run individual test logics for faster runs.
    
Do not fix yet.
IMPORTANT: After step 4, you MUST STOP and report back to the user. DO NOT continue with other ongoing tasks.
