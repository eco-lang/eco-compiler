# LSS stage-anchor writers — construction-anchored stage naming for `l|` heads

**FLAG REMOVED 2026-09-17 — the `lss.stageAnchor.rowFill` / `.demandFill` flags are deleted. ORDER 2 and ORDER 3 were never executed, so the flags had no consumer in the compiler at all — only config fields. The mechanism described below is GONE from the compiler (`plans/remove-default-off-lss-flags.md`); this plan stays as the record of what was measured and why it was refused.**

**Status: LOWERED, IMPLEMENTATION-READY (2026-09-02). Successor to
plans/lss-var-chain-roots.md §9.14 (M2/lamStages closed UNBUILT).
Adversarial review RUN 2026-09-02 against the code and the paper (§7,
findings AR-R1..R7); LOWERING pass same day added findings AR-L1..L4 and
SUPERSEDED the review's W1 quiescence-store design with the row-currency
demand/completion fill (§7 AR-L1 — read it before questioning why W1 is
not a store writer).**

**Metric: LSS COVERAGE (var/⊤ residue elimination), per the arc's standing
recalibration. Gate policy: small-gates (§5.2 of the parent plan) — any
sound improvement passes; the binding gate is soundness.**

Baseline (defaults, m2ref 2026-09-02, build-kernel corpus):

    coverage: positions=144165 k1=99106 kN=32904 var=10867 top=1146
              part=142 coveredBp=9156
    m2stage:  stageVar=142 bodyVar=274 arityMix=0 noHome=0


## §1 WHY — source replication, not pipe repair

The flow-repair arc established (parent plan §9.1–§9.15) that depth
knowledge — what sits BEYOND a lambda's head arrow — is minted exactly
once, at the lambda's own translation, and travels only by unification
across five hop families (argument, binder, data, join, item-boundary).
Every hop is a filter; a depth-9 chain clears only if ALL its pipes are
sound. flowConnect, varCtorRows, and LPartial each repaired one pipe, and
the residue duly concentrated in the chains that still cross an
unrepaired one. Head knowledge survives the same journeys because it has
REDUNDANT CARRIERS — member injection re-fires at references, argument
sites, and joins; it is re-derivable, multi-writer knowledge.

The mechanical root is the one design_docs/auto-borrow-inference/
lss-why-the-fidelity-program-failed.md §4 names: sets do not travel with
the type, because `Store.loadTypeC` mints fresh arrow structure on every
load (LSS_006 — `Can.TLambda` has no identity to memo on). This plan is
NOT another reconnect: it adds ANCHORED PRODUCERS that re-derive stage
knowledge locally wherever the head lands, from facts unambiguous at the
anchor. The requirement inverts: instead of "the depth survives all N
hops from the lambda's birth," it becomes "the HEAD survives to the
nearest anchor site" — which the target class satisfies by construction.

The corpus evidence (2026-09-01/02 queries over m2ref.log `pos|` rows):
the stage-hole class is dominated by single lambdas whose HEADS ride
long journeys perfectly while their next arrow goes var:

    mid 1180: 727 rows across 147 specs — a Json.Decode lambda stored
              INSIDE Decoder/Err ctor payloads at depth 7–9
    mid 5295: 124 rows across 124 specs — one lambda at map|/a0
    mid 9752:  17 rows across  17 specs — a 2-param foldl callback,
              hole at /a0/r (the second stage)

The family precedent already ships twice: for `g|` heads, the STORE half
is `mintPapSuccessorIds`/`papSuccGoC`/`papSuccWrite`
(LssInfer.elm:2858–2947) and the ROW half is `stampSelfSpine`
(Translate.elm:4707–4785 — claims LVar/⊤ cells on every demand and on
the completion join, bounded by declaredArity, never over an existing
LSet). The missing family member is the row half for `l|` heads. Per
LSS_013's shipped convention these writes use the lambda's OWN mid
("a PAP of m is still m") — no new member ids, no identity split (the
M2 kill's first horn, §9.14, stays respected).


## §2 THE FACT AND THE ALIGNMENT THEOREM

M2's settle-time own-mid hole-fill was killed (§9.14) on ALIGNMENT
ambiguity: a row fragment `Int -> (Int -> Int)` with head {l|m} cannot
tell "one more stage of m" from "q's arrow" — the arity-2-returning-
closure killer (`mkAdd3v = \a b -> \c -> …`) makes the type identical
either way, and filling with m writes a FALSE member onto q. The
m2stage census inherits the same gap (counts stageVar on
`home.arity >= 2` alone); an unknown fraction of the 142 are boundary
rows a sound writer must refuse — that fraction is a P0 deliverable.

The ambiguity is killed by ONE new fact, recorded where it is
unambiguous — the lambda's own birth injection:

**F2 (the qSpine fact):** at `injectLambdaMemberQualified arity srcLam
funcVar` (LssInfer.elm:173), record

    mid  →  StageFact { arity : Int, qSpine : Maybe Int }   -- Nothing = POISONED

where qSpine = the curried spine length of the value's type BEYOND the
first `arity` arrows — the returned q's own top-level arrow count,
measured on the funcVar store spine chasing aliases (papSuccGoC-style,
read-only). Verified (AR-R1): the injection fires PRE-BODY
(`classifyLambdaHead` at Translate.elm:1631 runs before `translate body`
at :1622) on the loaded canonical type or the demand-seeded root var —
the result region is NOT guaranteed concrete; the flex rule below is
the load-bearing guard. `injectLambdaMemberQualified` is also reached
from `injectArgLambdaMemberGo` (Translate.elm:4348) for lambda-literal
arguments, so recording covers both mint paths for free, and the fact
entry exists ATOMICALLY with the mid's first injection — no row can
carry a mid whose fact entry does not exist.

**UNITS (AR-R3, verified):** a, s, T are counted in CURRIED arrows. On
the store this is automatic (`IO.FunL` is unary). On mono rows it holds
because every mono-stage classifier emits strictly unary spines — one
arg per `MFunction` node (`Store.classifyGo` TLambda arm :3604-3621,
`zonkFlatC` :2842-2857, `Zonk.lambdaChain` :202-227); multi-arg grouping
appears only downstream in GlobalOpt (GOPT_016), after every consumer in
this plan. The walker nevertheless counts row-T as Σ `List.length args`
per node and gates cell-claims on curried start-depth — correct under
any grouping.

**The alignment theorem.** For a k1 head {l|m} at any arrow position,
with T = the observed successor-arrow chain length from that arrow
INCLUSIVE: the value is stage k of m (k unknown), T = (a − k) + s, so

    r = T − s          (within-arity arrows remaining, from here)

is decidable WITHOUT knowing k. Arrows 1..r from the position carry m;
arrows r+1.. are q's. Killer check: mkAdd3v a=2, s=1 — stage-1 fragment
T=2 ⇒ r=1 ⇒ head only, q untouched; home row T=3 ⇒ r=2 ⇒ arrows 1–2.

**Soundness direction of errors.** Over-write needs T over-counted
(impossible on a zonked row) or s under-recorded. Three rules close the
s direction:

1. **Flex ⇒ poison** (`sa|qspineFlex`): a birth walk that cannot see the
   full boundary (early non-arrow, or flex tail in q) POISONS the mid —
   not merely declines — because the hidden variant may have different s
   (rule 2).
2. **Conflict ⇒ poison** (`sa|qspineConflict`) — LOAD-BEARING (AR-R4):
   LSS_024 qualifies mids by the ENCLOSING spec's key, so a
   let-polymorphic lambda instantiated at two of ITS OWN layouts inside
   one enclosing spec shares one mid with different s (a is syntactic ⇒
   invariant; s follows instantiation: `\a b -> x` with x : α at Int vs
   Int→Int). Two variants of one mid always differ in total chain
   length (T0 = a + s), so they never inhabit the same typed position —
   which bounds the poison window's blast radius — but the fact table
   must still refuse to answer for a conflicted mid. FLIP GATE:
   `sa|qspineConflict == 0` on the corpus with a stageAnchor flag on;
   if it ever goes nonzero, the recorded v2 is keying facts by
   (mid, a + s) with ambiguous-candidate decline.
3. **Range check at every use:** decline unless 1 ≤ r ≤ a
   (`sa|rowMisfit` / `sa|fillMisfit`). r = 1 is the legitimate boundary
   (head already carries m; nothing below is m's).


## §3 DESIGN — one fact, one walker, three fill sites

**Delivery reality (AR-R5 + AR-L1 — the load-bearing architecture
facts, all verified):**

- Node/expression annotations FREEZE at translate-time zonk, bottom-up,
  and are never revisited (no post-drain re-annotation pass exists;
  `rezonkSettled` is read-only). Dispatch stamping reads node annos.
- `actualType` = `Mono.nodeType monoNode` — frozen at node build. The
  completion join (Monomorphize.elm:4260-4390) joins FROZEN types; its
  `changedJ` flag feeds censuses only, never a dirty mark
  (:4401-4421). Store writes made after translation are therefore
  UNDELIVERABLE — which killed both the draft's inline store writer
  (unsound: intra-item TOCTOU, AR-R2) and the review's quiescence store
  writer (sound but yield-null, AR-L1).
- The ONLY sound-and-delivering currencies are the ROW currencies:
  demand rows at enqueue (they seed the callee's body slots via
  `demandUnifyRoot`/`monoTypeToVarC` — LSet [m] → LsMembers [m] — so a
  filled demand makes the callee's NEXT translation emit covered
  interior annos: real node-level delivery), the stored row at the
  completion join, and the settled rows post-drain.

So both writers are ROW writers sharing ONE pure walker, and the design
collapses onto the shipped `regIdentity`/`injTotal` architecture
(stampSelfSpine at every demand + at the completion join), with the
alignment theorem replacing the declaredArity bound and `l|` facts
replacing `g|` tautologies:

- **W1 `lss.stageAnchor.demandFill`** — fill at (i) every demand before
  it reaches the registry (inside `enqueueSpecStamped`, after the
  stampSelfSpine call, Translate.elm:4792-4799; plus the two seed-path
  stampSelfSpine sites, Monomorphize.elm:118 and :4021) and (ii) the
  completion join, after the L1 stamp (the `joined1` slot,
  Monomorphize.elm:4325-4342).
- **W2 `lss.stageAnchor.rowFill`** — the same walker as a post-drain
  settle pass over registry rows (catches rows whose heads only became
  k1 late or that never re-joined).

**W1 soundness — the devirt contract, now genuinely applicable.** The
fill is conditional on a FROZEN row cell `LSet [m]` — the same
provisional-singleton epistemic status every devirt decision rides
(LSS_015: "a later join marks the spec dirty and the drain-end flush
re-translates"). Because the fill lives entirely in the row/flush world:

- a later, wider demand joins POSITION-WISE (`joinAnnotations` /
  `unionAnno`, Monomorphized.elm:2603-2657): the filled `LSet [m]` cell
  meets the newcomer's cell at the same position — LVar ⇒ LPartial [m]
  (honest lower bound, guarded at every singleton consumer), LSet ys ⇒
  union, LTop ⇒ ⊤, shape mismatch ⇒ widenSets. **No false singleton
  survives a widening join**, and the degraded row re-seeds any
  re-translation. This is what the store writer could never have: joins
  reach the row; nothing reaches a store slot.
- fills are idempotent (claim LVar cells only) and monotone up-moves in
  the finite annotation lattice ⇒ LSS_010 flush termination unaffected;
  `annoCovers`/`unionAnno` themselves are untouched (LSS_010 covers law
  — no new lattice forms).
- **Stability requires filling BOTH sides (AR-L2).** stampSelfSpine's
  own docstring records the lesson: a single unstamped demand erases
  the stamp at the join (LSet ∪ LVar). Post-LPartial the erase is
  gentler (⇒ LPartial, not ⊤) but still an erase. Hence fill at BOTH
  the demand sites and the completion join — stored and incoming agree
  at filled cells and the fill is join-stable.
- **Keyed-routing decline (AR-L3):** the fill depends on the growing
  fact table, so it is ROUND-DEPENDENT — it must never participate in
  spec-key identity. Under the default widened routing this is
  automatic (`widenSets` ⊤-widens every anno; stampSelfSpine's doc
  notes stamped/unstamped demands render identically). For globals on
  the keyed route (`lss.keyedGlobals` — annotation-carrying keys),
  DECLINE the demand-side fill (`sa|fillKeyedDecline`), reusing the
  exact routing predicate `enqueueSpec`/`lambdaInstanceMemberId`
  already share (LSS_017). The completion-join fill is post-key and
  unaffected. (stampSelfSpine can stamp pre-key because its stamps are
  tautological per global — fact-table-independent; ours are not.)
- The completion-join fill follows L1's AR-2 policy: `changedJ` is NOT
  recomputed for fill-only changes (the registry write runs
  unconditionally — Phase 4a note at :4373-4378; a fill-triggered
  re-flush would buy census value with flush churn).

**W2 soundness:** post-drain the k1 head is FINAL — every inhabitant is
an m-stage, so within-r successor cells hold deeper m-stages and the
complete-claim `LSet [m]` is exact. Nothing joins after settle.

**Fill scope notes (both writers):**

- Positions inside ARGUMENT subtrees of enclosing arrows are eligible:
  the trigger is position-local (the head set describes the value AT
  the position). This does not violate varLambda's AR-V6 (that forbids
  CONTEXT INHERITANCE into args) nor LSS_013's never-inject-arg-arrows
  (that concerns m's OWN argument arrows, which the walker never
  touches — it only descends the anchored position's result chain).
- Claim LVar cells ONLY. Never union into LSet/kN, never touch
  LPartial (v1 declines, counted) or LTop. Within a live fill context,
  a same-mid `LSet [m]` cell continues the context (already-covered
  stage); any OTHER anno stops it (`stopSet` counter).
- g| / p| / k| / c| heads are skipped by construction: only l| mids
  have fact entries, and the trigger is fact-gated. Mid-kind
  disjointness makes the no-overlap with stampSelfSpine / papSucc /
  varSucc total (AR-A5).

### v1 exclusions (v2 candidates, decisions not gaps)

- kN heads: sound with PER-MID depths (arrows 2..r_i per member i) —
  declined in v1, counted.
- LPartial heads: an LPartial [m] interior fill would be honest but is
  deferred with the rest of LPartial v2 — declined, counted.
- Raw-l| mids (signature-channel heads, LSS_017/LSS_020): no facts
  recorded (F2 records at the qualified mint) — decline as
  `sa|*NoFact`; v2 could record at the inference-phase
  injectLambdaMember if P0 shows mass.
- Conflict disambiguation by (mid, a+s) fact keys — only if
  `sa|qspineConflict` ever goes nonzero (§2 rule 2).


## §3L LOWERING — exact edits, per ORDER

### ORDER 0 — F0 config restructure (verified inventory 2026-09-02)

**DONE 2026-09-02. Gate: elm-tests 13,407/12 (the exact known-failure
baseline), full E2E 1718/1718 PASSED, decoder↔alias positional order
machine-verified 1:1 (31/31). CORRECTION (2026-09-02, found while
diagnosing census perf): `--target full` is "Gate A: clean, rebuild
default ALL + Stage 1, run JIT E2E" (/work/CMakeLists.txt:1177) and
`eco-compiler`/`eco-compiler-mlir` are NOT in default ALL
(compiler/CMakeLists.txt:440/:464, no `ALL` keyword) — so `full` runs
NEITHER Stage 5 (JS self-compile) NOR Stage 6 (native ELF). The
32-slot record GC-scan cap fails in the STAGE 6 native lowering, so
this gate did NOT re-verify it; the 31-field restructure's headroom
argument rests on the field count (31 ≤ 32), not on a Stage-6 run.
Re-verify with `--target eco-compiler` before any flip. Default hash unchanged by construction (no default values
moved; tokens emit only on divergence). NOTE: git was non-functional in
the build environment (worktree metadata pointing at an absent parent),
so the byte-diff-vs-HEAD form of the gate was replaced by the above.
FOUND+FIXED in passing, pre-existing and unrelated: PostSettleDevirtTest
still read the pre-rebundle flat AbiCloningStats fields
(devirtPostFn/Ctor/NoSpec — 13 sites → devirtPost.fn/.ctor/.noSpec);
elm-tests had been failing to COMPILE that file since the Sep 1
devirtPost re-bundle. Implementation details below are as-built.**

`LssConfig` has exactly 32 fields (Compiler/Eco/Config.elm:233-723);
the 32-slot GC-scan cap is proven binding (§9.14 trap). Restructure:

1. **Compiler/Eco/Config.elm — type alias.** Remove fields #29-31
   (`varSucc` :682, `varCtorRows` :693, `varLambda` :708). Append AT
   THE END (after `flowConnect` :722):
   `settle : LssSettleConfig` and `stageAnchor : LssStageAnchorConfig`,
   with new aliases
   `type alias LssSettleConfig = { varSucc : Bool, varCtorRows : Bool, varLambda : Bool }`
   `type alias LssStageAnchorConfig = { rowFill : Bool, demandFill : Bool }`.
   Net 32 → 31 fields (one slot headroom). Move the three fields' doc
   blocks onto the sub-record.
2. **`defaultLss` (:746-780):** replace the three lines (:776-778, all
   True) with `settle = { varSucc = True, varCtorRows = True, varLambda = True }`
   and add `stageAnchor = { rowFill = False, demandFill = False }`.
   This is the ONLY full record literal in the tree (verified — tests
   all use record-update over `defaultLss`).
3. **`lssDecoder` (:1144-1181) — POSITIONAL TRAP (AR-L4).** The decoder
   is `D.pure LssConfig` + one `D.apply` per field IN DECLARATION ORDER
   (the file warns "APPEND ONLY, and LAST" at :1154-1156). Delete the
   three applies (:1178-1180); append, LAST, one apply assembling
   `LssSettleConfig` from the SAME flat JSON keys ("varSucc",
   "varCtorRows", "varLambda" — eco-config.json compat: the JSON schema
   does NOT change) and one assembling `LssStageAnchorConfig` from new
   flat keys "stageAnchorRowFill" / "stageAnchorDemandFill"
   (defaults from `defaultLss.stageAnchor`).
4. **`hash` (:1234, LSS block :1376-1794):** rewire the three
   emit-when-non-default blocks (lssVS :1736-1747, lssVC :1750-1761,
   lssVL :1764-1775) to read `lss.settle.*` / `defaultLss.settle.*` —
   token STRINGS unchanged. Append two new emit-when-non-default blocks
   after lssFC (:1779-1790): `lssSAr=` / `lssSAd=`. Because tokens emit
   only on divergence from default, the default hash is unchanged.
5. **Behavior gates:** Monomorphize.elm:312 (`varCtorRows`), :642
   (`varLambda`), :1128 (`varSucc`) → `.settle.*`. (These are the ONLY
   three production reads; `varSuccRounds` at :1138 is an unrelated
   local name — do not touch.)
6. **Builder/Eco/Config.elm:** rewire the three handlers'
   record-updates through `updateLss` (:2114/:2117, :2136/:2139,
   :2179/:2182) to the nested field; env chain links :255-269 keep
   their names. Add two new links + handlers on the documented pattern
   (chain link → `applyLss*Override` → `updateLss`, bool parse via
   `List.member v ["1","true","yes"] / ["0","false","no"]`):
   `ECO_MONO_LSS_STAGE_ANCHOR_ROW_FILL`,
   `ECO_MONO_LSS_STAGE_ANCHOR_DEMAND_FILL`. While there, fix the three
   handler docstrings still saying "DEFAULT-OFF" (:2106, :2129, :2172 —
   defaults are ON since 2026-08-31/09-01; doc drift found by the
   inventory).
7. **Tests (6 files, record-update sites only):**
   LssVarSuccTest.elm:137, LssVarCtorRowsTest.elm:287,
   LssVarLambdaTest.elm:172, LssInjTotalTest.elm:274,
   LssRefPapSpineTest.elm:246, LssFlowEdgeLossTest.elm:229 — rewrite
   `varSucc = …` etc. as nested `settle` updates.
8. **GATE:** byte-exact typed artifacts vs HEAD (default hash and
   defaults unchanged ⇒ expected identical) + full battery
   (elm-tests, `--target full`, bootstrap).

### ORDER 1 — F2 facts + shared walker (census mode) + P0

**AS-BUILT (2026-09-02). Code complete + walker/fact CORRECTNESS proven
(tests/TestLogic/Monomorphize/StageAnchorTest.elm, 17/17 green in 10 ms):
the alignment walker on all shapes incl. the mkAdd3v BOUNDARY killer, and
the birth-side poison rules (exact/flex/conflict/absorbing — the AR-R4
let-poly variance case). Perf bug found + fixed (see PERF below). P0
corpus NUMBER pending a patient run — this machine is environmentally slow
for the JS self-compile census (see PERF).**

**PERF — the measureQSpine GC cliff (load-bearing lesson).** v1 of
`measureQSpine` walked the returned closure's FULL q-spine (unbounded by
arity) AND allocated a fresh seen-`Dict` per lambda mint. At every mint,
through demand-unified store graphs, this churned to 10 GB and OS-thrashed
(machine has 15 GB RAM): 232 min / 10 GB before the fix. Two fixes, both
in LssInfer.elm: (1) a `fuel` cap (`qMaxSpine = 8` past the arity arrows)
— overrun ⇒ `Nothing` ⇒ POISON ⇒ decline, the SAFE direction; (2) DROP
the seen-`Dict` entirely — `fuel` alone bounds the walk (a cycle burns
fuel → poison), so each call is now ≤ `arity + 8` `UF.get`s and ZERO heap
allocation. Also GATED recording on `report || stageAnchor.*` so default
builds pay nothing, and DROPPED the per-completion-per-round `sa|fillWould`
census (a `stageFill` walk per spec per flush round — the residual CPU
cost); the W1 ceiling is read from `sa|siteL1` instead, and the row `sa:`
line + `m2stage` split now print under `report` alone (not `arrowCensus`),
so a light `report=1 arrowCensus=0` run yields every P0 number.

**ENVIRONMENTAL — THE HEAP CAP IS THE WHOLE STORY (measured 2026-09-02,
supersedes the earlier "machine is just slow" reading):** the JS
`eco-boot` self-compile now needs a **peak RSS of 11.76 GB**. Under the
customary `--max-old-space-size=12288` that leaves ~240 MB of headroom,
so V8 enters a GC death-spiral and the compile NEVER COMPLETES (measured:
20:53 with zero stage-anchor code and still unfinished; 40/45/75 min
timeouts with it). Raise the cap and it completes normally:

    node --max-old-space-size=16384 ... bin/eco-boot-runner.js make ...
    → SUCCESS, wall 31:13, peak RSS 11.76 GB (12,327,216 kB),
      116 % CPU, 0 major page faults, 0 swaps, exit 0,
      artifact bin/probe_h16.mlir 15.55 MB
      (reverted/census-free tree, report OFF, machine otherwise idle)

So the historical "~12 GB is enough" note (CMakeLists Stage 5 comment,
and the ~8 min figure in [[eco-fast-census-loop-and-gate-traps]]) is
STALE — the workload has grown past it. ALWAYS pass 16 GB for a JS
self-compile here, and budget ~35-45 min (more with `report=1`).
Corollary: the machine is NOT swap-bound (0 swaps, 0 major faults at
11.8 GB peak with ~1.4 GB free) — it is a single-threaded ~116 % CPU
grind, which 16 GB does not shorten but does let FINISH.

A small probe corpus is NOT available via this path (the JS bootstrap
crashes on `Platform.Program` and the compiler package has no
`elm/html`, so only Terminal/Main.elm compiles through to mono). GET
WALKER/FACT CORRECTNESS FROM THE UNIT TEST, not the corpus.


1. **Engine.elm:**
   - `type alias StageFact = { arity : Int, qSpine : Maybe Int }`
     (Nothing = poisoned).
   - `LssMemberTable` (:466-474) gains field 8:
     `stageFacts : CoreDict.Dict Int StageFact`; update
     `emptyMemberTable` (:507). (S itself is at the 32-slot cap —
     AR-R6; the member table is the sanctioned home, per `rootLamOf`'s
     own docstring.)
   - `noteStageFact : Int -> Int -> Maybe Int -> S -> ( S, String )`
     — merge with tag for the counter bump: no entry + Just s ⇒ insert
     exact ("sa|qspineExact"); no entry + Nothing ⇒ insert poisoned
     ("sa|qspineFlex"); entry exact == measured ⇒ no-op; entry exact ≠
     measured (or arity mismatch, defensively) ⇒ poison
     ("sa|qspineConflict"); entry poisoned ⇒ stays; measured Nothing
     over exact ⇒ poison ("sa|qspineFlex"). Counter bumps report-gated
     at the call site (the m2| pattern).
2. **LssInfer.elm:**
   - `measureQSpine : Int -> IO.Variable -> Step (Maybe Int)` — walk
     funcVar chasing Alias without consuming depth (papSuccGoC arms,
     :2907-2913 pattern), consuming `arity` arrows (FunL or slotless
     Fun1 both count — an arrow is an arrow); early non-arrow/flex ⇒
     Nothing; then count q's arrow chain to a non-arrow ⇒ Just count;
     flex in q's chain ⇒ Nothing. Seen-guard like spineGoC. READ-ONLY
     (UF.get threading only).
   - Hook in `injectLambdaMemberQualified` (:173-186): after the mid
     intern, `measureQSpine arity funcVar` → `noteStageFact`. Gated on
     `lss.enabled` only — recording ships unflagged (inert without
     consumers; one extra spine walk per lambda mint, the injection's
     own cost class).
3. **Monomorphized.elm — the shared pure walker:**

       type alias StageFillStats =
           { wrote, would, boundary, misfit, stopSet, notVar, partial : Int }
       stageFill :
           Bool                                   -- True = write, False = census
           -> (Int -> Maybe StageFact)            -- fact lookup (dict passed as fn)
           -> MonoType
           -> ( MonoType, StageFillStats, Bool )  -- (row', stats, changed)

   Algorithm (single recursive walk, optional fill context
   `{ mid : Int, rem : Int }` in curried units):
   - At `MFunction _ anno args ret`, with live context (rem ≥ 1):
     anno == LVar ⇒ claim `LSet [ctx.mid]` (write mode; census bumps
     `would`); anno == LSet [ctx.mid] ⇒ continue (covered stage);
     any other anno ⇒ `stopSet`++, context dies, fall through to the
     anchor check. Budget into ret: rem − List.length args.
   - Anchor check (no live context): anno == LSet [m], fact m =
     Just { arity = a, qSpine = Just s }, a ≥ 2 ⇒
     T = curried chain length from this node inclusive
     (Σ List.length args over the MFunction spine — MonoTypes have no
     alias constructor, nothing to chase); r = T − s;
     r = 1 ⇒ `boundary`++; r < 1 or r > a ⇒ `misfit`++;
     else open context { mid = m, rem = r − List.length args } for ret.
   - args are each walked with NO context; all containers
     (MList/MTuple/MRecord/MCustom) recurse — ctor-payload positions
     (the mid-1180 class) are reached through MCustom args.
   - `changed` = any cell claimed; rebuild via `Mono.mFunction` only on
     change (hash discipline).
4. **Census wiring (all report-gated, no writes yet):**
   - renderLssReport: fold census-mode `stageFill` over
     `g.registry.reverseMapping` → render an `sa:` line
     (rowWould/boundary/misfit/stopSet/…). Keep the m2stage line for
     continuity.
   - Completion join: census-mode call on `joined1` under
     `lss.report` → `sa|fillWould` (+ per-decline tags via the
     censusCells1 list mechanism, :4344-4348).
   - Site census (informational): in `translateIndirectCallBody` after
     `translate func` (:2214 — the callee's type is in hand there, NOT
     at the :2040 arm which runs pre-translation), classify
     `Mono.headAnno (Mono.typeOf monoFunc)` × fact lookup at partial
     sites → sa|siteL1 / siteG / siteKn / sitePartial / siteTop /
     siteVar / siteNoFact.
5. **Run P0** on the build-kernel corpus; write the numbers into this
   plan. **GATE (small-gates), REVISED (fillWould census dropped for
   perf): GO if sa|rowWould + sa|siteL1 ≥ 50** (rowWould = W2 ceiling
   from the report-time row fold; siteL1 = W1 anchorable-site
   population). NO-GO ⇒ record the split, close the stageVar class with
   the number, proceed to the parent plan's ORDER 6 re-census. Note the
   baseline already puts the class at stageVar=142 (row) + lamPartialApp
   =491 (site), both » 50, so the gate's real question is what fraction
   is FACT-BACKED (svExact vs svPoison/svMiss; siteL1 vs siteNoFact).

### ORDER 2 — W2 rowFill (flag `lss.stageAnchor.rowFill`, default OFF)

1. Monomorphize.elm: `settleStageRowFill : S -> S` — the settle-family
   shape (private fold over `registry.reverseMapping` with index
   counter, write via `Registry.updateRegistryType` on changed —
   :245-278 / :1310-1345 precedents); write-mode `stageFill`; counters
   sa|rowWrote / rowBoundary / rowMisfit / rowStopSet (report-gated;
   `bumpN` pattern :586-587).
2. Wire into the chain at :160-165, after the ⊤-heal, before the first
   successor sweep (AR-A6 default; battery pins §8.4-style):

       settleVarSuccessors (settleVarLambda (settleVarSuccessors
           (settleStageRowFill (settleCtorRows (settleVarCtorRows sDrained)))))

3. Unit differential: tests/TestLogic/Monomorphize/StageAnchorTest.elm
   — pure walker cases (mkAdd3v a=2 s=1 home/fragment; plain a=2 s=0;
   a=1 no-op; misfit; nested anchors; a defensive multi-arg-node case)
   + off-vs-on pipeline differential pinning ALL overlapping flags
   (settle.varSucc/varCtorRows/varLambda, flowConnect, destrAnno, both
   stageAnchor flags — the papMembers/sigRootIdentity lesson).
   Accounting invariant to assert: write-mode wrote == census-mode
   would on the same rows.

### ORDER 3 — W1 demandFill (flag `lss.stageAnchor.demandFill`, default OFF)

1. Translate.elm `enqueueSpecStamped` (:4792-4799): after
   `stampSelfSpine`, if flag on AND the global routes WIDENED (reuse
   the exact keyed-routing predicate `enqueueSpec` /
   `lambdaInstanceMemberId` share — LSS_017; do NOT re-derive it) then
   write-mode `stageFill` on the demand; keyed-routed ⇒
   `sa|fillKeyedDecline`. Counters sa|fillWrote / fillBoundary /
   fillMisfit / fillStopSet.
2. Monomorphize.elm completion join: `joined2 = stageFill` after the L1
   stamp (insert in the :4325-4342 `joined1` let-chain; flag-gated;
   `changedJ` NOT recomputed — L1's AR-2 policy); `joined2` feeds
   `registry2`. Also apply at the two seed-path stampSelfSpine sites
   (:118 mainGlobal, :4021 flags decoder) — the "EVERY demand" clause
   of the stampSelfSpine doc is the spec.
3. Fixtures:
   - test/elm/src/LssStageAnchorFixture.elm (E2E, CHECK-carrying): the
     mkAdd3v shape; a plain arity-2 callback crossing an item boundary
     (the fill target); the let-poly variance shape (`\a b -> x`, x at
     two own-layouts in one enclosing function) pinning
     qspineConflict-poison + both writers declining; the
     provisional-widening shape (two callers passing different lambdas
     m / m′ into one callee spec) pinning the filled cell DEGRADES to
     LPartial/union across rounds — never a false singleton.
   - TestLogic keyed-decline test (keyedGlobals containing the callee ⇒
     fillKeyedDecline bumps, demand unfilled).
4. Watch `joinRounds` and `lssStats.retranslations` in the differential
   — fills must not perturb flush convergence (expected ≈flat; an
   explosion is a decline bug, treat as blocking).

### ORDER 4 — battery

Same-source arms: baseline / rowFill-only / demandFill-only / both.
Judge on:

- coverage line (var, top, part, coveredBp) — the arc's metric;
- ⊤ by provenance kind, WATCHING conflict (the +46 churn signature that
  killed flowConnect v1.1/v2 pre-LPartial; the LPartial producer rule
  should absorb the fills' asymmetric meets — pinned, not assumed);
- m2stage decay: stageVar must shrink ≈ sa|rowWould in the rowFill arm
  — exact accounting expected, unexplained residue investigated;
- settle counters (varsucc|/varlam| deltas — chains extending off newly
  named stages);
- joinRounds / retranslations (demandFill arm — flush health);
- k1/kN composition (report, don't gate);
- dispatch A/B: rowFill NEUTRAL BY CONSTRUCTION (registry-row channel);
  demandFill may move node annos via filled-demand body seeding — a
  move is a FINDING to explain either way;
- wall clock.

Soundness gates (binding): elm-tests, full E2E (`--target full` — flag
arms must delete bin/eco-compiler{,.mlir} per arm; env vars are not
ninja inputs), byte-exact self-compile bootstrap, probe rows
(LssGapLambdaStages.elm MEASURED section) identical per arm, and
`sa|qspineConflict == 0` corpus-wide (§2 rule 2's flip gate).

### ORDER 5 — flip decision + bookkeeping

Present per-arm numbers to the user for the default flip (small-gates).
On any flip: invariants.csv row for the fill discipline (fact atomicity,
poison rules, both-sides fill, keyed decline, LVar-cells-only), doc
sync, memory update.


## §7 ADVERSARIAL REVIEW — RUN 2026-09-02, plus lowering findings

Seed-by-seed outcomes (AR-A*), review findings (AR-R*), lowering
findings (AR-L*):

- **AR-A1 — ANSWERED, guard load-bearing.** Injection is pre-body; the
  result region is only as resolved as canType + demand make it.
  Flex ⇒ poison (§2 rule 1).
- **AR-A2 — REFUTED as stated; conflict path load-bearing.** LSS_024
  qualifies by the ENCLOSING spec's key; let-poly variance is real
  (§2 rule 2). a is invariant per mid; s is not.
- **AR-A3 — DISCHARGED.** papSuccGoC-pattern alias chasing on the store
  walk; MonoTypes carry no aliases; row-T counts Σ args per node.
- **AR-A4 — DISCHARGED.** deTopAnnos' negative LVar ids are ephemeral
  encode-side only (Translate.elm:3956-3970; two call sites :4054/
  :4100); read-back mints non-negative ids (Store.elm:2912-2928); no
  consumer inspects sign. Walkers may claim any LVar cell.
- **AR-A5 — DISCHARGED by mid-kind disjointness.** stampSelfSpine /
  refspine / papSucc / varSucc are g|/p|-keyed; the fill trigger is
  l|-fact-gated; mixed heads are kN ⇒ declined.
- **AR-A6 — DECIDED, battery-pinned.** rowFill after the ⊤-heal, before
  the first successor sweep.
- **AR-A7 — RESOLVED through two redesigns; see AR-R2 + AR-L1.** Final
  state: no store writes exist at all; every write is a row write whose
  flush interaction is the standard LSS_010 monotone join.
- **AR-A8 — DISCHARGED with citations.** LSet×LVar → LPartial producer
  rule (Monomorphized.elm:2626-2635); LPartial guarded at AbiCloning
  :1530-1546, MapTemplate :485-488, Borrow/LssFacts :244-247; encodes
  to FlexVar at the store boundary (Store.elm:903-910). Now
  LOAD-BEARING for W1's widening-degradation argument — pinned by the
  provisional-widening fixture.
- **AR-A9 — DISCHARGED.** Kernel-absorbed/k| heads fall into counted
  declines; nothing silently dropped.
- **AR-A10 — §8 rewritten** (AT-Abs/AT-App; unary world; quotient +
  reconstruction argument).

- **AR-R2 (review) — the inline store writer was unsound.** Per-item
  store (Engine.elm:2339, :1403-1409), monotone intra-item widening,
  LSS_010 defends cross-item only (Translate.elm:2450-2452), and
  head-only carriers exist (kernel/accessor arity-1 injects
  :4497-4501/:4457-4467; injectPapMember papInject|deep :4574-4640;
  branch-norm head unionAnno MonoGlobalOptimize.elm:271-286;
  peelResultAnno head carry :2784-2800) ⇒ an inline conditional
  interior write can freeze a false singleton into mid-item zonked
  annos (E11 class, unretractable). The review's fix (defer store
  writes to item quiescence) was itself superseded:
- **AR-L1 (lowering) — the quiescence STORE writer is yield-null;
  W1 is a ROW filler.** Verified: `actualType` is frozen at node build;
  the completion join's changedJ never dirties (:4401-4421); no re-zonk
  reads the store after translation. Post-translation store writes
  reach NOTHING. The deliverable currencies are demand rows (seed
  callee bodies — node-level delivery on the callee's next
  translation), the completion-join row, and settled rows. Hence W1 =
  demand+completion fill on the stampSelfSpine architecture, protected
  by the position-wise join lattice (a later wider join degrades a
  filled cell to LPartial/union — no false singleton survives), riding
  exactly the LSS_015 provisional-singleton contract. The TOCTOU
  vanishes because no live store slot is ever read or written.
- **AR-L2 — fill both sides or the join erases it.** stampSelfSpine's
  docstring is the recorded precedent ("a single unstamped demand would
  erase the benefit"); LSet ∪ LVar → LPartial still degrades a
  one-sided fill. Demand sites AND completion join.
- **AR-L3 — keyed-routing decline.** Fact-table-dependent fills are
  round-dependent and must not touch annotation-carrying spec keys;
  widened default routing is key-neutral under widenSets. Decline +
  counter on the keyed route.
- **AR-L4 — config decoder trap.** lssDecoder is POSITIONAL
  (D.pure + 32 applies, "APPEND ONLY, and LAST"); the restructure keeps
  the flat JSON keys (schema-compatible) and appends the two
  sub-record applies last. Full mechanical inventory (every read,
  write, hash guard, env handler, test site) is in §3L ORDER 0.
- **AR-R3 (units), AR-R5 (delivery reality), AR-R6 (fact-table
  placement), AR-R7 (range check)** — as folded into §2/§3/§3L.


## §8 PAPER FIDELITY

In the paper (Brandon et al., PLDI 2023), lambdas are UNARY —
`λ[x:τ1](y:τ2).(ε:τ3)`; multi-arg functions are tuple-takers or, for a
curried language like Elm, NESTED unary abstractions. An Elm lambda
`\a b -> \c -> e` elaborates to three abstractions ℓ1, ℓ2, ℓ3, and
every arrow carries its OWN lambda set, populated at its own
abstraction's typing (AT-Abs, Fig. 3) and merely CARRIED by AT-App —
partial application computes nothing; the result's sets are already in
the type. Cross-definition, the inclusion-constraint scheme
(`def d⟨ᾱ⟩ : (Q ⇒ τ)`, ℓ ⋸ α) re-delivers sets at every instantiation.
The question this plan answers — which arrows belong to the abstraction
and which to the value its body returns — never arises: ℓ3's arrow was
populated by ℓ3's own AT-Abs, never by ℓ1's.

Eco deviates twice; the writers close the composite gap:

1. **Mono-uncurry erases the nesting.** LSS_013's own-mid convention
   names all within-arity stage arrows with one mid m — a sound
   QUOTIENT of the paper's per-stage identity (stages of one lambda are
   one behavioral family; consumers are stage-aware through arity
   bounds). The quotient discards the paper's structural stage/body
   boundary; **F2's {arity, qSpine} is that erased boundary, recorded
   numerically at the one program point where it is still visible**,
   and r = T − s is its arithmetic shadow — reconstructing at any
   k1-headed position exactly the arrow partition (m's stages vs q's
   own-mid arrows) that AT-Abs gives the paper for free.
2. **Sets do not travel with the type** (LSS_006). Eco's transport
   approximates the paper's Q ⇒ τ instantiation and loses depth across
   hops. The fills compensate by LOCAL RE-DERIVATION where the paper
   needs none: what is a construction-time population (AT-Abs) or a
   carried result set (AT-App) there is, here, an inference from a
   frozen head cell plus construction facts — sound because under the
   own-mid quotient, "one stage deeper of every member of {m}" is the
   identity on the set's contents, placed at the depths the boundary
   fact licenses. W1's provisional version of this inference rides the
   same flush contract as every shipped singleton consumer (LSS_015);
   W2's settle version consumes final heads outright.

The deviation is representational, not semantic — the §9.10 precedent —
and the refusal arms are where the quotient's information loss is
honestly PAID: boundary/misfit/conflict refusals are positions where
the paper's distinct ℓ-ids would have known and Eco, having quotiented,
must decline. The paper's target-set semantics ("as σ — large enough to
accommodate … any other lambdas which might be present at locations to
which the result might flow") is respected end-to-end: fills claim only
unknown cells, every meet with later knowledge goes through the
position-wise join lattice, and every uncertain head (kN / LPartial /
⊤ / var / no-fact / misfit) declines.


## §9 EXPECTED YIELD, HONESTLY

Ceilings: W2 ≤ 142 minus the boundary/misfit/no-fact fractions,
registry-row currency (census + class-closure + settle feedstock,
dispatch-invisible by construction). W1's ceiling is sa|fillWould —
unknown until P0; its distinctive value is that filled DEMANDS seed
callee bodies mid-drain, i.e. node-level delivery the post-drain
writer structurally cannot produce (the Sep 1 l|-head/var-child query's
216 rows are the proxy for reachable mass). In-body expression
annotations at PAP construction sites are unreachable by ANY sound
design (frozen before every sound write point) — that residue class is
now permanently explained. This is a small-gates mechanism: its value
is (a) closing the last NAMED var class with writes or an exact refusal
count, (b) completing the anchored-writer family (g| has
papSucc+stampSelfSpine; l| gets stageAnchor), (c) de-noising the parent
plan's ORDER 6 re-census, which follows either way.


## §10 REFERENCES

- plans/lss-var-chain-roots.md §9.12–§9.16, §5.1/§5.2, §8.4/§8.5.
- plans/lss-lpartial-asymmetric-join.md (LPartial lattice; LSS_010
  covers law).
- design_docs/auto-borrow-inference/lambda-set-specialization.pdf
  (Fig. 2 L^annot, Fig. 3 AT-Abs/AT-App, §4.1 inclusion constraints);
  lss-paper-fidelity-mapping.md; lss-why-the-fidelity-program-failed.md §4.
- Compiler/MonoSolver/LssInfer.elm:173 (injectLambdaMemberQualified),
  :2858-2947 (papSucc family), :2950-3027 (LSS_013 spine injection).
- Compiler/MonoSolver/Translate.elm:1650 (classifyLambdaHead, pre-body
  at :1631), :2040-2054 (m2|lamPartialApp), :2214 (site census hook),
  :4707-4785 (stampSelfSpine — the row-fill precedent), :4792-4799
  (enqueueSpecStamped — W1 demand hook).
- Compiler/MonoSolver/Monomorphize.elm:118/:4021 (seed stamp sites),
  :160-165 (settle chain), :1795-1843 (coverage census), :2870-2955
  (m2StageWalk), :4260-4390 (completion join; W1 hook at the
  :4325-4342 joined1 slot), :4401-4421 (changedJ is census-only).
- Compiler/MonoSolver/Engine.elm:466-474 (LssMemberTable — fact home),
  :1254-1266/:2339 (resetItem contract).
- Compiler/AST/Monomorphized.elm:2603-2657 (unionAnno/LPartial arms),
  :1868-1907 (annoCoverage), :529-553 (mFunction — no collapsing).
- Compiler/Eco/Config.elm:233-780 (LssConfig+defaultLss), :1144-1181
  (lssDecoder — positional), :1376-1794 (hash LSS block);
  Builder/Eco/Config.elm:111-274 (env chain), :1724-1730 (updateLss),
  :2104-2188 (the three handlers).
- test/elm/src/LssGapLambdaStages.elm (probe; regression pin).
- design_docs/invariants.csv — LSS_005, LSS_006, LSS_010, LSS_013,
  LSS_015, LSS_017, LSS_024; FORBID_* before touching codegen-adjacent
  paths.
