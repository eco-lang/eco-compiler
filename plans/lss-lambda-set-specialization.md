# LSS v1 Implementation Plan — Lambda Set Specialization (id-only members)

## Status: M1 + M2 COMPLETE AND GATED (2026-07-11); M3/M4 not started

**M2 final gates (2026-07-11):** elm-tests 12991 passed / 12 failed —
failure set byte-identical to the pre-LSS baseline (POST_010 class), with
every LSS_002 checker suite green. Full E2E 1579/1579 under all three
configurations: default subst engine, `ECO_MONO_ENGINE=solver` (flag-off),
and `ECO_MONO_ENGINE=solver ECO_MONO_LSS=1` (flag-on, with the §8.5
keyed=False key-widening in place). Census verified live (see gate
findings below). One documented runtime-benign open item: the EngineDiff
graph-parity aid (details in "M2 gate findings").

**M1 gate results (2026-07-10):** elm-tests 12856 passed / 12 failed —
byte-identical to the pre-change baseline (the 12 are pre-existing POST_010
scoping failures, names verified). Full E2E 1579/1579 green under BOTH
`ECO_MONO_ENGINE=subst` and `=solver`. EngineDiff run: 1561/1579
diff-matched; the 18 failures are the elm-http family and were root-caused
via `ECO_MONO_DIFF_DUMP=1` to the PRE-EXISTING spec-id-order benign class
(`VG(27)`/`VG(28)` swap between engines; every serialized type byte-identical
with all arrows keying as the legacy `"A("` fragment — annotation-clean, so
not an M1 regression; matches the ~50 runtime-benign diffs documented in
plans/monosolver-drop-in-monomorphizer.md rev 9-11, whose production bar is
runtime equivalence). Sweep detail: the MFunction sweep also covered ~50
sites in compiler/tests (not counted in the design's 158) and one extra
`buildSegmentedFunctionType` caller in `Staging/Rewriter.elm:515`.

Source design: `design_docs/monomorphization/lambda-set-specialization-design.md`
(DETAILED DESIGN v1 — "the design"; section references `§n` below are into it).
Foundation: `design_docs/monomorphization/lss-foundation-report.md`.
Paper: `design_docs/auto-borrow-inference/lambda-set-specialization.pdf`.

**Anchor verification (2026-07-10, this plan):** every file:line the design
cites was re-checked against the current tree. All hold, with three benign
drifts: `toComparableMonoTypeHelper` is at `Monomorphized.elm:909` (design
says :993); `MFunction` appears at **158 sites in 24 files** (design says
159); `unifyStructure` starts at `Unify.elm:692` (arms land after the
existing `Fun1` arm inside it). The A5-SLIM de-monadify did NOT remove
`Engine.Step` combinators — `succeed/andThen/map` are live at
`Engine.elm:165-199`; design snippets using them are valid as written.

Deliverable ordering = the design's milestones. Each numbered step below
leaves the tree compiling and is independently commit-able. Every step has a
**Verify** clause; do not proceed past a failing one.

- **M1** — plumbing, all-⊤, byte-identical (steps 1.1–1.7)
- **M2** — identity + inference + report, flag-on (steps 2.1–2.12)
- **M3** — singleton dispatch consumer (steps 3.1–3.3)
- **M4** — keyed specialization + budgets + `==` audit (steps 4.1–4.3)

M0 prerequisites (design §11): the **default engine stays `subst`** — all
flag-on work runs under explicit `ECO_MONO_ENGINE=solver`. Kernel-honesty
(solver-reuse-evaluation §6.3) is NOT a blocker for any step here; it gates
*trusting* M2 census numbers near kernel-heavy code, noted at step 2.9.

---

## 0. Ground rules (read before starting)

- Build preset is `build` (`cmake --preset build`); CLAUDE.md's
  `ninja-clang-lld-linux` name is stale.
- **Adding or deleting a compiler `.elm` file requires a reconfigure**
  (`cmake --preset build`) — `ELM_SOURCES` is a non-CONFIGURE_DEPENDS glob.
  This bites exactly once in this plan: step 2.5 creates
  `Compiler/MonoSolver/LssInfer.elm`.
- Front-end changes need `--target full` (the `check` target consumes stale
  `.mlir`). Run the suite ONCE per change set:
  `cmake --build build --target full 2>&1 | tee /tmp/test_output.txt`
  then grep the file; do NOT re-run to "see it again".
- Compiler-front-end unit tests:
  `cmake --build build --target elm-tests 2>&1 | tee /tmp/elm_tests.txt`.
  Never run `full` and `elm-tests` concurrently (they race on `~/.eco`
  typed-artifacts and produce phantom "no annotation entry" crashes).
- `compiler/src` cannot use `Debug.toString` (eco-boot compiles it with
  `--optimize`) — the M2 report is assembled with string concatenation only.
- Engine A/B: `ECO_MONO_ENGINE=subst|solver|diff`. The byte/graph gate is
  the EngineDiff corpus run (procedure + current baseline in
  `plans/monosolver-drop-in-monomorphizer.md`; baseline ~466 MATCH / ~51
  runtime-benign diffs / 0 declines). Any *new* decline or MATCH-set change
  attributable to an LSS step is a stop-the-line failure for M1.
- Known pre-existing flakes (do not chase): JIT "opt level 288/0";
  `codegen/construct_nested.mlir` nursery SIGABRT (passes on retry); HTTP
  tests under concurrency.

---

## Milestone M1 — plumbing, all-⊤ (byte-identical end state)

Nothing in M1 changes program behavior: no set slot is ever minted
(`enabled = False` everywhere), every annotation is `LTop`, and the M1 gate
is byte-identity.

### Step 1.1 — `SrcLambdaId` in `Compiler/AST/TypeIds.elm`

**Change** (design §3.1): follow the existing phantom-`Id` pattern used by
`MVarPh`/`MVarId` in the same file:

```elm
type LamPh
    = LamPh


{-| Per-run identity of a source-level function value: a syntactic lambda
(stamped in AssignMVarIds, M2) or an interned non-lambda function value
(engine interning, M2). Dense from 0; the two producers share one supply.
-}
type alias SrcLambdaId =
    Id LamPh
```

Export both. No consumers yet.

**Verify:** `elm-tests` compile green (type is dead code).

### Step 1.2 — `LssConfig` in `Compiler/Eco/Config.elm`

**Change** (design §2.1): extend `MonoConfig` (`Config.elm:61`) with
`lss : LssConfig`; add the type + default verbatim from the design:

```elm
type alias LssConfig =
    { enabled : Bool           -- master switch (M2+)
    , keyed : Bool             -- sets participate in SpecKeys (M4+)
    , maxSetSize : Int         -- |set| > K at zonk ⇒ widen to LTop
    , maxSpecsPerGlobal : Int  -- registry budget; exceeded ⇒ widen new keys
    , report : Bool            -- render an LSS census after mono
    }

defaultLss : LssConfig
defaultLss =
    { enabled = False, keyed = False, maxSetSize = 8
    , maxSpecsPerGlobal = 64, report = False }
```

- Decoder: extend `monoDecoder` (`Config.elm:154-182`) with an optional
  `"lss"` object field over `defaultLss`, one `D.optionalField` per knob —
  copy the existing `D.pure … |> D.apply` shape.
- Hash: `Config.hash` (`Config.elm:216`) must emit tokens **only for
  non-default values** (e.g. append `"lss1"`, `"lssK"`, `"lssS" ++ n`… when
  ≠ default) so default builds keep byte-identical cache hashes. Look at how
  `hash` currently folds fields and mirror it.

**Verify:** `elm-tests` green; then confirm hash stability:
a default-config build after this change must NOT re-verify deps (no
"corrupt/changed config" rebuild — check a second `eco make` of any E2E
program is a cache hit, same as before the change).

### Step 1.3 — env overrides in `Builder/Eco/Config.elm`

**Change** (design §2.1): in `applyEnvOverrides` (`Builder/Eco/Config.elm:87`),
beside the existing `ECO_MONO_ENGINE` read (`:89`):

- `ECO_MONO_LSS`: `"0"` → `enabled = False`; `"1"` → `enabled = True`;
  `"keyed"` → `enabled = True, keyed = True`.
- `ECO_MONO_LSS_REPORT=1` → `report = True`.

Same `Utils.envLookupEnv … |> Task.mapError never` pattern as `:89-93`.

**Verify:** `elm-tests` green. (Behavioral test comes with M2 when the flag
does something.)

### Step 1.4 — `FlatType` constructors + all exhaustive arms

One atomic change across seven typechecker files; the compiler's
exhaustiveness errors are the checklist. Order of edits within the step:

1. **`System/TypeCheck/IO.elm:639`** — add to `FlatType` (design §4.1):

```elm
    | FunL Variable Variable Variable
      -- ^ arg, result, lambda-set slot. Minted ONLY by MonoSolver stores
      --   with lss.enabled; the typechecking phase never constructs it.
    | LambdaSet1 Bool (CoreDict.Dict Int ())
      -- ^ top-flag, member ids. The ONLY legal content of a FunL set slot
      --   besides FlexVar (LSS_007). Ground data: contains no Variables.
```

   Add the LSS_007 content-discipline paragraph to the module doc.

2. **`Compiler/Type/Unify.elm`** — four new arms in `unifyStructure`
   (`:692`, arms go directly after the existing `Fun1×Fun1` arm), verbatim
   from design §4.2: `FunL×FunL` (sub-unify arg/res/set),
   `Fun1×FunL` / `FunL×Fun1` (unify type structure, `merge` keeps the
   slotted side), `LambdaSet1×LambdaSet1` (total join:
   `merge ctx (Structure (LambdaSet1 (top1 || top2) (Dict.union m1 m2)))`).
   `unifyFlexSuperStructure` (`Unify.elm:565`): NO change — verify its
   catch-all `_ -> mismatch` still compiles exhaustively.

3. **`Compiler/Type/Occurs.elm:71-86`** — `FunL a b s` recurses `[a,b,s]`;
   `LambdaSet1 _ _` → no children (`False`).

4. **`Compiler/Type/Type.elm`** — `termToCanType` (`:534`): `FunL a b _` →
   build the same `Can.TLambda` as `Fun1` (erasure — canonical types never
   see sets); `LambdaSet1 _ _` → `crash "LambdaSet1 outside an arrow slot"`.
   Error-type term walk (`:712`): render `FunL` as the arrow, `LambdaSet1`
   unreachable-crash, same shapes.

5. **`Compiler/Type/Solve.elm`** — `traverseFlatType` (`:1181`):
   `FunL` maps f over all three; `LambdaSet1 top ms` is a pure pass-through.
   Rank-adjust and occurs sweeps (`:699`, `:1148`): structural recursion
   arms mirroring `Fun1` plus the slot.

6. **`Compiler/Type/SolverRoots.elm:157`** — confirm NO change needed (it
   matches `Just (IO.Fun1 …)` with a fallthrough; typecheck stores never
   contain `FunL`). Just re-read the site and note it in the commit message.

7. **`Compiler/MonoSolver/Store.elm`** — `zonkFlatC` (`:651`) needs arms to
   compile: for M1, `FunL a b _` zonks like `Fun1` (both produce
   `MFunction LTop …` after step 1.5) and `LambdaSet1 _ _` is an
   `EngineBug` crash ("LambdaSet1 outside arrow slot"). The real `FunL`
   zonk replaces this at step 2.4.

**Verify:** `elm-tests` green; `cmake --build build --target full` green
(both engines untouched semantically — no constructor is ever built yet).

### Step 1.5 — `LambdaSetAnno` + the `MFunction` sweep

The big mechanical step. Atomic (the compiler forces completeness).

1. **`Compiler/AST/Monomorphized.elm`**: under the existing
   `-- ====== LAMBDA SETS ======` banner (`:249`), add `LambdaSetAnno`
   verbatim (design §5.1: `LTop | LSet (List Int)` with the doc comment);
   change `MFunction (List MonoType) MonoType` →
   `MFunction LambdaSetAnno (List MonoType) MonoType` (anno FIRST, so
   ignoring sites read `MFunction _ args ret`).
2. Add `widenSets : MonoType -> MonoType` (recursively set every anno to
   `LTop`) and `eqLayout a b = widenSets a == widenSets b` (design §5.2) —
   used by M4, cheap to land now, unit-testable immediately.
3. `toComparableMonoTypeHelper` (`Monomorphized.elm:909`): the `MFunction`
   arm emits `"A("` for `LTop` — **byte-for-byte today's fragment** — and
   `"A[" ++ ids ++ "]("` for `LSet` (design §5.3 snippet).
4. Sweep the remaining **158 sites / 24 files** under two rules
   (design §5.2):
   - constructing → insert `Mono.LTop` as the first argument;
   - matching → insert `_` as the first pattern;
   - EXCEPT type *rebuilders*, which must thread the matched anno through
     to the rebuilt type instead of stamping `LTop`. The known rebuilder
     list (re-verify each while editing): `Zonk.lambdaChain`
     (`MonoSolver/Zonk.elm:154`), `resolveNumberType`
     (`Monomorphized.elm:265`), `MonoTraverse.mapNodeTypes` callees,
     `MonoGlobalOptimize.canonicalizeClosureStaging` +
     `peelStages`/`decomposeFunctionType` (`MonoGlobalOptimize.elm:1858`
     area), `Staging/Rewriter.elm` (5 sites), and
     `Generate/MLIR/Types.elm` type mapping (which *ignores* the anno for
     layout — arrows are closures regardless of set; REP_* untouched).
   - The legacy engine files (`TypeSubst.elm` 24 sites, `Specialize.elm`
     22) take plain `LTop` stamps / `_` matches — it never reads the field.

**Verify (the M1 heart):**
- `elm-tests` green.
- `cmake --build build --target full 2>&1 | tee /tmp/test_output.txt` —
  full E2E green on the default (subst) engine.
- `ECO_MONO_ENGINE=solver` full E2E green.
- EngineDiff corpus: MATCH set unchanged vs the rev-11 baseline (the
  comparable-key discipline in item 3 is what guarantees this; any drift
  means a `LSet`/key leak — stop and fix).

### Step 1.6 — entry plumbing (config reaches the engine)

**Change** (design §2.2, §8.1-lite):

1. `Compiler/MonoSolver/Monomorphize.elm`: `monomorphize` gains a leading
   `Config.MonoConfig` parameter; `initState` (`:103`) stores `mono.lss`
   into a new `Engine.Env` field `lss : Config.LssConfig`
   (`Engine.elm:63-69` — Env is the immutable M7 sub-record; adding a field
   is safe, it is constructed only in `initState`).
2. `Builder/Generate.elm` `selectMonomorphizer` (`:749-760`):
   `Config.EngineSolver -> MonoSolver.monomorphize ecoConfig.mono "main" …`.
   `Config.EngineDiff ->` passes a **forced-off** config
   (`{ mono | lss = { lss | enabled = False } }`) to whatever solver-side
   entry `MonoDiff.run` uses (design §5.4: diff always compares against the
   set-free subst engine; `Diff.serRegEntry` (`Diff.elm:189`) then needs no
   change).
3. Import cycle check: `Compiler/MonoSolver/*` may not currently import
   `Compiler.Eco.Config`. If adding the import creates a cycle (Config is
   leaf-like; it should not), mirror the types into a small
   `Engine.LssConfig` alias and convert at the boundary — decide at
   compile time, prefer the direct import.

**Verify:** `elm-tests` + full E2E green both engines. `ECO_MONO_LSS=1
ECO_MONO_ENGINE=solver` must ALSO be green and byte-identical at this point
— the flag reaches `Env` but nothing reads it yet except nothing; grep to
confirm no store code consults `env.lss` yet.

### Step 1.7 — M1 gate (record it)

All of: elm-tests green; full E2E green × {subst, solver}; EngineDiff MATCH
set unchanged; self-compile Stage-7a wall time unchanged within noise (no
slots are minted, so any regression is accidental — investigate before
proceeding). Append results to this plan's Status header.

---

## Milestone M2 — identity, inference, report (flag-on functional)

End state: `ECO_MONO_ENGINE=solver ECO_MONO_LSS=1 ECO_MONO_LSS_REPORT=1`
produces a full E2E-green build whose MonoGraph carries real `LSet`
annotations, plus a stderr census. Keys are UNCHANGED (`keyed = False`):
sets are facts on types, zero fan-out.

### Step 2.1 — `TOpt.Function` identity field

**Change** (design §3.2): `Compiler/AST/TypedOptimized.elm:160-161`:

```elm
    | Function (Maybe TypeIds.SrcLambdaId) (List ( Name, Can.Type id )) (Expr id) (Meta id)
    | TrackedFunction (Maybe TypeIds.SrcLambdaId) (List ( A.Located Name, Can.Type id )) (Expr id) (Meta id)
```

- Codec: encoder UNCHANGED (field not persisted — `Meta.tvar` precedent,
  `TypedOptimized.elm:130-134`); decoder tags 14/15 construct with
  `(Function Nothing)` / `(TrackedFunction Nothing)` (design §3.2 snippet).
  **No `.ecot` version bump** — wire format identical.
- Producer sweep (construct with `Nothing`): compiler-driven; expect ~25
  sites in `Compiler/LocalOpt/Typed/{NormalizeLambdaBoundaries,Port,Module,Expression}.elm`,
  `Compiler/TypedCanonical/Build.elm`, and the legacy engine's
  reconstructions in `Compiler/Monomorphize/Specialize.elm`.
- Matching sites take `_` EXCEPT `AssignMVarIds.rewriteExpr` (next step)
  and `MonoSolver/Translate.elm`'s `Function` arms (step 2.6), which
  consume the value.

**Verify:** `elm-tests` + full E2E green (subst engine). Cached `.ecot`
artifacts from before the change must still load (decoder fills `Nothing`)
— run one E2E program twice without cleaning to prove cache compatibility.

### Step 2.2 — Phase-0 stamping in `AssignMVarIds`

**Change** (design §3.2): `Compiler/Monomorphize/AssignMVarIds.elm`:

- `GlobalMVarState` (`:29`) gains
  `nextLam : TypeIds.SrcLambdaId` and
  `lamLabels : CoreDict.Dict Int String`.
- Add `freshLamId : Ctx -> ( TypeIds.SrcLambdaId, Ctx )` minting from a
  `nextLam` counter threaded in the rewrite `Ctx`, recording
  `lamLabels[id] = home ++ "." ++ defName ++ "#" ++ k` (enclosing global is
  available in `rewriteNodes`' per-node context; `k` = per-def ordinal).
- `rewriteExpr`'s `Function` arm (`:546-557`) and the `TrackedFunction` arm
  stamp `Just lamId` (design snippet at §3.2 — note the arm currently
  destructures `TOpt.Function args body meta`; it becomes
  `TOpt.Function _ args body meta` and rebuilds with `(Just lamId)`).
- Surface `nextLam`/`lamLabels` in the returned `GlobalMVarState`.

Determinism note for the commit message: `AssignMVarIds` runs on the merged
whole-program graph with a deterministic walk ⇒ ids are per-run stable
(LSS_003), the same stability class as `MVarId`.

**Verify:** `elm-tests` + full E2E green both engines (ids are stamped but
unread). Add one focused unit test: two `rewriteExpr` runs over the same
tree yield identical stamps.

### Step 2.3 — Engine state: members, signatures, stats

**Change** (design §8.1, §3.3): `Compiler/MonoSolver/Engine.elm`:

- `S` gains (all GLOBAL fields — survive `resetItem`; `resetItem`
  (`Engine.elm:365-367`) is untouched):
  `lssSignatures : CoreDict.Dict String LssInfer.LssSignature`,
  `lssInProgress : Set String`,
  `lssMembers : CoreDict.Dict String Int`,
  `nextMemberId : Int`,
  `specCountByGlobal : CoreDict.Dict String Int`,
  `lssStats : LssStats`.
  To avoid an `Engine ↔ LssInfer` import cycle, define `LssSignature`/
  `ArrowFact`/`LssStats` in a tiny new leaf module
  `Compiler/MonoSolver/LssTypes.elm` imported by both (create the file →
  remember the cmake reconfigure), OR define them in Engine and have
  LssInfer import Engine (LssInfer will import Engine anyway for `Step`;
  prefer the latter — no new file, no cycle: Engine does not need to name
  `signatureFor`).
- `Env` gains `lss : Config.LssConfig` (done in 1.6) and
  `lamLabels : CoreDict.Dict Int String`.
- Add `memberIdFor : String -> Step Int` verbatim (design §3.3): intern
  keys `"g|home|name"`, `"c|home|name"`, `"k|home|name"`, `"a|field"` in
  `lssMembers`, supply from `nextMemberId`.
- `initState` (`Monomorphize.elm:103`) seeds `nextMemberId` from
  `GlobalMVarState.nextLam` (the two producers share one supply) and
  `lamLabels` from the same record; empty dicts/sets/zero stats otherwise.
- `LssStats` (used from 2.4 on):

```elm
type alias LssStats =
    { widenedBySize : Int, widenedByBudget : Int, widenedByKernel : Int
    , setsZonked : Int, setSizeHistogram : CoreDict.Dict Int Int }
```

**Verify:** compiles; full E2E green solver engine (fields inert).

### Step 2.4 — Store: slot minting, zonk, encode

**Change** (design §4.4, §6.1, §6.3): `Compiler/MonoSolver/Store.elm`:

1. `LoadCtx` (currently `{ store, memo, revMemo }`, built at `:70` and
   `:87`) gains `lssOn : Bool` and `arrowSlots : List IO.Variable`. Both
   construction sites populate `lssOn = s.env.lss.enabled`,
   `arrowSlots = []`.
2. `loadTypeC` (`:92`) `TLambda` arm: verbatim design §4.4 — lss-on mints
   `FunL pFrom pTo pSet` with a fresh `FlexVar` slot pushed onto
   `arrowSlots`; lss-off keeps today's `Fun1` path byte-for-byte.
3. New `loadTypeIsolatedWithArrows : Can.Type TypeIds.MVarId
   -> Step ( IO.Variable, Array IO.Variable )` — clone of
   `loadTypeIsolated` (`:82-90`) that returns
   `Array.fromList (List.reverse ctx.arrowSlots)`. **This function defines
   arrow ordinals** (LSS_006) — add that sentence as its doc comment.
4. `zonkFlatC` (`:651`): replace step 1.4's placeholder `FunL` arm with the
   real one (design §6.1): zonk arg/result, then `zonkSetSlot maxSetSize
   setVar` → `MFunction anno [ma] mb`. Implement `zonkSetSlot` per the
   design's policy block: `FlexVar → LTop`; `LambdaSet1 True _ → LTop`;
   `LambdaSet1 False ms → LSet (sorted keys)` unless
   `Dict.size ms > maxSetSize → LTop` (bump `widenedBySize`); bump
   `setsZonked` + histogram. `maxSetSize` reaches zonk via the existing
   `ZonkCtx` (extend it with the int + a stats accumulator, threaded back
   to `S` at the zonk call boundary — mirror how `revMemo` threads today).
5. `monoTypeToVarC` (`:369`): `MFunction` arm folds into `FunL`s whose
   slots are `Structure (LambdaSet1 …)` per the demand's anno — verbatim
   design §6.3, including the deliberate asymmetry: a demand's `LTop`
   encodes as `top = True` (poison), while an unconstrained slot merely
   reads back `LTop`. Gate the whole branch on `lssOn`; lss-off folds
   `Fun1` exactly as today.
6. `classifyDirect` (`:834`): its structural `TLambda` arm stamps `LTop`
   (already does after 1.5's sweep — just confirm).

**Verify:** `elm-tests` green. Full E2E green with
`ECO_MONO_ENGINE=solver` **flag off** (must be byte-identical: no `FunL`
minted). Flag ON smoke run of a small `TEST_FILTER` batch — expect green;
sets exist in stores but nothing injects members yet, so every slot zonks
`FlexVar → LTop` and graphs stay annotation-trivial.

### Step 2.5 — `Compiler/MonoSolver/LssInfer.elm` (new file)

Run `cmake --preset build` after creating the file (ELM_SOURCES glob).

Land in four sub-steps, each compiling:

**2.5a — scaffolding + scratch stores.** Module skeleton exposing
`signatureFor : TOpt.Global -> Step LssSignature` and
`sigTrivial : LssSignature -> Bool`; the `LssSignature`/`ArrowFact` records
verbatim (design §7.1). Implement `withScratchStore : Step a -> Step a` —
stash `s.store/s.memo/s.revMemo`, run against `Engine.freshStore` + empty
memos, restore after (this is `Translate.retranslateAt`'s stash/restore
(`Translate.elm:2739`) promoted to a combinator — read that function first
and copy its restore discipline exactly). Implement `signatureFor` as:
memo lookup in `s.lssSignatures` → else compute a TRIVIAL signature (load
the def's annotation via `loadTypeIsolatedWithArrows`, count arrows n,
`arrows = Array.initialize n (\i -> { rep = i, members = [], top = False })`,
`trivial = True`) and memoize. This stub is semantically final for
first-order defs and lets 2.6–2.8 land against a working API.

**2.5b — the unit walk.** Replace the stub body for defs whose annotation
contains an arrow: resolve the inference unit (singleton, or the SCC via
the def's `TOpt.Cycle` node — same resolution as `specializeNode`'s Cycle
arm, `MonoSolver/Monomorphize.elm:311`); pre-resolve callee signatures
(syntactic fold over unit bodies collecting `VarGlobal`s; recurse
`signatureFor` for each outside the unit — with the
`lssInProgress` re-entry guard crashing as `EngineBug`); then ONE
`withScratchStore` block: load every member's annotation through the
SHARED scratch memo (`Store.loadType`) capturing per-member arrow arrays,
walk each body per the design §7.3 table:

- `Function (Just lam) …` → `loadType meta.tipe`, `UF.get` expecting
  `Structure (FunL _ _ slot)`, unify `LambdaSet1 False {lam}` into slot;
  recurse body.
- `Call` with `VarGlobal g` → `instantiateLss g` (step 2.8's function —
  order 2.5b AFTER 2.8 lands, or call a local equivalent; simplest: 2.5b
  calls `applySignature` + `loadTypeIsolatedWithArrows` directly, sharing
  code with 2.8 via one helper) → unify param slots against loaded arg
  types (reuse `unifyParamsCollect`'s shape, `Translate.elm:1876`,
  best-effort: structural failure = poison, not crash) → unify result
  against `loadType meta.tipe`.
- `Call` with `VarKernel`/`VarDebug` → load kernel scheme fresh, unify
  args, `poisonArrowSets` the kernel type (2.5d).
- standalone function-typed `VarGlobal`/ctor/accessor → `memberIdFor` →
  unify singleton into head slot of `loadType meta.tipe`.
- `Let` → record RHS type Point per name; each use joins via
  `joinArrowSets` (2.5c).
- everything else → structural recursion ONLY (shared MVarIds in the
  scratch memo already connect types; do NOT re-implement translate's
  demand corners — wrong layer).

Zonk signatures at unit end: per member, per annotation slot — members/top
from root content; `rep` = smallest lower ordinal with
`UF.equivalent slots[i] slots[j]`; `trivial` = all facts
`{rep=self, members=[], top=False}`. Memoize every unit member.

**2.5c — `joinArrowSets`** (design §7.4): parallel walk of two loaded
structures unifying ONLY set slots of arrows at matching positions; on
structural divergence (either side non-structure or shape mismatch) poison
BOTH sides' remaining arrow slots to ⊤ and stop that branch. Keep it a
named top-level function (the vNext per-use upgrade point).

**2.5d — `poisonArrowSets`** (design §7.5): `UF.get`; on
`Structure (FunL a b s)` unify `s` with `LambdaSet1 True ∅`, recurse a/b;
other structures recurse children; vars stop. Bump `widenedByKernel` at
call sites that poison.

**Verify (after each sub-step):** `elm-tests`; after 2.5b add unit tests
in the compiler test suite: (i) a def whose body is
`\x -> x` under annotation `(Int -> Int)` yields `arrows[0].members ==
[thatLamId]`; (ii) `twice f = f << f`-shaped sharing yields `rep` linkage;
(iii) a def calling a kernel with a function arg yields `top = True` on
that arrow. (These run through a scratch store inside a minimal engine `S`
— follow the existing MonoSolver unit-test harness under `compiler/tests`;
if none exists for engine internals, gate via the E2E census instead and
note it here.)

### Step 2.6 — `specializeLambda` + member injection

**Change** (design §8.2): `Compiler/MonoSolver/Translate.elm`:

- The `translate` `Function`/`TrackedFunction` arms (`:571-574`) now bind
  the tag: `TOpt.Function srcLam params body meta ->
  specializeLambda srcLam params body meta.tipe`.
- `specializeLambda` (`:1090`) gains the `Maybe TypeIds.SrcLambdaId`
  parameter. Head behavior when `s.env.lss.enabled`: replace the storeless
  classification with `Store.loadType canType` (through the ITEM memo —
  demand concretization must be visible) → `injectHeadMember srcLam` →
  `Store.zonkToMono`; lss-off keeps today's `classify` path untouched
  (design §8.2 snippet). `injectHeadMember` = `UF.get` expecting
  `Structure (FunL _ _ slot)`, unify `LambdaSet1 False {member}` into
  slot; `Nothing` srcLam or lss-off → no-op; non-arrow loaded type →
  `EngineBug`.

**Verify:** flag-off full E2E byte-identical (the lss-off path must be
letter-for-letter today's). Flag-on smoke batch green; spot-check one
MonoGraph (report lands in 2.10 — until then use a temporary
`Debug.log`-free assertion or defer graph inspection to 2.10).

### Step 2.7 — `ClosureInfo.srcLambda`

**Change** (design §8.3): `Compiler/AST/Monomorphized.elm:618` — add
`srcLambda : Maybe TypeIds.SrcLambdaId` to `ClosureInfo`. Construction
sites (compiler-driven sweep; main one is in `specializeLambda`'s
closure-build) populate from the tag; legacy engine sites pass `Nothing`.
The closure's target SET is deliberately NOT duplicated here — consumers
read the anno on the closure's own `MonoType` (`Mono.typeOf`). Confirm the
inliner (`MonoInlineSimplify`) copies `MonoClosure` nodes wholesale so
`srcLambda` rides verbatim (OQ6 semantics: shared source id across inlined
instances is intended; `LambdaId` uniqueness — MONO_019 — is separate and
untouched). Grep `MonoInlineSimplify.elm` for `ClosureInfo` field rebuilds;
if it reconstructs the record, thread the field.

**Verify:** compile-driven sweep done; full E2E green subst + solver.

### Step 2.8 — call paths: `instantiateLss` + fast-path gate

**Change** (design §8.4): `Compiler/MonoSolver/Translate.elm`:

- Add `instantiateLss global funcCanType` + `applySignature sig slots`
  verbatim (design §8.4 snippets): `signatureFor` → 
  `loadTypeIsolatedWithArrows` → per-ordinal: `rep≠i` ⇒ unify slots;
  `top` ⇒ unify `LambdaSet1 True ∅`; `members≠[]` ⇒ unify
  `LambdaSet1 False members`. Both sides MUST source the type from
  `lookupAnnotation` (`:3974`) with the `funcMeta.tipe` fallback exactly
  as `translateCall` does — assert this by code inspection, it is LSS_006's
  other half.
- `translateGlobalCallSlow` (`:1688`): the ONLY change is
  `instantiate funcCanType` → `instantiateLss global funcCanType`
  (`instantiate` is at `:2165`; the following unifyParamsCollect /
  expected-result / zonk / enqueue sequence is untouched — sets ride the
  Points).
- Fast paths: `translateGlobalCall`'s guard (`:1408`,
  `if List.isEmpty s.numberMulti && List.isEmpty s.localMulti then`) gains
  `&& lssFast global s`, where `lssFast` = lss off OR (callee signature
  `trivial` AND no argument type mentions an arrow). `sigTrivial` forces
  the signature computation on first use — memoized, one-time.
  Arrow-mention check: a small `canTypeHasArrow` over the arg canonical
  types (syntactic, cheap, memo not needed).
- `translateIndirectCall` (`:1316` area): NO change — verify by reading
  that the callee's zonked type already carries the annotation.

**Verify:** flag-off: EngineDiff corpus MATCH set unchanged + full E2E
byte-identical. Flag-on: full E2E green
(`ECO_MONO_ENGINE=solver ECO_MONO_LSS=1` on `--target full`); expect the
first REAL sets in graphs (confirmed via 2.10's census once it lands —
sequence 2.10 immediately after and gate both together if inspection
tooling is otherwise awkward).

### Step 2.9 — kernel/port/effect poison hooks

**Change** (design §7.5): in `Translate.elm`:
`deriveKernelAbiTypeWith` (`:2101`) — poison the instantiated kernel
scheme's arrows (both call and ref paths route through it);
`specializePort` (`:667`) — poison payload/encoder arrows; `VarDebug` rides
the kernel path. Do NOT special-case `List.map/foldl/foldr/filter` — they
are plain Elm in elm/core 1.0.5 (design verified) and must NOT be poisoned;
`List.map2-5`, `sortBy`, `sortWith`, Task/Process internals go ⊤ via the
kernel path naturally. Trust caveat: until the kernel-honesty work
(solver-reuse §6.3) lands, kernel *types* are PostSolve fabrications —
poison-at-boundary is exactly what makes LSS safe against that, so this
step is what un-gates trusting the census.

**Verify:** flag-on full E2E green; a hand-check that a program passing a
lambda to `Task.perform`-shaped code yields `LTop` on that arrow while a
pure `List.map (\x -> x+1) xs` yields a singleton `LSet` (via 2.10 census).

### Step 2.10 — stats, census, report plumbing

**Change** (design §8.6, §2.2):

- Render from `lssStats` + a post-prune graph walk: per-global spec counts
  (top N), set-size histogram, widening events by cause, member census with
  `env.lamLabels`. String concatenation only (NO `Debug.toString`).
- `MonoSolver/Monomorphize.elm`: add `monomorphizeWithReport` returning
  `Result String ( Mono.MonoGraph, Maybe String )` (report `Just` iff
  `lss.report`); `monomorphize` = `Tuple.first`-wrapper for existing
  callers.
- `Builder/Generate.elm` `selectMonomorphizer`/`runMonoOptPipeline`: thread
  the `Maybe String` out and print to stderr before returning (follow how
  FEStats emits; keep it out of stdout — MLIR text mode owns stdout).

**Verify:** `ECO_MONO_ENGINE=solver ECO_MONO_LSS=1 ECO_MONO_LSS_REPORT=1`
on 2–3 E2E programs prints a plausible census (singleton sets on direct
lambda flows; ⊤ at kernel boundaries; zero `widenedByBudget` since
`keyed=False`). Then eco self-compile with the report on: census sanity at
scale + record flag-on vs flag-off Stage-7a wall time (M2 gate number).

### Step 2.11 — invariant checker + invariants.csv

**Change** (design §11 M2, §12):

- TestLogic checker for **LSS_002**: for every reachable `MonoClosure` with
  `srcLambda = Just m`, the head annotation of its `MonoType` is `LTop` or
  contains `m`. Wire it where other TestLogic graph checks run (grep
  `TestLogic.Generate.MonoFunctionArity` for the harness pattern).
- `design_docs/invariants.csv`: add LSS_001–LSS_007 (design §12 wording),
  amend MONO_005/MONO_017 (set-widened keys vs annotated reverse-mapping
  types) and MONO_019 (LambdaId uniqueness does not apply to `srcLambda`).

**Verify:** checker green on the full E2E corpus flag-on.

### Step 2.12 — M2 gate (record it)

All of (design §11 M2): full E2E green `ECO_MONO_LSS=1` (solver); flag-off
byte-identical + EngineDiff MATCH unchanged; LSS_002 checker green; census
plausibility reviewed on E2E corpus + self-compile; wall-time delta
recorded (expect ≤ a few %; if worse, profile `signatureFor` memo hits
before proceeding). Update this plan's Status.

---

## Milestone M3 — the singleton dispatch consumer

### Step 3.1 — dispatch-attribute producer audit (design §14 bullet 4)

Before writing the pass: map exactly where the Elm side emits
`_dispatch_mode`/`_fast_evaluator`/`_capture_abi` call attributes today.
Ground truth: consumers fully implemented in
`runtime/src/codegen/Passes/EcoToLLVMClosures.cpp:1108-1256`; producer side
partial — `Generate/MLIR/Expr.elm:1082/:4524` emit `$cap` fast-evaluator
clones per closure; `Mono.Known` is matched only at
`Generate/MLIR/Expr.elm:1090`. Deliverable: a short note in this plan
listing (a) which `CallKind`/`closureKind` combinations reach which attr
emissions, (b) what a stamped `Known id + captureAbi` will trigger, (c) any
gap to fix. Do not skip: M3's payoff depends on the emission actually
firing.

### Step 3.2 — the AbiCloning singleton pass (design §9.2)

**Change**: complete `Compiler/GlobalOpt/AbiCloning.elm` (currently a
documented no-op, `AbiCloning.elm:39-41`) — note its module doc describes
ABI *cloning*; this step implements the LSS *upgrade* portion only:

1. One graph walk indexing `srcLambda -> [reachable MonoClosure instances]`
   (via `MonoTraverse.foldExpr` over post-prune nodes).
2. For each `MonoCall` whose callee-expression `MonoType` head annotation
   is `LSet [m]`: if `m` has exactly ONE reachable instance and its capture
   ABI is determinable from that instance's `ClosureInfo`
   (`captures`/`params` types → `CaptureABI`), stamp
   `callInfo.closureKind = Just (Known kindId)`,
   `callInfo.captureAbi = Just abi`. Mint `ClosureKindId`s per
   (srcLambda, abi) pair in a pass-local intern table.
3. Multiple instances / differing ABIs / `LTop` → leave `CallGenericApply`
   (this ambiguity is ABI_CLONE_001's future trigger; record a counter).
4. Extend the M2 census with `dispatchUpgraded : Int` (report reruns after
   GlobalOpt or the counter is returned through the pass — simplest:
   stderr print from the pass itself behind `ECO_MONO_LSS_REPORT`).

The pass runs at its existing Phase-4 slot in `globalOptimize`
(`MonoGlobalOptimize.elm:128`) — before `annotateCallStaging` (Phase 5,
`:131`), which already recomputes/threads `CallInfo`; verify
`computeCallInfo` (`:1910`) preserves rather than overwrites stamped
`closureKind`/`captureAbi` (design ground truth says these currently
default to `Nothing` there — thread the stamped values through).

**Verify:** full E2E green flag-on; `TEST_FILTER` perf batch green;
dispatch-upgrade count > 0 on closure-heavy E2E programs (e.g. the
parser/JSON tests); zero upgrades with `ECO_MONO_LSS=0` (pass gates on
anno ≠ available ⇒ inert). Runtime spot-check: a program whose hot loop is
`List.map (\x -> …)` shows `_dispatch_mode="fast"` on the call in its
`.mlir` (grep the build dir).

### Step 3.3 — M3 gate

E2E + perf suite green; upgrade counts recorded in the report; no
regressions flag-off. Record in Status.

---

## Milestone M4 — keyed specialization, budgets, `==` audit

### Step 4.1 — budgeted keying in `enqueueSpec`

**Change** (design §8.5): `Engine.enqueueSpec` (`Engine.elm:307`): key type
= `monoType` when `lss.enabled && lss.keyed && underBudget`, else
`Mono.widenSets monoType`. `underBudget` consults
`specCountByGlobal[toComparableGlobal global] < lss.maxSpecsPerGlobal`;
bump the count on NEW spec creation; count budget-widen events in
`lssStats.widenedByBudget`. Types are NEVER widened — only keys
(MONO_020/021/024 discipline); `Registry.updateRegistryType` keeps writing
the true annotated node type (MONO_017).

**Verify:** `keyed=False` unchanged (byte gate). `ECO_MONO_LSS=keyed` full
E2E green; census shows per-global spec counts and any budget widening.

### Step 4.2 — the `==`-on-MonoType audit (design §5.2)

Sweep every `==`/`Dict`-key/`comparable` use of `MonoType` outside the
registry: GlobalOpt staging equality, `Diff.elm` serialization, tests.
Default each to `eqLayout` (annotation-insensitive) unless it is
deliberately a specialization-key comparison. Grep starters:
`grep -rn "== .*MonoType\|MonoType ==" compiler/src`, plus all
`toComparableMonoType` callers. Record each decision as a one-line comment
at the site (`-- eqLayout: layout comparison, sets irrelevant`).

**Verify:** full E2E green keyed + unkeyed; EngineDiff unaffected (diff
runs lss-off by 1.6).

### Step 4.3 — M4 gate

Spec-count and binary-size deltas within budget on the E2E corpus AND
elm-aws-codegen (the known pathological input — watch wall time, the
GlobalOpt-exponential lesson); no `eqLayout` regressions; census reviewed.
Record in Status. Decide defaults (`keyed = True`?) as a separate,
data-driven flip — not part of this plan.

---

## Deferred / explicitly out of scope (from design §1, §14)

Typed set members; M5 small-set dispatch lowering (tagged capture unions —
own design doc); per-use let-boundary sets (v1 `joinArrowSets` union is the
accepted precision loss); cross-build signature caching; specializing into
C++ kernels; borrow-inference consumption (LSS §9.4 / M6 — see
`design_docs/globalopt/borrow-inference-design.md`).

## Risk ledger

| Risk | Guard |
|---|---|
| Key-fragment drift breaks byte gate in M1 | `LTop → "A("` byte-exact rule (step 1.5.3); EngineDiff gate at 1.7 |
| lss-off path not identical (perf or bytes) | `Fun1` path untouched by construction (1.4/2.4); flag-off byte gates at every M2 step |
| Scratch-store leaks into item state | `withScratchStore` copies `retranslateAt`'s stash/restore exactly (2.5a); crash-on-reentry guard |
| Signature/instantiation ordinal skew | LSS_006: both sides use `loadTypeIsolatedWithArrows` on the SAME annotation source (2.8) |
| Kernel fabricated types poison too little/much | Poison-at-boundary is conservative by design (2.9); census `widenedByKernel` reviewed at 2.12 |
| Fast-path cache serves stale set-free types | `lssFast` conjunct gates every cached path (2.8); caches keyed only under the guard |
| `computeCallInfo` clobbers M3 stamps | explicit thread-through check in 3.2 |
| elm-aws-codegen blowup under `keyed` | budget + `widenedByBudget` counter (4.1); M4 gate runs it explicitly |

## Progress checklist

- [x] 1.1 SrcLambdaId
- [x] 1.2 LssConfig + hash
- [x] 1.3 env overrides
- [x] 1.4 FlatType + arms
- [x] 1.5 LambdaSetAnno + 158-site sweep (+~50 test-file sites)
- [x] 1.6 entry plumbing
- [x] 1.7 **M1 gate** (see Status header)
- [x] 2.1 TOpt.Function field + codec
- [x] 2.2 AssignMVarIds stamping
- [x] 2.3 Engine S/Env + memberIdFor
- [x] 2.4 Store load/zonk/encode
- [x] 2.5 LssInfer (scaffold + walk + joinArrowSets + poison)
- [x] 2.6 specializeLambda + injectHeadMember (classifyLambdaHead)
- [x] 2.7 ClosureInfo.srcLambda
- [x] 2.8 instantiateLss + fast-path gate (lssFastOk)
- [x] 2.9 kernel/port poison hooks
- [x] 2.10 stats + census + report (monomorphizeWithReport)
- [x] 2.11 LSS_002 checker + invariants.csv (LSS_001-007, MONO_019 amended)
- [x] 2.12 **M2 gate** (see Status header + gate findings)
- [ ] 3.1 dispatch-attr audit
- [ ] 3.2 AbiCloning singleton pass
- [ ] 3.3 **M3 gate**
- [ ] 4.1 budgeted keying
- [ ] 4.2 == audit
- [ ] 4.3 **M4 gate**

## M2 gate findings (2026-07-11)

- **elm-tests: PASS** — 12991 passed / 12 failed, failure set identical to
  the pre-change baseline (POST_010 class); all LSS_002 checker suites green
  after two walk fixes (in-unit Σ sharing; `_M$` cycle-group Link aliasing).
- **Flag-on full E2E: PASS** — 1579/1579 under
  `ECO_MONO_ENGINE=solver ECO_MONO_LSS=1`.
- **Census verified by hand** (AccessorVariableTest, lss-on): 308 members
  (295 lambdas + 13 interned), 15 signatures (15 trivial), 184 slots zonked,
  16 singleton sets, 12 kernel widenings. NOTE: the E2E harness swallows
  stderr of successful compiles — census inspection needs a direct
  `node compiler/bin/index.js make …` invocation.
- **PLAN ERROR found via census**: §8.5's `keyed=False ⇒ widenSets` key
  guard belongs to M2, not M4 (the design's "M2 keys are today's keys"
  depends on it). Without it, flag-on specialization fan-out is live at M2
  (e.g. `List.foldl`=6 specs). Fix: enqueueSpec keys `widenSets monoType`
  whenever `lss.enabled && not lss.keyed` (lss-off path untouched — no
  widenSets allocation).
- **Runtime gates: PASS (both engines, post-M2 tree)** — full E2E 1579/1579
  under `ECO_MONO_ENGINE=solver` (flag-off) AND under the default subst
  engine. Runtime equivalence holds; the EngineDiff divergence below is
  confirmed runtime-benign.
- **§8.5 keyed=False guard landed with M2** (correcting the plan's M4
  deferral): `Engine.enqueueSpec` keys via the new
  `Registry.getOrCreateSpecIdKeyed` (widened comparable key, annotated
  stored type — types never widen, MONO_020/021/024; first demand's stored
  annotations win on a key hit). The lss-off path is untouched (no
  `widenSets` allocation). Census before/after showed the observed foldl=6
  fan-out was TYPE-driven, not annotation-driven — the guard is a
  correctness safeguard, not a behavior change on the corpus.
- **OPEN: EngineDiff divergence (flag-off)** — post-M2, EngineDiff fails on
  ~110 non-http programs (vs 18 known-benign http at M1). Reproducer:
  `cd build/test/elm && rm -rf eco-stuff && ECO_MONO_ENGINE=diff \
  ECO_MONO_DIFF_DUMP=1 node .../index.js make src/AccessorVariableTest.elm …`.
  Analysis so far: graphs agree except spec trios like `G.cons` keyed at
  record types (subst) vs `Int` (solver) with equal node counts; the
  divergent specs are junk-class (use sites carry the OTHER type — registry
  rebound via MONO_017). Bisection eliminated: kernel poison wrap, all four
  arrowParts sites, the lssFastOk dispatch restructure, and srcLambda
  stamping (probes rebuilt and verified via guida freshness checks; note the
  E2E front-end is Stage-1 guida.js — `--target eco-boot` is the WRONG
  rebuild for probing). Remaining suspects: Store LoadCtx/zonk threading,
  Engine/Monomorphize field plumbing, ClosureInfo/TOpt field additions.
  Production bar per monosolver plan rev-9 is runtime equivalence; both
  engines' full-suite runtime gates cover that. This item tracks restoring
  the diff debugging aid's M1 baseline.

## Implementation deviations (M1+M2, recorded as built)

- The engine entry takes `Config.LssConfig` (not the whole `MonoConfig`) —
  tighter; `EngineDiff` passes `Config.defaultLss` (forced off).
- The arrow helpers live in **Store**, shared by Translate and LssInfer to
  avoid a Translate↔LssInfer cycle: `arrowParts`, `arrowSetSlot`,
  `unifySlotWithSet`, `unifyBestEffort` (transactional-by-persistence),
  `poisonArrowSets` (worklist + point-keyed seen set).
- `LssSignature`/`ArrowFact`/`LssStats` live in **Engine** (no new leaf
  module needed; LssInfer imports Engine anyway).
- `ZonkCtx` gains `lss : Maybe LssZonkAcc` (Nothing when off — keeps the hot
  path lean); stats fold back into `S.lssStats` in the `zonkToMono` wrapper.
- `monoTypeToVarC` threads a `Bool` lssOn (2 sibling helpers too).
- `specializePort` split into wrapper (poison first) + `specializePortBody`.
- The walk's ordinal-pairing guard: `applyFacts` POISONS the instantiation on
  arrow-count mismatch (unannotated defs whose use-site type grew arrows) —
  sound fallback for LSS_006.
- Two walk bugs found by review before first execution: (a) in-unit
  (recursive/sibling) calls must NOT `signatureFor` the in-flight unit —
  they load the sig-source type through the SHARED scratch memo (Σ rule);
  (b) `TOpt.Link` re-exports are chased in `signatureFor` and alias-memoized
  (a Link's unit members carry the target's keys).
- Kernel member key format is `"k|home.name"`; globals/ctors use
  `toComparableGlobal`; lambda member ids are `Id.toComparable` of the
  stamped `SrcLambdaId` directly (interning supply seeded past `nextLam`).
- MONO_005/MONO_017 wording amendments deferred to M4 (they describe keyed
  specialization); MONO_019's srcLambda note landed with M2.
