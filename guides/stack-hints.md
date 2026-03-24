# Stack Reduction Hints — Stage 5 Bootstrap

## Baseline
- elm-test: 11667/11668 pass (1 pre-existing failure)
- E2E: 925/935 pass (10 pre-existing failures)
- Stage 5 original --stack-size: 65536

## Warm Run Halving Progress

| Stack Size | Result | Notes |
|-----------|--------|-------|
| 512 | PASS | Starting point for this round |
| 256 | PASS | |
| 128 | FAIL→PASS | Fixed by Specialize.elm foldr→foldl conversions |
| 120 | PASS | |
| 116 | PASS | **Current warm minimum** |
| 114 | FAIL | elm-format-number splitThousands + List.foldr in MLIR pretty printing |
| 112 | FAIL | Multiple List.foldr overflows in libraries |
| 96 | FAIL | |
| 64 | FAIL | |

## Cold Run Halving Progress

| Stack Size | Result | Notes |
|-----------|--------|-------|
| 984 | FAIL→PASS | Fixed by arrayTraverseMaybeState + canonicalizer loop rewrites |
| 272 | PASS | **Current cold minimum** |
| 256 | FAIL | elm/core List.foldrHelper overflow |

## Issues

### 1. TypeSubst.applySubst deep recursion on TLambda chains
- Phase: monomorphization
- Fix: Collect TLambda chain iteratively via `applySubstLambdaChain`, build
  MFunction chain from inside out. Also TRecord Dict.map→Dict.foldl, TTuple simplification.
- Status: FIXED

### 2. TypeCheck StateT.andThen monadic chain (arrayTraverseMaybeState)
- Phase: compilation / type checking (cold only)
- Fix: Rewrote to use IO.loop (tail-recursive) instead of Array.foldl + State.andThen
- Status: FIXED

### 3. Canonicalizer traversal functions chain ReportingResult.andThen
- Phase: compilation / canonicalization (cold only)
- Fix: Rewrote 6 functions to use ReportingResult.loop with accumulators
- Status: FIXED

### 4. Specialize.elm List.foldr calls with specializeExpr
- Phase: monomorphization (warm path)
- Root cause: `specializeExprs`, `processCallArgs`, `specializeNamedExprs`,
  `specializeBranches`, `specializeEdges`, `specializeJumps` all used List.foldr
  to traverse expression lists. List.foldr uses chunked recursion (4 elements/frame,
  cap at 500), and each element calls specializeExpr which itself recursively calls
  these same functions. The compound recursion depth exceeds 128KB stack.
- Fix: Converted all 6 functions from List.foldr to List.foldl + List.reverse.
  List.foldl is compiled to a while loop (tail-call optimized), adding zero stack
  frames for list iteration. Only the expression tree depth contributes to stack.
- Impact: warm boundary dropped from 144 to 116
- Status: FIXED

### 5. elm/core List.foldrHelper (cold) and library List.foldr usage (warm)
- Phase: various — compilation (cold), MLIR gen (warm)
- Root cause: elm/core List.foldr uses chunked recursion with depth N/4, capped at
  500. For very long lists (>~2000 elements cold, >~1500 warm), this exceeds the
  reduced stack sizes. The warm overflow is in MLIR pretty-printing via
  elm-format-number's splitThousands.
- Fix direction: Would require patching elm/core or the elm-format-number package.
  Not fixable within compiler source alone.
- Status: SKIPPED — library/runtime limitation

## Summary

| Path | Original | Current Minimum | Improvement |
|------|----------|----------------|-------------|
| Warm | 65536 KB | **116 KB** | **565x** |
| Cold | 65536 KB | **272 KB** | **240x** |
