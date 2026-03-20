# Memory Optimization Hints — Stage 5 Bootstrap

## Baseline (2026-03-20)
- Cold run peak: 12.4GB RSS / 11.8GB heap (post-compile spike at 214s)
- Warm run peak: 9.2GB RSS / 8.6GB heap (inline+simplify)
- E2E tests: 925/935 pass (10 pre-existing failures)
- elm-test: 11667/11668 pass (1 pre-existing failure)

## After all fixes (2026-03-20)
- Cold run peak: 12.4GB RSS / 11.8GB heap (post-compile spike — unchanged, inherent)
- Warm run peak: 8.4GB RSS / 7.7GB heap (inline+simplify — **~800MB reduction**)
- Cold compilation phase: 5.0GB peak (down from 6.2GB — **~1.2GB reduction**)
- E2E tests: 925/935 (unchanged), elm-test: 11667/11668 (unchanged)

## Applied fixes (FIXED)

### Fix 1: MVar bypass for Fresh modules (Generate.elm)
- Fresh modules' typed data passed directly without serialize/deserialize round-trip
- TypedLoadingObjects now carries both MVar-loaded (Cached) and direct (Fresh) modules
- Impact: reduced compilation-phase RSS from 6.2GB to ~5GB
- Status: FIXED

### Fix 2: Decouple artifacts record in buildMonoGraph (Generate.elm)
- Bind roots/modules in let-block to allow earlier GC of artifacts record
- Impact: minimal on its own (Elm JS closures capture full scope)
- Status: FIXED (complementary to fix 1)

### Fix 3: Inline candidates pre-filtering (MonoInlineSimplify.elm)
- Replaced ctx.nodes (full original graph) with Dict of only inlineable candidates
- Pre-filters by cost, recursion, and inlinability during initRewriteCtx
- Impact: reduces RewriteCtx memory; did not measurably reduce overall peak
  (dominated by output graph construction, not input retention)
- Status: FIXED (correct optimization, marginal impact)

### Fix 4: Release toptNodes after monomorphization worklist (Monomorphize.elm)
- Extract finalAccum, finalGlobalTypeEnv, finalLambdaCounter from finalState
  before entering assembleRawGraph, allowing toptNodes to be GC'd
- New assembleRawGraphFrom takes extracted values instead of full MonoState
- Impact: **~800MB reduction** in warm-run inline+simplify peak (8.5→7.7GB heap)
- Status: FIXED

## Remaining issues (OPEN)

### 1. Post-compile spike: BResult deserialization of all 232 modules
- Phase: after "Compiled 232 modules" (at bind 29673, io 13364)
- Impact: 12.4GB spike (cold only), GC recovers to 4GB
- Root cause: Build.elm finalizePathBuild deserializes all 232 BResult MVars
  simultaneously. All module data coexists in memory before being processed.
- Attempted: MVar bypass, artifacts decoupling — neither affects this spike
  because it occurs before Generate.elm code runs.
- Fix direction: would require restructuring Build.elm to process/discard
  modules incrementally rather than collecting all results at once.
- Status: OPEN (cold-only, transient spike — GC recovers immediately)

### 2. Inline+simplify: inherent 2x graph from fold-and-rebuild
- Phase: "Inline + simplify started"
- Impact: ~7.7GB heap (warm) — still the sustained peak
- Root cause: Array.foldl builds optimizedNodes while monomorphized graph input
  remains live. Both ~4GB graphs coexist. Inherent to immutable fold-and-rebuild.
- Fix direction: single-pass substituteAll, identity-preserving traversals,
  or processing nodes in chunks. All are moderate-complexity changes.
- Status: OPEN

### 3. Monomorphization: registry.mapping strings
- Phase: worklist
- Impact: 5-10% of mono peak
- Fix direction: drop mapping after worklist, use hash-based keys
- Status: OPEN
