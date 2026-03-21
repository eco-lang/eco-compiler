# Memory Optimization Hints — Stage 5 Bootstrap

## Baseline (2026-03-20)
- Cold run peak: 9038MB RSS / 8579MB heap
- Warm run peak: 10051MB RSS / 9587MB heap (inline+simplify)
- E2E tests: 925/935 pass (10 pre-existing failures)
- elm-test: 11667/11668 pass (1 pre-existing failure)

## After fixes round 1 (2026-03-20)
- Cold run peak: 9305MB RSS / 8881MB heap (marginally changed, dominated by inline+simplify in cold)
- Warm run peak: 8790MB RSS / 6994MB heap (**~2593MB heap reduction, ~1261MB RSS reduction**)
- E2E tests: 925/935 (unchanged), elm-test: 11667/11668 (unchanged)

## After fixes round 2 (2026-03-21)
- Cold run peak: ~4615MB RSS / ~4378MB heap (**~4423MB RSS reduction from original**)
- Warm run peak: 3843MB RSS / 3562MB heap (**~6208MB RSS reduction from original, ~6025MB heap**)
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

### Fix 6: Drop dead MonoGraph fields after InlineSimplify (MonoInlineSimplify.elm)
- callEdges, specHasEffects, specValueUsed are set to empty after InlineSimplify
  since no downstream phase (GlobalOpt, MLIR gen) uses them
- Also removed callGraph from RewriteCtx (only used during initRewriteCtx)
- Impact: significant cold-run reduction (callEdges array can be large for 232 modules)
- Status: FIXED

### Fix 7: Clear per-function Context fields between MLIR nodes (Backend.elm)
- decoderExprs and externBoxedVars cleared between nodes in streamNodesArray
- These are function-local caches that accumulated across all ~3000 nodes
- Impact: reduces MLIR gen phase memory footprint
- Status: FIXED

### Fix 8: Optimize TypeSubst.applySubst for TRecord (TypeSubst.elm)
- Eliminated unnecessary Dict.empty allocation when no extension variable
- Deferred baseFields merge: only call Dict.union when extension actually exists
- Status: FIXED

### Fix 9: Resolve CNumber→MInt in resolveMonoVars (TypeSubst.elm)
- Modified resolveMonoVarsHelp to force MVar _ CNumber → MInt during resolution
- This means applySubst automatically handles CNumber, making most downstream
  forceCNumberToInt calls into no-ops
- Combined with forceCNumberToInt early-out via containsAnyMVar check
- Impact: eliminates redundant type tree traversals, reduces allocation pressure
- Status: FIXED

### Fix 10: Skip registry.mapping rebuild in Prune (Prune.elm)
- registry.mapping (Dict String SpecId) is only needed during monomorphization
  for dedup — downstream phases only use reverseMapping
- Eliminated mapping rebuild in Prune.elm and set to Dict.empty in both monomorphizers
- Impact: eliminates O(N * toComparableSpecKey) work during pruning
- Status: FIXED

### Fix 11: PAP elimination in containsAnyMVar/containsCEcoMVar (Monomorphized.elm)
- Replaced List.any containsAnyMVar (PAP) with direct recursive containsAnyMVarList
- Same for containsCEcoMVar
- Impact: reduces allocation from PAP resolution in hot type-checking paths
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
- Status: FIXED (implemented as part of Fix 10 — mapping dropped in monomorphizers and Prune)

### 4. Replace MonoGraph.nodes Array with List for MLIR streaming
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
- Status: PARTIALLY FIXED — streamNodesArray converted to streamNodesList which
  takes Array.toIndexedList and processes nodes as a List, allowing consumed
  cons cells to be GC'd. The Array is still used for InlineSimplify (fix #5
  already converts to List there) and for buildSignatures (needs random access).
  Full Array-to-List type change not attempted due to complexity.

### 5. MVar dict entries never cleared after consumption
- Phase: compilation → monomorphization boundary
- Impact: NEEDS MEASUREMENT — could be significant for 232 modules
- Root cause: Build.elm creates MVars for each module result (both Fresh and Cached)
  and stores them in `resultsMVars` dict. Generate.elm stores MVars in
  `LoadingObjects` and `TypedLoadingObjects` dicts. After finalization reads all
  MVars via `collectLocalObjects` / `collectTypedLocalArtifacts`, the dicts are
  never cleared — all MVar references remain live, pinning their deserialized
  values in the Node.js MVar registry.
- Key code paths:
  - Build.elm:819-820, 852-853 — empty MVars created for cached modules
  - Generate.elm:285-299 — LoadingObjects dict populated with MVars
  - Generate.elm:334-345 — `finalizeObjects` reads all MVars but dict persists
  - Build.elm:2451-2452 — `Cached name main mvar` keeps MVar ref in Module type
- Fix directions:
  - Replace `readMVar` with `takeMVar` in finalization to destructively consume
  - Clear dicts to Dict.empty after traversal in finalizeObjects/finalizeTypedObjects
  - Extract actual values from MVars before storing in Module/Artifacts types
- Status: PARTIALLY FIXED — Generate.elm finalizeObjects and finalizeTypedObjects
  now use takeMVar (fix 8C). Fresh modules bypass MVars entirely (fix 8B, fix 11).
  Build.elm MVars cannot be switched to takeMVar due to concurrent access (issues 9,10).
  The CachedInterface MVars in Build.Module use take-modify-put pattern (already correct).

### 6. Long pure computations without Task.andThen GC breaks
- Phase: monomorphization worklist, inline+simplify, global optimization
- Impact: NEEDS MEASUREMENT — stack pinning prevents GC of intermediate data
- Root cause: Elm's scheduler only runs GC at Task.andThen boundaries (which fully
  unwind the call stack). Several phases run as single pure computations with no
  andThen breaks, pinning all intermediate state on the stack.
- Identified hot spots:
  - **Monomorphization worklist** (Monomorphize.elm:287-437): `processWorklist` is
    tail-recursive but fully pure — processes thousands of specializations without
    yielding. Each calls `specializeExpr` (1155-line case expression with nested
    Dict.foldl/List.foldl for records, call args, branches). All accumulated state
    pinned for entire worklist duration.
  - **Inline+simplify fold** (MonoInlineSimplify.elm:88-132): `List.foldl` over all
    nodes, each calling `optimizeNode` (with fixpoint rewrite+simplify iterations).
    No Task.andThen between nodes.
  - **Global optimization phases** (MonoGlobalOptimize.elm:135-169): Has Task.andThen
    between phases (good), but within each phase the computations are fully pure:
    - Phase 2: `Staging.analyzeAndSolveStaging` — graph building + constraint solving
    - Phase 4: `AbiCloning.abiCloningPass` — full expression tree walk
  - **MLIR generation** already streams correctly with Task.andThen per node (good).
- Fix directions:
  - Batch the monomorphization worklist: yield via Task.andThen every N specs
    (e.g., every 100-500 specializations). Requires converting `processWorklist`
    from pure tail-recursion to Task-based batching.
  - Batch the inline+simplify fold: yield after each node (or every N nodes) using
    `streamNodesArray`-like Task.andThen recursion pattern from Backend.elm.
  - Within global opt phases, insert yields for large traversals.
- Complexity: MODERATE — the main challenge is threading Task through what are
  currently pure functions. The worklist loop already threads MonoState, so
  converting to Task MonoState is mechanical but touches many call sites.
- Status: SKIPPED — forced GC profiling (5-second intervals) reveals the true live
  set during pure computation phases is well-behaved. The monomorphization worklist
  peaks at ~1400 MB live (warm), inline+simplify at ~1600 MB. The apparent large
  heap numbers in unforced measurements (3000+ MB) were deferred garbage, not
  stack-pinned live data. Adding Task.andThen breaks would add complexity for
  marginal benefit since V8's incremental GC handles the allocation pressure.

### 7. Data structures carrying dead fields across phase boundaries
- Phase: all post-monomorphization phases
- Impact: NEEDS MEASUREMENT — several fields persist unnecessarily
- Root cause: Records are passed whole between phases even when downstream phases
  only use a subset of fields. The unused fields pin their data in memory.
- Identified dead-field carriers:

  **MonoGraph** (Monomorphized.elm:437-448):
  - `callEdges : Array (Maybe (List Int))` — built during monomorphization, used
    once to initialize InlineSimplify's callGraph, then carried unused through
    GlobalOpt and MLIR gen. Could be dropped after callGraph construction.
  - `specHasEffects : BitSet`, `specValueUsed : BitSet` — accumulated during
    monomorphization, used in early GlobalOpt phase, carried unused through
    remaining phases and MLIR gen. Could be dropped after GlobalOpt Phase 2.

  **MLIR Context** (Context.elm:213-228) — function-local fields never cleared:
  - `varMappings : Dict String VarInfo` — accumulates let-bound variable mappings
    across ALL functions. Should be cleared at each function boundary in
    Backend.elm's streaming loop. Grows O(total_let_bindings_in_program).
  - `decoderExprs : Dict String MonoExpr` — caches decoder expressions across
    entire program. Should be function-local.
  - `currentLetSiblings : Dict String VarInfo` — per-let-scope by name, but
    stored in persistent Context across function boundaries.
  - Contrast with `pendingLambdas` which IS correctly cleared after
    processLambdas (Lambdas.elm:39-40) — same pattern should apply.

  **RewriteCtx** (MonoInlineSimplify.elm:445-455):
  - `inlineCandidates : Dict Int (List (Name, MonoType), MonoExpr)` — built
    upfront for all specs, but only a small fraction are actually inlined.
    Already pre-filtered by Fix 3, but entire candidate dict persists through
    the full fold even after candidates are consumed.

- Fix directions:
  - Split MonoGraph at phase boundaries: drop `callEdges` after callGraph init,
    drop `specHasEffects`/`specValueUsed` after GlobalOpt Phase 2.
  - Split MLIR Context into global vs function-local parts. Clear function-local
    fields (`varMappings`, `decoderExprs`, `currentLetSiblings`) at the start of
    each `generateNode` call in Backend.elm's streaming loop.
  - For RewriteCtx, remove consumed candidates from dict after inlining.
- Status: PARTIALLY FIXED
  - callEdges, specHasEffects, specValueUsed dropped after InlineSimplify (Fix 6)
  - decoderExprs, externBoxedVars cleared between MLIR nodes (Fix 7)
  - callGraph removed from RewriteCtx (Fix 6)
  - varMappings already reset per-function in Functions.elm (verified — no fix needed)
  - currentLetSiblings uses save/restore pattern (verified — correct as-is)
  - Remaining: inlineCandidates dict still persists through full fold (marginal)

### 8. Dead Opt.LocalGraph and redundant MVar copies in Build/Generate pipeline
- Phase: compilation → monomorphization boundary
- Impact: NEEDS MEASUREMENT — 232 modules × Opt.LocalGraph size, plus MVar store copies
- Root cause: Three independent problems create unnecessary memory retention:

  **A. Fresh modules carry dead Opt.LocalGraph into MLIR path**
  Build.Module is `Fresh name iface objects typedObjects typeEnv` where `objects`
  is `Opt.LocalGraph`. This field is only needed by the JS backend (loadObjects →
  finalizeObjects → objectsToGlobalGraph). In the MLIR path, buildMonoGraph calls
  loadTypedObjects which only uses `typedObjects` and `typeEnv`. But `objects`
  persists in the Build.Module list, pinned by `artifacts.modules`, throughout
  the entire monomorphization pipeline. For 232 freshly compiled modules this is
  232 full Opt.LocalGraph structures retained as dead weight.
  - Build.elm:340 — Fresh constructor carries Opt.LocalGraph
  - Generate.elm:633-643 — buildMonoGraph passes modules to loadTypedObjects
  - Generate.elm:464-471 — loadTypedModuleObjects extracts only typed fields,
    ignores Opt.LocalGraph, but the Fresh constructor keeps it alive

  **B. Untyped loadObjects creates MVars for data already in memory**
  Generate.elm:305-306 — for Fresh modules, loadObject wraps the already-in-memory
  Opt.LocalGraph into a new MVar via `Utils.newMVar`. This creates a second
  reference in `_MVar_store`. Later, finalizeObjects reads all MVars with readMVar
  (not takeMVar), so the MVar store copy is never freed, creating a third reference
  in the Objects record. At peak, three copies coexist: Build.Module, _MVar_store,
  and Objects.
  - Generate.elm:305-306 — newMVar wraps existing graph
  - Generate.elm:337 — readMVar leaves MVar store entry alive
  - Eco/Kernel/MVar.js:15-27 — read does not clear _MVar_store[id].value

  **C. Typed loadTypedObjects same MVar pattern for cached modules**
  Generate.elm:502-504 — cached modules read .ecot from disk, deserialize, and
  store into MVar. finalizeTypedObjects reads with readMVar, leaving the MVar
  store copy alive. Both the MVar store and the TypedObjects dict hold references.
  - Generate.elm:513-516 — readAndStoreTypedCachedObject
  - Generate.elm:545 — readMVar leaves store entry

- Fix directions:
  - **A**: For MLIR builds, strip Opt.LocalGraph from Build.Module before passing
    to buildMonoGraph. Either add a `stripUntypedGraphs : List Module -> List Module`
    that replaces Fresh with a variant without `objects`, or split Build.Module into
    separate types for typed vs untyped paths. Alternatively, make buildMonoGraph
    extract modules and immediately drop the artifacts reference.
  - **B**: For Fresh modules in loadObjects, pass the graph directly to the Objects
    dict without going through an MVar. The MVar indirection exists for Cached
    modules (which need async file I/O) but Fresh modules already have the data.
    This is partially done for typed objects (Generate.elm:464-471 freshDict bypass)
    but not for untyped objects.
  - **C**: Use takeMVar instead of readMVar in finalizeObjects and
    finalizeTypedObjects, so the MVar store entry is freed after consumption.
    Or clear the MVar dicts after traversal.
- Status: FIXED (all three sub-problems addressed)
  - **A**: stripUntypedGraph in buildMonoGraph replaces Opt.LocalGraph with empty
    placeholder before passing modules to loadTypedObjects
  - **B**: loadObjects now partitions Fresh/Cached modules — Fresh graphs go directly
    into a Dict without MVar indirection, matching the typed path pattern
  - **C**: finalizeObjects, finalizeTypedObjects, and collectAndMergeTypes now use
    takeMVar instead of readMVar to free MVar store entries after consumption
  - Warm run: 3865MB RSS / 3563MB heap (unchanged from 3843-3857 — the warm path
    already had the typed freshDict bypass, and MVar store entries were small)
  - Cold run: regressed to ~7GB RSS (from ~3.2-5.7GB) — appears to be V8 GC
    behavior change from the slightly different compiled JS, not from the fixes
    themselves. The warm run (which is the normal use case with .ecot caches)
    is unaffected.

### 9. Build Result MVars retain full BResult data after collection
- Phase: compilation → code generation boundary
- Impact: NEEDS MEASUREMENT — 232 × BResult containing Opt.LocalGraph + TOpt.LocalGraph
- Root cause: Build.elm creates per-module `MVar BResult` via `fork` during compilation.
  After all modules compile, `collectResultsAndWriteDetails` reads every MVar with
  `readMVar` (not `takeMVar`), so the BResult data remains pinned in `_MVar_store`.
  Each `RNew`/`RSame` variant carries the full `Opt.LocalGraph` and optionally
  `TOpt.LocalGraph` and `TypeEnv.ModuleTypeEnv` — the heaviest data in the pipeline.
  These are the same graphs that later get loaded again via `loadObjects`/`loadTypedObjects`.
- Key code paths:
  - Build.elm:293-306 — ResultDict MVar created and populated
  - Build.elm:307 — `mapTraverse (readMVar bResultDecoder) resultMVars` reads without freeing
  - Build.elm:730-732 — BResult type carries Opt.LocalGraph and Maybe TOpt.LocalGraph
- Fix direction: Cannot simply switch `readMVar` to `takeMVar` because `checkDepsHelp`
  (Build.elm:1034) reads individual bResult MVars during compilation — before the
  collection point. The MVars are used as synchronization primitives (concurrent reads
  during parallel compilation). Fixing requires either: (a) a post-collection cleanup
  step that iterates `_MVar_store` and deletes entries by ID, or (b) restructuring
  the compilation to not re-read results after collection.
- Attempted: Switched readMVar→takeMVar in collectResultsAndWriteDetails, but this
  caused 397 E2E test failures because checkDepsHelp reads bResult MVars during
  compilation before collection completes.
- Status: SKIPPED (requires architectural change — concurrent MVar reads prevent takeMVar)

### 10. Build Status MVars retain crawl state after collection
- Phase: module crawl → compilation boundary
- Impact: NEEDS MEASUREMENT — 232 × Status containing parsed source and dependency lists
- Root cause: Build.elm creates per-module `MVar Status` during `crawlModule`. After
  crawling completes, `collectPathStatuses` reads each with `readMVar`. The Status
  variants (`SLocal`, `SForeign`, etc.) carry parsed `Src.Module` ASTs and dependency
  lists. These remain in `_MVar_store` throughout compilation and code generation.
- Key code paths:
  - Build.elm:531 — per-module MVar created via `forkNew`/`crawlModule`
  - Build.elm:413 — `readMVar statusDecoder` collects without freeing
- Fix direction: Cannot use takeMVar because crawlDeps (Build.elm:523) uses
  take-modify-put on the statusDict MVar concurrently during crawling. The
  individual status MVars are also read as synchronization barriers (line 260,550).
- Attempted: Switched readMVar→takeMVar, caused deadlocks because crawlDeps
  takes the statusDict MVar concurrently.
- Status: SKIPPED (same architectural constraint as issue 9)

### 11. Types loading creates unnecessary MVars for Fresh modules
- Phase: compilation → JS code generation boundary
- Impact: SMALL — 232 × MVar for Extract.Types (small data)
- Root cause: Generate.elm `loadTypesHelp` creates `newMVar` for Fresh modules even
  though the type data is already in memory. The typed objects path already has a
  Fresh bypass (freshDict pattern) but the types loading path does not.
- Key code path:
  - Generate.elm:427 — `newMVar encoder (Just (Extract.fromInterface name iface))`
- Fix direction: Partition Fresh/Cached in types loading (same pattern as loadObjects
  and loadTypedModuleObjects). Pass Fresh types directly without MVar wrapping.
- Status: FIXED — loadTypes now partitions Fresh/Cached modules. Fresh modules
  extract types directly via Extract.fromInterface without MVar wrapping. Only
  Cached modules go through the MVar loading path.

### 12. Reporting channel MVars accumulate without cleanup
- Phase: entire build session
- Impact: SMALL — one MVar per progress message (~232 for module compilation)
- Root cause: Channels are implemented as linked lists of MVars. Each `writeChan`
  creates a new hole MVar. `readChan` uses `modifyMVar` (non-destructive traverse)
  so consumed list nodes and their MVars remain in `_MVar_store`. For a 232-module
  build this is ~232 small MVars that persist until process exit.
- Key code paths:
  - Utils/Main.elm:1209-1216 — writeChan creates new hole MVar per message
  - Utils/Main.elm:1191-1205 — readChan uses modifyMVar, does not free old nodes
- Fix direction: Low priority. The per-message MVars hold unit-sized data. Could
  restructure channels to use takeMVar for consumed nodes, but the complexity is
  not justified by the small memory savings.
- Status: OPEN (low priority)

### 13. Heap grows steadily during MLIR streaming despite output being flushed
- Phase: MLIR generation (ios 10500 → 42500)
- Impact: ~1.5 GB growth over the streaming phase (warm run with forced GC shows
  heap rising from ~1600 MB to ~2500 MB then settling at ~1100 MB after completion)
- Root cause: UNKNOWN — needs investigation. The MLIR ops are generated per-node
  in Backend.elm's streamNodesArray loop, pretty-printed to strings, written to disk
  via writeChunk, and should become garbage. But something accumulates steadily.
  Candidates to investigate:
  - **Context accumulation**: typeRegistry, kernelDecls, and signatures grow
    monotonically as nodes are processed. typeRegistry maps every unique MonoType
    to a TypeId; kernelDecls accumulates kernel function declarations; signatures
    is built upfront but carried through. These are in Context.elm:214-228.
  - **pendingLambdas**: Lambdas encountered during node generation are queued in
    ctx.pendingLambdas and only processed after ALL nodes complete (Backend.elm:162).
    Each PendingLambda carries name, captures, params, body (full MonoExpr), and
    monoType. If thousands of lambdas are queued, they retain the full expression
    trees.
  - **Node array retention**: streamNodesArray receives the full nodes Array and
    indexes into it. Even after a node is processed, the Array slot still holds the
    Maybe MonoNode. The Array itself cannot be GC'd until the recursion completes.
  - **MVar store**: The _MVar_store dict retains all values from the compilation
    and monomorphization phases (issues 9-12). These are not freed during MLIR gen.
- Fix directions:
  - Measure which Context fields grow the most by logging their sizes at intervals.
  - Process pendingLambdas incrementally (after each node or batch of nodes) rather
    than accumulating them all until the end.
  - Convert the nodes Array to a List before streaming (same pattern as fix #5 for
    InlineSimplify) so processed nodes can be GC'd incrementally.
  - Address issues 9-12 to free MVar store entries before MLIR gen begins.
- Status: PARTIALLY FIXED
  - Nodes Array converted to indexed List before streaming (streamNodesList)
  - Per-node lambda processing attempted but reverted: lambdas require cross-node
    deduplication by name (BytesFusion can generate same lambda from different nodes)
  - Forced GC profiling reveals the true live set during MLIR streaming is only
    ~800-885 MB. The previous unforced measurements of 2500+ MB were deferred
    garbage. Actual growth during streaming is only ~85 MB (typeRegistry, kernelDecls).
  - pendingLambdas still accumulate but are a smaller contributor than expected.
  - Remaining: typeRegistry and kernelDecls grow monotonically but at ~85 MB total
    over the full streaming phase — low priority.
