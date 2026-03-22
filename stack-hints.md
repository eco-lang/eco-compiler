# Stack Reduction Hints — Stage 5 Bootstrap (Cold Runs)

## Baseline
- elm-test: 11667/11668 pass (1 pre-existing failure)
- E2E: 925/935 pass (10 pre-existing failures)
- Stage 5 cold run succeeds at --stack-size=65536

## Halving Progress (Cold Runs)

| Stack Size | Result | Notes |
|-----------|--------|-------|
| 65536 | PASS | Baseline |
| 32768 | PASS | |
| 16384 | PASS | |
| 8192 | PASS | |
| 4096 | PASS | |
| 3072 | PASS | Before fixes — boundary was here (2560 failed) |
| 2560 | FAIL→PASS | Fixed by arrayTraverseMaybeState + canonicalizer loop rewrites |
| 1280 | PASS | |
| 984 | PASS | Node.js default — cold now works at default stack! |
| 512 | PASS | |
| 384 | PASS | |
| 320 | PASS | |
| 288 | PASS | |
| 272 | PASS | **Current minimum for cold runs** |
| 256 | FAIL | elm/core List.foldrHelper overflow (not fixable without patching elm/core) |

## Issues

### 1. TypeSubst.applySubst deep recursion on TLambda chains
- Phase: monomorphization (warm runs)
- Root cause: `applySubst` called itself recursively for both `from` and `to` in TLambda,
  creating stack depth proportional to function arity
- Fix: Collect TLambda chain iteratively via `applySubstLambdaChain`, then build
  MFunction chain from inside out using List.foldl
- Also converted TRecord to use Dict.foldl instead of Dict.map (reduces Dict tree frames)
- Also simplified TTuple to use List.map instead of manual cons chain
- Status: FIXED

### 2. TypeCheck StateT.andThen monadic chain depth (arrayTraverseMaybeState)
- Phase: compilation / type checking (cold runs only)
- Root cause: `arrayTraverseMaybeState` in Type.elm used `Array.foldl` with
  `State.andThen` per element, creating N nested closures for N-element arrays.
  When executed, each closure called the next, creating N stack frames.
- Fix: Rewrote to use `IO.loop` (tail-recursive) via `StateT` pattern matching
  `traverseList` in Strict.elm. Converts Array to List, processes with loop,
  builds result Array from reversed accumulator.
- Impact: eliminated stack depth proportional to array size in type checker
- Status: FIXED

### 3. Canonicalizer traversal functions chain ReportingResult.andThen per list element
- Phase: compilation / canonicalization (cold runs only)
- Root cause: `traverseExprsWithIds`, `traverseIfBranchesWithIds`,
  `traverseCaseBranchesWithIds`, `foldDefNodesWithIds`, `traverseDictEntriesWithIds`,
  `traverseUpdateEntriesWithIds` all used recursive `ReportingResult.andThen` chaining,
  creating stack depth proportional to list length
- Fix: Rewrote all six functions to use `ReportingResult.loop` (tail-recursive)
  with accumulator pattern
- Impact: cold run boundary dropped from 3072 to 272
- Status: FIXED

### 4. elm/core List.foldrHelper stack depth on large lists
- Phase: compilation (cold runs)
- Root cause: `List.foldr` in elm/core uses chunked recursion (4 elements per frame,
  switches to foldl at ctr>500). For lists exceeding ~2000 elements, this overflows
  at 256KB stack. The compiler's source modules contain lists this large.
- Fix direction: Would require patching elm/core to use a fully iterative foldr, or
  replacing all `List.map`/`List.foldr` usage on large lists with `List.foldl` + reverse.
  This is pervasive and not practically fixable without changing the core library.
- Status: SKIPPED — elm/core runtime limitation, 272KB is the practical minimum

## Summary

Stack reduced from 65536 to **272** (240x reduction) for cold runs. The remaining
barrier at 256 is the elm/core `List.foldrHelper` which cannot be fixed without
patching the core library. All fixes pass elm-test (11667/1) and E2E (925/10).
