# LSS — payload set slots on nominal types (the paper's `PStep[l] x a`)

**Status: SHELVED 2026-09-17 — NEGATIVE RESULT, implementation reverted, this document is what remains. The mechanism WORKS (a constructor payload position carrying a singleton that names the function stored in it, on both constructor shapes, flag-off byte-identical 61/61) and is TOO SLOW: ~55 min against an 8-10 min baseline, against a pre-registered criterion of ~11 min. The cost is the mechanism, not the measurement (checked). AND A CHEAPER IMPLEMENTATION WOULD NOT HAVE CHANGED THE RECOMMENDATION: the target positions are COLD, so the payoff was coverage 99.05 % → ~99.4 % against the completeness gate, paid in minutes of every compile. READ §14 FIRST; §13 has the cost attributions so they are not re-derived.**

**Origin census:** `build/compiler/build-kernel/bin/arcensus-2026-09-16-{summary.txt,pos.log.gz,.time}`
(`f8-bench-census` self-compile, `ECO_MONO_LSS_ARROW_CENSUS=1 ECO_MONO_LSS_ARROW_ROOTS=1`, 9:54 wall,
15.28 GB): `positions=151904 k1=115504 kN=34954 var=593 top=820 part=33`. ⊤ by kind: poison 330,
clsDestr 309, clsLet 108, clsMisc 41, clsIf 16, clsLocal 8, abi 6, conflict 2. The memory entry
`lss-residue-census-sep16` records the per-class reading; the poison class is a separate item
(origin unattributed — needs a `poison|<site>|<kernel>` census key first) and is OUT OF SCOPE here.

---

## 1. The gap, stated against the paper

In the paper a nominal type whose constructors carry function-typed payloads is parameterised by
lambda-set variables: `PStep x a` is `PStep[l₁..l₄] x a`. Construction `Cerr r c t` unifies `t`'s
set with `l₃`; matching `Cerr _ _ t` binds `t` at `l₃`; unifying two `PStep` types unifies the set
parameters; promote/internalize (`plans/lss-promote-quantified-set-variables.md` §1, paper 146:11
§4.2.2) treat them like any other set variable. Nothing is ever "re-tied by hand" because the
variable is part of the type.

Eco's store has no such parameter. `Vars.App1 home name args` (`Compiler/Type/Vars.elm:177`)
carries TYPE ARGUMENTS only. Consequences, each measured in the container plan:

  - An arrow in a type argument (`Maybe (a -> b)`, `List (Int -> Int)`) already flows — the
    `FunL` slot is inside the argument (E11 in the §10.3 edge map).
  - An arrow written in the CONSTRUCTOR DEFINITION (`Cerr Row Col (Row -> Col -> x)`) has no slot
    anywhere in the scrutinee's type. A destructure reaches it by re-instantiating the definition
    storelessly (`Translate.computeCustomFieldType` → `instantiateUnionType` →
    `Zonk.canTypeToMonoWithI`), which is ⊤ by construction — `classifyAs tkClassDestr`, the
    `top@clsDestr` class, 309 positions, unchanged through the whole F-series.
  - F3-a (`LsRow`, `settleRowRefs`) and Fix B (`settleCtorRows`) approximate the missing parameter
    by a PROGRAM-WIDE union per `(ctor, payload path)`. That is the paper's global-store solution
    reassembled after the fact, context-insensitive by construction, and one var contributor
    voids the row (AR-D2): `rowDefer|why` (2026-09-16) — Cerr/Eerr rows blocked by 8-11 var
    contributors out of 300+.
  - Records, tuples and lists are STRUCTURAL (`Record1`, `Tuple1`, `App1 "List"` with the element
    as an argument), so their arrows already have slots. The change is confined to nominal types.

## 2. Population (corpus census, 2026-09-17)

Script: `$SP/fnpayload.py` over `compiler/src`, the package cache, `eco-kernel-cpp/src`. A
custom type counts if any constructor payload mentions `->` (alias bodies not expanded — see §3.1
for the walk that must expand them).

| type | ctors : arrow occurrences | where |
|---|---|---|
| `FailureToReport` | 1 : 5 | `Compiler.Reporting.Error.Json` |
| `Tracker` (Typed) / `Tracker` (Erased) | 1 : 4 / 1 : 3 | `Compiler.LocalOpt.*.Names` |
| `PStep` | `Cerr` 2, `Eerr` 2 | `Compiler.Parse.Primitives` |
| `DocsGoal` | `KeepDocs` 1, `WriteDocs` 1 | `Builder.Build` |
| `Parser` (Terminal), `Chomper`, `Extractor`, `RResult`, `KeyDecoder`, `Decoder` (bytes), `Operator.Infix` (glsl), `Doc.Nesting/Column`, `Normal.LText/LLine` (pretty) | 1-2 : 2 each | various |
| `Key`, `Solver`, `Unify`, `Parser` (Primitives), `Resolution.Decline`, `Decoder` (json), `Level`, `StateT`, `Parser` (Cheapskate), `Time.Every`, `Parser.Advanced`, `Random.Generator`, `Url.Parser`, `QueryParser` | 1 : 1 each | various |

**28 types, 32 constructors, 50 payload arrow occurrences.** The `rowDefer|why` census gives the
construction volume behind them: `Parser;/a0` 1,036 constructions, `RResult;/a0` 324,
`Tracker;/a0` 144, `Chomper;/a0` 77, `Extractor;/a0` 37, `Infix;/a0/c1` 30. Small, fixed, static —
a per-type table, not a per-value discovery.

## 3. The mechanism

Five parts. Parts 1, 2 and 4 are representation; part 3 is the whole semantic content (two ties,
everything else is ordinary unification); part 5 is bookkeeping.

### 3.1 A static payload-position table per union

For each union `(home, name)` (from `Analysis.lookupUnion gte home name`, `Can.UnionData.alts`),
enumerate the arrow occurrences in its constructors' declared payload types in a FIXED order:
constructor index, then argument index, then pre-order within the argument's `Can.Type`.

  - DESCEND through `TRecord` fields (sorted by name), `TTuple` slots, `TType "List" [e]`'s
    element (structural containers), and `TAlias` bodies with the alias parameters substituted
    (an `IO a` alias in a payload IS an arrow — walk it as `KernelSetFacts.hasFunctionCapable`
    walks alias bodies).
  - DO NOT descend into a `TVar` (it is a type argument; its arrows travel in `args`) nor into a
    nested custom type (`TType` other than List — it gets its own vector when ITS value is loaded;
    this is also what keeps recursive types like `Doc = Nesting (Int -> Doc) | …` finite: a
    vector counts a type's OWN direct occurrences only).
  - A kernel-opaque type (no alternatives) has zero positions. `@unbox` single-constructor
    wrappers enumerate the same way (their one payload).

Yields `payloadArity : Canonical -> Name -> Int` and `payloadPositions : … -> List PayloadPos`
(ctor, argIx, path-within-arg). Lives next to `lookupUnion` in `Analysis`; computed once per
compile (memo on `GlobalTypeEnv`). The `(ctor, path)` grammar is exactly `settleVarCtorRows`'
row key (`r|<ctor>|<path>`) — the row id becomes a slot ordinal.

### 3.2 A slotted application node in the store

Add `AppL Canonical String (List Variable) (List Variable)` to `Vars.FlatType` beside `App1`,
the way `FunL` sits beside `Fun1`. The last list holds one `LambdaSet1` point per payload
position.

  - `Store.loadTypeC`'s `Can.TType` arm (`Store.elm:440`): when `lssOn` and `payloadArity > 0`,
    mint `n` fresh set points (`FlexVar` → reads back UNKNOWN at zonk, as arrow slots do), build
    `AppL`, and PUSH them onto `arrowSlots` so they are signature ordinals like arrows
    (LSS_006 amendment, §8). `payloadArity` reaches the loader through `LoadCtx` (a function
    field, the way `superStatic` does).
  - `Compiler.Type.Unify.unifyStructure`: `(AppL h n a s, AppL h' n' a' s')` → zip-unify args,
    then zip-unify slots (a set-slot unify is the join, LSS_001 total); mixed `App1`/`AppL` arms
    keep the slotted side, exactly the `Fun1`/`FunL` arms at `Unify.elm:741-751`. The front end
    never mints `AppL`, so the new arms are inert there.
  - `Store.poisonGoC` (`Store.elm:2239-2246`): the `App1` arm's `args ++ rest` becomes
    `args ++ slots-as-poison-writes` — every payload slot is `unifySlotWithSetC (Just tkPoison)`
    like a `FunL` slot. LSS_004 then holds for values crossing a kernel boundary inside a
    nominal type (a kernel that BUILDS an Elm constructor with a function payload never runs the
    §3.3 tie; the result-side poison is what makes that sound).
  - `Store.zonkFlatC` (`Store.elm:2839`): the `AppL` arm zonks args and reads each slot through
    `zonkSetSlot` into `MCustom`'s new payload-annotation list (§3.4).
  - `LssInfer`'s walkers and `Store`'s structural traversals that pattern-match `App1`
    (`Store.elm:1667`, `LssInfer.elm` ~958 region) gain the arm; grep `App1` — 34 sites total.

### 3.3 The two syntactic ties

**Construction.** A constructor global's type is `Row -> Col -> (Row -> Col -> x) -> PStep x a`
and is arrow-stamped (`AssignMVarIds.elm:586` rewrites `TOpt.Ctor`'s `canType`). When that type
is loaded for a constructor global — the `c|` mint paths (`Translate.elm:4752/4995`,
`LssInfer`'s `standaloneMember` twin) and `sigSourceTypeFor` — a helper `tieCtorPayloadSlots`
unifies result slot k with the set slot of the parameter arrow at payload position k (walk the
ctor's parameter types with the SAME enumeration as §3.1; both are the constructor's declared
types, so the walk is by construction aligned). After that, every application, partial
application and constructor-as-value (`List.map Cerr`) transports the argument's set into the
payload slot through the existing argument→parameter unification (E8) — no new transport.

**Destructure.** `Translate.computeCustomFieldType ctorName index container`
(`Translate.elm:~8580`) today returns a storeless type. New: overlay the container's payload
annotations onto the instantiated payload type — `instantiateUnionType` walks the payload
`Can.Type` and at each arrow occurrence takes annotation k of the `MCustom` (same enumeration).
Store side: in `specializeDestructor` (the Fix A site, `Translate.elm:~8250`) and the
decision-tree `TypedPath.Index` path (`specializeDtPath`), the bound local's arrow point is
`unifyStep`ped with the scrutinee's `AppL` slot point, so the local's slot IS the payload slot
(a Point, not a copy). `computeUnboxResultType` is the third caller of the projection and gets
the same treatment. `rowifyPayload` and the `LsRow` variant become dead once this lands (§7).

**Cross-item transport is free.** Payload slots are signature ordinals, so `zonkSigGo` writes a
fact per payload position, `applyFacts` instantiates it at the caller, and `rep` ties make a
definition returning `PStep x a` promote its payload set variables — the paper's promotion rule
applied to the new variables with no new code. The `applyFacts` length guard stays consistent
because both sides enumerate through one loader.

### 3.4 `MCustom` carries the sets; the spec key sees them, the layout key does not

`Mono.MCustom Int Canonical Name (List MonoType)` gains a `List LambdaSetAnno` (payload
annotations, empty for zero-arity types). Rules, mirroring `MFunction`'s annotation:

  - `mCustom` (the one smart constructor, `Monomorphized.elm:496`) takes the list; the spec-flavour
    hash (`specHashOf`) and `eqKeyWith True` include it; the layout-flavour hash, `eqKeyLayout`,
    `eqLayout` (`Monomorphized.elm:2139`), `toComparableLayoutKey` and every codegen consumer
    ignore it. No representation invariant moves: like `MFunction`'s annotation it is
    Logical-model metadata (REP_* untouched; MONO_029 structure untouched).
  - Annotation helpers gain an `MCustom` arm: `unionAnno`/`joinBranchTypes`,
    `enrichAnnotations`, `overlayAnnotations`, `deTopAnnos`, `hasTopAnno`, `collectAnnoMembers`,
    `annoCoverage` (payload positions become COUNTED positions — the denominator grows; §6),
    `Monomorphize.posWalk` (a new path segment, `/p<k>`, so census rows name the position),
    `toComparableMonoType`'s spec encoding (pinned by `ComparableKeyEncodingTest`).
  - ~90 pattern sites (`MCustom _ h n args` → add a wildcard): Monomorphized 28, Translate 20,
    Monomorphize 20, MLIR/Intrinsics 6, MapTemplate 3, one each in CafHoist/TypeTable/Types/
    TailRec/LogicalTypes/KernelAbi/Store. Mechanical; the compiler's exhaustiveness check finds
    every one.

**Consequence, by design:** a function over `PStep x a` specializes PER PAYLOAD SET
(annotation-sensitive keying, as for arrows). That is what makes the destructured `t`'s call a
stamped call inside that spec. Cost model: the same shape as `arrowSolverRoots`' +1.27 % out.mlir
(Run 26); bounded by the existing keyed-spec budget (`layoutQual`, `ECO_MONO_LSS_MAX_SPECS`).

### 3.5 Record constructors — accounted for, by the structural machinery

An Elm record constructor is NOT a nominal constructor here. `Canonicalize.Expression` turns
`Env.RecordCtor` into `Can.VarCtor Can.Normal …` (`Expression.elm:1470`), and
`LocalOpt.Typed.Module` synthesises it as an ordinary `TOpt.Define` of
`\f1 f2 -> { f1 = f1, f2 = f2 }` with annotation `f1t -> f2t -> { f1 : f1t, f2 : f2t }`
(`Module.elm:205-240`). So:

  - The result type is a `Record1` — every field arrow already has a `FunL` slot; nothing to add.
  - The parameter→field tie is the LAMBDA BODY: the literal `{ f1 = f1 }` is a record literal of
    locals, which `enrichFromEnv` (translation) and the F4-sig `Record` arm of `LssInfer.walkExpr`
    (`litFacts|record|honest` 1,244 on the corpus) already join into the literal's field slot;
    `walkFunction`'s result join then ties ordinal(param k) and ordinal(field k) by `rep`, so
    callers of `R f` get the field slot = `f`'s slot through promotion.
  - Partial application `R f` is a `p|` PAP member on the result spine (LSS_013); the eventual
    record's field is reached through the promoted signature variable, as above.

This plan therefore does not touch record constructors. It PINS the claim with a fixture
(§7 phase 2: construct via `R f` in one item, read `.f` in another, expect `k1`), because nothing
in the arc has measured record-constructor transport specifically and the synthesised annotation
holds two arrow OCCURRENCES (parameter and field) whose only link is the body join.

## 4. What it closes, and what it does not (from the 2026-09-16 census)

Closes, or is expected to: `top@clsDestr` 309 (E13, all of it — every case is a syntactic
payload arrow: `Parse.Primitives` Cerr/Eerr, `composeL /r/a0` 31, `List.foldl` 32, `toErr` 17,
Combine 21); the Cerr/Eerr/ChomperOk `/r/r/a0` var roots 19 (F3-a `markedVar` rows); the Combine
operator-table var family 60 (`/…/f:{lassoc,nassoc,prefix,postfix}/l/c1` — `Infix` payload arrows
reached through a record of lists: record and list are structural, the ctor payload supplies the
slot); the 118 surviving `top@row`; most of the 33 `part@1` (a known set joined with an unwritten
var that came from a payload). **≈ 500 of 1,446 → ≈ 99.4 %.**

Does NOT close: poison 330 (kernel attribution first — separate item); `clsLet` 108 (E12, store
overlay / tail-def `t|` member); `clsMisc` 40 (accessor specs' own arrow, `Translate.elm:977`);
fold callbacks arriving as bare parameters (`Dict.foldl /a0` 37 etc. — E4/E7 edges, not payloads).

## 5. Traps — design against these before building

  - **Totality of the construction tie (the lssAR false-singleton class, new coat).** A singleton
    read at a destructure devirtualises. If ANY construction path bypasses the tie — a
    constructor reached through a path that does not load its stamped type, a kernel that builds
    the value — a payload slot written by one site reads as the COMPLETE set and the
    `Task.map`-into-identity miscompile (`lss-arrowsolverroots-miscompiles`) recurs. Structural
    answer: the tie lives in the constructor's LOADED TYPE, which every use goes through; kernel
    construction is covered by result-side poison (§3.2). Census before flip: constructor
    applications whose result slots have no writer while the parameter arrow carried a member
    (must be ZERO), and destructure reads by class.
  - **Slot identity across loads.** Arrow slots are memoised per `ArrowId` (`arrowIdentity`,
    LSS_027); a `TType` occurrence has no id, so payload slots start per-load FRESH and rely on
    unification to tie. That is the paper's model (set variables ARE unification variables) and
    every edge that carries the VALUE already unifies its type, but it forgoes the sharing
    `arrowIdentity` bought for arrows. Measure `zc|…|flex` on `/p<k>` positions; if fragmentation
    shows, stamp `TType` occurrences in `AssignMVarIds` the way arrows are (a `TypeIds.AppId`).
    Do NOT reach for solver-root sharing here — Run 26 priced it.
  - **`LssConfig` is AT the 32-field cap.** The flag goes in a sub-record (`lss.payload.slots`).
  - **Keyed-spec growth.** Specs now split by payload set. Record `sites`/out.mlir per arm; the
    budget machinery caps it, but the census must say what the split buys at the destructure
    sites (stamped vs declined) before the default flips.
  - **Coverage denominator.** Payload positions are new counted positions. Quote coverage with
    BOTH denominators across the flip (old positions only, and all), or the number is not
    comparable to Run 27.
  - **Enumeration alignment is load-bearing in three places** (§3.1 table, §3.3 ctor-type walk,
    §3.3 destructure overlay). One walker, exported, pinned by a unit test that round-trips every
    type in the §2 table; a mismatch is a silent mis-pair, which is the LSS_006 "poison on
    count mismatch, never mis-pair" rule — apply the same fail-safe (length mismatch ⇒ ⊤).

## 6. Sequence, arms, gates

**Phase 0 — ceiling census (no representation change).** Extend the shipped `rowDefer|why`
instrument: per row, count contributions by class (known / var / ⊤) AND per DESTRUCTURE the
class the per-value slot would read (= the class of the construction that reaches it, which the
row census cannot see but a per-spec join of `pos|` rows can approximate offline). Deliverable:
predicted `k1`/`kN`/var at each of the 309 + 60 + 19 positions. One census run.

**Phase 0-b — the kernel partial-application member (§11, `stamp.kernelPap`).** Independent of the representation work and sequenced FIRST among the build steps: §10.2 shows 16.8 % of the target population is gated on it, so a Phase 3 A/B run without it prices payload slots 17 points low. Its own A/B is predicted near-zero (§11.5) — that is not a failure signal.

**Phase 1 — representation behind `lss.payload.slots` (default-off).** `AppL`, `MCustom`
annotations, keys, walkers, poison, zonk. Gate: flag-off byte-identical emission (no `AppL` is
ever minted), full `elm-tests`, `ComparableKeyEncodingTest` extended.

**Phase 2 — the two ties.** Unit fixtures (`LssPayloadSlotTest`): construct in one item and
destructure in another (`k1`); through a list and through an IO chain; a recursive `Doc`; an
`@unbox` wrapper; a partially applied constructor; a constructor passed to `List.map`; two
constructions with different lambdas reaching one destructure (`kN`, never `k1`); a kernel-built
value (⊤); the record-constructor pin of §3.5. Each as a flag-off/flag-on differential.

**Phase 3 — measure.** Arrow census both arms (Phase 0's prediction checked by name at the
cells); `benchmarks/call-stats.md` pair (control / treatment) for dispatch, wall, RSS, `sites`,
out.mlir; E2E `--target full` both arms; bootstrap fixed point (Stage 8c) before any flip.

**Phase 4 — retire the approximations.** With the slots default-on, `LsRow`/`settleRowRefs`/
`rowifyPayload` (F3-a) and `settleCtorRows` (Fix B) are subsumed; remove them and re-measure
(`rowDefer|*` counters must read zero first).

## 7. Invariants to amend / add

  - **LSS_006** — ordinals include payload slots, pushed at the `TType` arm in §3.1 order;
    count-mismatch still poisons, never mis-pairs.
  - **NEW LSS_0xx (payload slots)** — under `lss.payload.slots`, `AppL` slot k of a loaded
    `TType home name` is the lambda set of payload position k of that union (§3.1 enumeration);
    tied to the constructor's parameter arrow at construction and to the pattern-bound local's
    arrow at destructure; carried by `MCustom`'s payload annotations in the SPEC key flavour only;
    poisoned with the type at kernel boundaries (LSS_004).
  - **LSS_013** — unchanged: a constructor used as a member VALUE injects on its own result spine;
    payload slots are not spine positions.
  - **LSS_004** — extend the sentence "arrow positions crossing the kernel ABI carry LTop" to
    payload slots.
  - **MONO_029** — untouched (annotations only, structure identical).

## 8. Files (first pass)

`Compiler/Type/Vars.elm` (FlatType), `Compiler/Type/Unify.elm` (2 arms + mixed),
`Compiler/MonoSolver/Store.elm` (loadTypeC TType arm, LoadCtx, poisonGoC, zonkFlatC, traversals),
`Compiler/AST/Monomorphized.elm` (MCustom field, mCustom, keys, ~12 annotation helpers),
`Compiler/MonoSolver/Analysis.elm` (payload table), `Compiler/MonoSolver/Translate.elm`
(ctor tie at the `c|` mints, `computeCustomFieldType`/`instantiateUnionType`,
`specializeDestructor`, `specializeDtPath`, `computeUnboxResultType`),
`Compiler/MonoSolver/LssInfer.elm` (ctor-reference twin, pattern arms, App1 traversals),
`Compiler/MonoSolver/Monomorphize.elm` (posWalk `/p<k>`, report), `Compiler/Eco/Config.elm`
(sub-record flag, hash token), the ~90 mechanical `MCustom` pattern sites, and the census
instrument of Phase 0.

---

## 9. PHASE 0 RUN (2026-09-17) — BUILT, RUN, ANSWERED

**Headline: the mechanism reaches 99.0 % of the ⊤ births it is aimed at, and 79.1 % of those
births would resolve to a SET — but the win is bought entirely by CONTEXT-SENSITIVITY, not by
the payload slot as such. On the same events the program-wide union that F3-a takes today
produces 9 singletons; the per-container-type join produces 2,040. That 227× is the whole case
for the mechanism, and it is also the reason §4's estimate needs the caveat in §9.7.**

### 9.1 What was built (TEMPORARY, reverted the same session)

Two halves of one join, both report + `arrowCensus` gated, deliberately independent of
`flow.rowDefer` so they measure the shipped default arm:

  - **Destructure side — `Translate.payCensus`**, called at `specializeDestructor` between
    `destrBNowCensus` and `rowifyPayload`. For every arrow of the destructure-bound type it emits
    `pcell|use|<ctor>|<path>|h<layoutHash of the SCRUTINEE>|<class it holds today>`, reusing
    `payloadRowPrefix` for the cell and a new `payloadScrutType` (the container type at the
    nearest enclosing payload projection) for the key. An arrow that anchors on no payload emits
    `pcell|noCell|<class>` — that population is the mechanism's blind spot.
  - **Construction side — `pcell|ctor|` rows in `renderLssReport`.** For every CONSTRUCTOR
    registry entry, one row per arrow: `pcell|ctor|<ctor>|<path>|h<layoutHash of the entry's
    RESULT type>|<class>`, the member key riding the `k1:` rows because singleton AGREEMENT, not
    singleton-ness, decides k1 vs kN after the join.

**Why the join brackets the answer.** Grouping constructions by the container's layout key is
strictly finer than the program-wide union `settleVarCtorRows` takes and strictly coarser than a
per-value slot. So a group unanimous on one member is a GUARANTEED per-value singleton (k1 is a
LOWER bound) and a group that is var/⊤ here may still resolve per-value (uncovered is an UPPER
bound).

Build: instrumented tree → `.mlir` with `f8-bench-census` under `ECO_MONO_ENGINE=subst` (5:08) →
`eco-boot-native` (4:08) → census self-compile `ECO_MONO_LSS_REPORT=1
ECO_MONO_LSS_ARROW_CENSUS=1`, shipped defaults (10:02, 14.95 GB). **Analysis-neutral: `var` 593,
`⊤` 820, `part` 33 — identical to the 2026-09-16 baseline to the digit** (`positions` 151,904 →
151,971 and `k1` +63 are the instrument's own source). Source restored to its pre-edit md5 after
the run.

### 9.2 The blind spot is 1.0 %

17,403 destructure arrow events, of which 14,169 uncovered. **139 (0.98 %) anchor on no payload
cell** (117 `top@clsDestr`, 20 `var`, 2 poison); 14,030 do. Whatever else is true, the mechanism
is aimed at essentially the whole destructure ⊤ population — §1's reading of the class is
confirmed, and the `rowDefer|notPayload` 103 of the F3-a era was measuring the same thing.

### 9.3 THE DELIVERABLE — predicted class of the 14,030 uncovered payload-anchored events

| predicted | events | share | meaning |
|---|---:|---:|---|
| **kN** | 9,058 | 64.6 % | covered; honest multi-member set, declined by the singleton stamp |
| **k1** | 2,040 | 14.5 % | covered AND stampable — a guaranteed per-value singleton |
| `var-promote` | 2,640 | 18.8 % | a construction stored a flex PARAMETER: becomes a promoted set variable the caller instantiates (§9.5) |
| `noCtor` | 264 | 1.9 % | no construction shares the scrutinee's layout key — a limit of the METHOD, not of the mechanism (§9.6) |
| `top-kernel` | 21 | 0.15 % | a poisoned contributor; stays ⊤ (F5) |
| `top-chain` | 7 | 0.05 % | contributor is itself a destructure/let ⊤; resolves by fixpoint |

**Covered = k1 + kN = 11,098 = 79.1 % of the uncovered payload-anchored births.**

### 9.4 CONTEXT-SENSITIVITY IS THE WHOLE WIN — the same events under the row approximation

Re-running the identical join with the container key ERASED — which is exactly what
`settleVarCtorRows` does today, one cell per `(ctor, path)` program-wide:

| partition | k1 | kN | var-promote | top |
|---|---:|---:|---:|---:|
| per container type (the mechanism) | **2,040** | 9,058 | 2,640 | 28 |
| program-wide union (F3-a today) | **9** | 4,742 | 9,237 | 42 |

One unknown contributor anywhere in the program voids a cell (AR-D2), so the row form reads 65.8 %
of the population as var; splitting by container type moves almost all of it into real sets. The
partition is coarse-grained proof of the same point: `Decoder|/a0` holds **747 distinct container
keys and ≥1,713 members**, `Parser|/a0` 249 keys / ≥1,032 members (the row census's `n=1036`),
`Cerr|/r/r/a0` 140 keys / ≥177 members. **A program-wide union over a cell that wide can never
name anything; per container type it names a singleton 2,040 times.**

### 9.5 The `var-promote` class is 55 rows — nameable, not statistical

2,640 events trace to just **55 `(ctor entry, payload position)` rows carrying `LVar`** (≈27
distinct constructor specializations): `Eerr` 14+14, `Cerr` 7+7, `Decoder` 3+3, `ChomperOk`
2+2+1+1, `Nothing|/c0/f:sigs` 1. Decoder alone accounts for 2,352 of the 2,640 events from 3
entries. These are the `Eerr s.row s.col toError` shape the `rowDefer|why` census already named:
the stored function is the ENCLOSING definition's parameter. Under payload slots that parameter's
set variable is promoted into the signature and instantiated per caller, so the class is not
"unknown" but "deferred to the caller" — and it is small enough to settle by reading 27 specs
rather than by another census.

### 9.6 kN width, and the honest limit of the method

Distinct members in the per-container-key union, over the 9,058 kN events:

| width | 2 | 3 | 4-8 | 9-32 | 33+ |
|---|---:|---:|---:|---:|---:|
| events | 1,570 | 673 | 1,658 | 2,001 | 3,156 |
| share | 17.3 % | 7.4 % | 18.3 % | 22.1 % | 34.8 % |
| groups | 667 | 185 | 223 | 66 | 602 |

The 34.8 % at width 33+ is where the layout key is still too coarse: under §3.4 keying those
constructions split into several specs, each seeing a narrower set, so the true k1 lies ABOVE
14.5 % and the true kN width below this table. Nothing in this census can say how far — that is
what the Phase 3 A/B measures.

`noCtor` (264 events) is all `Cerr`/`Eerr` at six container keys where no constructor entry
carries that result layout key — the scrutinee is more general than any surviving construction
(pruned or kernel-built). It bounds the METHOD; the mechanism would read those slots directly.

### 9.7 What this does to §4 — and what is still NOT measured

§4 predicted "≈ 500 of 1,446 uncovered positions → ≈ 99.4 %". Phase 0 does not confirm that
number and cannot: **it measures ⊤ BIRTHS at destructures (14,030 events), while the coverage
book counts surviving POSITIONS in the registry (309 `top@clsDestr`) — a ~45:1 ratio, because
one birth flows into many demands and most are absorbed.** What it establishes is the birth-side
rate (79.1 % of births resolve) and the mechanism's reach (99.0 %). Carrying the birth rate to
the position book gives **309 → ~65**, i.e. ≈ 99.21 % rather than §4's 99.4 %, under the
assumption that the 309 are distributed over birth classes like the events are. That assumption
is the one thing Phase 3's A/B must check first.

Also still unmeasured, and now explicitly out of this census's scope:

  - **The decision-tree destructure path.** `payCensus` rides `specializeDestructor`, so it sees
    the `TOpt.Destructor` population only. `specializeDtPath`/`DtIndex` destructures in case
    branches are unmeasured here — and the shipped F3-a mechanism does not reach them either,
    so §3.3's "all three callers of the projection" is a REQUIREMENT this census cannot price.
  - The var-promote class's post-promotion fate (§9.5 — read the 27 specs).

### 9.8 A LIVE IMPRECISION FOUND IN THE SHIPPED MECHANISM

`settleVarCtorRows`' `gkeyOf` and `rowifyPayload`'s row key `r|<ctor>|<path>` name the
constructor by its **unqualified name**, so every same-named constructor in the program shares
one cell. The census makes the size of this visible: the `Parser|/a0` cell merges at least five
distinct `Parser` constructors (`Terminal.Terminal.Internal`, `Compiler.Parse.Primitives`,
`Common.Format.Cheapskate.ParserCombinators`, `elm/parser Parser.Advanced`, `elm/url Url.Parser`)
and `Decoder|/a0` merges `Compiler.Json.Decode` with `elm/bytes Bytes.Decode`. The union only
widens, so F3-a stays SOUND, but its cells are wider than the program justifies and its published
member counts (`Parser;/a0` n=1,036) are sums over unrelated types — the same de-aliasing trap
`lss-analysis-coverage-gate` records for `pos|` rows, in a second place. **The payload-slot
enumeration of §3.1 must key on `(home, name)`, never on the name.** (This census's own per-cell
tables inherit the flaw; its JOIN does not — the layout hash separates the types, so §9.3's
figures are unaffected.)

### 9.9 Artefacts

`build/compiler/build-kernel/bin/p0census-2026-09-17-{summary.txt,pcell-ctor.log.gz,pcell-use.txt,.time}`,
analysers `bin/p0join.py` and `bin/p0detail.py`. Instrument reverted (both modules restored to
their pre-run md5); the census binary is `bin/p0-census`.

### 9.10 Verdict

Phase 0 passes on its own terms: the mechanism reaches the population, and context-sensitivity —
the thing only a per-value slot can give — is worth 227× in singletons over the shipped row
approximation. Two numbers temper it: 64.6 % of the win is multi-member sets (coverage, not
dispatch), and the position-level yield is ≈ 99.2 %, below §4's ≈ 99.4 %. Proceed to Phase 1 with
§3.1 keyed on `(home, name)` and with the decision-tree path added to §3.3's scope.

---

## 10. THE `var-promote` CLASS, SETTLED BY READING (2026-09-17)

§9.5 left 2,640 events (18.8 % of the uncovered payload-anchored births) as "deferred to the
caller, settle by reading 27 specs". Done. **The class is four constructors, and only 11 % of it
is the promotion story §9.5 assumed.**

The 27 specs resolve (from the census `pos|` rows, spec index → qualified global) to:
`Compiler.Parse.Primitives.Eerr` 14, `.Cerr` 7, `elm/bytes Bytes.Decode.Decoder` 3,
`Terminal.Terminal.Chomp.ChomperOk` 2, `Maybe.Nothing` 1.

| subclass | specs | events | share | payload slots + promotion resolve it? |
|---|---:|---:|---:|---|
| `Bytes.Decode.Decoder` | 3 | 2,352 | 89.1 % | **NO — a second, independent fix is required (§10.2)** |
| `Cerr` / `Eerr` | 21 | 288 | 10.9 % | **YES, to a SINGLETON — measured (§10.1)** |
| `ChomperOk`, `Nothing` | 3 | ~35 | 1.3 % | not a payload case at all (§10.3) |

### 10.1 `Cerr`/`Eerr` — promotion works, and the callers are known

Every terminal construction in `Compiler/Parse/Primitives.elm` stores either a PAP of a local
(`Cerr st.row st.col (addContext (tx r c))`, lines 504-552 — already a `p|` member, already
covered) or the enclosing combinator's own parameter: `Eerr s.row s.col toError` at
`oneOfHelp` (line 200), `word1` (579), `word2` (608) and their siblings. `toError` is
`(Row -> Col -> x)` and it is IN THE SIGNATURE — `oneOf : (Row -> Col -> x) -> List (Parser x a)
-> Parser x a` — so it is exactly the paper's promoted lambda-set parameter, instantiated per
call site. The remaining constructions (`Cerr r c t -> Cerr r c t`, the re-wrap at lines 157,
278, 405, 523) are pass-throughs: the destructure reads the scrutinee's slot and the
re-construction writes it to the new value's, a fixpoint that terminates at the terminal
constructions above.

**What the callers supply is already measured.** At `oneOf`'s `toError` parameter the census
reads, over 47 specializations: `k1:g` 45, `k1:p` 1, `var` 1 (spec 6128); `oneOfHelp|/r/a0` is
identical (45/1/1, var spec 6149). Twenty-one modules construct `PStep` through these
combinators and every one passes an error constructor or a named global. **So the promoted
variable instantiates to a SINGLETON at 46 of 47 sites, and the destructured `t` becomes k1 —
covered AND stampable.** This subclass behaves exactly as §3.3 claims.

### 10.2 `Bytes.Decode.Decoder` — 89 % of the class, and payload slots alone do NOT fix it

`type Decoder a = Decoder (Bytes -> Int -> (Int, a))`, and the three var-carrying specs are the
endianness- and length-parameterised readers: `Decoder (Elm.Kernel.Bytes.read_i16 (endianness ==
LE))` and siblings (`read_i32/u16/u32/f32/f64` at `Bytes/Decode.elm:87-137`, `read_bytes n` 148,
`read_string n` 177). The stored value is a **partial application of a KERNEL**.

The reason it is `var` and not `⊤` is exact and checkable: all ten `Bytes.read_*` kernels carry
`TypeFaithful { scope = Inert }` rows (`KernelSetFacts.elm:1013-1083`) and the licences APPLY at
these occurrences (they are absent from this run's `kernel licenses REFUSED` line). A licensed
`Inert` boundary is a deliberate no-op on BOTH sides — `LssInfer.kernelCallBoundaryWith` returns
`WpNone` and `Translate.poisonKernelArrowsThen` passes the var through — so there is no poison
**and no member**. The slot is simply never written.

**And nothing can write it today**, because `Engine.papMemberKey : TOpt.Global -> Int -> String`
keys a PAP by a `TOpt.Global`; a kernel is `TOpt.VarKernel home name`, which that key cannot
name. A BARE kernel reference is fine (`Decoder Elm.Kernel.Bytes.read_i8`, line 80 → a `k|`
member via `standaloneMemberKernel`); it is the partial application that has no key. This is the
"partial applications ✗ — the only known missing producer form" of
[[lss-arrowsolverroots-miscompiles]], located and, for the first time, sized: **2,352 destructure
events, 16.8 % of the whole uncovered payload-anchored population.**

**The fix is small and independent of this plan:** a `p|k|<home>|<name>|<argCount>` key minted
through `Engine.kernelMemberIdFor`, which already takes an arbitrary key string plus the kernel
triple. It is also *insufficient on its own* — without a payload slot the destructure still
re-instantiates storelessly and the member has nowhere to land. **The two fixes multiply: either
alone leaves these 2,352 events uncovered; together they give k1** (and a singleton whitelisted
kernel is exactly what `devirtKernel` already consumes, 1,139 sites this run).

Soundness note for whoever builds it: the member must name the kernel AND the argument count, and
`Inert` is the right licence tier to allow it — an `Inert` row asserts there is no
function-capable position anywhere in the kernel's type, so the PAP's identity is the only
lambda-set fact at that position and a singleton there cannot be falsified by anything the C++
does.

### 10.3 `ChomperOk` and `Nothing` — the cell walker over-reaches

`type ChomperResult x a = ChomperOk Suggest (List Chunk) a` — the projected field is the TYPE
PARAMETER `a`, not a syntactic arrow, so that arrow already has a slot in the container's type
argument and payload slots would change nothing for it. Same for the `Maybe.Nothing` spec at
`/c0/f:sigs` (a record field inside the type argument) and for the small `Ok|/a0` (8 events) and
`RResult|/a0/r/r/c3` (10) groups in §9.3.

This is a property of `payloadRowGo` — **the SHIPPED F3-a anchors on any constructor-field
projection regardless of whether the field's declared type is a type variable** — inherited by
this census. It is sound (the row only widens) but it means §9.2's "the mechanism reaches 99.0 %"
mixes genuine payload arrows with type-argument arrows that are already slotted. The measured
over-reach is small, ~45 of 14,030 events (0.3 %), all of it visible in the var class because
type-argument arrows are usually already covered. **§3.1's enumeration is right to exclude `TVar`
positions**; the corollary is that §3.3's destructure overlay must FALL BACK to today's
projection for those fields rather than expect a slot.

### 10.4 The revised Phase 0 book

| outcome on the 14,030 uncovered payload-anchored births | events | share |
|---|---:|---:|
| covered by payload slots alone (k1 2,040 + kN 9,058 + Cerr/Eerr promote 288) | **11,386** | **81.2 %** |
| covered only WITH a kernel-PAP member (§10.2) | 2,352 | 16.8 % |
| method miss (`noCtor`) / kernel ⊤ / chain | 292 | 2.1 % |
| not a payload case (type-argument arrows, already slotted) | ~35 | 0.3 % |

The headline moves the right way — 79.1 % → **81.2 %** resolvable by this plan alone, because the
Cerr/Eerr promotion is now measured rather than deferred — and it exposes a 16.8 % block that is
gated on a fix belonging to a different plan. **Sequencing consequence: the kernel-PAP member
should ship BEFORE Phase 3's A/B**, or that A/B will price payload slots 17 points low on a
population that is not their fault.

---

## 11. BUILD SPEC — the kernel partial-application member (`stamp.kernelPap`)

§10.2 sized this at 2,352 destructure events, 16.8 % of the uncovered payload-anchored
population, and established that it must ship BEFORE Phase 3's A/B or that A/B prices payload
slots 17 points low. This section is its implementation. **It is independent of Phases 1-4 and
can be built first.**

### 11.1 What is missing, in one line

A member is an interned key string. Every producer form has one — `l|<lambdaId>`,
`g|<qualified global>`, `c|<qualified ctor>`, `k|<home>.<name>`, `a|<field>`,
`p|<qualified global>|<supplied>` — except a partial application of a KERNEL.
`Engine.papMemberKey : TOpt.Global -> Int -> String` needs a module-qualified Elm name, and a
kernel reference is a `TOpt.VarKernel prefix home name`, which has none. A BARE kernel reference
mints fine (`standaloneArgKernelMember` → `k|`); only the partial application has no key, so its
slot is never written.

### 11.2 Producer

**Key — ONE definition** (`papMemberKey`'s docstring records why: five sites mint the global
form and two of them once built the string independently, the LSS_017 drift):

```elm
kernelPapMemberKey : ( Name, Name ) -> Int -> String
kernelPapMemberKey ( home, name ) supplied =
    "p|k|" ++ home ++ "." ++ name ++ "|" ++ String.fromInt supplied
```

Mirrors the existing `k|` key, which also drops the prefix from the STRING while keeping it in
the triple.

**A FOURTH `MemberSource` case — not a reuse of `SourceKernel`:**

```elm
    | SourceKernelPap ( String, String, String ) Int
```

Registering this as `SourceKernel` would be a miscompile, not an imprecision (§11.4).

**Mint** — `kernelPapMemberIdFor : ( String, String, String ) -> Int -> Step Int`, the exact
shape of `papMemberIdFor`: `memberIdFor (kernelPapMemberKey …)`, then register the source iff
absent. Needs an `insertMemberKernelPap` beside `insertMemberKernel` (`Engine.elm:521`).

**Injection site** — the kernel twin of `injectPapMember`. Translation side: in the kernel call
path, after `poisonKernelArrowsThen` has made the licence decision and BEFORE
`Store.zonkToMono funcVar`, the same ordering `unifyResultThenInjectPap` enforces for globals.
Walk to the arrow remaining after `supplied` arguments (`resultVarAfter funcVar supplied`) and
`LssInfer.injectSpineMemberId` the member across that residual spine — LSS_013 unchanged: every
residual arrow within the declared arity holds a further partial application of the SAME kernel.
Inference side: the twin at `LssInfer`'s kernel handling (the `k|` mints at 1436/1509), because
LSS_006's two-sided discipline requires that the sides never disagree about a boundary.

**Arity, and the gate that makes it trustworthy.** Do NOT take arity from
`KernelFacts.devirtOf` — that is the devirt whitelist and covers only whitelisted kernels. Take
it from the arrow-spine length of the kernel's occurrence type, as `devirtDirectTarget` already
does for globals. That type is only meaningful where the type checker actually bounds it: an
unannotated kernel generates `CTrue`, so its "inferred" type is first-usage-wins bookkeeping
(`KernelSetFacts`' `TransportsAs` docstring). **So mint exactly where the licence APPLIED** —
`factFor` returned a `TypeFaithful` row and `licenseApplies` said yes at this occurrence. That is
self-consistent in both directions: where the licence applied, the occurrence type was verified
and the slots were left alone, so a member is both trustworthy and useful; where it did not, the
boundary poisoned and the slots are ⊤, so a member would be absorbed and pointless.

### 11.3 Worked example

```elm
Decoder (Elm.Kernel.Bytes.read_i16 (endianness == LE))     -- Bytes/Decode.elm:87
```

`read_i16 : Bool -> Bytes -> Int -> (Int, Int)`, arity 3, supplied 1, licence
`TypeFaithful { scope = Inert }` and it applies. Key `p|k|Bytes.read_i16|1` interns to some id;
source `SourceKernelPap ( "Elm", "Bytes", "read_i16" ) 1`. The residual `Bytes -> Int -> (Int,
Int)` carries the one-element set on its head and nested result arrows. With §3's payload slots
the `Decoder` value's payload slot is tied to it, and `decode (Decoder decoder) bs` reads a
SINGLETON where it reads nothing today.

### 11.4 Consumers — the safety core

Three consumers read `MemberSource`, and two of them would be WRONG on a kernel PAP:

1. **`Engine.memberClassOf`** must answer `"l"` (the declining class), never `"k"`. Write the arm
   out explicitly with the same "a future reader must not tidy this" comment the `SourcePap` arm
   carries. `membersClass` escalates `gc > k > l`, so a wrong answer here silently promotes every
   mixed fact containing one of these.

2. **`Engine.standaloneMemberKernel`** must answer `Nothing`. With a distinct constructor this is
   automatic — its case matches `SourceKernel k` only — **and that is the main reason for the
   fourth constructor: `devirtKernelTarget` then declines by construction rather than by a guard
   someone has to remember to write.**

   *The miscompile this prevents, concretely.* `devirtKernelTarget m argCount` fetches the triple,
   asks `kernelDevirtArity home name` (3 for `read_i16`) and devirtualizes when
   `arity == argCount`. A residual `Bytes -> Int -> (Int, Int)` OVER-APPLIED with three arguments
   hits `3 == 3` and emits a direct call to `Elm_Kernel_Bytes_read_i16` with the wrong three
   arguments, silently dropping the endianness flag bound at the construction site. Over-application
   is not hypothetical: `arityOver` is 12,378 sites
   ([[abicloning-decline-census-arityover]]). This is exactly the "a direct rewrite of a partial
   application drops its bound arguments" hazard `SourcePap`'s comment records, one table over.

3. **`Monomorphize`'s origin export** dispatches on the two-character key prefix, so `p|k|…` lands
   in the `"p|"` arm, fails to match `SourcePap`, and falls through to "no origin recorded" —
   safe by default, and every downstream consumer without an origin declines. **v1 leaves it
   unrecorded deliberately**; add `Mono.OriginKernelPap` and the three consumer arms
   (`AbiCloning`, `MapTemplate`, `Borrow.LssFacts` — all three already have declining `OriginPap`
   arms) only when a measured consumer wants it.

**One P0 check before building, not an assumption:** whether the LSS_040 `p|` fast stamp
(`papResolve`/`papFast`, [[pap-fast-stamp-plan]]) keys on `SourcePap` or on the `p|` key prefix.
If the prefix, a `p|k|` member is picked up for free and the fix carries a dispatch effect; if
the source, it declines and the fix is completeness-only until taught. Read it, do not guess.

### 11.5 Flag, gates, and the prediction that must be pre-registered

Flag `stamp.kernelPap` inside `LssStampConfig` — `LssConfig` is AT the 32-field cap, so no new
top-level field ([[lss-stage-anchor-writers-planned]]).

Gates:

  - **The over-application pin, and it must exist before the flag ever flips**: a fixture that
    over-applies a kernel partial application and asserts NO devirt and unchanged emission.
  - A producer fixture. NOTE the constraint: kernel references are legal only inside
    kernel-package source, so the fixture must go through a package function that is
    kernel-backed rather than writing `Elm.Kernel.*` in test source.
  - `papInject|kernel` fired count in the census; full `elm-tests`; E2E `--target full`;
    flag-off byte-identity; bootstrap fixed point before a default flip.

**PRE-REGISTERED PREDICTION — do not read a small standalone number as failure.** The 2,352
decoder events need payload slots as well; the two fixes MULTIPLY and neither alone moves them.
What this fix CAN move on its own is kernel partial applications in positions that already have a
slot — an argument to a higher-order function, say — and **that population is unmeasured**. So
the standalone A/B is expected to be small and possibly zero on the coverage book. Measure it,
record it, and do not tune against it; its designed payoff is only visible in combination with
Phase 2.

### 11.6 What this does NOT do

It does not license anything new: the `Inert` rows stay exactly as audited, and the claim they
make ("no function-capable position in this kernel's type") remains true — a partial application
manufactures its function value on the ELM side, by not finishing the call, so nothing extra
crosses the boundary. It does not make a kernel PAP devirtualizable (§11.4 point 2 forbids it).
And it does not touch the `Positional` tier or any poisoned boundary.

---

## 12. BUILD LOG (2026-09-17) — Phases 0-b, 1 and 2 IMPLEMENTED; Phase 1's gate PASSES

### 12.1 What is in the tree

**Phase 0-b — `stamp.kernelPap` (§11).** `MemberSource` gained the fourth case
`SourceKernelPap (prefix, home, name) supplied`; `Engine.kernelPapMemberKey`
(one definition) and `kernelPapMemberIdFor`; `memberClassOf` answers the
DECLINING class for it, written out with the same "do not tidy this" note the
`SourcePap` arm carries; `standaloneMemberKernel` declines it by construction,
so `devirtKernelTarget` cannot act on it. Producer:
`Translate.injectKernelPapMember`, called from `deriveKernelAbiTypeWith` AFTER
`poisonKernelArrowsThen` and BEFORE the zonk, gated on
`kernelLicenceApplies` (mint only where a `TypeFaithful` licence APPLIED, so
the arity read off the occurrence type is the audited one); head-only at the
residual per LSS_013, with `LssInfer.injectKernelPapSuccessorsFrom` filling the
deeper arrows at `p|k|…|<d>`. Config: `lss.stamp.kernelPap`,
`ECO_MONO_LSS_KERNEL_PAP`, hash token `lssKP=`, DEFAULT-OFF. Unit:
`TestLogic.Monomorphize.LssKernelPapTest` (containment pins — see §12.3 for why
they are containment and not transport).

**§11.4's P0 check is ANSWERED, and it settles the prediction.** The LSS_040
fast stamp keys on `Mono.OriginPap` — the recorded ORIGIN, not the key prefix
(`AbiCloning.elm:2659`). A `p|k|` member records no origin (the origin export
dispatches `String.left 2` → the `"p|"` arm → matches `SourcePap` only → falls
through), so `AbiCloning` classifies it `PsNotCandidate "g1absentp"` and
declines. **The fix is completeness-only in v1**, which is the branch §11.4
anticipated. Teaching the stamp would need `Mono.OriginKernelPap` plus a
`papResolve` analogue; not built.

**Phase 1 — the representation.** `Vars.AppL Canonical String (List Variable)
(List Variable)` beside `App1`, with arms in `Unify.unifyStructure` (both
slotted, plus the two MIXED arms keeping the slotted side, exactly as
`Fun1`/`FunL` do), `Occurs`, `Solve` (rank fold, restore, `traverseFlatType`),
`SolverRoots` (×2), `Type` (×3), `Store` (`qSigGo`, `poisonGoC` — payload slots
poison with the type, LSS_004), and `LssInfer` (litFacts List probe,
`joinArrowSets` with a new `joinSlotListPlain`, the flow degrade, the
arrow-mention probe). `Store.loadTypeC`'s `TType` arm mints one slot per
payload position and pushes each onto `arrowSlots`, so they become signature
ordinals (LSS_006, amended). `Analysis.payloadPositionsOf`/`buildPayloadTable`
enumerate them, keyed on `(home, name)` — §9.8's correction, applied.
`Mono.MCustom` gained `(List LambdaSetAnno)`; `mCustom` keeps its shape with
`[]` and `mCustomP` carries the annotations into the SPEC hash only.

**Phase 2 — both ties.** Construction:
`Translate.tieCtorPayloadSlots`, composed into the global-call path as
`instantiateLssTied`, unifies result slot `k` with the set slot of the arrow
payload position `k` names inside its parameter, using new store walkers
(`Store.paramVarAtC`, `Store.slotAtPathC`, `Store.payloadSlotsOf`). Destructure:
`Translate.overlayPayloadAnnos` wraps `computeCustomFieldType` and overlays the
scrutinee's payload sets onto the projected payload type, PRECISION-MONOTONE
(only a set/row/partial overwrites, so a ⊤ or unwritten payload leaves today's
answer rather than trading a ⊤ for a var). Round trips both ways:
`Store.zonkPayloadSlotsC`/`attachPayloadAnnos` read slots onto the MonoType,
`payloadSlotsFromAnnosS` rebuilds slots from annotations (sharing `varSlots`
for `LVar`, fresh flex for `LPartial` — the store keeps COMPLETE semantics).
Census: `posWalk` emits payload positions as `/p<k>`, deliberately NOT counted
by `Mono.annoCoverage` so every coverage figure stays comparable with runs
before the flag. Config: `lss.flow.payloadSlots` (it rides `flow` because
`LssConfig` is AT the 32-field cap — §5), `ECO_MONO_LSS_PAYLOAD_SLOTS`,
`lssPS=`, DEFAULT-OFF.

### 12.2 PHASE 1'S GATE PASSES

The compiler's own source grew, so the self-compile cannot be the subject of a
byte-identity test. Gate run on 61 FIXED external programs (the 60 largest E2E
tests + `PapStampTest`), each compiled from `/work/test/elm` by the pre-change
binary and by the payload-slots binary with every new flag OFF:

```
IDENT: tried=61 same=61 differ=0 fail=0
```

**61/61 byte-identical.** `AppL` is never minted flag-off, `MCustom` carries
`[]`, both ties return immediately, and the kernel-PAP member is not minted —
so the whole change is provably inert until a flag turns it on.

*Method note for whoever repeats this:* the E2E programs must be compiled from
the `test/elm` project (its own `elm.json` carries `elm/html` etc.) and WITHOUT
`--kernel-package eco/compiler`. Running them from `build-kernel` fails 59 of 61
with `MODULE NOT FOUND`, which looks like a regression and is not one.

*Tooling note:* an existing lowered binary compiling the CURRENT tree is a
~2-minute full type-check with a complete error list — far faster than a build
cycle, and it is what turned the 109-site `MCustom` edit into three iterations.
The edit itself is safe in a way the 2026-09-16 deletion was not: a wrong arity
is a compile error, never silent breakage.

### 12.3 Why the kernel-PAP unit tests are CONTAINMENT pins

`Translate.injectKernelPapMember` fires only for an INLINE kernel call — a real
`TOpt.VarKernel` callee. The mock unit env cannot build one: it synthesizes
kernel nodes for eta-free ALIASES only (`TestPipeline.aliasedKernels`, whose
docstring forbids naming anything that is not really an alias in package
source), so `List.cons inc` there is a partial application of the GLOBAL
`List.cons`, which `injectPapMember` has always covered. A fixture that reached
the inline path would have to synthesize a node shape production never builds.
So transport is gated behaviourally on the corpus (`papInject|kernel`, the
`Bytes.Decode` specs' class) and the unit file pins the half that would be a
MISCOMPILE if wrong: the key, its routing to the declining arm of the origin
export, and `memberClassOf`'s answer, with a control that a real kernel
REFERENCE still answers the kernel class.

### 12.4 MEASURED (2026-09-17) — the ties WORK, and three totality gaps found by measuring

**Probe programs** (`test/elm/src/PayloadSlotProbe.elm`, `PayloadPerfProbe.elm`), compiled
flag-off vs flag-on. The first declares a MULTI-constructor type with a function payload
(`Carry Int (Int -> x)` — the `PStep` shape); the second exercises `Bytes.Decode.Decoder`, a
single-constructor wrapper, which is what the real corpus is made of.

**THE MECHANISM WORKS on the `Ctor` path.** Flag-on, the probe reports
`payloadTie|ctor 4`, `payloadTie|destr 1`, and the decisive census row is

```
pos|Carry|/r/r/p0|k1:g;author/project:PayloadSlotProbe.bump|9
```

— payload position 0 of the constructor's RESULT type carrying a SINGLETON that names the
function stored in it. That is the paper's `PStep[l] x a`, populated, in Eco's store. Nothing
before this plan could put a member there at all.

**Gap 1 — the fast call paths (FOUND AND FIXED).** `translateGlobalCall` chooses between a
cached-scheme fast path (M2a), a ground-memo path (M2b) and the slow path, and only the slow
path mints store structure. The tie was written against the slow path, so it never fired for
any constructor whose call qualified as fast. Fixed by `needsPayloadSlow`, added to the same
guard `needsPapSlow` already uses for exactly this hazard — and its docstring already said why:
"the fast paths never mint store structure, so there is no slot to inject into: the injection
would silently never fire on its motivating case."

Routing to the slow path is also what keeps the tie SOUND, not merely effective: the fast
path's scheme is CACHED per `(global, funcCanType)`, so two constructions of one constructor at
one type share a `funcMonoType`, and writing a payload set into it would mix two sites' members
into one annotation — a false singleton by another door.

**Gap 2 — `TOpt.Box` (FOUND AND FIXED).** A single-constructor single-field type is a `Box`
node, not a `Ctor`, and `ctorPayloadPlan` matched `Ctor` only. `settleCtorRows`' `isCtorGlobal`
has always tested both; this now does too, and `computeUnboxResultType` gained the destructure
overlay (a box unwraps through it, never through `computeCustomFieldType`).

**Gap 3 — box CONSTRUCTIONS never reach either tie. NOT FIXED; this is the next task.**
Measured: with both fixes above in place, `Bytes.Decode` still reports `payloadTie` ZERO, and
its payload slots are minted but unwritten —

```
pos|Decoder|/r/p0|var@18.0|18      pos|Decoder|/r/p1|var@18.1|18
```

while the payload ARGUMENT of the same spec carries a known member (`/a0` reads `k1:l`). The
information is one unification away and nothing connects it.

Cause: a box constructor is referenced as `TOpt.VarBox`, and the call dispatcher in
`translateCall` has arms for `VarGlobal`, `VarKernel`, `VarDebug` and the two local forms only —
so `Decoder f` falls to `translateIndirectCall`, which has no `funcVar` to tie. **This matters
out of proportion to its size: most of the §2 population are single-constructor wrappers
(`Decoder`, `Parser`, `Tracker`, `RResult`, `Chomper`, `StateT`, `Extractor`, `KeyDecoder`), so
the mechanism currently reaches the MINORITY of its targets.**

The fix is a design choice, not a patch, and should be made deliberately: either give the
dispatcher a `VarBox` arm routing to `translateGlobalCall` (flag-gated — it changes box calls
from indirect to direct, which is a real emission change and possibly a win in its own right),
or tie inside `translateIndirectCall` when the callee is a payload-bearing `VarBox`. Decide with
a measurement of how many box constructions exist, not by preference.

### 12.5 The self-compile cost is REAL and UNDIAGNOSED

The flag-on self-compile ran **over 60 minutes against a 10-minute baseline** and was stopped
without reaching its census (CPU advancing 1:1 the whole time at 99.9 % of a core, RSS flat at
11 GB — computing, not stalled or leaking). Flag-off is unaffected (§12.2), so this is the
flag's own cost.

Two candidates, neither confirmed:

  - **Signature triviality.** Payload slots are pushed onto `arrowSlots` to become signature
    ordinals (§3.2, which is what buys cross-item transport). `loadTypeC`'s own comment warns
    that a longer ordinal array makes `LssSignature.trivial` go false more often and to "expect
    a small COMPILE-TIME cost". The baseline is 9,065 trivial of 10,395, i.e. 87 % of call sites
    take a short-circuit today, and the payload-bearing types are pervasive in this compiler.
  - **Spec growth** from payload sets entering the key (§3.4). A flat heap argues against it.

Ruled OUT by measurement: the per-load table lookup. It builds a qualified string at every
`Can.TType` load, which sounds alarming and is worth perhaps 15 seconds across a self-compile,
not 50 minutes. A bare-name pre-filter was added anyway (`payloadNames`), because the cost is
pure waste — 28 types corpus-wide have positions.

**Do not flip this flag on anything large until the cost is attributed.** The cheap next
measurement is the `signatures:` line on a mid-size program that uses the payload-bearing types,
flag-off vs flag-on; if the trivial rate collapses, the design question is whether cross-item
transport is worth paying for at every signature, or whether payload slots should stay OUT of
the ordinal array and rely on within-item unification plus the spec key.

### 12.6 State of the phases

| phase | state |
|---|---|
| 0 census | DONE (§9) |
| 0-b kernel-PAP member | BUILT, MEASURED (§12.1); coverage-flat as pre-registered, 9 mints, 2 positions ⊤→part |
| 1 representation | BUILT; **gate PASSES 61/61 byte-identical flag-off**, re-verified on the final binary |
| 2 the two ties | BUILT and WORKING on the `Ctor` path (singleton in the payload slot, proven); **blocked on gap 3 for `Box` types** |
| 3 measurement | self-compile unaffordable until §12.5 is attributed; probe-level measurement done |
| 4 retire F3-a | not started (correctly — it needs Phase 3 first) |

---

## 13. THE COST (2026-09-17) — three attributions, two fixes, and a verdict on the fourth

Phase 3 could not be run: the flag-on self-compile does not finish in a usable time. This section
is the attribution work, because the *sequence of wrong guesses* is the reusable part.

**Baseline for every comparison:** self-compile with `ECO_MONO_LSS_REPORT=1`, ~8-10 min. The
census is UNCHANGED from the 27 runs before it and is on BOTH sides, so it cancels; the heavier
per-position log was dropped entirely and the flag-on runs stayed slow. **The cost is the
mechanism, not the measurement.**

| attribution | tested by | verdict |
|---|---|---|
| the per-load table lookup | estimated | ~15 s across a self-compile. Not it. Pre-filtered anyway (`payloadNames`) — pure waste either way |
| signature triviality | `signatures:` on a payload-using probe | UNCHANGED (12 of 13 trivial both arms). **Not it** — and this was my stated leading hypothesis, wrongly |
| spec fragmentation from `var` ids in the key | probe spec count | REAL and FIXED (§12.6): an unwritten payload slot zonks to `LVar <id>`, ids are canonical only within ONE entry's zonk, and letting one into `mCustomP`'s hash made identical types key differently. Worth 2 specs of 46 on a probe; not the dominant cost |
| eager slot minting | `sets zonked` on a probe | REAL and FIXED: 187 → 327 (+75 %) eager, → 209 (+12 %) lazy. Creating slots ONLY where a construction writes one, and letting unification spread them, removed 84 % of the overhead |
| per-occurrence memoisation | probe + self-compile | NULL. Sharing a vector between repeated mentions does not reduce how many must be ZONKED. Built, measured, superseded by lazy minting — keep the negative result |
| **the fast-path diversion** | self-compile, §12.8 | **REAL and the last big one.** `needsPayloadSlow` routed every payload-bearing constructor call off the memoised fast path so the store-level tie could fire. In THIS compiler the parser and result constructors are the hottest code there is. Removing it (fast path carries payload sets itself, per site, at the MonoType level) took the run from >60 min with no census to ~30 min and still counting |

### 13.1 The verdict, and it is not close

Pre-registered criterion: within ~15 % of baseline, i.e. ~11 min. **Measured: past 30 min with no
census. FAILS.** Better than the >60 min of every earlier variant, so the attributions above are
real, but not usable.

**And the payoff does not justify pursuing it further.** The 309 `top@clsDestr` positions are
COLD — `plans/lss-container-payload-transport.md` §12.9.2 measured it: the parser's error
continuation runs once per parse FAILURE, and that plan says in terms "this is a completeness
fix, not a dispatch fix". So the trade on offer is coverage 99.05 % → ~99.4 % against the
completeness gate, paid for in minutes of every compile. That is a bad trade at 2x and would
still be a bad trade at 1.5x.

### 13.2 A general-purpose compiler cannot whitelist types (user, 2026-09-17)

An earlier draft of this section proposed an opt-in per-type allowlist so the hot parser types
kept their fast path. **That is rejected and the reasoning was wrong.** `KernelSetFacts` is not a
precedent: kernels are a CLOSED set that ships with the compiler, so auditing them by name is
auditing our own code. User types are open-ended, and a table naming `Parser`/`Decoder`/`RResult`
would be tuning the compiler to ONE program — which happens to be itself, the most seductive
form of the mistake. Any other codebase would get worse analysis for no stated reason.

The legitimate shape of a restriction, if one is ever wanted, is a COMPUTED property that applies
to any program — e.g. give a payload position a slot only if that position is destructured
somewhere, since a payload nobody matches out can never pay. (Suspected inert here: this compiler
destructures exactly the hot ones.)

### 13.3 What is true regardless

The mechanism WORKS and is proven, at probe scale, on both constructor shapes:
`pos|Carry|/r/r/p0|k1:g;…bump` and `pos|Decoder|/r/p0|k1:l;…` — a payload position carrying a
singleton that names the function stored in it, which was not representable at all before this
plan. Flag-off is byte-identical 61/61 on fixed external programs, re-verified after every change
including the ones touching default-path functions. All of it is DEFAULT-OFF, so nothing is at
risk.

---

## 14. SHELVED — the negative result (2026-09-17, user decision)

**This plan is CLOSED as not worth shipping. The implementation is reverted; this document is
what remains.** Read §14 before re-opening the direction: it is the whole result.

### 14.1 The mechanism works. That is not the problem.

Payload set slots were BUILT end to end — `Vars.AppL`, a static payload-position table per union,
both ties, payload annotations on `Mono.MCustom` in the spec key — and they do exactly what §1
says the paper does. Proven on probes, on both constructor shapes:

```
pos|Carry|/r/r/p0|k1:g;…PayloadSlotProbe.bump     (a multi-ctor type)
pos|Decoder|/r/p0|k1:l;…                          (a single-ctor wrapper)
```

A constructor payload position carrying a SINGLETON that names the function stored in it. Before
this plan that was not representable at all — the position was ⊤ by construction, because
`Vars.App1` carries type ARGUMENTS only and an arrow written in a constructor DECLARATION has
nowhere to live. Flag-off was byte-identical 61/61 on fixed external programs, re-verified after
every change including ones touching default-path functions.

### 14.2 It is too slow, and the cost is the mechanism

Pre-registered criterion: flag-on self-compile within ~15 % of the 8-10 min baseline (~11 min).
**Final build: killed at ~55 min with no census.** Earlier variants: >60 min, three times.

The measurement is NOT the cause and this was checked, not assumed: the `coverage:` census is
unchanged from the 27 runs before it, is on BOTH arms so it cancels, and the heavier per-position
log was removed entirely with no effect. §13 has the six attributions; four were real, two of
those were my own errors (the fast-path diversion, and letting zonk-local `var` ids into the spec
key), and fixing everything found still left ~5x.

### 14.3 Why it was not worth pushing further — the payoff, not the cost

**The target positions are COLD.** `plans/lss-container-payload-transport.md` §12.9.2 measured it
and says so in terms: the parser's error continuation runs once per parse FAILURE — "a
completeness fix, not a dispatch fix". So the trade was coverage 99.05 % → ~99.4 % against the
completeness gate, paid in minutes of EVERY compile. Bad at 5x, and it would still have been bad
at 1.5x. **A cheaper implementation would not have changed the recommendation** — which is the
part to remember if this is ever re-opened.

### 14.4 The constraint that closes the obvious escape hatch

An earlier draft proposed an opt-in per-type allowlist so hot parser types kept their fast path.
**Rejected by the user, and the reasoning behind it was wrong.** `KernelSetFacts` is not a
precedent: kernels are a CLOSED set shipping with the compiler, so auditing them by name audits
our own code. User types are open-ended. A table naming `Parser`/`Decoder`/`RResult` tunes the
compiler to ONE program — which happens to be itself, the most seductive form of the mistake —
and every other codebase gets worse analysis for no stated reason. **This is a general-purpose
compiler, not one that targets its own compilation.**

If a restriction is ever wanted it must be a COMPUTED property holding for any program (e.g.
slot a payload position only if it is destructured somewhere). Suspected inert here: this
compiler destructures exactly the hot ones.

### 14.5 If anyone re-opens this

  1. **Do not re-derive §13.** Six attributions, four real; per-occurrence memoisation is a
     measured NULL (sharing vectors does not reduce what must be ZONKED); lazy minting at the
     construction is the right shape and cut overhead 75 % → 12 % on a probe.
  2. **Re-check the payoff first.** The cost work is only worth restarting if the target class has
     become HOT, or if coverage on cold paths has acquired a value it did not have here.
  3. **Three totality gaps cost three build cycles to find** and would be found again: the
     memoised fast call paths mint no store structure; a single-ctor wrapper is `TOpt.Box`, not
     `TOpt.Ctor`; and a box CONSTRUCTION reaches the tie through neither the call dispatcher nor
     one load — the constructor's type is loaded TWICE and only the `classifyRef` load becomes the
     spec's stored type.
  4. **The tooling stands on its own:** an existing lowered binary compiling the CURRENT tree is a
     ~2 min full type-check with a complete error list, far cheaper than a build cycle.

### 14.6 What was kept

Nothing from this plan ships. Independently valid and recorded elsewhere: §9's Phase 0 census
(the residue is 92 % `var`, concentrated, and the row approximation's context-insensitivity
costs 227× in singletons), §10's settlement of the `var-promote` class by reading, and §11's
kernel partial-application member (`stamp.kernelPap`, built and measured coverage-flat exactly as
pre-registered — its own plan section, independent of payload slots).
