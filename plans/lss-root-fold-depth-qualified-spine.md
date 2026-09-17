# LSS: depth-qualify the root-fold spine write — one name per (global, stage)

**Status: IMPLEMENTED 2026-09-17, DEFAULT-OFF behind `lss.rootFoldDepthIds`;
§9 lists the flip gates. Supersedes §5 (R1/R2) of
`plans/lss-depth-qualified-spine-identity.md`, whose §4 attribution this plan
closes by code reading — the writer is named in §1, file:line.**

**SCOPE CORRECTION (2026-09-17, after `arrowSolverRoots` was flipped
DEFAULT-ON): this is NOT a prerequisite for a future 2b flip — 2b has
shipped, so the 139 `1id` sites of §0 are LIVE in the default build and this
is a live defect fix.** `sigRootIdentity` is correspondingly now
DEFAULT-OFF (the two are mutually exclusive by construction —
`recordRootKey` does not run when `useSolverRoots` is on). §0's A/B was taken
with 2b supplied by env on a tree whose default was off and whose
`flow.letOverlay` was off; the tree has since also gained
`flow.accessFlow`, `flow.litFacts` and `stamp.useInjectPap`. **Treat §0's
absolute counts as indicative only** — the authoritative baseline is the
flag-OFF arm of this plan's own A/B, which IS the shipping default.

**One sentence:** `Translate.classifyLambdaHead` writes a root-folded def's
STAMPABLE `g|G|<layout>` id at every depth `0..arity-1` of its own spine, while
the two other spine writers (`stampSelfSpine`, `injectPapSuccessors`) write
`g|` at depth 0 and the non-stampable `p|G|d` at depth `d≥1`; make the third
writer match the other two.

---

## §0 Evidence

**Per-site census, this tree, one JS compiler, two arms**
(`AbiCloningStats.instQual.multiSites`, `ECO_MONO_LSS_CENSUS=1`; instrument
reconciles exactly with `multiSetSiteHist`):

| arm | multi-set sites | `1id` — one code object, ≥2 names | `2id`+ |
|---|---:|---:|---:|
| `ARROW_ROOTS=0` (shipping) | 13 | **0** | 13 |
| `ARROW_ROOTS=1` (2b) | 243 | **139 (57.2 %)** | 104 |

The `1id` population is `gp`-kinded (145/243 sites) and names ordinary
multi-arity globals: `MonoTraverse.mapExprTypes` 18, `MonoInlineSimplify.
computeCost` 10, `Type.Solve.makeCopyHelp` 10, `TypedOptimized.exprEncoderS` 9.

**Dispatch-level corroboration, same session** (`lss globalopt:` line):

| counter | `ARROW_ROOTS=0` | `ARROW_ROOTS=1` | Δ |
|---|---:|---:|---:|
| `stampedPapGlobal` (LSS_040 `p|` fast stamps) | 3,348 | 3,239 | **−109** |
| `declinedShape` | 526 | 716 | +190 |
| `declinedBodyMismatch` | 1,311 | 1,454 | +143 |

A `{p|G|d}` singleton is a LSS_040 candidate (`lss.stamp.papFast`, default-on
since 2026-09-07). A `{g|G|L, p|G|d}` 2-set is not. −109 is the predicted
signature of exactly this defect and is the first number §9 expects to move.

**Method caveat (carried from the parent plan §0.1):** an earlier NATIVE-
compiler run reported the `ARROW_ROOTS=0` arm at 66 sites, not 13; cause not
discriminated (bootstrap stage, or `ECO_MONO_LSS_CENSUS` set vs unset). Only
within-run A/B is quotable. §9's gates are all within-run.

---

## §1 The defect — the writer, file:line

Three writers put member ids onto a global's result spine. Two are
depth-qualified; one is not.

| writer | site | depth 0 | depth d ≥ 1 |
|---|---|---|---|
| `Translate.stampSelfSpine` (`lss.regIdentity`) | `Translate.elm:5047–5090`, via `memberIdForDepth` `:4980` | ground `g|G|L` | `p|G|d` (`Engine.papMemberIdFor`) |
| `LssInfer.injectPapSuccessors` (`lss.refPapSpine`) | `LssInfer.elm:3047–3070` | (head written by `standaloneMember`) | `p|G|d` (`mintPapSuccessorIds` → `papSuccGoC`) |
| **`Translate.classifyLambdaHead` → `LssInfer.injectLambdaMemberQualified`** | `Translate.elm:1872` → `LssInfer.elm:174–185` → `injectSpineMemberId arity mid` → `spineGoC` `:3216–3252` | folded `g|G|L` | **folded `g|G|L` — SAME id** |

The chain for the third writer, precisely:

1. `Translate.elm:1819–1855` — under `lss.rootFold`, the stashed-root path
   records `rootLamOf[srcLambdaKey lamId] = g` (skipping local-multi RHSs
   under `stamp.useInject`, and kernel-alias globals).
2. `Translate.elm:1872` — `LssInfer.injectLambdaMemberQualified arity srcLam
   funcVar`, where `arity` is the root lambda's parameter count.
3. `Engine.lambdaInstanceMemberId` (`Engine.elm:677`) → `mintLayoutQualified…`
   (`:820–850`): with `rootLamOf` hit, the interned key is
   `"g|" ++ global ++ <layout tail>` — the GROUND STANDALONE key. This is the
   id E9.1 `devirtFnGlobals` and LSS_009/LSS_011 treat as stampable.
4. `LssInfer.spineGoC` (`:3216–3252`) writes that one `mid` into the slot of
   every arrow it descends, `remaining` = `arity` … 1.

`plans/lss-root-member-fold.md` §1.3/§1.4 states the intended scope as
**"Head only. Deep-spine pairs stay"** and lists only the INFERENCE-phase
`injectLambdaMember` as untouched; the translation-phase full-spine write in
step 4 is not mentioned. It was inherited from LSS_013 (correct for `l|`
members) and never re-examined when the id it writes changed class under the
fold.

Why it is invisible at the shipping default and visible under 2b: the def's
own depth-`d` slot is not a consumer head. Under `arrowSolverRoots`, a
MONOMORPHIC global's arrows share solver roots across every reference in the
module (HM instantiates nothing), so the def's depth-`d` slot merges with the
inner arrow of every `G x` callee — which IS a consumer head — and reads back
`{g|G|L, p|G|d}`.

---

## §2 Why this is a latent-soundness fix, not only precision

`plans/lss-root-member-fold.md` §1.5 AR-1, verbatim: *"The papMembers
miscompile required a stampable id on a PARTIAL application; depth>0 stays
`p|` (declining), so that door stays shut."* And
`plans/lss-solver-root-signature-identity.md` R1 records the drafted
`g|`-reuse for PAPs miscompiling *"via a stampable-class devirt"* — E9.1
devirtualizes a `g|` singleton straight to `G`'s spec without an arity check.

Step 4 above writes the stampable `g|G|L` at depth ≥ 1, i.e. onto exactly the
partial-application positions AR-1 says must carry `p|`. Today the only thing
standing between that and the recorded miscompile is that (a) at the default
those slots are not consumer heads, and (b) under 2b the co-resident `p|G|d`
makes the set a 2-set, which every consumer declines. Neither is a design
guarantee; both are accidents of slot sharing. The fix restores AR-1's
invariant for the writer it missed.

Soundness of the fix itself: the ids written at depth `d≥1` are the SAME
`p|G|d` the other two writers already put there; `papMemberIdFor` is
get-or-create by key with `SourcePap` origin. No new id class, no new
consumer. Unification is a total join, so the write is idempotent where the
other writers already reached and additive where they did not.

---

## §3 The fix — one rule, and what it is not

**Rule.** In `injectLambdaMemberQualified`, when the minted `mid` is a
root-folded ground id (i.e. `rootLamOf` has the raw lambda), write `mid` at
depth 0 ONLY and `p|G|d` at depths `1..arity-1`. Non-folded lambdas keep the
LSS_013 full-spine same-id write unchanged — LSS_011's PAP-prefix stamp on
`l|` members is layout-checked (`fastPapPrefix` from the site's layout
group), which is why one id across depths is sound for lambdas and unsound
for `g|` globals.

**Not R1 of the parent plan** (key `arrowMemo` by `(root, depth)`): that
avoids the merge. The merge is correct — every reference to a monomorphic `G`
IS one code object — and avoiding it would also cost the 13 → 104 genuine-
alternation sites 2b delivers. **Not R2** (`p|G|0` for heads): the head id
must stay the ground `g|G|L` because LSS_019 grounding, `regIdentity`, and
`rootFold` all converge on that string by design (`lss-root-member-fold.md`
§1.1); changing it re-opens the `{l|, g|}` split the fold closed. **Not R3**
(consumer-side collapse): unnecessary once the slot holds one name.

---

## §4 Implementation edit list

All in `compiler/src/`. Line numbers verified 2026-09-17 against HEAD.

### 4.1 `Compiler/MonoSolver/LssInfer.elm` — the writer

Replace `injectLambdaMemberQualified` (`:174–185`) with:

```elm
injectLambdaMemberQualified : Int -> Maybe TypeIds.SrcLambdaId -> Vars.Variable -> Step ()
injectLambdaMemberQualified arity srcLam funcVar s0 =
    case srcLam of
        Nothing ->
            Ok ( (), s0 )

        Just lamId ->
            case Engine.lambdaInstanceMemberId lamId s0 of
                Err e ->
                    Err e

                Ok ( mid, s1 ) ->
                    -- plans/lss-root-fold-depth-qualified-spine.md §3: a
                    -- root-FOLDED lambda's id is the global's ground
                    -- STANDALONE key — a stampable `g|` — and must not be
                    -- written past the head (AR-1: depth>0 is `p|`). Write it
                    -- at depth 0 only and the `p|g|d` successors the other two
                    -- spine writers already mint at depths 1..arity-1.
                    -- Non-folded lambdas keep the LSS_013 full-spine write.
                    if s1.env.lss.rootFold && s1.env.lss.rootFoldDepthIds then
                        case CoreDict.get (Engine.srcLambdaKey lamId) s1.lssMemberTable.rootLamOf of
                            Just g ->
                                case injectSpineMemberId 1 mid funcVar s1 of
                                    Err e ->
                                        Err e

                                    Ok ( _, s2 ) ->
                                        injectFoldedSuccessors g arity funcVar s2

                            Nothing ->
                                injectSpineMemberId arity mid funcVar s1

                    else
                        injectSpineMemberId arity mid funcVar s1
```

Add, beside `injectPapSuccessors` (`:3047`):

```elm
{-| Depth-qualified successors for a ROOT-FOLDED def's own spine
(plans/lss-root-fold-depth-qualified-spine.md §3). Identical walk and identical
ids to `injectPapSuccessors`, with two deliberate differences: the depth
bound is the root lambda's own `arity` (the LSS_013 bound — the arrows a
partial application of THIS lambda can peel), not `declaredArityOf`; and it is
NOT gated on `lss.refPapSpine` — this is the def's own identity write and must
not depend on the reference-side flag.
-}
injectFoldedSuccessors : TOpt.Global -> Int -> Vars.Variable -> Step ()
injectFoldedSuccessors g arity v0 s0 =
    if arity <= 1 then
        Ok ( (), Engine.bumpArgFlowCensus "rootFold|spineHeadOnly" s0 )

    else
        case mintPapSuccessorIds g 1 arity [] s0 of
            Err e ->
                Err e

            Ok ( midsRev, s1 ) ->
                Store.foldSetWrites
                    (papSuccGoC (List.reverse midsRev) CoreDict.empty v0 (Store.setWriteCtx (Store.qOnFor s1) s1.store))
                    (Engine.bumpArgFlowCensus "rootFold|spineDepth" s1)
```

`mintPapSuccessorIds` (`:3073`) and `papSuccGoC` (`:3091`) are reused verbatim.
No change to `spineGoC`, `injectSpineMemberId`, or the inference-phase
`injectLambdaMember` (signatures are pre-spec and never see the fold —
`lss-root-member-fold.md` §1.4).

### 4.2 `Compiler/Eco/Config.elm` — the flag

- `LssConfig` (`:567` region): add `, rootFoldDepthIds : Bool` directly after
  `rootFold`, with a doc comment naming this plan and stating
  "artifact-affecting; hash token `lssRFD=`".
- `defaultLss` (`:1015` region): `, rootFoldDepthIds = False`.
- `lssDecoder` (`:1601` region): `|> D.apply (D.optionalField "rootFoldDepthIds" D.bool defaultLss.rootFoldDepthIds)`.
- Hash (`:2274` region, copy the `rootFold` block): emit `"lssRFD=1"`/`"lssRFD=0"`
  only when `/= defaultLss.rootFoldDepthIds`.

### 4.3 `Builder/Eco/Config.elm` — the env override

Copy `applyLssRootFoldOverride` (`:2732–2745`) as `applyLssRootFoldDepthIdsOverride`
reading `ECO_MONO_LSS_ROOT_FOLD_DEPTH` (`=1|true|yes / 0|false|no`), and wire it
in the `Task.andThen` chain immediately after the `ECO_MONO_LSS_ROOT_FOLD` step
(`:275–277`).

### 4.4 `design_docs/invariants.csv` — one row

Add `LSS_041;Monomorphization;LambdaSets;tested;` with the §3 rule: under
`lss.rootFold`, a root-folded lambda's ground `g|` id appears ONLY at depth 0
of its own spine; depths `1..arity-1` carry `p|<g>|<d>`. Sources:
`LssInfer.injectLambdaMemberQualified`, `injectFoldedSuccessors`; test §7.1.

### 4.5 `plans/lss-root-member-fold.md` — §1.4 correction

Append to §1.4: *"CORRECTION (2026-09-17): the translation-phase
`injectLambdaMemberQualified` spine write was NOT head-only — it wrote the
folded `g|` at depths 0..arity-1. Repaired by
`plans/lss-root-fold-depth-qualified-spine.md`."*

---

## §5 What changes at the shipping default — read before flipping

This is **artifact-affecting at the default**, not only under 2b. At the
default the def's OWN inner-arrow slots go from `{g|G|L, p|G|d}` to `{p|G|d}`;
those annotations are zonked onto the node `MonoType`, which
`Registry.updateRegistryType` writes back (MONO_017) and `toComparableSpecKey`
embeds under keying. Spec keys can therefore drift even though no consumer
HEAD changes (0 `1id` sites at the default). Expect `out.mlir` to differ by
bytes flag-on at the default; §9 requires the difference to be
key-relabelling only (functional byte-identity of the LOWERED binary, or a
clean E2E/bootstrap run if relabelling changes symbol numbering).

Consumers that read inner-arrow sets and must be checked for neutrality:
- `Borrow/LssFacts.elm:315–321` — `OriginPap` → `Poison PUnresolved` today;
  `{p|G|d}` alone resolves the same as `{g,p}` (both poison). Neutral.
- `AbiCloning.papResolve` (`:2740–2760`) — a `{p|G|d}` singleton at a
  noInstance site is now a `PsStampPap` candidate under `papFast`. This is the
  INTENDED consumer and the source of §9's `stampedPapGlobal` movement.
- LSS_002 (`LambdaSetIntegrity`) — the closure's HEAD still carries its own
  (folded) member. Unchanged by construction.

---

## §6 Census (report-gated, artifact-neutral)

Two `ARGF` keys via `Engine.bumpArgFlowCensus` (`Engine.elm:1195`):
`rootFold|spineHeadOnly` (arity ≤ 1 — nothing to depth-qualify) and
`rootFold|spineDepth` (successors written). Plus the existing
`instQual.multiSites` per-site dump and `lss globalopt:` counters.

---

## §7 Tests

### 7.1 `compiler/tests/TestLogic/Monomorphize/LssRootFoldTest.elm` — extend

Fixture: the SourceIR DSL (`makeModuleWithTypedDefs`, `define`, `callExpr`,
`letExpr`, `ifExpr`, `binopsExpr` — the builders `LssRootFoldTest` and
`SpinePapDispatchTest` already import). Reuse `SpinePapDispatchTest`'s
recursion-protected HOF `applyPartial` VERBATIM (`:110–132`: `f n acc`, self-
recursive so the SCC guard forbids inlining, `let g = f 10` inside) — NOT
`List.map`, which is not guaranteed to resolve in the single-module harness
and could be inlined away. Replace its lambda-literal argument with a
partial application of a 2-arity top-level def:

```elm
add2 : Int -> Int -> Int
add2 x y = x + y

applyPartial : (Int -> Int -> Int) -> Int -> Int -> Int   -- SpinePapDispatchTest's, verbatim

testValue = applyPartial add2 2 3          -- `f` is the ROOT-FOLDED `add2`; `f 10` is add2@1
```

Inside `applyPartial`'s spec, `f`'s head arrow is `add2`'s head (depth 0)
and `g = f 10` is `add2`'s depth-1 arrow. Under `arrowSolverRoots = True` the
def's own depth-1 slot and this inner arrow share a root — the merge §1
describes — so this is the minimal reproducer of the census population.

`runWith` (`:277`) already takes the `LssConfig` record; add
`runWith2b : Bool -> Src.Module -> …` setting
`{ defaults | enabled = True, keyed = True, regIdentity = True, rootFold = True,
arrowSolverRoots = True, rootFoldDepthIds = flag }`. The harness honours
`arrowSolverRoots` — `TestPipeline.elm:286–316` runs
`SolverRoots.stampArrowRoots` / `stampArrowRootsInAnnotation` after solving,
exactly as `Compiler.Compile` does.

Pins:

1. **DIFFERENTIAL, 2b arm.** Read the `letdef g` annotation inside
   `applyPartial`'s spec (the reader `SpinePapDispatchTest` uses at `:222`).
   Flag-off: its head anno is a 2-set whose member keys (via
   `lssMemberKinds`) are one `"g|…add2|…"` and one `"p|…add2|1"`. Flag-on:
   `LSet [ m ]` with `lssMemberKinds[m]` starting `"p|"` and ending `"|1"`.
2. **Head unchanged.** Both arms: `headAnnos "add2"` is the singleton ground
   `g|` id (test 1's existing property), flag on or off.
3. **Non-folded lambdas untouched.** Keep `SpinePapDispatchTest`'s original
   lambda-literal fixture as a second module in this test: under the flag its
   `letdef g` still carries `LSet [l]` (the LSS_013 property), so the fix is
   provably scoped to root-folded ids.
4. **LSS_002 integrity** under `arrowSolverRoots = True, rootFoldDepthIds = True`
   over both fixtures — add the arm to `LambdaSetIntegrityTest` alongside the
   existing `expectLambdaSetIntegrityArrowId`.

### 7.2 Existing suites that must stay green

`SpinePapDispatchTest`, `LssRootFoldTest` tests 1–N, `LssGroundingTest`,
`LssSharedSpecJoinTest`, `MuTieTest`; `test/elm/src/HofPapPrefixDispatchTest.elm`
and `StagedFastDispatchTest.elm` (E2E). The flag is OFF in all of them by
default; 7.1 is the only ON coverage until the flip.

---

## §8 Build and verify sequence

1. Edits §4.1–4.3. `cmake --build build --target eco-boot` (Stage 2 JS).
2. `cmake --build build --target elm-tests` once, output to
   `/tmp/test_output.txt`; expect the pre-existing failure set exactly plus
   7.1 green.
3. Two-binary byte-identity, flag OFF: `out.mlir` from this tree with
   `ECO_MONO_LSS_ROOT_FOLD_DEPTH=0` `cmp`-equal to the pre-edit tree's. This
   is the rail; the edit is dead code flag-off.
4. Per-site census, both flags × both `ARROW_ROOTS` arms, ONE compiler
   (`bin/eco-boot-runner.js`, `rm -rf eco-stuff` per arm,
   `ECO_MONO_LSS_REPORT=1 ECO_MONO_LSS_CENSUS=1`). Four arms, ~25 min each.
5. `ecoc --emit=mlir-opt` `_call_kind` tally on the four `.mlir` outputs
   (script at scratchpad `tally.sh`; the dump point landed 2026-09-16).

---

## §9 Gates — pre-registered, with the numbers expected to move

All within-run, same compiler, same env set. Baselines are this session's
`ARROW_ROOTS=1` arm.

| gate | expectation |
|---|---|
| byte-identity, flag OFF | `cmp` equal, both `ARROW_ROOTS` arms |
| `1id` sites, 2b + flag ON | `gp`-kinded `1id` → **0** (139 → 0); `?g`/`?l` `1id` rows (members absent from `lssMemberKinds`) are a different population and may remain — report them, do not count them against this gate |
| `2id`+ sites, 2b + flag ON | ≥ 104 (unchanged or higher; the fix must not destroy alternation) |
| `stampedPapGlobal`, 2b + flag ON | recovers toward 3,348 from 3,239 (the −109) |
| `declinedShape`, `declinedBodyMismatch`, 2b + flag ON | move toward the `ARROW_ROOTS=0` values (526 / 1,311) |
| `singleton_fast` share of `eco.papExtend`, 2b + flag ON | ≥ 44.75 % (2b baseline); the honest metric is the `--emit=mlir-opt` tally, NOT `dispatchUpgraded` (which moved +2.07 % under 2b while `singleton_fast` moved −0.8 %) |
| default arm, flag ON | 0 `1id` sites (already 0); `stampedPapGlobal` ≥ 3,348; lowered-binary functional identity or a clean E2E + bootstrap 8c |
| elm-tests | pre-existing failure set, plus §7.1 |
| E2E `--target full` ×3 legs, bootstrap Stage 8c | green, flag ON, both `ARROW_ROOTS` arms |

**Flip criterion for `rootFoldDepthIds` default-ON:** every row above, plus
the runtime dispatch A/B on the default arm (the flag is artifact-affecting
there). Do not flip on static counters alone — that is the documented failure
mode of this register.

**`arrowSolverRoots` is already default-ON** (flipped 2026-09-17), so the
flag-OFF arm of this A/B is the shipping default and every gate above is a
statement about the SHIPPED compiler, not about a hypothetical flip.

---

## §10 P0 checks (hours) — before §8 step 4

- **Arity agreement.** For every root-folded def, `arity` (lambda params) vs
  `declaredArityOf g 8`. Add a one-shot `ARGF` counter `rootFold|arityMismatch`
  when they differ; expect 0. A nonzero count means `stampSelfSpine` and this
  writer disagree about how deep the spine is and the fix would write `p|G|d`
  at depths `stampSelfSpine` does not — sound (extra `p|` write) but worth
  knowing before reading the census.
- **The `?`-kinded `1id` rows** (`2|?g|1id`, `2|?l|1id` — 40 sites under 2b):
  members missing from `lssMemberKinds` under `lss.report`. Identify them
  (likely pruned instances or ids minted after the kinds snapshot); they are
  not this plan's population and must be excluded from the gate rather than
  silently counted either way.

---

## §11 Risks and rollback

- **Risk: spec-key drift at the default** (§5) changes symbol numbering and
  invalidates cross-run joins by `lambda_N`. Mitigation: compare by the
  `MSITE` member-key strings and `ARGF` keys, never by symbol.
- **Risk: `refPapSpine` OFF arm.** `injectFoldedSuccessors` is deliberately
  ungated; with `refPapSpine=0` the def's own spine is now the only writer of
  `p|G|d` at those depths. That is strictly MORE coverage than today's OFF
  arm and cannot create a stampable-on-PAP id (it writes `p|`). Acceptable;
  censused.
- **Risk: a consumer somewhere reads the def's OWN inner annotation and
  expected the folded `g|` there.** None found (§5), and LSS_002 covers the
  head only. If one surfaces, it is a consumer bug — AR-1 says `g|` must not
  be there.
- **Rollback:** `ECO_MONO_LSS_ROOT_FOLD_DEPTH=0`; the edit is byte-inert
  flag-off by §9 row 1.

---

## §12 Relationship to other plans

- `plans/lss-depth-qualified-spine-identity.md` — parent; this plan is its §4
  attribution (by reading, pending §8 step 4 confirmation) and replaces its
  §5 R1/R2.
- `plans/lss-root-member-fold.md` — the writer's origin; §1.4 gets the
  correction in §4.5.
- `plans/lss-ref-pap-spine.md`, `plans/lss-registration-self-identity.md` —
  the two writers already doing this right; §4.1 reuses their code.
- `plans/lss-pap-fast-stamp.md` / LSS_040 — the consumer that turns
  `{p|G|d}` singletons into `stampedPapGlobal`; §9's headline metric.
- `plans/lss-unknown-elimination.md` §11 — 2b; this removes one measured cost
  of flipping it, and nothing else.

---

## §13 RESULTS (2026-09-17) — the defect is closed; emitted dispatch improves

Built and measured on the 32-slot-fixed tree (§14). One compiler
(`bin/eco-boot-runner.js`), workload `compiler/src/Terminal/Main.elm`,
`rm -rf eco-stuff` per arm, `ECO_MONO_LSS_REPORT=1 ECO_MONO_LSS_CENSUS=1`,
`arrowSolverRoots` at its shipping default (ON). Flag-OFF **is** the shipping
default. Raw: `/work/lss-rfd2/`.

### 13.1 The gate — met exactly

| | OFF (= shipping) | ON | gate |
|---|---:|---:|---|
| multi-set sites | 243 | 104 | — |
| **`1id`** (one code object, ≥2 names) | **139 (57.2 %)** | **0** | → 0 ✅ |
| `2id`+ (genuine alternation) | 104 | **104** | unchanged or higher ✅ |
| `1id` by kind | `gp=139` | (none) | ✅ |

The fix is exactly scoped: it destroys the spurious population and leaves
genuine alternation untouched, to the site.

### 13.2 Representation — the kN collapse

```
OFF: positions=152064 k1=115643 kN=34975 var=593 top=820 coveredBp=9904
ON:  positions=151836 k1=147794 kN= 2602 var=593 top=814 coveredBp=9905
```

kN −92.6 % (34,975 → 2,602); k1 +32,151. **`var` is IDENTICAL (593) and `top`
falls 6** — the load-bearing check against information loss: had the fix
removed a `g|` from a slot no other writer reached, that slot would read back
`var` and the count would rise. It does not. The removed writes were
duplicates of an id already present, and unification is a join, so the sets
could only shrink where two names denoted one object.

### 13.3 Emitted dispatch — `--emit=mlir-opt`, post M4 slot

The honest metric per §9. Populations differ, so shares matter:

| `_call_kind` on `eco.papExtend` | OFF | ON | Δ | share OFF→ON |
|---|---:|---:|---:|---|
| `singleton_fast` | 14,839 | **14,909** | **+70** | 54.73 % → **55.41 %** |
| `segmentation_unknown` | 11,556 | **11,434** | **−122** | 42.62 % → **42.49 %** |
| `direct_known_segmentation` | 429 | 283 | −146 | |
| `generic_apply` | 281 | 271 | −10 | |
| resolved (fast + known) | 15,268 | 15,192 | | 56.31 % → **56.46 %** |

Fast dispatch is up absolutely **and** in share; unresolved generic dispatch
is down absolutely **and** in share.

### 13.4 The counter that lies, again

`dispatchUpgraded` **fell 419** (17,871 → 17,452) while emitted
`singleton_fast` **rose 70**. Opposite signs, same change. The graph shrank —
`positions` −228, `multiInstanceGroups` −166, `eco.papCreate` −784,
`eco.call` −2,114, MLIR 13,750,783 → 13,586,743 B (−1.19 %) — so there are
simply fewer sites to stamp. This is the third instance in one session of a
static AbiCloning counter pointing the wrong way (cf. `arrowSolverRoots`:
`dispatchUpgraded` +2.07 % while `singleton_fast` −0.8 %). **Do not judge this
class of change on `dispatchUpgraded`.**

Decline counters all moved the predicted way: `stampedPapGlobal` **+91**
(3,253 → 3,344 — the LSS_040 recovery §0 predicted), `declinedShape` −179,
`declinedBodyMismatch` −135, `declinedNoInstance` −15.

### 13.5 Gate status

| gate | result |
|---|---|
| `gp`-kinded `1id` → 0 | ✅ 139 → 0 |
| `2id`+ unchanged or higher | ✅ 104 → 104 |
| `stampedPapGlobal` recovers | ✅ +91 |
| `declinedShape` / `declinedBodyMismatch` toward OFF | ✅ −179 / −135 |
| `singleton_fast` share ≥ OFF | ✅ 54.73 % → 55.41 % |
| lowering health (`ecoc --emit=mlir-opt`) | ✅ 0 GC-scan errors, exit 0, BOTH arms |
| elm-tests | ✅ 13,568 pass / 12 fail = the documented pre-existing set (all POST_010, LSS-unrelated) — **flag OFF only** |
| **LSS_002 under flag ON** | ❌ **NOT RUN** — §7.1 pin 4 unwritten. §13.2's `var` invariance is indirect evidence, not the invariant. |
| E2E ×3, bootstrap 8c | ❌ NOT RUN |
| runtime dispatch A/B | ❌ NOT RUN — required for the default flip |

**Verdict: the defect this plan targets is closed and the change is a net
improvement on every metric measured. It stays DEFAULT-OFF** until §7.1's
flag-ON invariant pins, E2E, bootstrap 8c and the runtime A/B are green.

---

## §14 IMPLEMENTATION NOTE — the 32-slot record cap (a build break, recorded)

The field was first added at `LssConfig` top level. `LssConfig` was at
**exactly 32 fields**; the 33rd made the compiler's own config record
unlowerable:

```
error: 'eco.construct.record' op field_count (33) exceeds Record's 32-slot GC scan limit
```

Mono and GlobalOpt were unaffected — the census ran and its numbers were
valid — so **the front end and the whole elm-test suite pass while the
compiler cannot compile itself.** Only an explicit
`ecoc --emit=mlir-opt` on the produced artifact catches it. That check is now
step 5 of §8 and a row in §13.5 for exactly this reason.

Fixed by nesting as `stamp.rootFoldDepth` in `LssStampConfig`, beside
`useInject`/`useInjectPap` — which are also injection-site knobs, so the home
matches precedent. The cap is recorded in the field's own doc comment. This is
the same constraint that already forced `AbiCloningStats.instQual` to be a
nested record and `rootLamOf` onto `LssMemberTable` rather than `S`.
