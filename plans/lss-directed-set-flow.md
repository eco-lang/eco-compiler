# LSS Directed Set Flow — deferred inclusion between set positions (the fired FromArrow re-open)

**Status: IMPLEMENTED (2026-08-20/21, Phases A-E; `lss.sigFlow` stays DEFAULT-OFF per the Phase-E decision — see the execution record). Originally: PLAN (2026-08-20; lowered from the same-day outline to implementation-ready
detail and adversarially verified against HEAD — §0 records where this lowering
SUPERSEDES the outline, and the verification round's corrections are folded in).**
Successor to `plans/lss-fidelity-3-signature-flow-completion.md` §A.2 + Phase D: the
re-open criterion recorded there FIRED — Run X measured the symmetric-pollution cost
at runtime (fast dispatch coverage **8.30% → 6.08%**, −22.6M stamped events,
`sat+fast` identical, wall flat) and that is what keeps `lss.sigFlow` DEFAULT-OFF.
This plan is the recorded path to precision-without-pollution and the flip's
prerequisite.

All code references verified at HEAD 2026-08-20 (post LSS_020/LSS_021).

---

## §0 Deltas from the outline (load-bearing; read first)

1. **No batch resolution pass, no zonk barrier, no item-end ordering.** The outline
   said "resolution pass at item end before ANY zonk" — that conflicts with
   reality: zonks run per-call-site throughout body translation
   (`Store.zonkToMono` sites at Translate.elm 1196/1292/1310/1467/1640/2694/2765/
   3006/3348; `zonkSetSlot`'s "item quiescence" doc is aspirational for shared
   slots). The lowered mechanism is **pull-at-read**: deferred edges live IN the
   slot's content, and every read (`zonkSetSlot`, `zonkSigGo`) resolves the
   reachable edge graph at that moment. No write hooks, no worklist, no barrier.
2. **Temporal soundness is an inheritance, not a new invariant.** For every flip
   site in §5.2 the edge is installed at exactly the program point where the
   symmetric design would have unified, so a target read pulls precisely the
   symmetric class content of that moment: **directed inherits exactly HEAD's
   read-time exposure — no more, no less.** LSS_010's dirty flush covers the
   cross-item registry-join schedules it covers today (Registry `HitChangedJoin`
   → `markDirty`; the devirt rider at Translate.elm:2023-2025) — it is NOT a new
   blanket guarantee for intra-item late growth, which both designs expose
   identically under the same MONO_028 discipline.
3. **No pending-edge side table, therefore no idempotency machinery.** Edges as
   slot CONTENT means: LSS_010 re-translations run on a virgin store after
   `resetItem` (Engine.elm:1443-1445; `freshStore` restarts Point indices —
   Points never cross items); scratch stores are discarded after `zonkSigGo`
   resolves; and the MONO_029 saturation re-pass (same store,
   Monomorphize.elm:715-723) needs no cleanup — pass-2 edges land on families
   that may still carry pass-1 edges, and **idempotency comes from monotone union
   plus pointKey/visited dedupe, not from orphaning** (source lists on shared
   families can grow per saturation pass, bounded by the pass cap; the §9 growth
   valve is the backstop).
4. **Variance is load-bearing.** Symmetric joins are direction-blind; a directed
   walk that recursed argument positions co-variantly would install
   wrong-direction edges and UNDER-approximate — the miscompile class. The
   directed walk flips operands at FunL argument positions (contravariance) and
   DEGRADES TO SYMMETRIC for whole container subtrees (App1/Record1/Tuple1 —
   per-parameter variance unknown; symmetric is the sound over-approximation).
5. **The signature encoding is the paper's promote-or-internalize, literally.**
   `zonkSigGo` resolving an edge graph splits each reachable source into: another
   signature ordinal (→ `fact.sources`, the paper's promoted `ᾱ`) or a
   non-signature slot (→ its resolved members fold into `fact.members`, the
   paper's internalization `S(Q,α)`). Fig. 7's split, at the id level.
6. **No new flag.** Directed REPLACES the symmetric mechanism under `lss.sigFlow`
   (still DEFAULT-OFF; unshipped, so no compatibility surface). Run X archives
   the symmetric arm. LSS_020's "FromArrow deliberately NOT implemented
   (snapshot)" clause is amended — the SNAPSHOT variant stays banned; this plan
   is the deferred variant.

## §1 The problem, precisely

sigFlow's only cross-position fact forms are concrete members and rep links = slot
UNIFICATION (`applyFactsGo`'s `Store.unifyStep repSlot slot`, LssInfer.elm:220).
Unification is an equivalence relation: the true fact at a `chooseHandler`-shaped
def is directed ("params flow into the result"), but the fact language can only
say "params and result share one set" — so at every instantiation the caller's
per-param singletons union into one class. The result becomes honest (the win) and
the params become 2-sets (the pollution); AbiCloning declines their
formerly-stamped dispatches. The pollution is intra-instantiation, so keyed
routing cannot partition it away. Fix: make the result's relation to the params an
INCLUSION, evaluated late enough to be complete. The eager/snapshot version stays
banned: `applyFacts` runs inside `instantiateWithSignature` (LssInfer.elm:129)
strictly before `unifyCallShape`'s arg writes (:1107) — a snapshot read there is
empty and under-approximates.

## §2 Representation — the third `LambdaSet` variant (Phase A)

### 2.1 The type (`System/TypeCheck/IO.elm:663-686`)

```elm
type LambdaSet
    = LsTop
    | LsMembers (List Int)
    | LsFrom (List Int) (List Variable)   -- NEW: members-so-far + DEFERRED in-edge
                                          -- source SLOT Points ("this slot ⊇ each
                                          -- source slot, resolved at read")
```

Invariants (write into the type doc):
- `LsFrom`'s source list is NON-EMPTY by construction (no sketched transition ever
  produces a source-free `LsFrom` — `addSlotSource` only adds, merges carry
  sources through, ⊤ drops the whole variant; there is deliberately NO collapse
  rule to implement); members list ascending/deduped but MAY be empty (unlike
  `LsMembers`).
- Sources deduped by `pointKey` at install; UF unions may later alias them
  (resolution dedupes via its visited set).
- `LsTop` remains terminal and absorbing: any ⊤ write or ⊤ join DROPS sources
  (⊤ ⊇ everything — sound).
- Doc rewrites forced by the variant: IO.elm:645-649 and :663-679 ("no Variables
  inside … total join" — sets now may carry source Points; the join is still
  total), **plus three typechecker-phase comments restating the retired
  Variable-free claim**: Occurs.elm:82-84, Solve.elm:705-707/:1214-1216,
  Type.elm (§2.3 items 11-13). Add `pointKey : Variable -> Int` to IO.elm
  (trivial `\(Pt n) -> n` twin of `Engine.pointKey`) so Unify can dedupe without
  importing MonoSolver (§2.3 item 3's layering wall).

### 2.2 Reachability discipline (flag-off inertness + no-escape)

`LsFrom` is CREATED only by `Store.addSlotSource` and mergers of existing `LsFrom`
content, and **every `addSlotSource` caller is `lss.sigFlow`-gated — including the
kernel-tunnel flip, which selects `flowArrowSets` only when `sigFlow` is on and
keeps today's symmetric `joinArrowSets` otherwise (§5.2 row 4).** This gate is not
optional pedantry: the kernel boundary itself is NOT sigFlow-gated
(`walkCall`'s VarKernel arm and `Translate.joinKernelTunnels` run flag-off under
LSS_021), so without it, the day a `PSFTunnels` row lands, flag-off runs would
mint `LsFrom` — silently falsifying this section and the Phase-A byte gate.
Consequences, each an explicit gate:
- **Flag-off:** no producer runs ⇒ no `LsFrom` exists ⇒ Phase A is byte-inert.
- **Never escapes the store:** `zonkSetSlot`/`zonkSigGo` resolve it;
  `Mono.LambdaSetAnno` stays `LTop | LSet`; `monoTypeToVarC` (Store.elm:529-577)
  never mints it; the registry stores MonoTypes only (Registry.elm:140-188).
- **Never dangles:** §0.3 — content dies with its store.

### 2.3 Consumer edits — the complete list (repo census: 70 hits, 8 files, 0 in tests)

The two sites that do NOT become compile errors are the dangerous ones:

1. **`Store.unifySlotWithSetC` (Store.elm:896-953) — MUST gain an explicit arm**
   (its defensive `_` arm silently reroutes unknown content to `needSlow` →
   `unifySlotWithSetSlow` → `unifyStep` — a behavior change, not a compile
   error):
   ```elm
   IO.Structure (IO.LambdaSet1 (IO.LsFrom cur srcs)) ->
       if top then
           setRootC slot desc IO.lsTopContent { c1 | topJoin = c1.topJoin + 1 }   -- drop srcs: ⊤ absorbs
       else
           case IO.classifySorted members cur of
               IO.SortedEqual -> { c1 | skip = c1.skip + 1 }
               IO.SortedSub   -> { c1 | skip = c1.skip + 1 }
               _ ->
                   setRootC slot desc
                       (IO.Structure (IO.LambdaSet1 (IO.LsFrom (IO.unionSortedAsc members cur) srcs)))
                       { c1 | union = c1.union + 1 }
   ```
2. **`Store.zonkSetSlot` (Store.elm:1359-1424) — the trailing `_ -> LTop` arm
   would silently eat `LsFrom`** (sound but precision-dead). Insert §3.1's arm
   before it.
3. `Unify.elm:751-783` — the nested `case ( ls1, ls2 )` is exhaustive over 2×2 →
   COMPILE ERROR forcing the join arms (total, never mismatches):
   `(LsTop, _) / (_, LsTop)` → keep the ⊤ side (sources dropped);
   `(LsFrom m1 s1, LsFrom m2 s2)` →
   `LsFrom (unionSortedAsc m1 m2) (dedupe by IO.pointKey (s1 ++ s2))`;
   `(LsFrom m s, LsMembers m2)` + mirror → `LsFrom (unionSortedAsc m m2) s`.
   (Class merges MERGE edge lists — the union-hook problem solved by
   representation. Dedupe uses the new `IO.pointKey`, §2.1 — Unify cannot import
   `Engine`.)
4. `Store.unifySlotWithSetSlow` (:965-991) — no edit (defers to `unifyStep` =
   item 3).
5. `Store.poisonGoC` (:1002-1058) — no edit: the `LambdaSet1 _` payload wildcard
   compiles; poison routes through item 1's ⊤ write, which drops sources. Poison
   does not traverse INTO sources — sound: it tops every structural position the
   type walk reaches, and a topped target absorbs regardless of its sources.
6. `Store.zonkFlatC`'s `LambdaSet1 _ -> EngineBug` arm — no edit.
7. `Store.monoTypeToVarC` (:529-577) — no edit (mints only `LsTop`/`LsMembers`).
8. `LssInfer.zonkSigGo` (:604-681) — §3.2 arm; note ALL FIVE existing fact
   constructors (LsTop arm, the three LsMembers branches, FlexVar arm) gain
   `sources = []` (compile-forced).
9. `IO.elm` helpers (`classifySorted`/`unionSortedAsc`/`lsTopContent`) — no edits.
10. Tests: zero representation matches.
11. **`Compiler/Type/Occurs.elm:82-84`** — `LambdaSet1 _ ->` "no child variables".
    MONO-REACHABLE (`Store.unifyStep` → `Unify.unify` → `comparableOccursCheck`,
    Unify.elm:626, and `occursHelp` descends FunL slots). No code change: the
    occurs check deliberately does NOT descend into `LsFrom` sources — sound,
    because inclusion edges are not type structure (no infinite TYPE can arise
    through them; they are set-lattice edges). UPDATE THE COMMENT to say exactly
    that.
12. **`Compiler/Type/Solve.elm:705/1165/1214-1216`** (rank/restore/
    `traverseFlatType` copy arms) — unreachable for `LsFrom`: LSS_007's clause
    "typechecking-phase stores contain neither FunL nor LambdaSet1"
    (invariants.csv:615) plus the verified fact that no MonoSolver module imports
    Type.Solve. Record the argument in the plan-landing commit and refresh the
    "no variables to transform" comment (it becomes conditionally-true).
13. **`Compiler/Type/Type.elm:552/756/969`** (crash arms / getVarNames) —
    unreachable (FunL arms erase the slot before descent + phase separation).
    No code change; note only.

Defensive-arm direction rule (applies to §2.4 and §3.1): a defensive fallback
must fail toward **⊤**, never toward skip/empty — dropping an edge or a source's
contribution under-approximates, which is the miscompile direction. (`needSlow`'s
precedent defers to a SOUND slow path; ours writes/returns ⊤.)

### 2.4 The edge-install primitive (new, Store.elm; export it)

```elm
{-| Install a deferred inclusion "dst ⊇ src" (both FunL SET SLOTS). ⊤ dst
absorbs (skip). Self-edge (UF-equivalent) skips. Total; never fails.
-}
addSlotSource : IO.Variable -> IO.Variable -> Step ()
-- Body pattern (descriptor-preserving, mirrors setRootC Store.elm:956-962 —
-- UF.set replaces the WHOLE descriptor at the root, so always write
-- { desc | content = … }, never a fresh descriptor):
--   liftIO (UF.equivalent src dst) → True: skip
--   ( store1, desc ) = UF.get dst …
--   case desc.content of
--     Structure (LambdaSet1 LsTop)            -> skip
--     FlexVar _                               -> UF.set dst { desc | content =
--                                                  IO.Structure (IO.LambdaSet1 (IO.LsFrom [] [ src ])) }
--     Structure (LambdaSet1 (LsMembers ms))   -> … LsFrom ms [ src ] …
--     Structure (LambdaSet1 (LsFrom ms ss))   -> if List.any (\p -> IO.pointKey p == IO.pointKey src) ss
--                                                then skip else … LsFrom ms (src :: ss) …
--     _ (defensive)                           -> write ⊤ (lsTopContent) — §2.3's direction rule
-- Report-gated census bump: edgesInstalled (§6).
```

## §3 Resolution — pull-at-read

### 3.1 `zonkSetSlot` (translation-side reads; Store.elm:1359-1424) — Phase A

New arm before the trailing wildcard:

```elm
IO.Structure (IO.LambdaSet1 (IO.LsFrom members0 srcs)) ->
    case c1.lss of
        Just acc0 ->
            case resolveSlotMembers members0 srcs c1 of
                ( Nothing, c2 ) ->            -- a reachable ⊤
                    ( Mono.LTop, bumpZonkAcc Nothing c2 )
                ( Just [], c2 ) ->            -- EMPTY resolution = NO INFORMATION.
                    -- Mirrors the FlexVar policy ("LTop, never empty",
                    -- :1365-1366): an LSet [] would claim a provably-dead
                    -- arrow where symmetric HEAD reads an unconstrained
                    -- class → LTop. Without this arm the copied LsMembers
                    -- tail (which never sees [] — LsMembers is non-empty by
                    -- construction) would emit LSet [].
                    ( Mono.LTop, bumpZonkAcc Nothing c2 )
                ( Just ms0, c2 ) ->
                    -- THEN ground (LSS_019), THEN cap — verbatim the
                    -- LsMembers arm's tail on ms0 (resolution precedes
                    -- grounding: groundMembersC keys on this arrow's
                    -- already-zonked paramT/resultT).
                    …
        Nothing ->
            ( Mono.LTop, c1 )
```

`resolveSlotMembers : List Int -> List IO.Variable -> ZonkCtx
-> ( Maybe (List Int), ZonkCtx )` — DFS over the edge graph:
- **Visited keying:** raw `Engine.pointKey` of each source Point (UF exposes NO
  root accessor — `UF.get` returns the Descriptor, not the root Point; keying on
  raw ids is sound and terminating: finitely many recorded Points, each visited
  once; aliased Points re-read identical class content, and re-unioning the same
  members is idempotent).
- **Mark on ENTRY, before descending sources** — an insert-after-descend
  implementation loops forever on edge cycles; with insert-before-descend the
  entry slot re-entered through a cycle is caught on its first arrival as a
  node. The visited set is FRESH per `zonkSetSlot` call (local, not in ZonkCtx).
- Node dispatch: `LsTop` → `Nothing` (⊤, short-circuit the whole resolution);
  `LsMembers ms` → ms; `LsFrom ms ss` → union ms with each unvisited source's
  resolution; `FlexVar` → `[]`; defensive other → treat as ⊤ (`Nothing`) —
  §2.3's direction rule.
- Cycle exactness: one-pass DFS union-over-reachables IS the least fixpoint of
  the monotone inclusion system (a visited-hit contributes `[]`; every SCC
  node's own members are collected at that node; ⊤ absorbs).
- **Do NOT write the resolved value back** — later reads must re-pull (sources
  may have grown; collapsing would freeze them out). Quiescence-collapse is a
  recorded non-built optimization.

Reads outside zonk need no changes: `devirtDirectTarget`/`indirectResultAnno`
read zonked MonoTypes (Translate.elm:2027-2043, :2314-2344); AbiCloning/Borrow
read MonoTypes post-registry; `singletonHeadMember` consumers are post-zonk
(Monomorphized.elm:1429-1436).

### 3.2 `zonkSigGo` (scratch-store signature readback; LssInfer.elm:604-681) — Phase B

New arm between `LsMembers` and the FlexVar wildcard — promote-or-internalize:

```elm
IO.Structure (IO.LambdaSet1 (IO.LsFrom ms0 srcs)) ->
    if s2.env.lss.sigFlow then
        -- Walk the edge graph (same visited discipline as §3.1); classify
        -- each reached node:
        --   * UF-equivalent to slots[j], some ordinal j /= i (scan ALL
        --     ordinals, repOrdinal-style): PROMOTE — record j in `sources`,
        --     do NOT descend (the caller-side edge delivers j's members);
        --   * otherwise: INTERNALIZE — collect members, descend its srcs.
        -- Reachable ⊤ → { rep, members = [], top = True, sources = [] }.
        -- Self-filter (B.1.f) the collected members; cap: resolved members
        -- > maxSetSize → top = True, DROP sources (⊤ absorbs; bump
        -- widenedBySigSize). Dedupe sources; drop self and any j with
        -- rep(j) == rep(i).
        ( { rep = rep, members = msResolved, top = …, sources = ordinalSources }, sN )
    else
        -- Defensive (unreachable while §2.2's gating holds — no flag-off
        -- producer exists). MUST NOT read ms0 as complete: emit
        -- { rep = rep, members = [], top = True, sources = [] } — a set
        -- claiming completeness while dropping its sources' members is the
        -- false-singleton miscompile.
        ( { rep = rep, members = [], top = True, sources = [] }, s2 )
```

## §4 The fact language and its application (Phase B)

### 4.1 `ArrowFact` (Engine.elm:83-87) and ripple

```elm
type alias ArrowFact =
    { rep : Int            -- unchanged: genuine UF-equality (same-value chains —
                           -- for `pass f = f` param and result ARE one value)
    , members : List Int
    , top : Bool
    , sources : List Int   -- NEW: ordinals whose sets flow INTO this one
    }
```

Compile-forced ripple: `trivialSignature` (Engine.elm:276-280) adds
`sources = []`; the trivial predicate (LssInfer.elm:611-616) adds
`&& List.isEmpty f.sources`; **all five** fact constructors in `zonkSigGo`
(LsTop arm, three LsMembers branches, FlexVar arm) gain the field.
`Translate.lssFastOk` reads `sig.trivial` — automatically correct, which also
keeps the M2b ground-memo path (Translate.elm:2366-2386, guard `lssFastOk`
:2399-2412) edge-free by construction.

### 4.2 `applyFactsGo` (LssInfer.elm:211-252)

Per ordinal `i`, AFTER the existing rep/top/members steps: for each
`j ∈ fact.sources`, `Store.addSlotSource slots[j] slots[i]` (missing ordinal →
skip; count mismatch is already poisoned by `applyFacts`' length guard).
Pull-at-read makes the eager-vs-late ordering irrelevant — this is exactly the
deferral that makes directed facts sound where the snapshot read was not, even
though `applyFacts` still precedes arg unification.

## §5 The walk — which joins become directed (Phase C)

### 5.1 The directed structural walk (new, LssInfer-local)

```elm
{-| "Values of src flow into dst" — the directed twin of joinArrowSets.
Slot positions get a deferred edge instead of unification; ARG positions flip
operands (contravariance: dst's callers' arguments flow into src's params —
double-flip in nested arg positions is correctly covariant); container
positions (App1/Record1/Tuple1) DEGRADE the WHOLE subtree to the symmetric
join (variance unknown; joinArrowSets never resumes a directed spine inside —
it recurses only into itself). Alias chase, EmptyRecord/Unit accept,
mismatch/variable → poisonBoth onPoison, all as joinArrowSets. Any FUTURE
directed call site must re-argue variance — say so in this doc.
-}
flowArrowSets : (Engine.S -> Engine.S) -> IO.Variable -> IO.Variable -> Step ()
--   ( FunL argS resS slotS, FunL argD resD slotD ) ->
--       Store.addSlotSource slotS slotD
--         → flowArrowSets onPoison resS resD        -- result: covariant
--         → flowArrowSets onPoison argD argS        -- ARG: flip
--   ( Fun1 …, Fun1 … ) -> recurse (res same, arg flipped), no slots
--   container pairs -> joinArrowSets onPoison src dst
--       + bump flowDegraded ONLY when the degraded pair can carry a set —
--         guard on arrow-mention in the structure (ground App1 leaves like
--         Int would otherwise dominate the counter and make it meaningless)
flowArrowSetsSig : IO.Variable -> IO.Variable -> Step ()
flowArrowSetsSig = flowArrowSets Engine.bumpWidenedByCf
```

### 5.2 Call-site flips (exact anchors; everything else stays symmetric)

| site | today (anchor) | becomes |
|---|---|---|
| If/Case hub branch joins | `joinAllSig hub pts` → `joinArrowSetsSig hub p` (LssInfer.elm:2058) | `flowArrowSetsSig p hub` per branch Point (branch → hub) |
| local-callee arg side | `joinArrowSetsSig argVar pParam` (:1245) | `flowArrowSetsSig argVar pParam` |
| local-callee result side | `joinArrowSetsSig restVar callVar` (:1195) | `flowArrowSetsSig restVar callVar` |
| kernel PSFTunnels | `joinArrowSets identity v resVar` (:1373) / `LssInfer.joinArrowSetsPlain` (Translate.elm:3487) | **`if s.env.lss.sigFlow then flowArrowSets identity … else joinArrowSets identity …`** at BOTH sites (+ export `flowArrowSetsPlain`). The kernel boundary is NOT sigFlow-gated (LSS_021 runs flag-off), so the gate lives here — without it, the first `PSFTunnels` row would mint `LsFrom` flag-off and break §2.2. Zero tunnel rows ship in THIS plan; the sortBy/sortWith row unlocks after (LSS_021 amendment carries the same warning) |
| **kept symmetric** (same-value or v1 policy): walkMembers root join (:565), walkFunction result join (:1004 — safe because the hub's in-edges are one-way; no back-path to params), Let/Def rhs (:860), Let/TailDef result (:896), joinLetUse (:1723 — union-over-uses stays the let channel's v1 policy; per-use separation stays Phase-H-parked) | | |

Honesty rule UNCHANGED: hubs publish only when every branch is
`WpHonest`/`WpSelf`, else poison — a directed edge from a blind branch would
still under-approximate the hub; directedness fixes pollution, not blindness.

### 5.3 Worked trace (the depollution proof — chooseHandler at the caller)

Scratch: param uses join symmetrically into the letEnv families (=`funcVar`'s
param Points); the If arm installs `hub ⊇ use_f`, `hub ⊇ use_g`; `resVar ~ hub`
(symmetric, same-value); root `R ~ funcVar` (symmetric). Minting is
children-before-parent (Store.elm:199), so ordinals are 0 = f-param arrow,
1 = g-param arrow, 2 = result arrow. `zonkSigGo`: ord2's sources resolve to
ordinals {0,1} → fact `{ rep = self, members = [], top = False,
sources = [0,1] }`; ord0/ord1 trivial; `repOrdinal` returns self everywhere
(directed edges create no UF equivalence). Caller: `applyFactsGo` installs
`slot2 ⊇ slot0, slot1`; arg unification writes `{A}`/`{B}` into slot0/slot1
(unchanged machinery); the call's zonk pulls slot0 → `LSet [A]`, slot1 →
`LSet [B]`, slot2 → `LSet [A,B]`. **Params keep their singletons (stamps live);
the result keeps the honest 2-set (fidelity kept).** Two-caller check: caller2's
instantiation is its own isolated slot family (`loadTypeIsolatedWithArrows`) —
caller1's slots never see C/D; cross-caller mixing remains a REGISTRY join
(LSS_010), exactly as today.

## §6 Census, config, invariants

- **Counters** (extend `SigFlowStats`, Engine.elm:172-176 — LssStats stays under
  the 32-slot cap at 29 fields; both new counters REPORT-GATED per plan-1 §7.6,
  copying `bumpWidenedByCf`'s pattern :463-476): `edgesInstalled : Int`,
  `flowDegraded : Int`. Report: extend the `sigflow:` line (Monomorphize.elm:242)
  with `" edges=" ++ … ++ " degraded=" ++ …`. (Store.elm imports Engine — the
  bump is callable from `addSlotSource`.)
- **Config:** none (§0.6). `lssSF=` token semantics unchanged.
- **Invariants delta:**
  - NEW **LSS_022** (verified next free id): the `LsFrom` representation +
    pull-at-read semantics — content-carried deferred inclusions; **every
    producer is lss.sigFlow-gated (including the tunnel-site selector)**; ⊤
    absorbs and drops sources; empty resolution reads ⊤, never `LSet []`; never
    escapes zonk; resolution = one-pass entry-marked DFS, exact on cycles,
    visited keyed on raw pointKey; read-time semantics inherit HEAD's exposure;
    defensive arms fail toward ⊤.
  - AMEND **LSS_007** (invariants.csv:615): slot content becomes "FlexVar or
    Structure (LambdaSet1 …) where LambdaSet is LsTop | LsMembers | LsFrom;
    LsFrom carries source slot Points". (The "no Variables inside" retirement is
    an IO.elm/Occurs/Solve DOC edit — §2.1/§2.3 — not a csv clause; row 615
    never contained it.)
  - AMEND **LSS_020** (:628): the "directed inclusion (FromArrow) deliberately
    NOT implemented" clause → "directed inclusion IS implemented in its DEFERRED
    form (LsFrom/pull-at-read, LSS_022); the SNAPSHOT form remains banned".
  - AMEND **LSS_021** (:629): PSFTunnels becomes directed UNDER sigFlow (the
    tunnel-site selector), symmetric otherwise; a PSFTunnels row may land only
    with that selector in place.

## §7 Tests (Phase D) — extend `compiler/tests/TestLogic/Monomorphize/LssSigFlowTest.elm`

Harness (`run`, `demandsOf`, `annosOf`, `deepestRetAnno`, `annoHasSize`,
:226-333) and the five fixtures / six tests carry over. New accessor (verified
against `zonkFlatC`'s one-arg-per-arrow output, Store.elm:1302/1319):

```elm
paramArrowAnnos : Mono.MonoType -> List Mono.LambdaSetAnno
paramArrowAnnos t =
    case t of
        Mono.MFunction _ _ args ret ->
            List.filterMap
                (\a -> case a of
                    Mono.MFunction _ anno _ _ -> Just anno
                    _ -> Nothing)
                args
                ++ paramArrowAnnos ret
        _ -> []
```

1. **THE depollution pin (upgrades test 1a):** chooseHandler flag-on — result
   arrow `LSet` size 2 (unchanged) AND `paramArrowAnnos` yields two singletons
   with DISTINCT members. Under the archived symmetric arm (Run X) the params
   read 2-sets — the assertion that separates the designs.
2. **Existing tests 2-6 pass UNCHANGED** — each traced through the directed
   mechanism during verification: mk2's hub sources are lambda slots →
   internalized → fact still carries both ids (and test 6's `maxSetSize = 1` cap
   fires exactly once on the RESOLVED list); countdown's rep transport becomes
   `sources = [0]` with the same observable (`deepestRetAnno` = LSet 1); apply
   installs zero edges (TVar guards in `joinCallArgs`/`localCalleeJoin`) and
   stays trivial under the extended predicate; pick's honesty poison is
   untouched (its `callVar ⊇ restVar` edge is then topped through §2.3 item 1's
   ⊤ arm — the dependency that makes item 1 mandatory). Any outcome change is a
   design bug, not a test update.
3. **Transitive chain:** `chain b c f g h = if b then f else (if c then g else
   h)` ground-typed, three lambdas at the caller → result arrow `LSet 3`, all
   three param arrows singletons (edge depth ≥ 2 through the nested hub).
4. **Cycle termination/exactness — Store-level, NOT a pipeline fixture.** Legal
   Elm cannot reach an `LsFrom` cycle through §5.2's sites (mutual let VALUES
   are rejected by the canonicalizer; function-izing turns the back-reference
   into a call → `WpOpaque` → the hub poisons; Cycle-sibling value refs mint
   standalone members without touching sibling slots). Test the resolver
   directly: a TestLogic test that mints FunL slots in a store, installs a
   2-cycle + member writes via `Store.addSlotSource`/`unifySlotWithSet`, and
   asserts termination + exact SCC union + the ⊤-in-cycle short-circuit.
   (Precedent for pure store-level tests: LssGroundingTest's layer-1 pattern.)
5. **Container degrade:** branches must be letEnv-bound NAMES at a container
   type — a `TOpt.List` literal branch returns `WpNone` and the hub POISONS
   before any join runs. Fixture: `choosePair b p q = if b then p else q` at
   `Bool -> (hInt, hInt) -> (hInt, hInt) -> (hInt, hInt)`, caller passing two
   lambda-pairs → the hub join degrades at `Tuple1`: result-tuple element annos
   are the symmetric `LSet 2` AND the report shows a nonzero degrade count —
   assert `not (String.contains "degraded=0" report)` (the bare key prints
   unconditionally once §6 lands; presence-checking would be vacuous — pin
   values, per test 6's `bySigSize=1` precedent).
6. **Contravariance pin — all flows through NAMED sites, observable on the
   def's own demand** (let-bound HOFs have no registry rows, and an
   expression-callee `(if …) k` hits `walkCall`'s wildcard — the outline's
   fixture was doubly inert): `useH b hof1 hof2 k = let h = if b then hof1
   else hof2 in h k` with hof1/hof2 : `(Int -> Int) -> Int` and k : `Int ->
   Int` all PARAMS of the annotated def. Edges: hub ⊇ hof-uses (flip at the
   FunL arg gives `hof_i.param ⊇ h.param`), `joinCallArgs` gives `h.param ⊇
   use_k`. Assert on `demandsOf "useH"`: each hof param position's inner
   `(Int -> Int)` anno is `LTop` or CONTAINS k's member — never a k-less
   non-⊤ set (a backwards flip yields exactly that). Exact expected annos
   pinned from the first run; the assertion shape is fixed here.
7. E2E: `test/elm/src/LssSigFlowTest.elm` unchanged (behavior pins are
   flag-independent); re-runs in the flag-on battery leg.

## §8 Phases, batteries, gates

- **A — representation** (§2 + §3.1 + `addSlotSource`; no producers; unused
  defs are legal Elm). Gates: elm-tests once; `--target full` once; **out.mlir
  byte-identity** (LsFrom unreachable — pure-refactor gate). Exit ritual: re-run
  the §2.3 grep census and reconcile against items 1-13.
- **B — signature channel** (§3.2 + §4). Sources always empty until C (the only
  `addSlotSource` caller is `installSources`, and `zonkSigGo` emits sources only
  from `LsFrom`, which needs C's producers — verified inductively) ⇒ behavior
  identical to symmetric HEAD; battery green is the gate.
- **C + D — walk flips + tests together** (§5, §6 counters, §7 — the
  depollution pin is C's acceptance test). Gates: full unit suite; flag-off
  byte-identity leg; flag-on `--target full`.
- **E — measurements + decision:**
  1. **lss-opt.md Run Y** — A/B on `lss.sigFlow` per THAT file's protocol (both
     arms built AND measured solver+LSS, one cold run per arm, tables-first
     ≤10-line entry, numbers-only summary row). **Precision expectations are
     SAME-TREE on/off deltas, not cross-run absolutes** (this plan grows the
     corpus; Run X's own entry declined a Run-W comparison for exactly this
     reason): expect the flag-on arm to reproduce Run X's SHAPE — hundreds of
     nontrivial signatures, a five-figure singleton gain over its own off-arm,
     ⊤-share down several points — with `edges=`/`degraded=` attributing the
     wall and `joins: noop` DROPPING vs Run X's 22,074 (no more
     rebuild-and-discard unions from rep links).
  2. **Run-M dispatch A/B** — per `benchmarks/runtime-calls.md` Commands:
     solver-built, counters-lowered (`ECO_LSS_DISPATCH_SITE_COUNTERS=1` at
     build; remember ninja env-blindness — `rm -f bin/eco-compiler
     bin/eco-compiler.mlir` + `rm -rf eco-stuff` before each flavored build),
     **cold SUBST workload** (the job held constant while the binary changes —
     the file's own convention, and what the 8.30%/6.08% baselines mean).
     Gate: directed-built fast coverage ≥ the SAME-TREE default-built coverage
     (re-measure both arms; do not hardcode 8.30%), `sat+fast` invariance,
     byte-identical workload out.mlir (LSS_005 behavioral gate).
  3. **Flip re-decision:** if 1 holds fidelity and 2 shows non-regression, the
     fidelity-3 Phase-D blocker is discharged — re-open the `sigFlow` default
     flip as its own recorded decision (fresh full battery + bootstrap fixed
     point at default-on, per the groundStandalones G3 precedent). If 2 still
     regresses, the residual channel is measured (`degraded=` containers /
     joinLetUse family) and Phase H's per-use separation is the next lever —
     record, do not improvise.

## §9 Risks

- **Wrong-direction edge = under-approximation = miscompile.** Contained by
  construction (direction asserted only along FunL/Fun1 spines; containers
  degrade whole-subtree symmetric; defensive arms fail toward ⊤) and pinned by
  §7.1 + §7.6. Any new directed site must re-argue variance.
- **Resolution cost at zonk.** Fast paths unchanged; `LsFrom` exists only at
  fact-target/hub/tunnel slots; DFS depth = edge-chain depth. Watch Run Y's
  wall attribution; quiescence-collapse is recorded, not built.
- **Edge-list growth on shared slots.** Install-time pointKey dedupe +
  skip-on-⊤ + join-arm dedupe; MONO_029 saturation passes CONCATENATE onto
  shared families (bounded by the pass cap — §0.3). If Run Y shows pathological
  source lists, cap-and-⊤ (sources > N → poison the slot) is the LSS_005-shaped
  relief valve — recorded, not built.
- **Silent-wildcard regressions:** the two non-compile-error sites are §2.3
  items 1-2; items 11-13 are the audited-no-op wildcards. The Phase-A census
  reconciliation ritual + §7 tests 3-5 are the catchers.
- **LSS_013 spine-injection interplay:** member writes into `LsFrom` slots
  union into the members field, sources untouched (§2.3 item 1) — spine
  semantics unchanged; no LSS_013 amendment.

---

# EXECUTION RECORD — Phases A-D (2026-08-20)

**Invariant-id correction:** the plan reserved "LSS_022 (verified next free id)";
that id was taken the same day by the kernel parametricity license
(`plans/kernel-parametricity-license.md`), so this plan's invariant is
**LSS_023**. LSS_007/LSS_020/LSS_021 amendments landed as §6 specified.

## Phase A — representation (byte-inert, verified)

`LsFrom (List Int) (List Variable)` + `IO.pointKey`; the Unify 2×2 became 3×3
exactly as predicted (compile-forced; class merges MERGE edge lists, deduped by
`IO.pointKey`); `unifySlotWithSetC` gained its MANDATORY explicit arm (member
writes union into `members`, sources untouched — the LSS_013 interplay; ⊤ drops
sources); `zonkSetSlot` gained the pull-at-read arm + `resolveSlotMembers`
(entry-marked DFS, fresh visited per read, no write-back); `addSlotSource`
(descriptor-preserving, self-edge skip, pointKey dedupe, defensive-arm-to-⊤).
Comment retirements in IO/Occurs/Solve landed; the §2.3 census reconciled (8
files, LssInfer's remaining match being the Phase-B site). Gates: E2E
1685/1685, elm-tests same 12, six fixed probes BYTE-IDENTICAL against the
pre-change baseline.

## Phase B — signature channel

`ArrowFact.sources` (all five constructors compile-forced through a
`Result`-shaped fact split in `zonkSigGo`), trivial predicate extended,
`sigResolveEdges` promote-or-internalize (with `ordinalOf` scanning ALL
ordinals, unlike `repOrdinal`'s below-i scan), `finishSigFact` applying the B.4
cap to the RESOLVED list with sources dropped on ⊤, `applyFactsGo` →
`installSources` installing deferred edges per source ordinal. One deviation
from §3.2's sketch, recorded: rep-equal ordinals are NOT filtered from
`sources` at fact creation — `addSlotSource`'s UF-equivalence skip at the
CALLER makes such an edge a no-op after the rep link unifies the slots, which
is the same outcome with less machinery. Gates: probes byte-identical flag-off;
flag-on smoke shows the symmetric channel live (25 nontrivial signatures on the
Wide probe) with `edges=0` — no producers yet, as § phase-B required.

## Phases C+D — the flips and the pin

`flowArrowSets` (contravariant arg flip, whole-subtree container degrade via
`degradeToSymmetric` + `storeMentionsArrow` so ground leaves don't pollute the
counter, defensive-to-poison); flips landed at the hub (`joinAllSig` →
`flowAllSig`, branch INTO hub), local-callee arg and result, and the kernel
tunnels behind the sigFlow SELECTOR at both sites (LssInfer.joinTunnels and
Translate.joinKernelTunnels — the §2.2 gate, since the kernel boundary runs
flag-off). Census counters `edges=`/`degraded=` on the `sigflow:` line.

**THE depollution pin passes**: chooseHandler's result reads the honest 2-set
AND the params keep two DISTINCT singletons — the assertion that separates the
designs (Run X's symmetric arm read 2-sets on the params). Tests 2-6 pass
UNCHANGED, as §7.2 demanded. New: transitive 3-chain (result 3-set, three
singleton params through a nested hub); store-level resolver suite
(`LssDirectedFlowTest`, 5 tests: 2-cycle termination + SCC exactness, ⊤
short-circuit incl. inside a cycle, diamond dedupe, FlexVar contribution) —
with one recorded deviation: content is written via `UF.set` rather than
`addSlotSource` (Step-typed, needs a full S; the installer is exercised
end-to-end by the pipeline tests); contravariance pin (LTop-or-honest shape on
the hof-param inner arrows).

**Test 8 correction — the plan's sketch over-promised.** §7.5 expected
"result-tuple element annos are the symmetric LSet 2"; that is NOT OBSERVABLE
in either design, because member transport into container LITERALS does not
exist (`injectArgLambdaMember` is per-direct-argument; the symmetric Run-X arm
reads LTop here too). The degrade guard protects the JOIN DIRECTION's
soundness, not new precision. The test asserts the degrade counter fires and
the elements read ⊤-or-honest; the 2-set claim is struck.

Gates: flag-off probes byte-identical; `--target full` 1685/1685 flag-off AND
flag-on (fresh `eco-stuff` per leg); elm-tests 13,165 / same 12 pre-existing.

## Phase E — measurements and the flip decision (2026-08-21)

**Measurement 1 (lss-opt.md Run AC), fidelity: HELD, and better than expected.**
Same-tree A/B: precision reproduces Run X's shape exactly (394 nontrivial
signatures, singletons 64,431 → 95,854, grounded +7,595, byBudget +5.6% with
watchdogs quiet) — and **the analysis wall cost is GONE**: sf-on 328.4 s vs
sf-off 329.6 s (−0.4%, FLAT), where Run X's symmetric arm paid +3.6%. Majors
13 = 13 both arms. Two §8.1 counter expectations corrected by measurement:
`joins noop` did NOT drop (22,169 ≈ symmetric's 22,074 — the noops come from
the KEPT symmetric joins and rep links; only 177 edges exist on this corpus),
and `declinedNoInstance` +133 persists (the LSS_017 raw-`l|` channel,
orthogonal to pollution).

**Measurement 2 (runtime-calls.md Run AB), non-regression: FAILED — by half.**
Re-measured same-tree baseline 8.79% (not the stale 8.30%); directed-built
7.68%. Directed removes HALF the symmetric regression (−1.11 points vs −2.22)
and keeps `sat+fast` invariant (+76 in 2.09B) with byte-identical workload
output. **The residual is not on §8.3's menu**: containers degraded 4 times,
edges cost nothing, and the absolute fast-event loss (−23.2M) matches
symmetric's (−22.6M) while mono-time stamp counts barely move in EITHER design.
The mechanism is stamp RESHUFFLING: sigFlow's extra facts change joined
registry types → spec keys → AbiCloning layout groups, so a hot-loop site
loses its stamp while cold sites gain them — stamp-count-flat,
coverage-negative, invisible to the depollution pin (which passes; the
chooseHandler shape IS fixed).

**Per-fp diff (2026-08-21, runtime-calls.md Run AB addendum) — the residual
NAMED.** Matching all ~950 fast-bearing evaluators across arms by exact count:
439 pairs are pure RENAMES (105.5M events preserved — lambda indices renumber
between arms, so name-keyed diffs lie). The genuine loss is ONE dominant site:
`Extract.typesDecoder`'s spec holds a 44.25M-event stamped direct call into the
inlined `Utils.Bytes.Decode.list/loop` continuation flag-off; flag-on that spec
is BUILT DIFFERENTLY (structurally different body) and the site does not exist
in stampable form. The top gainer (16.9M) is a DIFFERENT decoder
(`Eco.Config.lssDecoder`) acquiring a fresh flag-on stamp. Implicated
mechanism, consistent with +133 `declinedNoInstance` in BOTH sigFlow designs:
the shared combinators' signatures transport RAW `l|` lambda ids (LSS_017's
recorded live channel) into caller slots, missing AbiCloning's instance index
and/or widening past singleton — "not material" at 133 SITES, 44M EVENTS when
one site is the artifact-decode loop. Next lever RE-RANKED: LSS_017 v2
enqueue-time qualification (`plans/lss-fork-qualified-members.md` §8) ahead of
Phase H, with a per-site decline log as the confirming measurement first.

**Per-site decline log (2026-08-21, `/work/lss-decline-log-analysis.md`) — the
confirming measurement RAN and REFUTED the re-ranking.** Two corrections:
(1) the +133 noInstance members are INTERNED-range ids, not raw `l|` (5 of
1,034 ON-only pairs in the raw range) — they are `g|`-class function globals,
which have no closure instances BY DEFINITION; the +133 is unexploited E9.1
(`lss.devirtFnGlobals`) precision, not pollution. LSS_017 v2 is DEPRIORITIZED
back below Phase H. (2) `Extract.typesDecoder` appears in NEITHER arm's log —
the 44M loss is not a decline; the spec's body is BUILT differently upstream
of AbiCloning (spec construction / inlining), so no decline-side fix can
recover it. Corrected next levers: (a) typesDecoder spec-construction diff
between arms; (b) one `lss.devirtFnGlobals=1` run on the sf-on arm.

**Spec-construction diff (2026-08-21, `/work/lss-spec-construction-diff.md`)
— lever (a) RAN; the residual mechanism is now NAMED, and it is not
typesDecoder.** Global canonical diff of the two arms' artifacts: **zero spec
bodies restructured** (9,675 roles; the 59 diverged roles differ only by
instance count, every extra instance a canonical duplicate); typesDecoder
keeps all five stamps in BOTH arms (confirmed in the Run-AB disassemblies
too — its identification was dispatch-census symbol aliasing, 859 fps
printing as one name). The real delta: sigFlow's richer annotations SPLIT
SPEC KEYS in the solver zonk/UnionFind family (`Type.Type.variableToCanType`
/ `variableToErrorType` / `getVarNames` off=1→on=2, `UnionFind.modify`
10→14, plus their `IO.andThen` chains), and a net ~6 andThen callback
wrappers lose `singleton_fast` (= `stampedStaged −6`): the callback member's
instance misses the index under the new key → `declinedNoInstance` → stamp
refused. So part of the +133 is key-split instance misses (needs instance
dedup or canonical-body stamping), not `g|`-class devirt targets. Final
lever ranking: (1) fix census symbolization (prerequisite for any future
attribution); (2) size instance dedup / canonical-body stamping for the
split family; (3) `lssDF=1` for the fn-global subset. Phase H and LSS_017 v2
stay deprioritized — neither is implicated. [Refined same day: the hot
sites' decline mode is slot WIDENING to 2-sets of qualified siblings, not
index misses — andThen noInstance is 26 = 26 across arms; see the plan
below.]

**Census fixed + attribution EXACT (2026-08-21).** Root cause of the
aliasing: awk's numeric comparison of hex-address strings that happen to
parse (pure digits / `...e0` scientific notation) — symbols were never
missing. `dispatch-census.sh`/`closure-census.sh` rewritten (explicit
hex2dec + binary search, `sym+0x<off>` on off-start lookups). Re-symbolized
Run-AB logs: net unmatched fast = **23,231,541 = the global delta to the
event**, in FOUR de-stamped solver callbacks — `variableToCanType`'s chain
19.29M (83%), its adjacent chain 2.79M, `getVarNames`' chain 1.15M. The
16.9M "lssDecoder gainer" was aliasing too (real gains: 4,818 events).
Lever (2) is THE lever — the `Type.Type` zonk-family key split alone is the
whole remaining runtime regression; lever (3) `lssDF=1` deprioritized (no
event weight). Full record: `/work/lss-spec-construction-diff.md`.

**Plan filed (2026-08-21): `plans/lss-layout-qualified-members.md`** —
layout-qualified member identity (share ids across annotation-only spec
splits by qualifying on the widened immutable creation key) PLUS a
mandatory AbiCloning fingerprint fence (the E11 §11.7 record proves
same-layout annotation-only clones can be behaviorally divergent, so id
sharing needs a verbatim-body fence, not layout checks). If its Phase-3
acceptance holds, its §6.4b re-opens THIS plan's §8.3 flip decision as a
separate recorded decision.

**Decision per §8.3: the flip stays CLOSED.** `lss.sigFlow` remains
DEFAULT-OFF. The directed mechanism ships DORMANT as the strictly-better
substrate — same precision, no analysis-wall cost, half the runtime regression
— and the fidelity-3 Phase-D blocker is now HALF-discharged with the remaining
half precisely characterised. Next levers, in order and recorded rather than
improvised: (1) per-fp census diff (`dispatch-census.sh` over both Run-AB
logs) to NAME the reshuffled hot sites; (2) Phase H per-use let separation
(`joinLetUse` stayed union-over-uses, the largest kept-symmetric channel).

Status: **IMPLEMENTED IN FULL (Phases A-E); flip decision recorded: not
flipped.**
