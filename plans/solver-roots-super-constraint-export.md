# Export Super Constraints via SolverRoots — Implementation Plan

## Status: Planning

## Goal

Type-variable constraint information (`number`, `comparable`, `appendable`,
`compappend`) currently reaches monomorphization by **re-parsing type-variable
name prefixes** (`AssignMVarIds.constraintFromName`, via `Name.isNumberType`).
This plan replaces that channel with explicit data exported from the solver:

1. **Root-attached supers**: every solver-root entry in `SchemeRoots` carries
   the root descriptor's `SuperType`, read from the solver's own union-find
   content — not from any name.
2. **Name-keyed supers for non-rooted vars** (`varSupers`): a per-module map
   computed once at artifact production, covering type variables that reach
   monomorphization without a recorded solver root (internal let-generalized
   vars, constructor scheme vars, kernel/PostSolve types).
3. **All four supers travel**, not just number. Downstream mono behavior still
   only *consumes* `Number` (maps to `Mono.CNumber`; everything else remains
   `CEcoValue`), but the full super is stored in the side tables so future
   work (solver-reuse in mono, comparable-aware specialization) can read it.
4. **The name-prefix mechanism is removed from monomorphization entirely**:
   `constraintFromName` is deleted, along with the CNumber join-upgrade patch
   in `ensureMVarIdForRoot` (made unnecessary, not just fixed) and the
   duplicated root-claim logic in `rewriteAnnotation`.

The plan also fixes, structurally, the two latent bugs documented in
`design_docs/monomorphization/design-recovery.md` (§9.1) and
`design_docs/monomorphization/solver-reuse-evaluation.md` (§6.1):

- **Bug A**: `rewriteAnnotation` duplicates `ensureMVarIdForRoot`'s root-claim
  logic *without* the CNumber join patch — a `number`-named annotation binder
  whose root was already claimed by a non-number name silently loses the
  constraint.
- **Bug B**: `rootEnv : Dict Int MVarId` is keyed by raw per-module `Pt`
  indices, which restart at 0 for every module's solve — unrelated definitions
  in different modules can silently share an MVarId, and the number join can
  stamp CNumber across modules. Fixed by keying `rootEnv` with
  `( moduleKey, rootIdx )`.

This is also **Phase 0 of the solver-reuse roadmap**
(`solver-reuse-evaluation.md` §7): identity hardening + structural constraint
export.

## Background

Read first: `design_docs/monomorphization/design-recovery.md` §6 ("The number
saga") and §10.1. Summary of the current mechanism:

**Where supers are born (unchanged by this plan).** The surface language
encodes supers in type-variable names. The solver ingests that convention in
exactly three places, all of which STAY:

- `Compiler/Type/Type.elm:396-411` — `toSuper` (used by `nameToFlex` :381,
  `nameToRigid` :393) when instantiating source annotations.
- `Compiler/Type/Solve.elm:903-915` — `srcTypeToVariable`'s name→super mapping.
- `Compiler/Type/Type.elm` — `getFreshSuper "number"` etc.: the solver *names*
  freshly-zonked super vars `number`, `number1`, `comparable1`, … and writes
  the names back into descriptors. This is why every super-named var in a
  persisted type satisfies the prefix convention *by construction*.

`Builder/Deps/Diff.elm:375-384` also uses the prefix predicates for package
API diffing (semver: `number` → `a` is a breaking change). That is a
surface-syntax concern and STAYS. After this plan, the prefix predicates have
no callers under `Compiler/Monomorphize/`.

**Where supers currently die and get re-derived.** After solving,
`Compile.typeCheckTyped` (Compile.elm:308-395) extracts:

- `nodeVars` / `annotationVars` — root-normalized via
  `SolverRoots.normalizeNodeVars` / `normalizeAnnotationVars`,
- `allSchemeRoots : SolverRoots.AllSchemeRoots` — per-def binder name → rooted
  `IO.Variable`, from annotated defs (`normalizeAllSchemeRoots`) plus a
  lockstep tree walk for inferred defs (`extractBinderRootsFromInferred`).

`allSchemeRoots` flows into `LocalGraphData.schemeRoots`
(LocalOpt/Typed/Module.elm:99, TypedOptimized.elm:399), is persisted in the
`.ecot` / `typed-artifacts.dat` binary as `(name, int32 rootIdx)` pairs
(TypedOptimized.elm:1490-1527), and is re-keyed Name→Global at whole-program
assembly (GraphAssembly.elm `addTypedLocalGraph`, :129-176). **The descriptor
content — including `FlexSuper`/`RigidSuper` — is dropped.**

At the start of monomorphization, `AssignMVarIds` converts names → `MVarId`s:

- Root path (`ensureMVarIdForRoot`, :184-231): binder names found in the def's
  `schemeRootsForDef` share an MVarId per root via
  `rootEnv : Dict Int MVarId`. Constraint on first claim:
  `constraintFromName name` (:148-154, prefix parse). Later claims by a
  `number`-named alias upgrade via the join patch (:204).
- Fallback path (`ensureMVarId`, :159-178): names without roots (internal
  let-generalized vars, ctor scheme vars, PostSolve/kernel names) get
  per-binding-scoped ids; constraint again from `constraintFromName`.
- `rewriteAnnotation` (:268-317) re-implements the root path inline — without
  the join (Bug A).

Number-ness is stored in `GlobalMVarState.numberVars : Set Int`, seeds
`State.MVarEnv.numberVars`, and is consumed by `State.isNumberVar`
(TypeSubst.elm:56 `constraintOf`; Specialize.elm:409, :433, :552).

## Design

### D1. `RootedVar` — supers ride the identity channel

Define in `System/TypeCheck/IO.elm` (home of both `Variable` and `SuperType`;
zero-dependency, importable by both the Type layer and the AST layer):

```elm
{-| A root-normalized solver variable together with the super constraint
recorded on its root descriptor at snapshot time. The super is solver truth
about the ROOT — independent of whichever type-variable name refers to it.
-}
type alias RootedVar =
    { var : Variable
    , super : Maybe SuperType
    }
```

`SolverRoots.SchemeRootsForDef` becomes `Dict Name IO.RootedVar`. The super is
attached at normalization time by reading the root's descriptor content:

```elm
superOfRoot : SolverState -> IO.Variable -> Maybe IO.SuperType
superOfRoot state (IO.Pt rootIdx) =
    case lookupContent state rootIdx of
        Just (IO.FlexSuper s _)  -> Just s
        Just (IO.RigidSuper s _) -> Just s
        _                        -> Nothing
```

Note this is *not* a name lookup. That is the whole fix for the root-reuse
bug family: when solver unification made `b` and `number1` the same root, the
root's content is `FlexSuper Number _` regardless of which name claims it
first. With the super read from the root, the join-upgrade patch (and Bug A's
missing copy of it) become dead logic and are deleted.

### D2. `varSupers` — the fallback channel for non-rooted names

For type variables that reach `AssignMVarIds`'s name-fallback path (no root
recorded): a per-module map

```elm
varSupers : Dict Name IO.SuperType
```

computed **once at LocalGraph construction** by sweeping every `Can.TVar name`
occurring in the finished graph (annotations, node metas, def signatures —
mirror the existing full-graph sweep `collectStringsFromLocalGraph` in
TypedOptimized.elm) and recording `Type.toSuper name` hits.

Honesty note (record this in the code comment): for names, `toSuper` *is* the
convention — solver-minted names (`getFreshSuperName`) and user/declaration
names (ingested via `toSuper` at instantiation) both satisfy it, so this map
is convention-equal to today's prefix parse. The semantic bug fix is D1; the
purpose of D2 is that **monomorphization becomes name-blind**: parsing happens
exactly once, at artifact production (a surface-syntax boundary, like
`srcTypeToVariable`), and ships as data. A descriptor-scan alternative was
considered and rejected: it is equivalent for solver-touched vars but misses
declaration-derived names (e.g. `type Box number` ctor schemes) and
kernel/PostSolve types that never pass through the solver's zonk.

Because `map(name) = toSuper(name)` universally, per-module maps can be
flat-unioned into the GlobalGraph without conflict. (Optional debug assertion
on conflicting insert during development.)

### D3. Module-scoped `rootEnv` (Bug B)

`GlobalMVarState.rootEnv` becomes `Dict ( String, Int ) MVarId`, keyed by
`( ModuleName.toComparableCanonical home, rootIdx )` where `home` is the
current def's `Global` home module. Root identity is only ever meaningful
within one module's solve (each module's `Pt` indices restart at 0 —
`unsafePerformIO` seeds empty arrays). Intra-module root sharing (the reason
`rootEnv` is global across defs) is preserved; cross-module collisions become
unrepresentable.

### D4. Side tables carry the full super

- `GlobalMVarState.numberVars : Set Int` → `superVars : Dict Int IO.SuperType`
  (key = `Id.toComparable mvarId`; absent = unconstrained).
- `State.MVarEnv.numberVars : Set Int` → `superVars : Dict Int IO.SuperType`.
- `State.isNumberVar mvarId env` = `Dict.get (Id.toComparable mvarId)
  env.superVars == Just IO.Number` — all existing consumers
  (TypeSubst.constraintOf, Specialize :409/:433/:552) keep their behavior.
- `State.freshMVar : Mono.Constraint -> MVarEnv -> …` keeps its API;
  `CNumber` inserts `IO.Number`, `CEcoValue` inserts nothing. (Mono-side
  allocations never mint comparable/appendable vars.)
- `Mono.Constraint` is **unchanged** (still `CNumber | CEcoValue`).
  Comparable/appendable/compappend map to `CEcoValue` exactly as today —
  they are layout-erased. No MonoType, SpecKey, or codegen change.

### D5. Persistence and format versioning

The binary format of `.ecot` (per-module `TypedModuleArtifact` →
`localGraphEncoder`) and `typed-artifacts.dat` (per-package
`globalGraphEncoder`) changes:

- `schemeRootsForDefEncoderS` entries: `(name, int32)` →
  `(name, int32, superByte)` with `superByte`: `0`=none, `1`=Number,
  `2`=Comparable, `3`=Appendable, `4`=CompAppend.
- New `varSupers` dict in both `localGraphEncoder` and `globalGraphEncoder`
  (`stdDict (StringTable.string st) superByte`).
- **Add a format-version byte** (new constant
  `typedGraphFormatVersion : Int`) at the head of both encoders; decoders
  `Bytes.Decode.fail` on mismatch. Neither format has a version today; decode
  failure currently degrades to "artifact missing", and per project memory a
  missing `typed-artifacts.dat` is silently treated as an **empty graph**,
  crashing far away in monomorphization ("no annotation entry for global").
  A version byte makes staleness deterministic. We are breaking the format
  anyway, so the one-time invalidation is free.

Companion recommendation (out of scope, note for follow-up): make
absence/decode-failure of an *expected* typed artifact loud at load time
instead of degrading to an empty graph.

## Non-goals

- No change to `Mono.Constraint`, MonoType comparable keys, layouts, or any
  codegen behavior for comparable/appendable (still `CEcoValue`).
- No change to solver-side name ingestion (`toSuper`, `nameToFlex`,
  `nameToRigid`, `srcTypeToVariable`) or to `Builder/Deps/Diff.elm`.
- No per-node solver-variable persistence (`Meta.tvar` codec) — that is
  solver-reuse Phase 1+ territory.
- No behavioral redesign of number defaulting (still eager in `applySubst`;
  moving it to quiescence is a separate effort per design-recovery §10.2).

## Expected behavior changes

Intended to be **zero** on the existing green test suites, except where the
old channel was wrong:

1. Bug A path: a number-named annotation binder on a reused root now keeps
   CNumber (previously silently lost → Int default → potential
   `mul_Float (f64, i64)` miscompile).
2. Bug B path: unrelated cross-module vars no longer share MVarIds; in
   particular a number binder in one module can no longer stamp CNumber onto
   an unrelated module's generic var (previously could flip its defaulting
   behavior and number-multi gating).
3. `superVars` provenance: root path constraints now come from root content
   rather than first-claimer's name. By the convention argument (D2 note)
   this is equal except at the bug sites above.

Any e2e output diff must be investigated individually — each is a latent
miscompile surfacing, not an acceptable regression.

---

## Implementation

Phases are ordered so the tree compiles and full suites pass at the end of
each phase. Phases 1 and 2 both change the binary format; bump
`typedGraphFormatVersion` in each (cheap), or land them back-to-back.

### Phase 0 — characterization tests first

New test module `compiler/tests/TestLogic/Monomorphize/SuperConstraintExportTest.elm`
(follow the structure of existing `TestLogic/Monomorphize/*` suites; check
`tests/` for existing SolverRoots/AssignMVarIds coverage and extend rather
than duplicate):

- **T1 (Bug A repro)**: build a `GlobalGraph Name` with two annotations whose
  `schemeRootsForDef` map different names (`"a"` first, `"number"` second) to
  the *same* root `IO.Pt k`; run `AssignMVarIds.assignIds`; assert the shared
  MVarId is Number-constrained. This should FAIL against current code when
  the `"a"`-claiming annotation is processed first (annotation path lacks the
  join), and pass after Phase 1. If constructing the failing order is
  awkward via public entry points, assert through `assignIds` on a crafted
  graph — annotations are rewritten before nodes (AssignMVarIds.elm:89-93),
  so two annotations suffice to hit `rewriteAnnotation`'s inline path.
- **T2 (fallback coverage)**: a def whose node meta contains
  `TVar "number1"` with *no* entry in `schemeRootsForDef`; assert CNumber via
  the varSupers channel (Phase 2) — until Phase 2, this passes via the
  legacy prefix path; keep it as a pin.
- **T3 (Bug B repro)**: two `Define` nodes under Globals with *different home
  modules*, whose `schemeRootsForDef` both contain root `IO.Pt 42`; assert
  the two defs receive **distinct** MVarIds after Phase 1 (currently they
  collide).
- **T4 (all supers)**: binders rooted to `Comparable`/`Appendable`/
  `CompAppend` contents are recorded in `superVars` with the right super, and
  their `Mono` constraint remains `CEcoValue`
  (`TypeSubst.canTypeToMonoType` produces `MVar _ CEcoValue`).

Also grep the existing regression suites named in
`plans/fix-number-constraint-lost-solver-root-reuse.md` and the number test
family (`EmbeddedNothingInCustomTypeTest`, `UnboxWrapperNothingTest`,
number-destructure tests) — these are the do-not-break set.

### Phase 1 — RootedVar through the pipeline (root path becomes data-driven)

One atomic change-set; the `SchemeRootsForDef` type change ripples and the
compiler enumerates every site.

1. **`System/TypeCheck/IO.elm`**: add `RootedVar` type alias (D1). Export it.

2. **`Compiler/Type/SolverRoots.elm`**:
   - `SchemeRootsForDef = Dict Name.Name IO.RootedVar`.
   - Add `superOfRoot` (D1) next to the existing `lookupContent` (:216-223).
   - `normalizeAnnotationVars` stays `Dict Name IO.Variable` (it feeds
     `annotationVars`, not schemeRoots — verify its consumers before
     touching; likely unchanged).
   - `normalizeAllSchemeRoots` (:65-71): resolve to root, then build
     `{ var = rootVar, super = superOfRoot state rootVar }`.
   - `extractBinderRootsFromInferred` / `walkTypeForBinders`: the two insert
     points (TVar leaf :117, record ext :156) build `RootedVar` the same way.

3. **`Compiler/AST/TypedOptimized.elm`**:
   - `SchemeRootsByGlobal` (:115) and `LocalGraphData.schemeRoots` (:399)
     switch to `IO.RootedVar` values.
   - Codecs (:1490-1527): add `rootedVarEncoder/Decoder` =
     `variableEncoder/Decoder` + super byte (D5 encoding). Update
     `schemeRootsForDefEncoderS/DecoderS` to use them.
   - Add `typedGraphFormatVersion : Int` (start at `1`) and emit/check it as
     the first byte of `localGraphEncoder`/`localGraphDecoder` (:510-546) and
     `globalGraphEncoder`/`globalGraphDecoder` (:470-499). Decoder mismatch →
     `Bytes.Decode.fail`.

4. **`Compiler/Compile.elm`** (:322-370): compiles unchanged in shape — the
   enriched values come from SolverRoots. Verify `schemeBinderVars` (raw,
   from `constrainWithIds`) is only ever passed through
   `normalizeAllSchemeRoots` before storage.

5. **`Builder/GraphAssembly.elm`** (:150-176): type flows through the re-key;
   no logic change.

6. **`Compiler/Monomorphize/AssignMVarIds.elm`**:
   - `GlobalMVarState`: `numberVars : Set Int` → `superVars : Dict Int
     IO.SuperType`; `rootEnv : Dict Int MVarId` → `Dict ( String, Int )
     MVarId` (D3, D4).
   - `Ctx` gains `moduleKey : String`. `rewriteNodes` and
     `rewriteAnnotationsByGlobal` compute it per entry from the `Global`'s
     home via `ModuleName.toComparableCanonical` and put it in the ctx.
   - `freshMVarId : Maybe IO.SuperType -> GlobalMVarState -> ( MVarId,
     GlobalMVarState )` — inserts any `Just s` into `superVars`.
   - `ensureMVarIdForRoot : IO.RootedVar -> Ctx -> ( MVarId, Ctx )`:
     - `Just mvarId` branch: **delete the join patch** (:194-216) — return
       `( mvarId, ctx )`. The root's super was recorded at first claim from
       `entry.super`; a second claim cannot disagree (same root → same
       descriptor → same super; cross-module keys no longer collide).
     - `Nothing` branch: allocate with `freshMVarId entry.super`, insert into
       `rootEnv` under `( ctx.moduleKey, rootIdx )`.
   - **Deduplicate Bug A's site**: rewrite `rewriteAnnotation` (:268-317) to
     build its binder env by calling `ensureMVarIdForRoot` / `ensureMVarId`
     through a `Ctx` (construct one from `schemeRootsForDef` + state +
     moduleKey) instead of the inline copy. The duplicated logic must not
     survive in any form.
   - `ensureMVarId` fallback: still `constraintFromName`-driven in this phase
     (temporary), but route through `freshMVarId (Just IO.Number / Nothing)`.
   - `assignIds` returns `superVars` in the final state; thread `moduleKey`
     as above. `assignIdsToType` (test helper): audit callers; give it an
     explicit `varSupers : Dict Name IO.SuperType` parameter now (empty from
     existing callers) so Phase 2 doesn't re-touch it.

7. **`Compiler/Monomorphize/State.elm`**: `MVarEnv.superVars : Dict Int
   IO.SuperType`; `initMVarEnv : MVarId -> Dict Int IO.SuperType -> MVarEnv`;
   `isNumberVar` = `== Just IO.Number`; `freshMVar` maps `CNumber` →
   `IO.Number`. Add the `System.TypeCheck.IO` import (no cycle: IO is
   dependency-free).

8. **Callers**: `Monomorphize.elm:86` (`initMVarEnv mvarState.nextId
   mvarState.superVars`), `Monomorphize.elm:613` and `Analysis.elm:587`
   (`Dict.empty`). `GlobalGraph` pattern matches in `Monomorphize.elm:82` and
   `insertFlagsDecoderNode` (:115-179) unchanged in this phase (arity
   unchanged until Phase 2).

9. **Gate**: `T1`, `T3`, `T4` flip to green; `T2` still green via legacy
   path. Run per CLAUDE.md: elm-tests target once (tee to
   `/tmp/test_output.txt`), then `cmake --build build --target full` once.
   Delete stale build artifacts if decode-version failures appear as
   "missing artifact" symptoms (see Dev-environment notes).

### Phase 2 — varSupers channel; delete the name mechanism

1. **`Compiler/AST/TypedOptimized.elm`**:
   - `LocalGraphData` gains `varSupers : Dict Name IO.SuperType`.
   - `GlobalGraph` gains a fifth component `varSupers : Dict Name
     IO.SuperType` (flat union across modules — safe per D2; the compiler
     enumerates all construct/match sites: `AssignMVarIds.elm:78/:95`,
     `Monomorphize.elm:82/:171`, `GraphAssembly.elm`, `Builder/Generate.elm`,
     `Builder/Elm/Details.elm`, `Optimized.elm`, plus tests).
   - Codecs: encode/decode the new dicts in both graph encoders; bump
     `typedGraphFormatVersion`.
   - Add `computeVarSupers : LocalGraph Name -> Dict Name IO.SuperType` — a
     full-graph sweep over every `Can.TVar` name (annotations incl. `Forall`
     binder names, node metas, `TailDef`/`Destructor` types, Ctor/Enum/Box
     canTypes) recording `Type.toSuper name` hits. Mirror
     `collectStringsFromLocalGraph`'s traversal structure so coverage is
     provably identical to what gets persisted. (If importing
     `Compiler.Type.Type` into TypedOptimized creates a layering problem,
     inline the four-prefix check as a local `toSuper` — but keyed off
     `Name.is*Type`, in ONE place, with a comment marking it as the single
     surface-convention ingestion point for persisted graphs.)

2. **`Compiler/LocalOpt/Typed/Module.elm`** (:99 region): populate
   `varSupers = computeVarSupers …` when building `LocalGraphData` (compute
   after the graph record is otherwise complete, or over the same inputs).

3. **`Builder/GraphAssembly.elm`**: union `data.varSupers` into the
   GlobalGraph's dict in `addTypedLocalGraph` (and the `GlobalGraph`-merge
   at :120 if both sides carry them).

4. **`Compiler/Monomorphize/AssignMVarIds.elm`**:
   - `assignIds` destructures the new `GlobalGraph` component; `Ctx` gains
     `varSupers : Dict Name IO.SuperType`.
   - `ensureMVarId`: constraint := `Dict.get name ctx.varSupers` (a
     `Maybe SuperType`, straight into `freshMVarId`).
   - **Delete `constraintFromName`** and the `Name` import usage for it.
   - Grep gate: `grep -rn "isNumberType\|prefixNumber" compiler/src/Compiler/Monomorphize/`
     returns nothing.

5. **Gate**: full suites again (once each, tee). `T2` now passes via data.
   Expect byte-identical MLIR on the e2e suite; investigate any diff.

### Phase 3 — docs, invariants, cleanup

1. **`design_docs/invariants.csv`**: add (adjust ID to the next free slots):

   - `TYPE_SUPER_001;TypeChecking;Constraints;enforced;Type-variable super
     constraints (Number Comparable Appendable CompAppend) are exported from
     the solver as data: every SchemeRoots entry carries the super read from
     its root descriptor (IO.RootedVar) and every persisted LocalGraph and
     GlobalGraph carries a varSupers name-to-super map computed at artifact
     production; monomorphization derives all constraint information
     exclusively from these channels;Compiler.Type.SolverRoots|Compiler.AST.TypedOptimized|Compiler.Monomorphize.AssignMVarIds`
   - `FORBID_SUPER_NAME_001;CrossPhase;Constraints;enforced;No compiler phase
     after typed-artifact production may derive type-variable constraint
     information from variable NAME prefixes; Name.isNumberType and related
     predicates are restricted to surface-syntax ingestion (solver
     instantiation, varSupers computation) and package API diffing;Compiler.Monomorphize|Builder.Deps.Diff`

2. **`design_docs/theory/pass_monomorphization_theory.md`**: update the
   Constraints section (CNumber origin: "from SolverRoots/varSupers export",
   not "assigned by name"). Add a dated note.

3. **`design_docs/monomorphization/design-recovery.md`**: add a short
   addendum to §9.1/§10.1 noting both bugs fixed by this plan and the
   name-channel removal (link this plan).

4. Mark `plans/fix-number-constraint-lost-solver-root-reuse.md` as superseded
   by this plan (one-line header note).

5. Sweep for stragglers: `grep -rn "constraintFromName\|numberVars"
   compiler/src` — only `superVars` remains; update stale doc comments in
   `State.elm` / `AssignMVarIds.elm` headers ("constraint information is
   recorded in a side table" — now "super side table, exported from the
   solver").

## Testing summary

- Unit: `SuperConstraintExportTest` T1–T4 (Phase 0, flipped green by P1/P2).
- Suites, per CLAUDE.md discipline (run ONCE, tee to file, grep the file):
  - `cmake --build build --target elm-tests 2>&1 | tee /tmp/test_output.txt`
  - `cmake --build build --target full 2>&1 | tee /tmp/test_output.txt`
- Do-not-break set: number regression tests (`EmbeddedNothingInCustomType`,
  `UnboxWrapperNothing`, number-destructure/mul_Float family), SolverRoots /
  MVarId suites (`solver-root-backed-mvar-ids.md`,
  `per-binding-mvarid-isolation.md` test modules).
- Self-compile: the full target exercises the compiler on itself; also run
  one multi-module + package-dependency e2e (the package suites) since both
  artifact formats changed.

## Dev-environment notes / hazards

- **Artifact invalidation**: both `.ecot` and `typed-artifacts.dat` formats
  change (twice, if phases land separately). With the version byte, stale
  artifacts fail decode deterministically; the *loader* still treats decode
  failure as absence — for `typed-artifacts.dat` that degrades to a silently
  empty graph whose symptom is a distant "no annotation entry for global"
  crash (see project memory). After pulling these changes: clean the build
  dirs and `~/.eco` package caches (`rm -rf ~/.eco/0.1.0/packages` stale
  stages) before judging test failures.
- `ELM_SOURCES` is a non-CONFIGURE_DEPENDS glob: adding the new test module
  (a new `.elm` file) requires a `cmake --preset build` reconfigure.
- `dummyCompare _ _ = EQ` is passed to `DMap.foldl` in AssignMVarIds — folds
  must not depend on ordering; keep the new per-entry `moduleKey` derivation
  order-independent (it is: pure function of the key).

## Risks / edge cases

| Risk | Assessment |
|---|---|
| A persisted `TVar` name with a super that `varSupers` misses | Impossible for solver-derived names (zonk writes root-representative names; those satisfy the convention `toSuper` reads) and covered for declaration/kernel/PostSolve names by sweeping the *persisted graph itself*. The sweep's coverage equals the encoder's traversal by construction. |
| Two `varSupers` entries conflict at global union | Impossible: `map(name) = toSuper(name)` for every entry; optional debug assert. |
| Root entry super disagrees between two defs sharing a root | Impossible intra-module (same descriptor); cross-module keys no longer collide (D3). |
| `superOfRoot` sees `Structure`/`Alias` content (binder resolved concrete) | Returns `Nothing`; such a root cannot appear as a `TVar` in zonked output, so the entry's super is never consulted for constraint purposes. Total function, no crash. |
| Behavior shift from Bug B fix (previously-merged unrelated MVarIds now distinct) | CEcoValue ids are erased in SpecKeys (normalized to sentinel), so key identity is unaffected; the observable change is only the removal of spurious cross-module CNumber stamping. Watch the number-multi gate tests. |
| `numberOfThings`-style user tvar names | Treated as Number today by the solver itself (`toSuper` prefix rule — language-level behavior, inherited from Elm); this plan neither fixes nor worsens it, and keeps mono consistent with the solver. |
| Elm-side churn from `GlobalGraph` arity change | Mechanical; compiler-enumerated. Prefer converting `GlobalGraph` positional args only where matched; consider a follow-up to make it a record (out of scope). |

## Follow-ups unlocked (not in scope)

- Solver-reuse Phase 1 (`solver-reuse-evaluation.md` §7): the mono-time store
  loader reads `superVars`/`RootedVar.super` to seed honest `FlexSuper`
  contents.
- Defaulting-at-quiescence (design-recovery §10.2) — now safe to sequence,
  since constraint provenance is loss-free.
- Comparable-aware key/specialization decisions and lambda-set work can read
  the full super table without new plumbing.
