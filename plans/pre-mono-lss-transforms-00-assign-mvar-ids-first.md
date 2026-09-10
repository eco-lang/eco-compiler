# pre-mono-lss-transforms 00 — run `AssignMVarIds` before the pre-mono passes; mint on copy

**Status:** IMPLEMENTATION-READY (2026-09-10). Item 0 of `plans/pre-mono-lss-transforms.md`.
**Origin:** `/work/pre-mono-transformation.md` §0 (the two facts), `plans/pre-mono-inline-simplify.md`
§12 (the `_pi` type-rename machinery this replaces) and §16 (the `TAlias` fix this must carry).
**Scope:** IR change only — no flag, no dispatch change expected. Every later item (01, 03, 04, 05)
is written against the graph shape this item produces.

## 1. Problem

The pre-mono inliner runs on `TOpt.GlobalGraph Name` and freshens a copied body by string suffix:
`suffixType` renames `TVar "a"` to `TVar "a_pi3"` (`InlineSimplify.elm:494-552`), `withRenamedSupers`
re-keys `varSupers` by the new NAMES (`:211`), the copy's `TLambda` slots are cleared to `NoArrow`
(`:494` doc), and `renamedTypeVars` is threaded through `Ctx` for that purpose. It works — E2E
887/889 — but it exists only because identity is assigned by name AFTER the pass. Moving
`AssignMVarIds` in front of the pre-mono pipeline makes every id an `Int`, replaces four
name-keyed mechanisms with one supply, and gives items 01/03/04 a single place to mint identity for
the nodes they create.

**What it does NOT do: ground anything.** `determines` sees the same variables after the move
(`undetermined` = 864: caller-polymorphic 520 / unsolved local 188 / body-only 156). Item 05 is
what recovers the first class. Gate accordingly (§8): the EARLY inline count must not move.

**Discrepancy found while reading (must be handled first — step 0a).** The §16 `TAlias` fix
was REVERTED from the tree after `eco-q1b` was built: `InlineSimplify.elm` and `Builder/Generate.elm`
were overwritten whole-file at 09:26:43 from a pre-Q1 copy (`eco-q1b` is 08:26:58). At the time of
reading, `typeVarsOfType`'s alias arm (`:671+`) folded the alias PARAMETER names into the free set
and `matchType`'s alias arms (`:617-622`) used `aliasBody` (the raw `Holey` body, parameters
unbound) rather than substitute-then-match, and Q1's census fields were absent. The Q1 agent is
re-applying its edits; step 0a is the check that the re-applied fix reproduces the 1,865 / 864
reference (produced by the binary) before anything is moved. Line numbers cited from
`InlineSimplify.elm` below are from the 09:26:43 copy and will shift once the edits are back.

## 2. What exists today, verified by reading

| fact | where |
|---|---|
| `assignIds : Bool -> Bool -> GlobalGraph Name -> ( GlobalGraph MVarId, GlobalMVarState )`; `state0` seeds `nextId`/`nextLam`/`nextArrow` from `TypeIds.first*`, `nextRootKey = -1` | `AssignMVarIds.elm:243-263` |
| annotations first, then nodes; each node gets a FRESH `SchemeEnv` (`env = Dict.empty`) plus its `schemeRootsForDef` | `:266-272`, `rewriteNodes :488-522` |
| `Function`/`TrackedFunction` arms mint `freshLamId` (Ctx-level; inserts `lamLabels` key with `""`) | `:734-764`, `:96-118` |
| `TLambda` arm mints `ArrowId`: `SolverRoot idx` → `ensureArrowIdForRoot` (GLOBAL `arrowRootEnv`, keyed `( moduleKey, rootIdx )`) when `useSolverRoots`, else `recordRootKey (freshArrowId ctx)`; any other slot → `freshArrowId` | `:1279-1310`, `:133-141`, `:159-186`, `:192-214` |
| `TVar name` → `ensureBinder` → root path `ensureMVarIdForRoot` (global `rootEnv`) or `ensureMVarId` (per-def `env`) → `freshMVarId` records the super in `superVars` keyed `Id.toComparable id` (STATE-level, already the right shape) | `:395-402`, `:362-390`, `:335-348`, `:310-329` |
| `TAlias` arm: each alias PARAMETER NAME also goes through `ensureBinder` — so post-assignment an alias param `a` and a scheme binder `a` of the same def share an id; alias params are alias-local by POSITION in the `( MVarId, Type )` pair, never by "not a binder" | `:1352-1376` |
| `rewriteMeta` keeps `tvar` verbatim; mono never reads it | `:615-622`; `MonoSolver/Monomorphize.elm:15` |
| `withFreshBinding` (env reset, state kept) wraps `Def`/`TailDef` bodies | `:222-235`, `:1071-1100` |
| solver entry: `insertFlagsDecoderNode` → `assignIds lssConfig.arrowSolverRoots lssConfig.arrowCensus` → `findEntryPointId` → `initState … mvarState` | `MonoSolver/Monomorphize.elm:83-106` |
| `initState` consumes `superVars`, `nextId`, `nextLam` (→ `nextMemberId`), `lamLabels`, `arrowRootOf`, `nextArrow`, `nextRootKey`, and the five stamp-census counters | `:3879-3928` |
| subst entry: same shape with `assignIds False False`; `State.initMVarEnv mvarState.nextId mvarState.superVars` | `Monomorphize/Monomorphize.elm:85-102` |
| diff engine calls BOTH Name-typed entries on the Name graph | `MonoSolver/Diff.elm:44-62` |
| `insertFlagsDecoderNode` builds a Name-typed `TOpt.Define` (decoder expr from `Port.toFlagsDecoder`, `tvar = Nothing`) under `main$flagsDecoder`; `findEntryPointId` is on the MVarId graph | `EntryPrep.elm:29-96`, `:99-120` |
| Generate: `runMonoOptPipeline :741` runs `InlineSimplify.optimize` on the Name graph; `monoPipelineFrom :771` → `selectMonomorphizer :824` dispatches per engine to the Name-typed entries; `mono.validate` gates `ValidateLayout.validate` on the MonoGraph at `:796` | `Builder/Generate.elm` |
| occurrence-id `==` fast path `sameCanTypeIgnoringArrows` = `(a == b) || strip == strip` | `Translate.elm:3004-3006` |
| tests: `runToMono :340` → `monomorphizeAny :860` (Name); `runSolverMonoWithReport :514`, `runSubstMonoWithLimits :534` (Name); `LssSigRootIdentityTest.elm:204` calls `assignIds False False globalGraph`; `InlineSimplifyTest.elm:158-206` and `InlineSimplifyDestructCaptureTest.elm:64-67` call `optimize` on `runToMono`'s Name graph | `TestLogic/…` |
| `InlineConfig` has 19 fields; this item adds none | `Compiler/Eco/Config.elm` |

## 3. Design

### 3.1 The moved entry (both engines keep their Name-typed wrappers)

Add an "assigned" core to each engine; the existing entry becomes a 3-line wrapper, so `MonoDiff`,
`TestPipeline` and every existing test are untouched:

```elm
-- MonoSolver/Monomorphize.elm
type alias Assigned = { graph : TOpt.GlobalGraph TypeIds.MVarId, flagsGlobal : Maybe TOpt.Global, mvarState : AssignMVarIds.GlobalMVarState }
monomorphizeWithReportAssigned : Config.LssConfig -> Config.SpecLimits -> Name -> TypeEnv.GlobalTypeEnv -> Assigned -> Result String ( Mono.MonoGraph, Maybe String )
-- body = today's :91-135 from `findEntryPointId` on, reading nodes/annotations out of `assigned.graph`
monomorphizeWithReport lss limits entry env g = monomorphizeWithReportAssigned lss limits entry env (assign lss entry g)
-- Monomorphize/Monomorphize.elm: monomorphizeWithLimitsAssigned … Assigned …; wrapper likewise with `assignIds False False`
-- MonoSolver/Diff.elm: runAssigned dump entry env assigned — calls both Assigned cores
```

`assign : ( Bool, Bool ) -> Name -> GlobalGraph Name -> Assigned` lives in `EntryPrep` (it is
engine-agnostic): `insertFlagsDecoderNode entry g |> \( g1, fg ) -> ( assignIds a b g1, fg )`.
The flags decoder node is Name-typed and is built BEFORE assignment at both sites today (`:85-90`,
`:93-99`); it moves with assignment. `findEntryPointId` stays in the engines (MVarId graph).

**Per-engine assignment flags are preserved:** solver `( lss.arrowSolverRoots, lss.arrowCensus )`,
subst and diff `( False, False )` — `assignFlagsFor : Config.MonoEngine -> Config.LssConfig -> ( Bool, Bool )`
in Generate. Changing the subst engine's flags would move its output.

### 3.2 Generate: the pre-mono pipeline

```elm
runMonoOptPipeline ecoConfig stats typedGraph globalTypeEnv =
    FEStats.withPhase stats FEStats.PhaseMono   -- keep assignIds's time where it is attributed today
        (let assigned0 = EntryPrep.assign (assignFlagsFor engine lss) "main" typedGraph
             ( assigned1, metrics ) = preMonoPasses ecoConfig assigned0     -- items 04 → 01 → 03 → InlineSimplify, each `Config -> Assigned -> ( Assigned, m )`
         in reportPreMono … |> andThen (\_ -> validateMinted ecoConfig assigned1) |> andThen (monoPipelineFromAssigned …))
```

`selectMonomorphizer` gains `selectMonomorphizerAssigned : EcoConfig -> GlobalTypeEnv -> Assigned -> …`
(solver/subst/diff → the three Assigned cores); the Name-typed `selectMonomorphizer` is deleted
(its only caller was `monoPipelineFrom`). `validateMinted` runs `Fresh.assertMinted` when
`ecoConfig.mono.validate` (the flag that already gates MONO_029 at `:796`), throwing
`Exit.GenerateMonomorphizationError`.

### 3.3 `Compiler/GlobalOpt/PreMono/Fresh.elm` — the ONE minting helper

```elm
module Compiler.GlobalOpt.PreMono.Fresh exposing (Subst, freshenCopy, mintNewNode, assertMinted, mintedReport)
type alias Subst = Dict String (Can.Type TypeIds.MVarId)          -- keyed by Id.toComparable
freshenCopy : Subst -> GlobalMVarState -> TOpt.Expr TypeIds.MVarId -> ( TOpt.Expr TypeIds.MVarId, GlobalMVarState )
mintNewNode : GlobalMVarState -> TOpt.Expr TypeIds.MVarId -> ( TOpt.Expr TypeIds.MVarId, GlobalMVarState )
assertMinted : TOpt.GlobalGraph TypeIds.MVarId -> Result String ()
```

Needs three STATE-level supplies exported from `AssignMVarIds` (today `freshLamId`/`freshArrowId`
are `Ctx`-level, `freshMVarId` is already state-level): `mintLamId`, `mintArrowId` (5 lines each,
`Id.succ` on `nextLam`/`nextArrow`; `mintLamId` inserts the `lamLabels` key with `""` exactly as
`:113` does so census `Dict.size` parity holds), and the existing `freshMVarId`. Export
`GlobalMVarState(..)` fields are already accessible (alias).

`freshenCopy` — COPY semantics, one walk with `CopyEnv = { subst, renamed : Dict Int MVarId, st }`:
- `TVar id`: `subst` hit → splice the bound type VERBATIM (it is the caller's type; its ids and
  arrows are already consistent with the caller — do not walk it); else `renamed` hit → that id;
  else `freshMVarId (Dict.get (toComparable id) st.superVars) st`, record in `renamed` (the super
  is copied by id — this replaces `withRenamedSupers`).
- `TLambda _ a b` → `TLambda (Arrow fresh)` with `mintArrowId`. Root-backed originals keep their
  `arrowRootOf` entry; the fresh occurrence id gets none and degrades to occurrence identity —
  the documented partial-map behaviour (`AssignMVarIds.elm:53-55`). This replaces the
  `SolverRoot → NoArrow` clearing and is what the old `_ -> freshArrowId` arm did for it anyway.
- `TRecord fields ext`: `ext` follows the `TVar` rule. `TAlias home name args real`: each
  `( paramId, t )` — re-mint `paramId` through `renamed` (so the `Holey` body's occurrences follow),
  walk `t`; `Filled`/`Holey` bodies walked. `TType`/`TTuple`/`TUnit`: structural.
- `Meta`: `{ tipe = walk, tvar = meta.tvar }` (matches `rewriteMeta`).
- `Function`/`TrackedFunction _ params body meta` → `Just (mintLamId)`, params' types walked,
  body walked. `Def`/`TailDef` declared types walked. `Destructor` meta walked. Every other
  variant: metas walked, structure kept. Term-level names are NOT touched here.

`mintNewNode` — NEW-NODE semantics: `Function Nothing` → `Just fresh`; `Function (Just _)`
unchanged; `TLambda NoArrow` → `Arrow fresh`; `TLambda (Arrow _)` unchanged; `TLambda (SolverRoot _)`
cannot occur post-assignment (every slot is `Arrow` after `:1310`) — treat as `NoArrow`; `TVar`
untouched (new nodes are built from existing, already-assigned types; a transform that needs a
fresh variable calls `freshMVarId` directly). Transforms build with `Can.tLambda` (`Canonical.elm:358`,
`NoArrow`) and `Function Nothing`, then call this once per created subtree.

`assertMinted` — walk every node's expression, metas, `Def`/`TailDef` types, `Destructor` metas,
and every annotation: fail on `Function Nothing`, `TrackedFunction Nothing`, `TLambda NoArrow`,
`TLambda (SolverRoot _)`, naming the global and the first offending node kind.

`mintedReport` — counters `{ lams, arrows, mvars }` incremented by both entry points, rendered
`pre-fresh: lams=N arrows=N mvars=N` on the `inline.report` stderr line (§7). The denominator whose
zero is impossible once any copy happens.

### 3.4 `InlineSimplify` port, `Name → MVarId`

`optimize : Config.InlineConfig -> GlobalMVarState -> GlobalGraph MVarId -> ( GlobalGraph MVarId, GlobalMVarState, Metrics )`.
`Ctx` gains `state : GlobalMVarState`, loses `renamedTypeVars`; `Candidate.typeVars : List Int`.

| function (`InlineSimplify.elm`) | change |
|---|---|
| `withRenamedSupers :211` | DELETE |
| `suffixType/suffixFieldType/suffixAliasType/suffixMeta :494-552` | DELETE (→ `Fresh.freshenCopy`) |
| `suffixExpr/suffixDef/suffixPath/suffixDecider :1623-1800` | keep as TERM-ONLY renamers: drop the `Subst` parameter and every `mt`/`ty` meta rewrite; they rename `VarLocal`/binders/`Case` labels/`TailCall` labels/`Path` roots only |
| `freshenBody :1588` | `= termSuffix sfx (Fresh.freshenCopy subst ctx.state body)`, params' types through `freshenCopy`'s type walk, `ctx.state` updated |
| `matchType/matchList/aliasBody :579-634` | `Can.Type MVarId`; `TVar` keyed `Id.toComparable`; alias arms per step 0a (same-name aliases match argument-wise; else substitute-then-match) |
| `candidateTypeVars/typeVarsOfExpr/typeVarsOfType :655-671` | ids; `TAlias` arm = the ARGUMENTS' variables only (alias params are alias-local by position, §2 row 6) |
| `buildCandidates :245` | `varSupers` → `state.superVars` keyed `Id.toComparable`; `superVar` guard by id |
| `isFunctionType/hasOpenRecord/openRecordIn*/polyKernel/hasPolymorphicKernel :359-445` | type parameter only |
| `children/defChildren/deciderChildren/bodyOf/recursiveGlobals/namesSelf/cost*/rewrite*/mapBody/rewriteList/rewriteDef` | type parameter only |
| `tryInline/callSiteSubst/determines/isGroundType/doInline :1440-1529` | ids; `isGroundType` = no `TVar` reachable, alias params excluded as above |
| `rewriteGraph :1101` | destructure the MVarId graph; thread `state` |
| `locatedName` | unchanged |

Report line gains nothing; the existing `pre-inline-simplify:` fields are unchanged.

## 4. Adversarial review

- **R1 — the discipline hazard.** Once identity exists during the pre-mono passes, a transform that
  creates a node without minting produces a `Function Nothing` (memberless, `g1absentl`) or, worse,
  a transform that COPIES a node with its id produces two bodies under one member — LSS_009
  impersonation across different instantiations, a silent miscompile. *Resolution:* one helper
  (§3.3) that every pass must use; `assertMinted` under `mono.validate` catches `Nothing`/`NoArrow`;
  DUPLICATION cannot be caught by a presence check, so `assertMinted` also collects every
  `Just lamId` and every `Arrow id` into a set and fails on a repeat — that is the check that
  catches a copy-without-mint. Both run in the `ECO_INLINE_THRESHOLD=0` and EARLY E2E legs with
  `ECO_MONO_VALIDATE=1`.
- **R2 — byte-stability at defaults.** `assignIds` itself is unchanged and walks the same graph in
  the same `DMap` order, so `nextId`/`nextLam`/`nextArrow`/`nextRootKey` numbering is identical;
  `sameCanTypeIgnoringArrows`'s `==` fast path and the five stamp-census counters consumed at
  `:3922-3928` are unaffected. The only default-path difference is WHEN it runs. *Resolution:* gate
  = byte-identical `.mlir` at defaults and re-established fixed point (§8).
- **R3 — LSS_003** says member ids are minted "only by AssignMVarIds … Engine.memberIdFor seeded past
  `GlobalMVarState.nextLam`". `Fresh.mintLamId` mints from the SAME supply and advances `nextLam`, so
  `initState`'s `nextMemberId = toComparable mvarState.nextLam` (`:3892`) stays past every id ever
  minted. *Resolution:* amend LSS_003's text to name `PreMono.Fresh` as a minting site on the same
  supply; add the sequencing sentence "every pre-mono pass runs before `initState` reads `nextLam`".
- **R4 — LSS_024 / LSS_038.** Layout-qualified and instance-qualified members key on the raw
  `lambdaId` plus post-mono layout/ordinal. Fresh ids per copy = distinct raw members, which is
  exactly what happens today (assignment after inlining minted distinct ids per copy). *Resolution:*
  no change in outcome; the §12 unit pin "two inlines of one body yield distinct lambda ids after
  mono" is re-pointed at `Fresh` and kept.
- **R5 — subst and diff engines.** They assign with `( False, False )` today. *Resolution:* per-engine
  flags (§3.1); `MonoDiff.runAssigned` so `preMono=1` under `EngineDiff` diffs the same pre-mono
  output through both engines instead of silently skipping the passes.
- **R6 — alias parameter ids.** After assignment an alias param is an `MVarId` minted BY NAME in the
  def's env (`:1358`), so it may share an id with a same-named scheme binder. Any "is it a binder?"
  test on ids is therefore wrong for alias params. *Resolution:* alias-locality is by POSITION in
  the `TAlias` pair everywhere (`typeVarsOfType`, `isGroundType`, `matchType`, `freshenCopy`), never
  by id membership — the same rule §16 established on names.
- **R7 — `tvar`.** Carried verbatim; unread by mono (`MonoSolver/Monomorphize.elm:15`). No action.
- **R8 — FEStats attribution.** `assignIds` is inside `PhaseMono` today; moving it into Generate
  would shift its wall to the enclosing phase and make the `mlir-timing-report` rows move for no
  reason. *Resolution:* wrap the whole pre-mono pipeline in `FEStats.withPhase stats PhaseMono` (§3.2).
- **R9 — the flags-decoder node** is now visible to the pre-mono passes. It is a `Define` whose body
  is a decoder expression, not a `Function`, so `bodyOf` = `Nothing` and no pass touches it; items
  01/04 must keep it that way (state it in their plans: skip `EntryPrep.flagsDecoderName`).
- **R10 — the §16 fix was reverted after its binary was built.** The reference census
  (1,865 / 864) was produced by `eco-q1b`; the tree was overwritten afterwards. *Resolution:* step
  0a confirms the re-applied fix on names FIRST (rebuild, re-derive the numbers); only then is the
  port measured against them. If the re-applied source does not reproduce 1,865 / 864 exactly, the
  re-application is incomplete — stop there.

## 5. Lowered steps

| step | change | files | gate |
|---|---|---|---|
| 0a | Confirm the re-applied §16 fix on names (Q1 agent's edits): `typeVarsOfType` `TAlias` arm = arguments only; `matchType` alias arms: same-name → argument-wise `matchList`, else expand (substitute params by position) then match. Rebuild. | `InlineSimplify.elm` (alias arms), `Builder/Generate.elm` (report fields) | EARLY census `inlined=1,865 undetermined=864` REPRODUCED; both-arm E2E 887/889; defaults byte-identical |
| 1 | Export `mintLamId`, `mintArrowId`, `freshMVarId` from `AssignMVarIds`; add `EntryPrep.assign` and the `Assigned` record | `AssignMVarIds.elm`, `EntryPrep.elm` | compiles; `LssSigRootIdentityTest` unchanged and green |
| 2 | `monomorphizeWithReportAssigned` / `monomorphizeWithLimitsAssigned` / `MonoDiff.runAssigned`; Name-typed entries become wrappers | `MonoSolver/Monomorphize.elm:83-135`, `Monomorphize/Monomorphize.elm:85-102`, `Diff.elm:44-62` | ALL existing tests green; defaults byte-identical (nothing else has moved yet) |
| 3 | `Fresh.elm` (§3.3) + `FreshTest` (§6) | new module, new test | unit: ids distinct and above the originals; supers copied; `Subst` spliced verbatim; `assertMinted` rejects a duplicate id |
| 4 | Port `InlineSimplify` (§3.4); delete the four name-keyed mechanisms; `runToAssigned` in `TestPipeline`; re-point the two inline tests | `InlineSimplify.elm`, `TestPipeline.elm`, `InlineSimplifyTest.elm`, `InlineSimplifyDestructCaptureTest.elm` | unit suite at baseline (13,464 / same 12); `PreMonoInlineTest` EARLY smoke |
| 5 | Generate: `runMonoOptPipeline` on `Assigned` (§3.2), `selectMonomorphizerAssigned`, `validateMinted` under `mono.validate`, `pre-fresh:` report line | `Builder/Generate.elm:741-835` | **defaults byte-identical + fixed point; EARLY census EXACTLY 1,865 / 864** |
| 6 | Full gates: both-arm E2E; `ECO_INLINE_THRESHOLD=0` leg with `ECO_MONO_VALIDATE=1`; amend LSS_003 text | `design_docs/invariants.csv` | 887/889 both arms; validator silent |

Order matters: steps 1–2 change nothing observable and can land alone; 3–4 are the substance; 5
is the switch; 0a precedes everything because the reference numbers depend on it.

## 6. Tests

| test | pins |
|---|---|
| `TestLogic/GlobalOpt/PreMono/FreshTest.elm` (new) | `freshenCopy` on a body with two lambdas and three arrows: all lambda ids and arrow ids distinct from the originals and from each other; an unsubstituted `TVar` gets a fresh id whose `superVars` entry equals the original's; a substituted `TVar` becomes the bound type with its arrow ids UNCHANGED; `mintNewNode` on `Function Nothing`/`tLambda` assigns and is idempotent; `assertMinted` fails on `Function Nothing`, on `NoArrow`, and on a graph with a REPEATED lambda id |
| `InlineSimplifyTest`, `InlineSimplifyDestructCaptureTest` | unchanged assertions on the assigned graph via `runToAssigned` |
| `PreMonoInlineTest` (E2E, EARLY) | the polymorphic-copy pin; unchanged |
| `LssSigRootIdentityTest:204` | unchanged — proves the Name-typed `assignIds` still exists |
| step-0 pin (from §12 plan) | two inlines of one body yield distinct lambda ids — now asserted directly on `Fresh`'s output, before mono |

## 7. Census / measurement

`pre-fresh: lams=N arrows=N mvars=N` on stderr under `inline.report`; for this item alone
`lams`/`arrows` must equal the pre-mono inliner's copied-lambda/arrow counts and `mvars` its
unsubstituted-variable count. `pre-inline-simplify:` fields unchanged. No `lss-opt.md` run is
owed by this item (no dispatch change is possible); the gates are identity gates.

## 8. Gates (item-specific, on top of the standing ones)

1. `.mlir` byte-identical at defaults against the step-0a compiler, and the bootstrap fixed point.
2. EARLY-arm self-compile census EXACTLY `inlined=1,865 undetermined=864` (± nothing): a move up
   means something got grounded that should not have; a move down means a copy was refused.
3. `PreMonoInlineTest`, `RecordNarrow01/06`, `LetNumberFoldr/ApplyTo`, `PapFastStampTest` smoke in EARLY.
4. Full E2E 887/889 in both arms; `ECO_INLINE_THRESHOLD=0` leg with `ECO_MONO_VALIDATE=1` silent.

## 9. Risks

- A transform in a later item copies a subtree with `TOpt` structure-preserving code and forgets
  `freshenCopy` — caught only by `assertMinted`'s duplicate check, which is off by default. Run the
  validator in CI's E2E legs, not only locally.
- `superVars` growth: every copied unsubstituted variable adds an entry. Today `withRenamedSupers`
  did the same by name; no new cost class.
- The `Assigned` record carries the whole graph through the Task chain; scope it so the Name graph
  is GC-eligible after `assign` (the reason `monoPipelineFrom` is a separate function today).

## 10. What not to do

- Do not split `AssignMVarIds` into an mvar phase and an identity phase — the whole point of
  running it intact is that nothing in it changes.
- Do not keep the `_pi` TYPE suffix "for safety" alongside `Fresh` — two mechanisms for one
  identity is how the name/id disagreement in R6 becomes a bug.
- Do not decide alias-locality by id membership (R6).
- Do not add a flag: this item is an IR move; the pre-mono passes it enables are the flagged things.


---

## 11. IMPLEMENTED (2026-09-10) — all gates green

`AssignMVarIds` now runs in `Builder/Generate.runMonoOptPipeline`, before the
pre-mono passes; `InlineSimplify` operates on `TOpt.GlobalGraph MVarId`; and
`Compiler/GlobalOpt/PreMono/Fresh.elm` is the single minting helper items
01/03/04 are written against.

### 11.1 Gates

| gate | result |
|---|---|
| 1 — `.mlir` byte-identical at DEFAULTS | **GREEN** (frozen corpus, `eco-q1b` vs `eco-p00`) |
| bootstrap fixed point | **GREEN**, byte-identical on the first iteration |
| 2 — EARLY census unchanged | **GREEN, every field:** `inlined=1866 candidates=653 recursiveSkipped=1 overBudget=4632 polymorphic=142 polyKernel=6 rowPoly=0 superVar=22 hofParam=40 undetermined=864 bodiesSeen=5354` — identical before and after. Nothing grounded, nothing lost. |
| 3/4 — E2E, defaults | 887 / 889 (the two pre-existing) |
| 3/4 — E2E, `preMono=1 postMono=0` | 887 / 889 |
| validator leg — `ECO_INLINE_THRESHOLD=0 ECO_MONO_VALIDATE=1`, BOTH passes on | 887 / 889, **zero validator complaints** |
| unit suite | **13,474 / 12** — the same 12 pre-existing, +10 from `PreMonoFreshTest` |

**The reference numbers moved from the plan's 1,865 / 864 to 1,866 / 864.** The
plan's figure came from Q1's run on the tree as it stood then; the corpus frozen
for this item additionally contains steps 1–2's own new code (the `Assigned`
record, the two engine cores, `Fresh`), which is itself inlinable. `undetermined`
is unchanged at 864 — the number the gate is actually about — and the ported
compiler reproduces the baseline to the digit ON THE SAME frozen corpus, which is
the comparison that means anything.

### 11.2 The EARLY arm's `.mlir` is NOT byte-identical, and that is correct

779 bytes on a 14 MB output. `Fresh` mints a copy's lambda and arrow ids DURING
inlining; the old arrangement minted every id afterwards, in one deterministic
walk. Same program, different id NUMBERING. Gate 1 (defaults) is byte-identical
because no copying happens there, and the EARLY arm's correctness is carried by
E2E + the identity validator, both green. §8's gate list asks for census equality
and E2E in this arm, not byte-identity — deliberately.

### 11.3 Deviations from the design

  - **`Fresh` exports `freshenType` as well.** `freshenBody` needs the copied
    parameter types put through the same walk as the body; §3.3 assumed one entry
    point would serve, and it does not.
  - **`callerBinders` comes from the annotation's TYPE, not its `FreeVars`.**
    `Can.FreeVars = Dict Name ()` is not `id`-parameterised, so it still holds
    NAMES after assignment. The two agree by construction —
    `rewriteAnnotation` seeds every binder through `ensureBinder` — so
    `typeVarsOfType annType` is the id-keyed binder set. (Plan 05 predicted this;
    it lands here because Q1's census plumbing already used the field.)
  - **`mintedReport` / the `pre-fresh:` census line was not built.** §7 wanted it
    as a denominator; gate 2's per-field census equality is a stronger check of
    the same property, and the counters would have to be threaded through
    `Fresh`'s pure signatures for no additional information. Items 01/03/04
    should add it if their transforms need per-pass mint counts.

### 11.4 A process finding worth more than the code

**The verified Q1 source was reverted twice by a host-side working-tree restore**
(`/work/.git` is a worktree pointer; git runs on the host), the second time
mid-implementation, taking the §16 alias fix with it. Both times the tree kept
COMMITTED work and lost only the uncommitted edits. Two consequences, both now
standing practice:

  - snapshot verified sources to the session scratchpad the moment a gate passes
    (`good-src/`, `port-src/`), and re-verify a re-apply by recompiling with the
    SAME compiler and `cmp`-ing the `.mlir` — byte-identity proves the source, no
    lowering needed;
  - a guard script checks the marker counts before every build.

**And: never measure a self-compile census while editing the tree.** Two runs
were invalidated by exactly that — the workload IS the source. Freeze a corpus
(`scratchpad/corpus/`) and point both arms at it.
