# Monomorphizer Consolidation (post-quiescence / post-J5)

## Status: IMPLEMENTED (2026-07-06) except the coupled 2.2b+2.2c and the optional 3.2b/3.4/3.6.
Progress log: `CONSOLIDATION-PROGRESS.md`. All landed items are green on 12,868 unit + 1,547
E2E and byte-identical on the deterministic MLIR corpus (HTTP tests excluded — proven
nondeterministic run-to-run), and validated by the Phase-1 and final bootstraps (Stage-8c
fixed point held).

DONE: 1.1a (finishEagerLet — 4 copies → 1), 1.2 (Closure scrutinee-type priority fix + dead
guess-tier deleted), 1.3 (4 Tracked twins deduped), 1.4 (specializeValueCycle deleted), 2.1
(PendingGlobal+PendingCall → PendingExpr; containsCEcoMVar deleted), 2.2a (Prune post-close
MONO_002 verification sweep), 2.3 (LambdaId spec-key axis deleted across 13 files), 3.1
(applySubstFiltered — dead FreeVars param dropped), 3.2a (hasCEcoTVar → hasNonNumberVar), 3.3
(canTypeToMonoType collision resolved), 3.5 (stale comments).

NOT DONE (with reasons in the progress log): 1.1b (analyzed UNSAFE — probe/re-spec run in
different specialization states, so reuse would change behavior; correctly left as-is), 1.1c
(optional fold dedup, deferred), 2.2b+2.2c (the `MVar Constraint` removal — feasibility and
byte-identical equivalence CONFIRMED, but coupled and large [plan's own estimate: 1–2 days for
2.2c]; deferred as a ready-to-implement unit to preserve budget for completing the rest),
3.2b/3.4/3.6 (optional/cosmetic/codegen-subsystem — deliberately skipped).

--- Original plan (verified, ready-to-implement) below ---

### (historical) Verification-time note: verified against the code
(Specialize.elm @ 5,917 lines, 2026-07-06). Three phases = three tiers; each item is
independently shippable. Line numbers WILL drift as items land — every item includes an
anchor grep; run it before editing.

Corrections made during verification (vs the first draft of this plan):
- **1.2**: adding a typed scrutinee to `MonoCase` would touch 15 consumer files (GlobalOpt +
  MLIR gen included). Verification found a much cheaper complete fix: a fold-priority bug in
  Closure.elm makes the real `DtRoot` type lose to a `MUnit` guess; flipping the order makes
  the guess tier provably dead. The IR change is explicitly deferred.
- **2.1**: `PendingGlobal` and `PendingCall` have identical payloads AND identical resolver
  bodies — they merge into one constructor. No wrapper type needed.
- **2.2**: upgraded to FULL removal of `MVar`'s embedded `Constraint` (originally deferred
  to Arch C). Re-verification showed full removal is implementable now and is MORE coherent
  than the halfway keyed-comparable step (which left refreshed *types* flowing into the
  registry, keeping the stamp-freshness concept alive at 2 of 6 sites). Verified: MonoType is
  never serialized (no artifact risk); every mid-pass constraint read has env in scope; all
  post-close reads are constraint-invariant by MONO_002. The one real loss — the stamp as a
  syntactic fail-fast witness of a missed closing rewrite — is replaced by a strictly
  stronger per-compile post-close verification sweep (2.2a). Sweep size measured: ~120 src
  refs in 13 files + ~290 test refs in 10 test files, overwhelmingly mechanical.
- **1.4**: verified `unify env t m` ≡ `unifyExtend env t m Dict.empty` **exactly** (both are
  `unifyHelp env t m <subst>`, TypeSubst.elm), making the deletion provably behavior-identical.

### Already done — do NOT redo
`forceCNumberToInt` (gone), standalone `resolveResidualNumbers` (fused into Prune),
`monoTypeContainsFloat` guard + `localMultiInstanceCount`/`rhsUsesLocalMulti` (deleted),
demand replay + `applySubstKeepNumber` (gone), `applySubst`→`applySubstPure` (env-pure),
J5 env threading (Join-R total). **Load-bearing, keep:** `pushExpectedType` (its removal
fails `LetNumberIfBranchTest`) and the `PendingNumberValue` path (37 `LetNumber*` failures).

---

## Test & equivalence protocol (applies to every item)

1. **Compile:** `cmake --build build --target guida` → "Success! Compiled N modules".
2. **Unit:** `cmake --build build --target elm-tests 2>&1 | tee /tmp/test_output.txt` →
   `Passed: 12868, Failed: 0`. Do not re-run; grep the file.
3. **E2E:** clear caches then run once:
   `find build -type d \( -name eco-stuff -o -name elm-stuff \) -prune -exec rm -rf {} +`
   then `/work/build/test/test 2>&1 | tee /tmp/e2e.txt` → `Tests passed: 1547`.
4. **MLIR-corpus diff (cheap byte-equivalence check, per item):** the E2E run regenerates
   ~515 deterministic `.mlir` files. Before starting an item, after a green E2E run:
   `cp -r build/test/elm/eco-stuff/mlir /tmp/mlir_before`. After the item's green E2E run:
   `diff -rq /tmp/mlir_before build/test/elm/eco-stuff/mlir`. Items marked **[BYTE-IDENTICAL]**
   must diff clean; a non-empty diff means the "refactor" changed semantics — stop and diagnose.
   Items marked **[SEMANTIC-OK]** may legitimately diff (the diff must be explainable).
5. **Bootstrap (once per phase, and after 1.1 specifically):**
   `cmake --build build --target bootstrap` (~35 min) → exit 0 (Stage 8c fixed point).
   Run exactly ONE bootstrap at a time (two racing on `build/` corrupt Stage 8a — this
   happened; check `pgrep -f "ninja bootstrap"` before launching).
6. **Snapshot/revert:** before each item `cp` the files it touches to a scratch dir; revert
   from there if the gate fails. Keep one snapshot per item, not one shared.

---

## Phase 1 — Tier 1

### 1.1 Collapse the 4× eager-let fallback into one helper
**simplify · readability · eliminate latent double-emit bug · ~150 lines removed**
**Anchor:** `grep -n "useExprType" Specialize.elm` — 4 hits, all inside `specializeExpr`'s
`TOpt.Let` arm. Verified copies (current lines):
- **A** 3231–3302: localMulti path, `Dict.isEmpty topEntry.instances` fallback
- **B** 3374–3432: localMulti path, `[] ->` stack-underflow fallback
- **C** 3472–3539: value-multi path, empty-instances fallback
- **D** 3793–3856: plain eager let (the `else` of the D7 number gate)

**Verified structure (identical in all four, modulo let-alias names `c1/c1f/cvme/c1n`):**
```elm
defMonoType0 = applySubstFV state subst defCanType        -- NOTE: OUTER `state`, not state1
exprMonoType = monoDefExprType monoDef
useExprType  = Mono.containsAnyMVar defMonoType0 || recordWidened defMonoType0 exprMonoType
defMonoType  = if useExprType then exprMonoType else defMonoType0
( enrichedSubst, enrichedEnv ) =                           -- J5 threading
    if useExprType then TypeSubst.unifyExtend state1.ctx.mvarEnv defCanType defMonoType subst
    else ( subst, state1.ctx.mvarEnv )
stateWithVar = { state1 | ctx = { c | varEnv = State.insertVar defName defMonoType c.varEnv
                                    , mvarEnv = enrichedEnv } }
( monoBody2, state2 ) =
    if useExprType then specializeExpr body enrichedSubst stateWithVar
    else ( monoBody, stateWithVar )                        -- A/B/C reuse the probe body
in ( Mono.MonoLet monoDef monoBody2
       (if Mono.containsAnyMVar monoType0 then Mono.typeOf monoBody2 else monoType0)
   , state2 )
```
D differs ONLY in the body step: it has no probe body, so it runs
`specializeExpr body enrichedSubst stateWithVar` unconditionally — which is the same
expression the helper produces when the probe is `Nothing` (when `useExprType` is False,
`enrichedSubst == subst`, so the single spec under `subst` is what A/B/C's probe already
computed). **One helper therefore covers all four with a `Maybe Mono.MonoExpr` probe.**

The conditional **double body specialization** (A/B/C spec the body a second time under
`enrichedSubst` when `useExprType` fires) is semantically required — the enriched subst can
produce a different body — but its side effects (enqueues, instance recording,
`lambdaCounter`) run twice with no rollback, absorbed only by instance-key dedup. The helper
does not remove that hazard, but it confines it to ONE audited place and enables a follow-up
guard (`if enrichedSubst == subst then reuse probe` — Elm Dict equality is structural) that
skips the re-spec when enrichment added nothing. Land the guard as a separate commit AFTER
the helper, gated by the MLIR-corpus diff.

**Steps:**
1. Add above the `TOpt.Let` arm (private, no exposing change):
   ```elm
   finishEagerLet :
       MonoState            -- OUTER state (for applySubstFV — see NOTE above)
       -> TOpt.Expr MVarId  -- body (TOpt, for the possible re-spec)
       -> Maybe Mono.MonoExpr  -- probe body from the multi machinery (Nothing on path D)
       -> Name -> Can.Type MVarId -> Mono.MonoType -> Substitution
       -> Mono.MonoDef -> MonoState   -- (monoDef, state1) from the caller's specializeDef
       -> ( Mono.MonoExpr, MonoState )
   ```
   Body = the verified structure above, with the body step:
   `case ( probeBody, useExprType ) of ( Just pb, False ) -> ( pb, stateWithVar ); _ -> specializeExpr body enrichedSubst stateWithVar`.
2. Replace A: keep its `specializeDef def subst {stateAfterBody | localMulti = restOfStack}`
   call (the specializeDef *inputs* are what differ between copies — they stay at the call
   site), then `finishEagerLet state body (Just monoBody) defName defCanType monoType0 subst monoDef state1`.
3. Replace B (specializeDef on whole `stateAfterBody`), C (valueMulti restOfStack), D
   (specializeDef on `state`, probe `Nothing`) the same way.
4. Compile; run protocol. **[BYTE-IDENTICAL]** — the helper is a verbatim extraction.
5. Separate follow-up commit: the `enrichedSubst == subst` reuse guard. **[BYTE-IDENTICAL]**
   expected (if the corpus diffs, the guard exposed a case where re-spec under an equal subst
   changed output — that would be a determinism bug worth knowing; revert the guard and file it).
6. Optional third commit: the three instance-emission folds (localMulti 3315–3369,
   valueMulti 3551–3618, number-multi 3724–3786) are near-identical
   (fold: `unifyExtend`→`specializeDef`→`renameMonoDef`; varEnv fold; `MonoLet`-chain fold).
   Differences: localMulti unifies against `info.monoType` directly; valueMulti/number-multi
   re-derive `applySubstFV stateAfterBody info.subst defCanType` (D6) — and number-multi
   additionally wraps `eagerDef` outside. Extract `emitInstanceDefs` parameterized by an
   `instanceType : Instance -> MonoType` function; keep the number-multi wrap at its call
   site. ~80 further lines. **[BYTE-IDENTICAL]**

**Bootstrap after this item** (it touches the hottest let path).

### 1.2 Fix the Closure.elm scrutinee-type priority bug; delete the dead guess tier
**remove compensation · eliminate real mistyping bug · ~45 lines removed**
**Anchor:** `grep -n "collectCaseRootTypesHelper\|inferRootTypeFromDecider" Closure.elm`

**Verified bug (Closure.elm:636–655):** for a captured var that appears only as a `MonoCase`
scrutinee, `collectCaseRootTypesHelper` inserts a type guessed from the decider's *tests*
(`inferRootTypeFromDecider` → `inferTypeFromTest`, :765–808) which maps IsInt/IsChr/IsStr
correctly but collapses **customs, Bool, List, Tuple to `MUnit`** — and only *then* folds the
decider paths (`collectCaseRootTypesFromDecider` → `collectDtPathCaseRootTypes`, :744–762),
which contain the **real** scrutinee type (`DtRoot Name MonoType`, Monomorphized.elm:780) but
insert `if not (Dict.member name acc)` — so the correct type never overrides the guess.

**Key structural fact (verified):** every `MonoDtPath` terminates in `DtRoot` (`DtIndex`/
`DtUnbox` wrap an inner path recursively). Therefore whenever `inferRootTypeFromDecider`
can return `Just` (i.e. at least one test exists), a `DtRoot` for that root is present in the
same decider — the guess tier can NEVER supply information the DtRoot fold doesn't have.
After the priority flip it is dead code.

**Steps:**
1. In `collectCaseRootTypesHelper`'s `MonoCase` arm: compute
   `accAfterDecider = collectCaseRootTypesFromDecider decider acc` FIRST; then, only if
   `root` is still absent from `accAfterDecider`, insert the `MUnit` fallback (needed only
   for a test-less `Leaf`-only decider). Delete the `inferRootTypeFromDecider` call.
2. Delete `inferRootTypeFromDecider` and `inferTypeFromTest` (now unreferenced — verify with
   grep before deleting).
3. Keep tier 1 (`varTypeMap` body scrape) and the tier-3 crash unchanged — they are
   legitimate (the body scrape is the primary source; the crash is the invariant).
4. Protocol. **[SEMANTIC-OK]**: if any corpus/bootstrap capture previously received a wrong
   `MUnit` type, its output legitimately changes — each diff must be explainable as
   "capture type corrected". Suites must stay green. (Plausibly zero diffs: an MUnit-typed
   custom capture would likely have crashed codegen already, so live occurrences are rare.)
5. **Deferred, do not do now:** adding the scrutinee `MonoType` to the `MonoCase` constructor.
   Verified cost: 15 consumer files (all of GlobalOpt, MLIR gen, MonoTraverse, Analysis…),
   and the producer (Specialize.elm:3917 `TOpt.Case` arm) does not have the scrutinee type
   at hand (it would need a `State.lookupVar root` → decider-DtRoot fallback chain of its
   own). After step 1–3 the remaining "compensation" is two small dict folds; the IR change
   no longer pays for itself. Revisit only if a fourth consumer of scrutinee types appears.

### 1.3 Deduplicate the big `Tracked*` twin arms
**simplify · readability · ~110 lines removed [BYTE-IDENTICAL]**
**Anchor:** `grep -n "TrackedVarLocal\|TrackedDefine\|TrackedRecord" Specialize.elm`

Verified pairs worth touching (bodies literally identical or near):
| Pair | Current lines | Method |
|---|---|---|
| `specializeExpr` `VarLocal`/`TrackedVarLocal` | 2514 / 2540 | **reconstruction**: `TOpt.TrackedVarLocal _ name meta -> specializeExpr (TOpt.VarLocal name meta) subst state` — payloads identical after dropping the region (verified TypedOptimized.elm:151–152) |
| `specializeNode` `Define`/`TrackedDefine` | 1566 / 1592 | reconstruction: `TOpt.TrackedDefine _ expr deps meta -> specializeNode ctorName (TOpt.Define expr deps meta) …` (check `Define`'s exact payload first: TypedOptimized.elm:431 region-only difference) |
| `processCallArg` `VarLocal`/`TrackedVarLocal` | 4406 / 4441 | reconstruction, same as above |
| `Record`/`TrackedRecord` | 4126 / 4185 | **helper extraction, NOT reconstruction**: `TrackedRecord` fields are `Data.Map.Dict String (A.Located Name) (Expr)` ordered by `A.compareLocated`; converting to `Record`'s `Dict Name` could REORDER fields, changing field-expr evaluation order (enqueue side effects) and the emitted node. Extract the shared per-field body into a helper taking a pre-extracted `List ( Name, TOpt.Expr MVarId )`, with each arm building the list in its own iteration order. |

Leave the ~2–6-line dispatch twins (1437/1440, 2739/2746, 2984/2987, 631/638) alone — the
churn exceeds the win. For reconstruction arms: re-entering `specializeExpr` with the
untracked constructor is one extra function call; the region being dropped is already ignored
(`_`) in every one of these arms (verified).

Protocol per pair (they are 4 independent commits if desired, or one). **[BYTE-IDENTICAL]**

### 1.4 Delete `specializeValueCycle`
**simplify · reduce debt · ~62 lines removed [BYTE-IDENTICAL]**
**Anchor:** `grep -n "specializeValueCycle\|specializeFunctionCycle" Specialize.elm`

Verified: with `funcDefs = []`, `specializeFunctionCycle` (2086–2172) reduces exactly to
`specializeValueCycle` (1947–2001):
- `substFromFunc = Dict.empty`, `envFromFunc = env` (its `maybeRequestedDef` is `Nothing`);
- `sharedSubst = unifyExtend env (TOpt.typeOf expr) requested Dict.empty` ≡
  `unify env (TOpt.typeOf expr) requested` — **proved identical**: `unify` is
  `unifyHelp … Dict.empty` and `unifyExtend` is `unifyHelp … baseSubst` (TypeSubst.elm:350–366);
- the `funcDefs` fold over `[]` is the identity on `( nodes, state )`;
- both then run the same `specializeValueInCycle` fold and a byte-identical
  requestedSpecId-lookup/`MonoExtern`-fallback tail.

**Steps:**
1. In `specializeCycle` (1907), change the `( True, Just (Mono.Global rc rn) )` branch to
   `specializeFunctionCycle rc rn valueDefs [] requestedMonoType state`.
2. Delete `specializeValueCycle` (def + doc comment). `specializeValueInCycle` STAYS (it is
   the shared per-value worker used by the function cycle).
3. Update `specializeFunctionCycle`'s doc comment (it currently says "specializeValueCycle
   still handles pure-value SCCs").
4. Protocol. **[BYTE-IDENTICAL]**

**End of Phase 1: run the bootstrap.**

---

## Phase 2 — Tier 2

### 2.1 Merge `PendingGlobal` + `PendingCall`; delete `containsCEcoMVar`
**cleaner design · ~25 lines removed [BYTE-IDENTICAL]**
**Anchor:** `grep -n "PendingGlobal\|PendingCall\|containsCEcoMVar" Specialize.elm Monomorphized.elm`

Verified: constructors 63–64 carry the identical payload
`(TOpt.Expr MVarId) Substitution (Can.Type MVarId)`; resolver arms 4619–4632 and 4634–4646
are byte-identical (`unifyExtend state.ctx.mvarEnv canType paramType savedSubst` →
`specializeExpr savedExpr refinedSubst (setMVarEnv refinedEnv state)`).

**Steps:**
1. Rename `PendingGlobal` → `PendingExpr` (doc: "deferred polymorphic argument — a VarGlobal
   or nested Call that needs the callee's parameter type"); delete `PendingCall`.
2. Producers: 4519 (VarGlobal, guard `Mono.containsAnyMVar monoType`) and 4485 (Call, same
   guard) both construct `PendingExpr`.
3. Resolver: one arm replaces the two.
4. `containsCEcoMVar` (Monomorphized.elm:409–421): verified **zero** uses outside its own
   definition/exposing. Remove from exposing list + `@docs` + delete.
5. Protocol. **[BYTE-IDENTICAL]**
Do NOT fold `LocalFunArg` (different payload, instance-creating resolution) or
`PendingNumberValue`/`PendingAccessor` (load-bearing, distinct resolutions) into this.

### 2.2 Remove `MVar`'s embedded `Constraint` field entirely (single source of truth)
**cleaner design · eliminate stale-stamp bug class · stronger fail-fast · net ~100+ lines
removed, `Constraint` type deleted**
**Anchors:** `grep -rn "TypeSubst.refreshConstraints" src/` ·
`grep -rn "CNumber\|CEcoValue" src/ tests/ --include="*.elm"`

**Feasibility (verified):** MonoType is never serialized (the Builder-side "Constraint" grep
hits are the version-solver's unrelated type; zero encoder references) — no artifact-format
risk. Every mid-pass read of the stamp has `MVarEnv` in scope (joins, shape guards, keying);
every post-close read is constraint-invariant because MONO_002 guarantees all surviving
MVars are boxed. Measured sweep: ~120 src refs in 13 files (Monomorphized 34, Specialize 30,
TypeSubst 20, MonoGlobalOptimize 9, Monomorphize/KernelAbi 8, State 5, MLIR KernelAbi 4,
Types 3, TypeTable 2, Prune/Monomorphize/AssignMVarIds/Analysis/Expr 1 each) + ~290 test
refs in 10 test files (mostly constructing `MVar id CEcoValue` values — mechanical arity
drops; the MONO_020/021/024-family assertions check "no MVar in user positions", which is
stamp-independent).

**Why full removal beats the halfway keyed-comparable design:** a keyed comparable alone
leaves refreshed *types* flowing into `getOrCreateSpecId` (whose internal
`toComparableSpecKey` keys on stamps), so stamp freshness would still matter at 2 of the 6
sites. Removing the field deletes the freshness concept itself: there is nothing to be stale.

**The honest trade, and its mitigation:** today, a missed closing rewrite (e.g. an
`anyNodeType` coverage gap) leaves a stamped `MVar _ CNumber` that crashes codegen or an
invariant test IF the shape is exercised — the stamp is a syntactic fail-fast witness.
Without stamps, a missed number var would silently lower as boxed (`i64` in a pointer slot —
the SIGSEGV class). **2.2a replaces this with a strictly stronger guarantee:** a per-compile
post-close sweep at the Prune boundary, unconditional rather than shape-dependent.

Land as three commits, in order, each fully gated:

**2.2a — Post-close residual verification sweep (FIRST — it guards 2.2b/c).**
In `Prune.pruneUnreachableSpecs`, after the close, verify no residual survived: for each
live closed node, `Traverse.anyNodeType (Mono.typeHasResidualNumber isNum) node` must be
False — crash `"MONO_002: residual number var survived the closing pass (specId …)"`
otherwise. Reuses the existing zero-alloc predicates; both work stamp-free (after 2.2c,
`typeHasResidualNumber`'s MVar arm is just `isNumber id`). Also close+verify
`reverseMapping`/`ctorShapes` the same way (they already run the gated close — assert the
gate is False after). Perf: one extra O(graph) allocation-free scan; measure on the phase
bootstrap — if visible, fold the check into `closeNode` (return a residual flag from the
rebuild) instead of a second scan. Update `invariants.csv` MONO_002 enforcement wording.
**[BYTE-IDENTICAL — crash-only addition]**

**2.2b — Move all mid-pass keying to a keyed comparable; delete `refreshConstraints`.**
1. Add `toComparableMonoTypeKeyed : (MVarId -> Bool) -> MonoType -> String` to
   Monomorphized.elm — the same worklist fold (~925+), with the `MVar id _` arm ignoring the
   stamp: `if isNumber id then <id-preserving CNumber encoding> else <CEcoValue sentinel>`.
   Copy both encodings verbatim from the existing arm; output must equal
   `toComparableMonoType (refreshConstraints env ty)` by construction (both read the same
   `superVars`). Add a keyed `toComparableSpecKey` variant likewise.
2. `Registry.getOrCreateSpecId` (and `lookupSpecKey` if needed) gains
   `isNumber : MVarId -> Bool` and keys via the keyed variants. Callers all have env in
   scope (verified): Monomorphize.elm ×2, Specialize.elm ×5.
3. Convert the 6 `refreshConstraints` sites (Specialize.elm 252 `enqueueSpec`, 300, 932,
   1021, 1155, 3675) to the keyed comparable, passing the UNREFRESHED type onward — safe
   because after step 2 the registry no longer keys on stamps, and the stored/forwarded
   types' stamps no longer participate in any decision (closing and joins consult the table).
4. Delete `refreshConstraints`, `hasStaleConstraint`, `refreshConstraintsRebuild`
   (+ exposing/@docs). Fast check first: `--filter LetNumber`, `--filter Float`,
   `--filter Destruct`; then full protocol.
**[BYTE-IDENTICAL — identical dedup by construction]**

**2.2c — The field-removal sweep.**
1. **Inventory first:**
   `grep -rn "CNumber\|CEcoValue" src/ tests/ --include="*.elm" > /tmp/constraint_sites.txt`
   and work it file-by-file to zero. Re-confirm no encoder matches before starting.
2. `MVar MVarId Constraint` → `MVar MVarId` (Monomorphized.elm:214). Then by read-class:
   - **applySubstPure** unbound-`TVar` arm: return `Mono.MVar mvarId`; DELETE the
     `constraintOf` lookup — a Dict lookup per unbound var on a hot path (perf win).
   - **J1/J2 joins** (`unifyMonoMono` ~529, `unifyHelp` ~381): replace stamp-pair matches
     (`( Mono.CNumber, Mono.CEcoValue )` …) with `State.isNumberVar id env` per side — env is
     already in scope; this also kills the stale-stamp-join hazard for good.
   - **Closing predicates** (`resolveNumberType`/`typeHasResidualNumber`): collapse the two
     MVar arms to `MVar id -> isNumber id`.
   - **Plain `toComparableMonoType`**: `MVar id` → sentinel unconditionally, with a doc
     banner: "POST-CLOSE ONLY — mid-pass keying MUST use toComparableMonoTypeKeyed (an
     unclosed number var would merge Int/Float specializations)". Correct post-close by
     MONO_002 + the 2.2a sweep.
   - **Mid-pass shape guards** gaining an env/isNumber parameter (callers all hold state —
     verify per function): `isNumericFixableShape`'s `MVar _ CNumber` arm, the Destruct
     dispatch's `fieldIsScalarNumber`, `isFullyMonomorphicType`'s CNumber carve-out (~5623),
     `hasCEcoTVar`, and the `MonoGlobalOptimize`/`KernelAbi` constraint reads (9 + 8 + 4
     sites — inspect each: post-GlobalOpt reads are post-close and become `MVar _` matches).
   - **Codegen** (`Generate/MLIR/{Types,TypeTable,Expr}`): `MVar _ CEcoValue` arms →
     `MVar _`; delete now-unreachable `MVar _ CNumber` crash arms (2.2a is the enforcement).
   - **`KernelAbi.canTypeToMonoType_preserveVars`**: emit `MVar id` (drop the CEcoValue arg).
   - **Tests** (~290 refs, 10 files): constructions drop the argument; assertions that
     scanned for stamped residuals re-express via the graph invariant (post-close: any
     `MVar _` in a checked position is the boxed case; the numeric-resolution tests assert
     `MInt` outputs, which is already stamp-free).
3. Delete `type Constraint = CNumber | CEcoValue` and `constraintOf` (callers move to
   `State.isNumberVar`). Rewrite the Monomorphized.elm header contract text (~186–234) and
   `invariants.csv` (MONO_002: "no MVar whose id is Number-classed in the final superVars
   survives the close — enforced every compile by the Prune post-close sweep"; MONO_003 and
   MONO_028 wording similarly de-stamped).
4. Full protocol + bootstrap + gcstats diff. Expected: small alloc win (dropped lookup,
   1-field-smaller MVar nodes). This step is design-motivated: a small regression is
   investigated, not auto-reverted.
**[BYTE-IDENTICAL expected on the corpus and the bootstrap fixed point]**

Effort: 2.2a ~1 hour; 2.2b ~half day; 2.2c ~1–2 days of inventory-driven mechanical work.

### 2.3 Delete the LambdaId spec-key axis
**reduce debt · simplify · ~40 lines removed [BYTE-IDENTICAL]**
**Anchor:** `grep -rn "Maybe LambdaId\|getOrCreateSpecId\|toComparableSpecKey" src/`

Verified: every keying call passes `Nothing` (`getOrCreateSpecId … Nothing` ×11 across
Monomorphize/Registry/Specialize; `enqueueSpec … Nothing` ×10); `toComparableSpecKey`
appends a constant `"N"` segment; **no MONO_019 test exists** (grep-confirmed — the design
doc was wrong). `LambdaId` itself is live in GlobalOpt/staging as closure identity — it
stays; only the spec-key axis goes.

**Steps (mechanical sweep, bounded — verified consumer set):**
1. Monomorphized.elm: `SpecKey Global MonoType (Maybe LambdaId)` → `SpecKey Global MonoType`;
   drop the `maybeLambda` segment from `toComparableSpecKey`; `reverseMapping` triple
   `( Global, MonoType, Maybe LambdaId )` → pair.
2. Registry.elm: `getOrCreateSpecId` drops the `Maybe LambdaId` param (6 internal refs).
3. Sweep the triple/param through the verified consumer files: Prune.elm (6 refs —
   includes the J5-closing `Maybe.map` over the triple), Monomorphize.elm,
   MonoInlineSimplify.elm (2), MonoGlobalOptimize.elm (1), Specialize.elm
   (5 `getOrCreateSpecId` + `enqueueSpec`'s own `Maybe LambdaId` parameter and its 10
   `Nothing` args).
4. Protocol. **[BYTE-IDENTICAL]** (keys shrink by a constant suffix; nothing graph-visible).

**End of Phase 2: run the bootstrap.**

---

## Phase 3 — Tier 3 (hygiene batch; one commit per bullet)

All **[BYTE-IDENTICAL]** unless noted. Anchors are greps for the symbol named.

- **Drop `applySubstWithFreeVars`' dead `FreeVars` param** (TypeSubst.elm:904 takes `_`;
  the doc at :893–895 admits filtering is by MVarIds in `canType`). Callers: Specialize.elm
  177 (`applySubstFV` — also drop `state.ctx.currentFreeVars` from the call) and 5554/5633
  region (one caller passes a real `freeVars` value — it is ignored; delete the argument and,
  if the local binding feeding it becomes unused, delete that too). Consider renaming to
  `applySubstFiltered` while touching it.
- **Rename misleading predicates.** `hasCEcoTVar` (Specialize.elm:411) is
  "has any non-number free var" — rename `hasNonNumberVar` (grep callers first).
  `isFullyMonomorphicType` (Specialize.elm:5620) treats `MVar _ CNumber` as True
  (closes-to-Int) — it is NOT `not << containsAnyMVar`; rename to
  `isMonomorphicAfterClosing` or add a doc line stating the CNumber carve-out. Do not merge
  it with `containsAnyMVar`.
- **Resolve the `canTypeToMonoType` name collision.** TypeSubst.elm:1039 (alias of
  `applySubstPure`) vs Monomorphize.elm:614 (local wrapper over the same). Delete the
  TypeSubst alias, point its 2 callers at `applySubstPure`, and rename the Monomorphize
  wrapper `entryPointMonoType` (it hardcodes a dummy env for entry points).
- **Single-ctor enums** (`MainInfo = StaticMain`, `ClosureKind = Known`,
  `KernelBackendAbiPolicy = ElmDerived`): do NOT collapse — they are deliberate placeholders
  with GlobalOpt/codegen consumers; churn exceeds value. Instead fix their doc comments to
  stop describing deleted siblings (`AllBoxed` mentions at Generate/MLIR/KernelAbi.elm:62,75
  and Context.elm:108).
- **Stale comment sweep** (verified list): `resolveResidualNumbers` mentions →
  "the residual-number close fused into Prune" (TypeSubst.elm:674, Specialize.elm:5625);
  `MONO_027` mislabel in ResolveAccessorValues.elm:14 (MONO_027 is the MonoVarGlobal-arity
  invariant — cite MONO_002/the accessor-elimination text instead); "TIER 2+3" banner
  (ResolveAccessorValues.elm:130 — two tiers exist; renumber); `numberBoxedKernels` mention
  (Monomorphize/KernelAbi.elm:191). Audit the three retirement comments naming
  `demandedNumericUseType`/`applySubstKeepNumber` (Specialize.elm 902/2345/3627, 4513) —
  these are accurate historical notes; keep, but confirm wording.
- **Perf follow-ups** (each needs the bootstrap gcstats diff, not just suites; cross-ref
  `monomorphization-perf-analysis.md` §5): (a) String spec-key economy — see
  `hash-prefix-comparable-keys.md`; (b) finish changed-flag identity preservation in
  `normalizeMonoType`/`normalizeAndOccursCheck`; (c) cache the per-`VarLocal` `freeVarIds`
  verdict. **[SEMANTIC-OK]** on gcstats numbers, byte-identical on emitted MLIR.

---

## Landing order & ground rules

1. Phase 1 in order 1.1 → 1.2 → 1.3 → 1.4; bootstrap after 1.1 and at phase end.
2. Phase 2 in order 2.1 → 2.2a → 2.2b → 2.2c → 2.3; bootstrap after 2.2c (with gcstats
   diff) and at phase end. 2.2's three sub-steps are separate commits — 2.2a must land
   first (it is the safety net for b/c).
3. Phase 3 any order, batched; one bootstrap at the end.
4. One item per commit (1.1 is up to three commits: helper, reuse-guard, fold dedup).
   Commit messages per GITSTYLE.md.
5. If any item's gate fails: revert from its snapshot, re-run the suite to confirm green,
   record the failure in this file under the item, and move on — no in-place debugging of a
   refactor that was supposed to be behavior-preserving.
6. Out of scope (Architecture C, `mvar-env-threading-and-arch-c-horizon.md`): unifying the
   localMulti/valueMulti/number-multi stacks and the solver-store engine swap. Items
   2.1/2.2 deliberately shrink what that migration must port — 2.2 in particular hands
   Arch C a constraint-free MonoType, which is exactly the representation its `zonkToMono`
   readback produces natively.

**Expected net effect:** Specialize.elm ≈ 5,500 lines (−400), Closure.elm −45,
TypeSubst.elm −80 (refresh machinery + `constraintOf`); the `Constraint` type and the
stamp-freshness concept deleted outright; MONO_002 enforced every compile at the Prune
boundary instead of shape-dependently; the double-emit hazard confined and guarded; the
`MUnit` capture mistyping fixed; zero behavior change outside item 1.2's explainable
corrections.
