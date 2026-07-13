# Solver Layout Connectivity: Residual Reconciliation (principled fix)

**Status: IMPLEMENTED 2026-07-13 (R0+R1+R2+R4 landed; gates in progress —
see "Implementation record" at the bottom). The emitter workaround is GONE:
the Patterns arms now CRASH on the erased-container/unboxable-leaf pattern
(MONO_029), and the solver records layout-consistent views instead.**

## Goal

The MonoSolver engine must never record two layout-disagreeing views of
the same runtime value. Concretely: a bare-solver-built compiler
(`ECO_MONO_ENGINE=solver`, LSS off) must self-build and run correctly —
today it SIGSEGVs in `System.TypeCheck.IO.foldMGo` ~8s into any
self-compile (the "Run A" configuration from the 2026-07-13 closure
study). The fix is solver-side type reconciliation, NOT runtime layout
dispatch: per the user ruling, **Int/Float/Char are ALWAYS unboxed in
heap fields, everything else boxed, and layout remains a pure static
function of the recorded type**. No header consultation on the mutator
read path.

## The invariant (new row, proposed MONO_029)

> Every recorded MonoType that views the same runtime value must be
> layout-equal at every aggregate interior position: all views
> concretely equal, or all views erased. `MVar _ CEcoValue` may appear
> only where EVERY view of that value is erased (erased ⇒ boxed
> everywhere, per MONO_003).

Related existing rows: MONO_013 (per-ctor CtorLayout consistency),
MONO_014 (structural layout canonicalization), FORBID_LAYOUT_002 (no
phase may assume layout equality without canonicalization),
REP_HEAP_001. None of them states the cross-view value-flow agreement
above; nothing enforces it today except the subst engine's architecture.

## Background — the miscompile

Tuple/record/ctor slot layouts are compile-time static on BOTH sides:

- The **constructor** site decides raw-vs-boxed per slot from its
  recorded element MonoTypes, emits raw or pointer stores, and writes
  the header `unboxed` bitmap (`Heap.hpp:159` — which the **GC** duly
  consults when tracing).
- The **projection** site (`EcoToLLVMHeap.cpp` Tuple2/3/custom
  lowerings) picks `emitInlineBoxedLoad` vs `emitInlinePrimLoad` purely
  from the asked result type. It never reads the header.

So construct and project must agree statically. Subst guarantees this by
construction (solve-completely-then-emit: one substitution types every
site). The solver **emits while solving**: each item zonks types out of
a store that is still accumulating constraints, and disagreement is
possible. Observed instance (solver self-compile, LSS off): inside
`foldMGo`'s spec, `eco.construct.tuple2 %acc, %i {unboxed_bitmap=4}`
stored slot 1 as raw i64 while the destructure path's recorded element
type was an erased residual → boxed arm → `emitInlineBoxedLoad` derefs
raw Int bits as an HPointer → SIGSEGV.

Two variants:
- **erased container / concrete leaf** — worked around 2026-07-13 in
  `Patterns.generateMonoPathHelper` (project the RAW slot at the
  reconciled unboxable target). This is why solver+LSS self-builds.
- **erased container / erased leaf** — hypothesized, NOT observed.
  CORRECTION (2026-07-13, deep investigation): the "still crashes"
  claim came from a STALE binary (`eco-so3-bin`, built 02:54 from MLIR
  emitted by the interim boxed+unbox front-end, before the final
  raw-slot fix landed at ~03:55). A fresh bare-solver binary built
  from post-fix MLIR (`eco-gcstats-D.mlir` → `eco-so4-bin`)
  **self-compiles green (5:50.61) and its output is BYTE-IDENTICAL to
  its input — a bare-solver fixed point**. The destructor leaf's
  `dmeta.tipe` var belongs to the connected (annotation) family in all
  observed shapes, so the leaf classifies concrete and the workaround
  always has a reconcile target.

## Two distinct defects (both confirmed in code)

**D1 — missing connections.** Views of one value live in disconnected
store components; one resolves concrete from local constraints, the
other zonks free → erased. Confirmed gap: the `TailCall` arm
(`MonoSolver/Translate.elm:424-436`) translates recursive-call args with
NO unification against the enclosing TailDef's loop params. Path/element
types then peel from the binder's recorded type (`specializeDtPath`,
`Translate.elm:3997-4030`, via `Engine.lookupVar` + `projIndexType`), so
a stale/disconnected binder type poisons every projection under it.
Other suspects: cycle sibling (`VarCycle`) boundaries;
`unifyParamsBestEffort` / `unifyStepBestEffort` silently dropping
connections on clash (`Translate.elm:2112-2140`); inliner-copied
subtrees carrying foreign canonical-id domains (the TupleSlotBoxingClosure
"crossed ids" precedent).

**D2 — read-before-saturation.** Recorded types are zonk snapshots taken
DURING translation from a monotonically-improving store. Loop params are
classified, recorded, and inserted into varEnv at function entry
(`specializeCycleFuncDef`, `Translate.elm:1099-1147`); the body
translates after; any unification the body performs (call-site
instantiations, connects — including the D1 fixes themselves) arrives
too late for already-recorded types. Even with D1 closed, snapshots can
be stale.

## Reproducers and coverage (SUPERSEDED by the 2026-07-13 deep dive — see below)

REPRODUCTION ACHIEVED at 40-line scale. The earlier "no small test
reproduces it" conclusion was an artifact of the workaround making the
emitted MLIR indistinguishable from the genuinely-concrete case.
Detection method: temporarily crash the reconcile arm
(`Utils.Crash.crash` in the `isUnboxable targetType` arms of
`Patterns.generateMonoPathHelper`), rebuild guida (`--target guida`,
DEV mode so `Debug.log` tracing is also available in
MonoSolver/Translate), compile probes via
`cd test/elm && GUIDA_JS_PATH=build/compiler/build-xhr/bin/guida.js
ECO_MONO_ENGINE=solver node /work/compiler/bin/index.js make src/X.elm
--output /tmp/x.mlir` (purge `test/elm/eco-stuff` between runs — a
crashed compile poisons it with a bogus cached Success).

### The reproducing tests (in the suite, `test/elm/src/`)

- **SolverLayoutFoldMTest** (primary) and **SolverLayoutFoldMCycleTest**
  (cycle-path variant): the reconcile arm FIRES for both under
  solver/LSS-off; traced types show the destructure root recorded as
  `T(R{count:I}, eco)` while its own leaf `b` classifies `I` — the
  disagreement in one item, demand fully concrete.
- **Runtime demonstration (harness-verified)**: with the reconcile arm
  reverted to the pre-fix boxed-load+unbox, `TEST_FILTER=SolverLayout
  ECO_MONO_ENGINE=solver cmake --build build --target check` fails
  exactly these two tests with **`Test crashed: SIGSEGV`** (the
  original foldMGo crash), and the identical build passes 6/6 under
  subst. With the workaround restored, 6/6 green under both engines —
  the tests are permanent regression sentinels for the arm.

### Mechanism localization (task: leak found)

- The disconnected id family is confined to the **TCO/TailDef-rebuilt
  node region**: the indirect-call result node under a destructure in a
  TAIL-RECURSIVE function (top-level TailDef or cycle member). The same
  destructure-of-indirect-call in a PLAIN function (SolverLayoutStepMonad's
  `andThen`) stays connected; destructures of params
  (ErasedThread/TailState probes) stay connected.
- The plain-let `bodyType` for such a call is erased too (both
  `classify defCanType` and `Mono.typeOf monoDefBody` show
  `T(R{count:I},eco)`), so the varEnv root inherits the erased view.
- **Healing channels (why no unmasked runtime failure is craftable
  today)**: (1) destructor LEAF `dmeta.tipe` vars belong to the
  connected family → concrete → the Patterns raw-slot arm reconciles;
  (2) global-call ARG unification (`unifyParamsWithArgExprs`) loads
  use-site canTypes (connected family) → callee demands heal to
  concrete (verified: `sinkSecond`/`continue`/`keep` all specialized
  `tuple2:v:i`); (3) literal/ctor patterns deep enough to touch the
  erased slot are type-blocked on a generic element; (4) `number`-super
  vars erase to CNumber, which Prune closes to MInt. SolverLayoutLeakTest
  pins channel (2) as a sentinel.
- Remaining exposure therefore = exactly the reconcile arm's
  precondition. If a shape ever produces a disconnected LEAF too, the
  final else arm emits a boxed read of a raw slot with no mask — the R0
  checker is the detector for that class.

### Bare-solver status correction

Fresh bare-solver binary (post-fix front-end): self-compile rc=0,
5:50.61, output byte-identical to input (fixed point). The historical
Run A crash = stale interim-fix binary. R3's original acceptance is
thus ALREADY MET with the workaround in place; R3 is redefined as: the
fixed point must hold with the workaround arm converted to a crash
(R4) — i.e., zero reconcile-arm firings on the self-compile after
R1/R2 fix the root.

## Milestones

### R0 — Mono-time layout-agreement checker + census (do first)

A validator over the final MonoGraph, engine-agnostic (run on subst too;
subst should be clean — that's the control). Gate under
`ECO_MONO_VALIDATE=1` env (Builder/Eco/Config.elm pattern, like
ECO_MONO_LSS); also wire into EngineDiff mode. All checks are local —
no value-identity analysis needed:

1. Case/destructure: scrutinee's recorded type vs each `specializeDtPath`
   /`specializePath` peel — flag erased-vs-unboxable disagreements per
   slot.
2. `MonoTailCall` arg types vs enclosing `MonoTailFunc` param types
   (mono-level mirror of `TailRec.checkedYieldOperands`, which fires too
   late when both recorded sides lie identically).
3. Ctor/tuple construct nodes: element layouts vs the ctorShapes
   registry entry / demanded result type interiors.
4. Call args vs callee spec's stored param layouts (registry lookup);
   assert spec keys distinguish erased-vs-Int at aggregate interiors.

Report as census counters on stderr (like the `lss globalopt:` line),
with per-violation global/spec/position detail under the env flag.

**Census run**: corpus (515 elm progs + packages) + the solver
self-compile, both engines. Expected: subst clean everywhere; solver
clean on corpus (it runs green) but VIOLATIONS on the self-compile —
including the foldMGo item. **Distill the first violating item into a
minimal corpus test** (SolverLayout naming), replacing guesswork.

Gate: checker lands with zero behavior change (validation only);
E2E suite green; census numbers recorded here.

### R1 — Close the connection gaps (D1)

- **Primary (mechanism-directed, from the 2026-07-13 localization):**
  connect the TCO/TailDef-rebuilt node family. The indirect-call
  translation's `appShapeConnect` unifies the callee's USE canType
  (`TOpt.typeOf func` — rebuilt family) with the app shape, which keeps
  the rebuilt region only internally consistent. Add an
  `enrichFromEnv`-style unification of the callee's use var with the
  callee's **varEnv-bound MonoType** (annotation family — e.g. the
  TailDef param `f`'s classified arrow) so the rebuilt result node
  joins the demand-concretized component. Verify with the
  SolverLayoutFoldM probes: after the fix, the reconcile arm must NOT
  fire (re-run the crash-instrumented detection).
- `TailCall` arm: `connectTypes (TOpt.typeOf argExpr) <paramCanType>`
  per arg. Needs the enclosing TailDef's `typedArgs` in scope — thread a
  loop-params entry through `S` (mirroring how `caseCanType` threads
  into deciders), pushed in `specializeCycleFuncDef`/TailDef and the
  local TailDef path, popped after.
- Cycle sibling calls: audit whether `VarCycle`-ref call sites replay
  arg/result unification against the sibling's annotation; add connects.
- `unifyStepBestEffort`: census-count silent failures where either side
  contains an unboxable leaf (each is a future disagreement); review the
  counts before deciding whether any must become hard failures.

Gate: R0 census strictly improves; corpus byte-diff vs subst does not
grow (the ~51 documented CEcoValue divergences may SHRINK — this moves
solver toward subst's concreteness); E2E green both engines.

### R2 — Fix read-before-saturation (D2): stale-read barrier + item re-translation

Chosen design (over full two-phase saturate-then-emit, which fights the
body-first multi-instance interleaving): reuse the LSS_010 dirty pattern
intra-item.

- Store tracks a **read set** of var roots zonked into recorded output
  (`Store.classifyDirect`/`zonkToMono` add roots to a BitSet in S).
- When a later unification **binds** a root in the read set
  (write-after-read), set an item-level `staleRead` flag (detect in
  `Store.unifyStep` where a var's content goes from unbound to bound).
- At item end (`processItem`): if stale, discard output and re-translate
  the item against the now-saturated store; loop to fixpoint with a
  small cap (`maxRetranslate`, EngineBug on exceed — the `maxJoinRounds`
  idiom). Reset the read set per pass, KEEP the store.
- Multi-instance interplay: number-multi/local-multi recording must be
  idempotent under re-translation — audit `recordMultiInstance` and the
  stacks; the LSS_010 drain-end re-translation and `retranslateAt`
  already exercise this machinery, extend their crash guards.

Expected cost: near-zero (most items never trip the barrier; TailDefs
like foldMGo pay one extra pass). Measure: corpus compile-time A/B and
a solver self-compile wall-clock vs the 5:53 baseline
(benchmarks/frontendstats.txt methodology).

Gate: R0 census → ZERO on the solver self-compile; E2E green; perf
within noise.

### R3 — Acceptance: bare-solver self-build fixed point

The Run A configuration must work end to end:
1. Solver (LSS off) Stage-7a self-compile → MLIR → eco-boot-native → binary.
2. That binary re-self-compiles (rc=0) — no SIGSEGV, no verifier rejects.
3. Its output MLIR is byte-identical to its input (fixed point), or
   divergence is triaged runtime-benign.
Also re-run the LSS configurations (solver+LSS=1, keyed) as genuine
recompiles — `find /work/test -name "*.elm" | xargs touch` first
(env-blind harness cache), never concurrently with elm-tests (~/.eco
race).

### R4 — Demote the emitter workaround; strengthen guards

- `Patterns.generateMonoPathHelper`'s reconciled-target raw-slot arm:
  once the census is clean, convert to a loud located crash when it
  would fire (regression tripwire; layout stays type-static either way).
- Keep `TailRec.checkedYieldOperands` and `ECO_LAX_CASE_VERIFY`
  diagnostics as-is.
- Remove the TEMP dbg counters in AbiCloningStats while touching
  adjacent code (flagged remove-before-commit).

### R5 — Invariants + docs + memory

- invariants.csv: add MONO_029 (text above), status `enforced` (checker),
  refs MONO_003|MONO_013|FORBID_LAYOUT_002|REP_HEAP_001.
- Update `plans/monosolver-drop-in-monomorphizer.md` §6.3-adjacent notes
  (the "solver self-compile miscompile" entry) to point here; update the
  monosolver memory when milestones land.
- Note in design_docs/monomorphization: the solver's soundness argument
  now includes the connectivity invariant + barrier.

## Risks

| Risk | Guard |
|---|---|
| Re-translation × multi-instance stacks (double-recording, index skew) | idempotency audit in R2; existing retranslateAt crash guards; corpus byte gate |
| Barrier false-positives → pathological re-translation loops | `maxRetranslate` cap → EngineBug; census counter for retranslation rounds (join-flush precedent: rounds=3 at self-compile scale) |
| Read-set bookkeeping slows the hot zonk path | BitSet on var indices (Prune/LSS BitSet precedent); measure corpus A/B before/after |
| Connects change spec keys → byte drift vs subst corpus | parity bar is runtime equivalence (user decision 2026-07-09); expectation is the 51-mismatch set shrinks; investigate any NEW mismatch |
| Checker too strict (flags benign erased-vs-erased id diffs) | compare layouts via widened/erasure-insensitive keys (`toComparableLayoutKey` intent), not raw equality |
| Env-blind harness cache invalidates gate claims | touch corpus .elm before every flag-config run |
| E2E + elm-tests concurrency corrupts ~/.eco | run serially, always |
| LSS interplay: barrier re-translation must not double-count LSS census/joins | re-use LSS_010 flush structure; run 3-config E2E gate |

## Verified facts (2026-07-13, do not re-derive)

- `Zonk.canTypeToMono`: unresolved var → `MVar id CEcoValue` (Number
  super → CNumber) — `MonoSolver/Zonk.elm:31-54`.
- `TailCall` arm has no arg↔param connect — `Translate.elm:424-436`.
- Path element types peel from the binder's recorded MonoType —
  `Translate.elm:3997-4030` (`specializeDtPath`), `4044+`
  (`specializePath`); destructor leaf = `classify meta.tipe` (`:4040`).
- TailDef params classified+recorded before body translates —
  `Translate.elm:1099-1147` (lss-on overlay branch + lss-off branch).
- The real `foldMGo`: `compiler/src/System/TypeCheck/IO.elm:325-336`
  (indirect call through param `f`, tuple destructure, tail recursion,
  member of the System.TypeCheck.IO SCC).
- SolverLayout probes: green under subst AND solver; FoldM probe's
  solver MLIR projects slot 1 raw i64, consistent bitmap=4 (checked via
  `ecoc --emit=mlir` — dumps to STDERR; .mlir artifacts are bytecode).
- Crash artifact: `build/compiler/build-kernel/bin/eco-so3-bin`
  (solver-off-built compiler) SIGSEGVs in `foldMGo_$_10564`; keyed-built
  `eco-keyed-1` works (LSS transport supplies concreteness).

## Implementation record (2026-07-13)

All milestones landed in one change set; the emitter workaround is REPLACED
by the root fix + crash enforcement.

**R1-primary** — `Translate.appShapeConnect` now runs `enrichFromEnv func
funcUseVar` before the app-shape unify: the callee's varEnv-bound MonoType
(annotation family) joins the TCO-rebuilt call node's family. Verified: the
reconcile pattern no longer occurs on any SolverLayout probe (crash arms
live, zero firings), and disabling JUST this line makes the R0 validator
fail the FoldM probe with "destructor b: path element boxed vs leaf
raw-int" (detection self-test).

**R1-secondary** — TailCall arg↔param connects: `S.loopParams` frames
(name + typed args) pushed by `withLoopFrame` around all three TailDef
body translations (cycle lss-on, cycle lss-off, local TailDef);
`connectTailCallArgs` in the TailCall arm unifies each recursive-call
arg's canType with its loop param's canType (matched by name,
best-effort). Cycle-sibling audit: sibling demands heal via use-site
canTypes (verified by the FoldMCycle probe end-to-end).

**R2** — stale-read barrier: `Store` records every read that produces a
CEcoValue residual (`ZonkCtx.ecoReads` → `S.ecoResidualReads` for store
vars; `S.ecoResidualKeyReads` for classify-miss MVarIds).
`Monomorphize.specializeNodeSaturating` re-translates the item AGAINST ITS
OWN SATURATED STORE (not a reset — a drain-end re-push would rebuild the
store and deterministically reproduce the staleness) when any recorded
read's var was later bound or Number-tainted; capped at 5 passes →
EngineBug. Scratch stores stash/restore the read lists. Known accepted
side effects when a pass is discarded: possible unreferenced (pruned)
specs enqueued under a since-healed key, and lambdaCounter gaps —
runtime-benign, only when staleness actually fired.

**R4** — the Patterns.elm reconcile arms (tuple2/tuple3/unbox-custom) are
now `Utils.Crash.crash "MONO_029 layout disagreement …"` — NO reconciling
emission exists (per the ruling: raw read is wrong if the producer boxed,
boxed read is wrong if it stored raw; the only correct fix is upstream).
The MonoRoot non-I1 unbox arm STAYS functional: it unboxes a genuinely
boxed root value (a legal MONO_003 boundary coercion), not a raw slot.

**R0** — `Compiler.Monomorphize.ValidateLayout` (first-order foldExpr
walker) gated by `ECO_MONO_VALIDATE=1` (`MonoConfig.validate`, env-only,
hash-excluded), wired into `Builder/Generate.runMonoOptPipeline` for ALL
engines; fails the compile listing violations. Checks: destructure path
element vs leaf ABI kind + tuple path slot chain; MonoTailCall args vs
loop-param ABI kinds (frames per node incl. local MonoTailDefs);
MonoTupleCreate elements vs recorded slot types. DT-path (case test)
types and custom-ctor slot cross-checks vs ctorShapes are v2 items.

**R5** — invariants.csv row MONO_029 (enforced) added. AbiCloningStats
TEMP dbg counters: deferred to the LSS commit set (cosmetic, flagged
remove-before-commit there).

**Gates run** (all with crash arms LIVE): SolverLayout probes solver+subst
clean; full default suite 1590/1590 (pre-R2 build) and re-running post-R2;
genuine solver corpus 832/832 (pre-R2) and re-running post-R2 with
ECO_MONO_VALIDATE=1; bare-solver self-build fixed point (R3) with crash
arms + validator = the acceptance gate.

## Final gate results + census findings (2026-07-13, completion)

**R3 ACCEPTANCE MET — bare-solver fixed point with the workaround GONE:**
bootstrap (subst, 4:54) → `eco-rootfix-bin` → bare-solver self-compile with
crash arms + `ECO_MONO_VALIDATE=1` → rc=0, **6:09.5** (vs 5:50 workaround-era
baseline; +5.6% = barrier + validator overhead) → lower → re-self-compile →
**`FIXED POINT: BYTE-IDENTICAL`**, zero crash-arm firings, zero validator
violations at self-compile scale.

The R0 census earned its keep — three real findings, each fixed:

1. **Saturation livelock via per-call fresh instantiations**: isolated loads
   (`loadTypeIsolated`, the SKI per-call-site design) mint vars that are
   read-free-then-bound on EVERY pass by construction. Fixes: only record
   canonical-backed reads (revMemo entry — necessary but not sufficient,
   isolated loads also populate revMemo), then the real discriminator: a
   point read is stale ONLY if its class is `UF.equivalent` to the ITEM
   MEMO's point for its canonical id (the shared family).
2. **Scratch-store point leakage**: `retranslateAt` has its own inline
   stash/restore predating `withScratchStore` and did not restore the read
   lists — scratch Point indices leaked out and aliased low outer indices
   (47 phantom stale reads at point 1, elm-parser livelock). Both stash
   sites now clear/restore the lists.
3. **Validator direction over-reach**: a RAW element with a BOXED leaf is a
   legal scalar coercion (project raw + box — the pre-existing
   unboxed-field arm); only a BOXED/erased element over a RAW leaf is
   unemittable. Also custom-container slots excluded (CtorLayout registry
   is the shared truth — MONO_013).

**Representation landmine discovered**: compiled Record heap objects have a
32-slot GC scan limit and `Engine.S` sat exactly at 32 fields — adding ANY
top-level field breaks the native self-compile at MLIR parse
("field_count (35) exceeds Record's 32-slot GC scan limit"; the corpus
never compiles S itself, so only bootstraps catch it). The three new fields
+ `lssRootAnn` are packed into ONE `S.itemAux : ItemAux` sub-record
(net 32). Anyone adding S state must extend `ItemAux` (comment on S).

Gates on the FINAL tree: SolverLayout probes clean both engines; solver
corpus 832/832 with ECO_MONO_VALIDATE=1 and zero violations (pre-itemAux
tree; re-run post-itemAux in progress at record time); full subst suite
1590/1590 (re-run in progress); keyed spot-check 6/6; R3 fixed point above.
Detector self-test: disabling the R1 enrich makes the validator fail
SolverLayoutFoldMTest with "destructor b: path element boxed vs leaf
raw-int" (rc=1).
