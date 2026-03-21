# Memory Optimization Hints — Stage 5 Bootstrap

## Baseline (2026-03-20)
- Cold run peak: 9038MB RSS / 8579MB heap
- Warm run peak: 10051MB RSS / 9587MB heap (inline+simplify)
- E2E tests: 925/935 pass (10 pre-existing failures)
- elm-test: 11667/11668 pass (1 pre-existing failure)

## After all fixes (2026-03-20)
- Cold run peak: 9305MB RSS / 8881MB heap (marginally changed, dominated by inline+simplify in cold)
- Warm run peak: 8790MB RSS / 6994MB heap (**~2593MB heap reduction, ~1261MB RSS reduction**)
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
- Impact: **~800MB reduction** in warm-run inline+simplify peak
- Status: FIXED

### Fix 5: List-based fold with scope isolation in MonoInlineSimplify.optimize
- Converted Array.foldl over `nodes` to List.foldl over `Array.toList nodes`
- Extracted the fold into separate `optimizeNodes` function so the `nodes` Array
  reference goes out of scope, enabling GC of the original array during processing
- List.foldl releases consumed cons cells incrementally, allowing GC to reclaim
  processed input nodes while building output nodes
- Before: warm peak 10051MB RSS / 9587MB heap; inline+simplify jump +4278MB
- After: warm peak 8790MB RSS / 6994MB heap; inline+simplify jump +2855MB
- Impact: **~2593MB heap reduction** in warm-run peak, **~1261MB RSS reduction**
- Status: FIXED

## Remaining issues

### 1. Post-compile spike: BResult deserialization of all 232 modules
- Phase: after "Compiled 232 modules"
- Impact: cold-only spike, transient — GC recovers immediately
- Root cause: Build.elm finalizePathBuild deserializes all 232 BResult MVars
  simultaneously. All module data coexists in memory before being processed.
- Attempted: MVar bypass, artifacts decoupling — neither affects this spike
- Fix direction: would require restructuring Build.elm to process/discard
  modules incrementally rather than collecting all results at once.
- Status: SKIPPED (cold-only transient spike; restructuring Build.elm is a
  major effort with high risk of correctness issues for minimal benefit since
  GC recovers immediately)

### 2. Inline+simplify: remaining output graph coexistence
- Phase: inline+simplify
- Impact: +2855MB jump (warm), the dominant warm-run peak contributor
- Root cause: The output graph (~2.9GB) must exist in memory as it's being built.
  With fix #5, input is GC'd incrementally, but output accumulation is irreducible.
  At the end of the fold, the full output graph exists before being passed downstream.
- Attempted: List-based fold (fix #5) reduced this from +4278MB to +2855MB.
  Further reduction options analyzed:
  - Identity-preserving traversals: moderate complexity, would help if many nodes
    are unchanged by inlining, but most nodes are touched during simplification
  - Streaming MLIR emission: would require merging inline+simplify with MLIR gen,
    a fundamental architecture change
  - inlineCandidates Dict: retains subset of input bodies, but subset is small
- Status: SKIPPED (remaining +2855MB is mostly the irreducible output graph size;
  further fixes require architectural changes to merge optimization with emission)

### 3. Monomorphization: registry.mapping strings
- Phase: worklist
- Impact: analysis shows mapping Dict is only ~1-3MB for the self-compiling compiler
  (originally estimated 5-10%, but that was incorrect)
- registry.mapping is only used during the worklist for deduplication; all downstream
  consumers only use registry.reverseMapping
- Fix: drop mapping to Dict.empty after worklist — trivial change but negligible impact
- Status: SKIPPED (< 3MB savings, not worth the change)

### 4. Replace MonoGraph.nodes Array with List to avoid Array.toList conversion
- Phase: inline+simplify (fix #5 does Array.toList to enable incremental GC)
- Idea: if nodes were already a List, the conversion would be free
- Investigation: NOT FEASIBLE as a simple type swap. Several critical paths
  require O(1) random access by SpecId:
  - Backend.elm:streamNodesArray — accesses nodes by SpecId during MLIR gen
  - MonoGlobalOptimize.elm — three Array.get lookups for call model / closure
    param count / body arities during staging annotation
  - Both monomorphizers (Monomorphize.elm, MonoDirect/Monomorphize.elm) build
    nodes via Array.set from a Dict keyed by SpecId
  Sequential-only consumers (GraphBuilder, ProducerInfo, Rewriter, InlineSimplify,
  Prune, Analysis, Context) only fold/map and would work fine with List.
- Alternative idea: keep Array for random-access phases, but have the
  monomorphizer also produce a parallel List (or convert to List once at the
  boundary between random-access and sequential phases). The Array could then
  be dropped before inline+simplify, avoiding the Array.toList copy.
- Status: OPEN (not yet attempted)
