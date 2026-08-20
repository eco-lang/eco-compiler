# LSS Fidelity 2 — Standalone Element Identity (GAP-1): Ground `g|`/`c|` Members by Demanded Type at Zonk

**Status: COMPLETE — DEFAULT-ON (2026-08-19).** G1→G3 all landed in one pass;
results in §9 at the bottom. LSS_019 claimed; LSS_003/LSS_013 amended.
Second of three plans implementing the gap register of
`design_docs/auto-borrow-inference/lss-paper-fidelity-mapping.md`. Covers **GAP-1**
(fidelity: HIGH): standalone set elements are family names — `g|`/`c|` members name a
*source global*, one id over many SpecIds, where the paper's post-substitution
elements name *specialized entities* (μ-aware substitution, Fig. 10, 146:15). `l|`
members are already faithful (Fix B / LSS_017); this plan brings `g|`/`c|` to the same
standard.

Prerequisite: `lss-fidelity-1-watchdogs-budget-accounting.md` landed (the watchdogs
are the safety net for any change that moves keyed fan-out; the fidelity census
sub-record created there receives this plan's counters).

Aims served: 3 directly (element identity = the central fidelity axis, mapping doc
§5); 1 indirectly (typed elements retire per-consumer resolution machinery — mapping
doc GAP-1 consequence list).

References verified at HEAD 2026-08-17; anchor by function name if lines drift.

---

## 1. The design, from the mapping doc's own repair direction

Mapping doc §5: *"keep the element symbolic until the instantiation exists, then
ground it. In store terms: standalone slot entries stay symbolic during solving and
ground to `g|G|<typeKey>` at zonk, where the arrow's demanded type is sitting in the
very slot being read — the qualifier is the type (= the instantiation, = what picks
the SpecId), not the SpecId itself, so the mint-before-resolve circularity dissolves,
and both the inference-phase and translation-phase mints ground identically."*

Key realization that makes this a **small** change: the existing interned id
`g|<global>` *is already the symbolic entry*. It is an opaque int whose meaning lives
in `LssMemberTable.sources` (`Engine.elm:146-165`) — exactly "(Global)" with no
instantiation. So:

- **No mint-site changes.** `LssInfer.standaloneMemberWith` (:985-1001), the
  `walkExpr` var arms (:657-699), and `Translate.standaloneArgMember` /
  `injectArgLambdaMember` (:3073-3125) keep minting today's ids. These ids are
  hereafter called **provisional**.
- **No store-representation changes.** Slots stay `LsMembers (List Int)` /
  `LsTop` (LSS_007 untouched); merge stays total int-set union; μ stays
  unrepresentable. The founding id-only decision (design doc §0) is preserved.
- **The whole feature is a zonk-time refinement**: when a set slot is read back at an
  arrow whose type is concrete, each provisional `g|`/`c|` member is rewritten to a
  **ground** member `g|<global>|<arrowTypeKey>` — one id per (global ×
  instantiation-layout), interned in the same table with the same `SourceGlobal`
  reverse entry so every existing consumer resolves it unchanged.
- **Signatures stay symbolic through the pre-spec phase for free**: `zonkSigGo`
  (`LssInfer.elm:531-581`) reads slot content directly (not via `zonkSetSlot`), so
  signature facts keep provisional ids; `applyFactsGo` injects them into caller
  instantiations, and they ground at the *caller's* zonk against the caller's
  concrete arrow — which is precisely the paper's staging ("what the paper defers,
  Eco loses" — no longer). This dissolves the phase asymmetry of mapping doc §4
  point 2 without touching the inference layer.

Element denotation after this plan (mapping doc §5 table):

| namespace | identity carried | paper-faithful? |
|---|---|---|
| `l|` (Fix B) | source lambda × minting SpecId | YES (unchanged) |
| `g|`/`c|` ground | source global × demanded arrow layout | **YES** — the type IS the instantiation; it is what picks the SpecId |
| `g|`/`c|` provisional | source global only | survives only where the instantiation never became concrete — sound, equals today |
| `k|`, `a|` | unchanged | out of scope (GAP-4 owns kernels; accessors are correctly a family) |

## 2. Data-shape changes

### 2.1 `LssMemberTable` (`Engine.elm:162-165`)

After plan 1's additions the table has 4 fields; this plan adds one (5 — ordinary
record, fine):

```elm
, provisionalStandalone : Dict Int TOpt.Global
  -- ids minted by standaloneMemberIdFor with a "g|"/"c|" key (NOT kernel-alias-folded,
  -- NOT ground). Written at the same intern site; the zonk rewrite consults this to
  -- decide "rewrite" vs "pass through". Ground ids are NEVER in this dict — that is
  -- what makes grounding idempotent.
```

Write site: `Engine.standaloneMemberIdFor` (:685-696) — on the fresh-intern branch,
insert into both `sources` (as today) and `provisionalStandalone`. Kernel-alias folds
mint via `kernelMemberIdFor` and never enter it. Ground ids are interned via a new
`Engine.groundStandaloneMemberIdFor` (below) which writes `sources` only.

### 2.2 `ZonkCtx` (`Store.elm:1073-1079`)

The rewrite runs inside `zonkSetSlot`, which today threads a `ZonkCtx` with no access
to the member table. Add:

```elm
, memberTable : Engine.LssMemberTable   -- carried in from S, written back once
, nextMemberId : Int                    -- ditto (interning may allocate)
, grounding : GroundAcc                 -- census: grounded / deferred counts
```

`zonkToMono` (:1120-1149) seeds them from `S` and writes them back in the single
write-back (alongside `store`/`next`/`intern`). NOTE an import-cycle check:
`Store.elm` already imports `Engine` — `Engine.LssMemberTable` is reachable. The
intern helper must be callable from Store without a Step: give Engine a pure
`internMemberKey : String -> LssMemberTable -> Int -> ( Int, LssMemberTable, Int )`
(key → (id, table', nextId')) and re-express `memberIdFor` over it, so Store and
Engine share one interning code path.

### 2.3 `MemberSource` — unchanged

Ground ids get a `SourceGlobal g` entry, so `standaloneMemberGlobal`
(`Engine.elm:702-712`), the E9/E9.1 devirt (`Translate.devirtDirectTarget`,
:2026-2076), and `buildMemberOrigins` (`MonoSolver/Monomorphize.elm:1062-1099`,
prefix-dispatches on `String.left 2`, payload from `sources`) all resolve ground ids
with **zero changes**. The ground key format `g|<comparableGlobal>|<typeKey>` keeps
the 2-char prefix contract.

## 3. The zonk rewrite

### 3.1 Signature change

`zonkSetSlot` (`Store.elm:1354-1399`) currently receives only the slot var. Its one
call site is `zonkFlatC`'s `FunL` arm (:1287-1302), where the arrow's param and
result MonoTypes `ma`/`mb` are already in hand. Change to:

```elm
zonkSetSlot : Mono.MonoType -> Mono.MonoType -> IO.Variable -> ZonkCtx -> ( Mono.LambdaSetAnno, ZonkCtx )
zonkSetSlot paramT resultT setVar c0 = …
```

### 3.2 Rewrite rule (inside the `LsMembers members` branch, before the size-cap check)

```
groundKey = toComparable (widenSets (mFunction LTop [paramT] resultT))
for each mid in members:
  case Dict.get mid c.memberTable.provisionalStandalone of
    Nothing -> keep mid                          -- lambda, kernel, accessor, or already-ground
    Just g  ->
      if arrowIsConcrete then
        mid' = intern ("g|" ++ TOpt.toComparableGlobal g ++ "|" ++ groundKey)
               (+ SourceGlobal g on fresh intern; ctx census .grounded += 1)
        replace mid with mid'
      else
        keep mid                                 -- DEFERRAL: residual-carrying arrow; ctx census .deferredResidual += 1
re-sort + dedup the rewritten list (unionSortedAsc-fold or List.sort >> dedup)
then apply the existing maxSetSize policy to the REWRITTEN list
```

Three load-bearing details:

1. **`arrowIsConcrete`** = `not (Mono.containsAnyMVar paramT || Mono.containsAnyMVar
   resultT)` (`containsAnyMVar` exists — used at `Translate.elm:4741`). Grounding at
   a residual-carrying arrow would embed per-item residual MVar ids in the key —
   unstable across items → the same value would get different ids in different specs
   → spurious 2-sets. Deferral keeps the provisional id: exactly today's semantics,
   sound, and convergent under LSS_010 re-translation (a later round with a more
   concrete demand grounds it then). Do **not** attempt residual normalization in v1;
   record it as the explicit precision frontier (census counts it).
2. **The key is annotation-widened** (`widenSets` before `toComparable`). An arrow's
   own set cannot participate in its members' identity — that is the μ-circularity,
   and widening the key severs it by construction. Use the existing pure
   `Mono.widenSets` (`Monomorphized.elm:860-878`) + `toComparableMonoType`; go
   through `Intern`-consed forms only if the profiler says so (K6 discipline —
   measure first).
3. **Ordering with the size cap**: rewrite first, then cap. Dedup can only shrink the
   list; grounding can only *split* one provisional id into (at most one per arrow —
   grounding happens per-slot, so within one slot a provisional maps to exactly one
   ground id). Net: per-slot size is unchanged or smaller. Cap semantics
   (`widenedBySize`) therefore never regress from grounding alone.

### 3.3 Spine positions ground per-arrow, and that is correct

LSS_013 writes a standalone member on every result-spine arrow (bounded by
`spineDepthForGlobal`, `LssInfer.elm:923-955`). Under this plan each spine arrow
grounds with **its own** arrow key: `add : Int -> Int -> Int` yields
`g|add|<(i,i)->i… full>` at the head and `g|add|<i->i>` at depth 2. This is the
faithful reading — a PAP of `add` *is* `add` one stage in, and its element identity at
that stage is (add × the stage's layout). Consumers resolve both ids to the same
Global through `sources`; nothing keys on "the head id equals the inner id" (verified:
devirt compares member→Global + arity; AbiCloning indexes `l|` instances only; Borrow/
MapTemplate go through `lssMemberOrigins`).

### 3.4 What deliberately does NOT ground

- `k|` kernels — head-only, whitelist-keyed devirt (LSS_016); grounding them buys
  nothing until GAP-4 gives kernels per-param facts (plan 3).
- `a|` accessors — layout-generic by design ("arguably correctly a family", §5).
- `l|` lambdas — already spec-qualified (LSS_017).
- Demand-encoded members: `monoTypeToVarC` (`Store.elm:529-577`) writes annotation
  members back into slots when encoding a demand. Ground ids pass through the rewrite
  untouched (not in `provisionalStandalone`), so zonk∘encode∘zonk is idempotent —
  the stability LSS_010's finite-lattice argument needs. State this in the rewrite's
  doc comment.

## 4. Consumer audit (what changes, what must not)

| consumer | reads | effect of ground ids | action |
|---|---|---|---|
| E9/E9.1/E9.2 devirt (`Translate.elm:2026-2135`) | singleton member → `standaloneMemberGlobal` → arity | resolves via `sources`; unchanged logic. Ground ids make the singleton *more* often true (two globals' families no longer collide… they never did; rather: one global at two layouts no longer shares an id, so a join of different-layout flows now yields a 2-set instead of a false singleton — a **correctness-adjacent precision improvement**; devirt's arity re-derivation stays as belt-and-braces) | none (test coverage below) |
| AbiCloning (`stampCall`, :1035+) | `l|` instances only; `g|` members have no instances → decline | unchanged (unstampable-but-sound, same as today) | none |
| `buildMemberOrigins` (:1062) | key prefix + `sources` | ground keys keep `g|`/`c|` prefixes; payload from `sources` | none |
| Borrow `LssFacts.buildMemberTable` | `lssMemberOrigins` | more ids, each resolving to its Global; per-layout ids UNBLOCK the BORROW_006 "standalone members resolve PUnresolved pending v2" item — a `BorrowSig` can now be keyed per (global × layout) | follow-up, out of scope here; note in `borrow-inference-phase6-v2-backlog.md` |
| MapTemplate G-3 layout matching | origins + site layouts | the layout is now IN the member key — G-3's re-derivation can be cross-checked or simplified | follow-up, plan 3 window |
| Registry joins (LSS_010) | zonked annotations | joins union ground ids; per (G × layout) the id is deterministic → joins stable (see 3.4 idempotence) | convergence test below |
| Census `lamLabels`/report | lambda ids only | untouched | none |

The mapping-doc consequence being retired: "every consumer needing code rather than a
name must re-derive it with type context or decline — `devirtGlobalTarget`'s
annotation-arity re-derivation, MapTemplate's G-3 layout matching,
`unresolved{global=15}`, Borrow's PUnresolved" (GAP-1). This plan makes the id carry
the type context; the per-consumer machinery becomes redundant rather than removed —
removal is follow-up hygiene once the census confirms coverage.

## 5. Flag, config, hash

- `Config.LssConfig` gains `groundStandalones : Bool` (after plan 1: 11 fields),
  default `False` at G1, `True` at G3. JSON `optionalField "groundStandalones"`; env
  `ECO_MONO_LSS_GROUND=1|0` (Builder pattern at `Builder/Eco/Config.elm:1162+`); hash
  token `lssGS=1` when non-default (artifact-affecting under keyed routing: member
  ids → annotations → keyed spec keys → fan-out).
- Flag-off must be **allocation-identical** on the zonk path: gate the whole rewrite
  on `c.lss` being `Just` AND the flag (thread the flag into `ZonkCtx` via the
  existing `lss : Maybe LssZonkAcc` — extend `LssZonkAcc` with
  `groundStandalones : Bool` rather than adding a ctx field).
- Census counters (plan 1's `FidelityStats` sub-record):
  `grounded : Int`, `groundingDeferred : Int`. Report line extension:
  `"grounding: grounded=… deferred=…"`.

## 6. Phasing and gates

**G1 — mechanism behind the flag (default off).**
Tables (2.1), pure intern helper (2.2), zonk rewrite (3), counters. Gates:
- `--target full` E2E green with flag off; **byte-identity** of flag-off artifacts
  (the rewrite is unreachable; `ECO_MONO_LSS=0` additionally unchanged).
- Unit tests (`tests/TestLogic/Monomorphize/LssGroundingTest.elm`):
  - provisional→ground rewrite at a concrete arrow; deferral at a residual arrow;
  - idempotence: encode(ground) → zonk → same ids;
  - spine case: head and inner arrows of a 2-ary global get distinct ground ids,
    both `SourceGlobal`-resolvable;
  - dedup: `{provisional, its-own-ground}` in one slot collapses after rewrite;
  - size-cap ordering (3.2 detail 3).

**G2 — flag on locally: behavior + census.**
- E2E `--target full` with `ECO_MONO_LSS_GROUND=1` (purge `build/test/*/eco-stuff`
  between legs; suites serial).
- Targeted E2E: extend `test/elm/src/CtorDevirtTest.elm` / `ConsDevirtTest.elm`
  patterns with a fixture where ONE global flows at TWO layouts into a shared HOF —
  assert (via `ECO_MONO_LSS_REPORT` or the sites dump) the join is a 2-set, not a
  false singleton; and a same-layout fixture still devirts (`devirtDirect` count
  unchanged).
- LSS_010 convergence: self-compile completes; `joinRounds` within normal band
  (single digits); no `EngineBug`.
- Bootstrap fixed point at flag-on (two-binary/frozen-corpus protocol).
- Census (fast loop first, then native): `grounded`/`deferred` split;
  `sizeHist`/`widenedBySize` movement (expected: slight singleton growth at
  formerly-family-collided arrows); `widenedByBudget` movement (ground ids make keys
  finer — budget pressure may RISE; plan 1's μ-tie and watchdogs are the installed
  guard rails — this interaction is why plan 1 lands first); `devirtDirect`/
  `devirtKernel` non-regression; mono wall delta (rewrite cost is per zonked
  set-slot with a Dict probe per member — expected noise-level; `setsZonked` ≈ 390k
  on self-compile bounds it).

**G3 — default flip.**
Flip `groundStandalones = True` in `defaultLss`; hash token disappears at default;
full battery re-run (E2E, bootstrap fixed point, census archived in this file's
results section). Then file the consumer-hygiene follow-ups (Borrow per-layout sigs;
MapTemplate G-3 cross-check; possible removal of devirt arity re-derivation) as
plan-3-window items.

## 7. Invariants delta

- **LSS_019** (Monomorphization;LambdaSets;implemented): Under `lss.groundStandalones`,
  a provisional standalone member (`g|`/`c|`, recorded in
  `lssMemberTable.provisionalStandalone`) read back from a set slot at an arrow whose
  param/result zonk is residual-free is rewritten at zonk to the ground member
  `g|<global>|<widened-arrow-typeKey>` (interned once, `SourceGlobal`-resolvable;
  annotation-widened key so a set never participates in its own members' identity).
  Residual-carrying arrows keep the provisional id (deferral — equals pre-plan
  semantics). Ground ids are never re-ground (not in `provisionalStandalone`), making
  zonk∘encode∘zonk idempotent — the stability LSS_010's termination argument
  consumes. Element identity for standalones is thereby (global × instantiation
  layout), the id-space image of the paper's μ-aware substitution for `d⟨σ̄⟩`
  occurrences inside sets (mapping doc GAP-1); signature facts stay provisional
  (symbolic) through the pre-spec phase and ground at their consuming
  instantiation's zonk.
- Amend **LSS_003** (member minting): add `Store.zonkSetSlot` grounding (via
  `Engine.internMemberKey`) as the third minting site.
- Amend **LSS_013**: spine arrows ground per-arrow-layout; PAP-stage identity is
  (global × stage layout).

## 8. Risks and rejected alternatives

- **Key instability via residuals** — handled by deferral (3.2.1); the census
  `groundingDeferred` bounds the deferred mass. If it is large, the recorded
  next step is reusing the spec-key normalization machinery
  (`plans/normalize-cecovalue-mvar-speckeys.md`) — NOT ad-hoc renumbering.
- **Budget pressure from finer ids** — real; sequenced after plan 1 deliberately.
  Watch `widenedByBudget` in G2; the F-2A sweep baseline (plan 1 B3) prices any
  budget raise.
- **Rejected: SpecId-qualified re-mint of standalone members** — already examined
  and rejected 2026-08-16 for the mint-before-resolve circularity (mapping doc §5;
  the qualifier naming S₁ while the runtime value is S₂ is the hijack through
  another door). This plan's type-keyed grounding is the recorded faithful
  alternative; do not resurrect the SpecId variant.
- **Rejected: symbolic (Global, Point) entries inside `LambdaSet`** — would put
  store variables in sets, reopening μ and breaking the total-join/no-μ foundation
  (design doc §0). The provisional-int + zonk-rewrite formulation delivers the same
  semantics with zero store-representation change.
- **Mixed provisional/ground sets in one slot** — legal and expected mid-run;
  rewrite+dedup at every zonk keeps annotations canonical; consumers only ever see
  zonked annotations.

---

## 9. Results (2026-08-19, implementation session)

Implemented exactly as specified in §§2–5; all three gates ran to green in one
session. Deviations from the letter of the plan, all recorded here:

- Plan 1's `FidelityStats` sub-record no longer exists (its one-shot counters
  were removed after Run J), so the census counters live in a new 2-field
  `lssStats.grounding : GroundingStats` sub-record (same report line format).
- The rewrite core is the pure `Engine.groundSetMembers` (called from
  `Store.zonkSetSlot` via `groundMembersC`) so the unit tests drive it
  directly; `Engine.internMemberKey` is the shared pure interning path and
  `memberIdFor` is re-expressed over it as §2.2 required.
- Ground keys use the `g|` prefix for `c|` provisionals too (per §3.2's rule);
  verified safe: `buildMemberOrigins`' `g|` arm resolves ctor-backed globals
  to `OriginCtor` via `ctorBackedGlobal`, and the E9 devirt distinguishes
  ctor/fn-global by node shape, never by key prefix.

**G1** (flag off, default): unit tests
`tests/TestLogic/Monomorphize/LssGroundingTest.elm` 9/9 (pure rewrite:
concrete-arrow grounding, residual deferral, idempotence, per-arrow-layout
spine distinctness, dedup, no-growth; pipeline: flag wiring end to end —
1 origin flag-off vs ≥3 flag-on for a two-layout global). E2E `--target full`
1,681/1,681. Byte-identity: pre-change (Run V) binary vs post-change binary,
one frozen corpus, flag off → **byte-identical** (13,557,049 B).

**G2** (flag on via `ECO_MONO_LSS_GROUND=1`, same tree, same binary):

| axis | flag off | flag on |
|---|---|---|
| grounding | 0 / 0 | **grounded=4,955 deferred=11** |
| members interned | 40,374 | 42,738 (+2,364 unique ground ids) |
| sets zonked / singletons / 2-sets | 366,207 / 64,045 / 805 | 366,222 / 64,047 / 805 |
| widened bySize / byKernel / byBudget | 43 / 4,061 / 36,691 | 43 / 4,062 / **36,693** |
| join flush rounds / retranslations | 3 / 590 | **3 / 590** |
| devirtDirect / devirtKernel | 3,984 / 771 | **3,984 / 771** |
| dispatchUpgraded / declinedNoInstance | 3,568 / 1,378 | 3,568 / 1,378 |
| top specs/global | foldl=2,052 … | identical list |
| out.mlir | 13,557,049 B | 13,557,262 B (+213 B) |

The §8 budget-pressure risk is **unrealized on the self-compile**: finer ids
moved `widenedByBudget` by +2 events and spec fan-out not at all. The
deferral frontier is 11 events. E2E flag-on 1,682/1,682 including the new
`test/elm/src/LssGroundStandaloneTest.elm` (one global + one box ctor at two
layouts each through recursion-protected HOFs; LSS_005 answers pinned).
Bootstrap fixed point flag-on: Stage 8c **byte-identical**
(`eco-compiler-boot == eco-compiler-boot-2`, boot .mlirs 13,557,262 B — also
the determinism witness for the accepted +213 B output change).

**G3** (default flipped True): E2E 1,682/1,682; bootstrap 8c byte-identical;
elm-tests 13,126/12 (the same 12 pre-existing POST_010/TYPE_007/golden-
fingerprint failures, untouched by this change). Benchmark: one cold
solver+LSS Stage-7a run recorded in `benchmarks/lss-opt.md` (Run W).

**§4's consumer claims, re-checked against the as-built code (2026-08-19) —
one is WRONG.** §4 asserts that per-layout ids "UNBLOCK the BORROW_006
standalone-members-resolve-`PUnresolved` item". They do not. Both standalone
consumers already resolve a `g|` member's spec by `eqLayout`-matching the
SITE's own type against the registry — `LssFacts.matchGlobal` and
MapTemplate's `resolveSpecFor` — using the member id only to fetch the
`Global`. `PUnresolved` / `declinedSpecUnresolved` therefore fire on an EMPTY
or AMBIGUOUS layout match (≥2 SpecIds of one global at one layout — the
annotation-keyed clones), never on member identity. A ground id adds no
resolving power there because its key is `widenSets`-widened by construction,
so it is isomorphic to the layout `eqLayout` already tests; the layout is not
even exported (`MemberOrigin` carries only the `Global`). What grounding
genuinely buys those consumers is **distinguishability**: honest
singleton-vs-multi determination, and a per-member `meet`/sig table that no
longer collapses two layouts of one global into one callee. Corrected in
`plans/borrow-inference-phase6-v2-backlog.md` item 10; the ambiguity class
needs annotation-sensitive identity and is a separate item.

Follow-ups filed: backlog item 10 (above); MapTemplate G-3 cross-check and
possible removal of the devirt arity re-derivation remain plan-3-window items.
