# LSS set-write substrate: sorted-list sets, Top constant, direct joins, no-op-free annotation joins

**Status: PLANNED (2026-08-17).** Executes the substrate redesign from the 2026-08-17
set-write exploration (8-reader verified survey; findings summarized per phase below with
file:line evidence). Motivation: Run-K forensics measured the e2v2→e9 regression at
+116 s (+13.7%) solver wall, **two-thirds GC/allocation churn**, from a +29% concrete-set
population (`plans/lss-dispatch-value-extraction.md:2152-2156`) — i.e. per-set-write cost
is the price of LSS precision. This plan cuts that price BEFORE the flow repairs
(`design_docs/auto-borrow-inference/lss-paper-fidelity-mapping.md` GAP-2/GAP-9) raise the
concrete-set population further.

**Everything here is solver-internal.** No phase may change any artifact byte.

**Gate structure (restructured 2026-08-17, after Phase 2's gates ran):** per-phase gates
are the FAST, decisive ones only — type-check, the two-binary identity byte-compare
(OLD-binary output vs NEW-binary output on the same tree; byte-identity across a SOURCE
change is unsatisfiable), the census witness-line compare, and the phase's benchmark
run. The SLOW suites — elm-tests, E2E ×3 legs, bootstrap Stage-8c — run ONCE as a
**final correctness sweep** (section at the end) after all phases land, not per phase.
Rationale: every phase is behind the same byte-identity proof, so the suites re-verify
what the identity gate already established; batching them trades per-phase latency for
one sweep, with the identity gate as the per-phase safety net. If a phase's identity
gate FAILS, fix before proceeding — do not stack unverified phases. Precedent that
Point-mint elision passes the identity gate: E9.3 v1.1 shipped fresh-var elision
byte-identical (`Store.elm:758-759` comment).

**The workload shape these changes exploit** (all verified):

- Sets are tiny: 94% of concrete sets are singletons; ≤8 at readback (`maxSetSize`).
- Every member list entering the store is ALREADY ascending: `Dict.keys` output, `[]`,
  or `[mid]` (verified at all four `unifySlotWithSet` call sites and `monoTypeToVarC`).
- ⊤ is terminal (un-topping impossible — every construction site audited) and members
  are DEAD under ⊤ at every reader in the repo, census included.
- **Set-write split, MEASURED (Run B, `benchmarks/lss-opt.md`), and it refutes what the
  code comment claims:** of 205,623 writes, `skip=62` (**0.03%**), `flex=144,158`
  (70.1%), `slow=61,403` (**29.9%**). The "~90% hit the E9.3 skip" claim at
  `Store.elm:755-758` is wrong by three orders of magnitude — fix that comment while
  editing the function. The FlexVar-adopt case IS dominant as documented (LSS_006
  fresh-arrows-per-load), but the real-join path is the second-largest population, not a
  rarity, which raises Phase 2's payoff substantially.
- **Join split, MEASURED:** `identical=80,869` (the cheap `==` exit), `noop=4,566`
  (rebuild-and-discard waste), `changed=3,425` (real widening; consistent with
  `retranslations=1,010`), `completion=33,541` (unconditional full-tree joins). Phase 4a's
  target is 4,566 + an unmeasured fraction of 33,541.
- **In-store set sizes, MEASURED:** the 462 size-widened sets run 9→115 … 35→13 36→6
  48→1 **81→18 97→24**. Sets DO reach ~100 members, so the sorted-list worst case is real
  — but only 42 of 462 are ≥81, so a generous write-time collapse threshold catches the
  whole tail.

All file:line references verified against HEAD on 2026-08-17. Re-verify before editing —
several are load-bearing to the diffs below.

---

## Phase 1 — Instrumentation (land first; everything later is sized by it)

No behavior change; counters and one histogram. All output rides the existing
`lss.report` stderr census (report is hash-excluded).

1. **`LssStats` gains 7 fields** (`Engine.elm:101-122`; it is one S field, so the S
   32-slot cap at `Engine.elm:379-383` is not at issue):
   `setWriteSkip, setWriteFlex, setWriteSlow, joinIdenticalHit, joinNoop, joinChanged,
   completionJoins : Int` and `widenedSizeHist : CoreDict.Dict Int Int`. Zero them in
   `emptyLssStats` (`Engine.elm:195-197`).
2. **Set-write path split**: increment `setWriteSkip/Flex/Slow` in the three arms of
   `unifySlotWithSet` (`Store.elm:761-801`). The function already threads `Step S`, so
   this is a record bump in each arm.
3. **Registry hit split**: change `Registry.getOrCreateSpecIdKeyed`
   (`Registry.elm:88-133`) return from `( SpecId, SpecializationRegistry, Bool )` to
   `( SpecId, SpecializationRegistry, KeyedHit )` with
   `type KeyedHit = CreatedNew | HitIdentical | HitNoopJoin | HitChangedJoin`.
   The three hit cases already exist as distinct branches: the `storedType == storeType`
   short-circuit at :98 (→ `HitIdentical`), the `joined == storedType` test at :107
   (→ `HitNoopJoin`), else `HitChangedJoin`. Callers: `Engine.enqueueSpec` unkeyed-lss
   branch (`Engine.elm:779-793`) and `enqueueSpecKeyed` (`Engine.elm:870-934`) —
   `storedChanged` becomes `hit == HitChangedJoin`; bump the three counters there.
   `getOrCreateSpecId` (lss-off path) is untouched.
4. **Completion joins**: bump `completionJoins` at the `processItem` completion join
   (`Monomorphize.elm:554-591`, the `Mono.joinAnnotations actualType storedT` at :572).
   Count invocations only — do NOT add an equality probe here (that would be a full tree
   walk; the no-op fraction at this site arrives free with Phase 4's changed flag).
5. **Widened-size histogram**: the widened branch of `zonkSetSlot` (`Store.elm:1184-1185`)
   currently bumps `widenedBySize` without recording the size — `sizeHist` is blind on
   exactly the sets whose magnitude Phase 2's worst-case analysis needs. Add the size to
   `widenedSizeHist` via `LssZonkAcc` (`Store.elm:924-929`) and fold it in
   `foldZonkStats` (`Store.elm:964-986`), mirroring `sizeHist`.
6. **Render** the new numbers in `renderLssReport` (`Monomorphize.elm:144-210`), e.g.
   `set-writes: skip=N flex=N slow=N` / `joins: identical=N noop=N changed=N completion=N`
   / `widenedSizes: 9->k 12->k ...`.

**Gates:** type-check; elm-tests baseline; one full E2E; solver+LSS build with
`ECO_MONO_LSS_REPORT=1` prints the new lines; frozen-corpus artifact identical (stats
cannot affect output). **Record the census numbers in this file** — `setWriteSlow`,
`joinNoop`, `completionJoins`, and the widened-size tail decide how much Phases 2/4 must
deliver and whether the Phase-2 list worst-case needs a write-time cap.

### Phase 1 — LANDED 2026-08-17

Files: `Engine.elm` (8 `LssStats` fields + `bumpKeyedHit`/`bumpCompletionJoin`),
`Store.elm` (three-arm split folded into the S copies each arm already made;
`LssZonkAcc.widenedHist`), `Registry.elm` (`KeyedHit` sum replacing the `storedChanged`
Bool), `Monomorphize.elm` (completion counter + three census lines).

Gates: type-check clean; elm-tests **13,104 / 12** (baseline); E2E default **1,675 /
1,675**; **two-binary identity byte-identical** (pre-Phase-1 binary vs post on the same
tree — the real stats-only proof, since the tree itself grew). Benchmark **Run B** in
`benchmarks/lss-opt.md`: wall FLAT (+0.5 s), minors 1348→1379, promoted +2.0%; the
instrumentation cost and the +8,841 B corpus growth cannot be separated by one run and
both push the same way.

Two implementation notes worth carrying forward. (1) Every counter rides an S copy the
arm already made — the skip arm's bump replaced the old `s1 = { s0 | store = store1 }`
rather than adding to it, and the FlexVar arm went from two S copies to one. Measuring
the hot path must not tax it. (2) The ONE place instrumentation adds a copy the
un-instrumented compiler did not make is `bumpKeyedHit` on the D2 "return S unaltered"
path (`HitIdentical`/`HitNoopJoin`); `CreatedNew` deliberately bumps nothing. That is
the accepted price of the join census and it is exactly the population Phase 4 removes.

**Follow-up the numbers created:** `setWriteSlow` conflates the real-join arm with the
defensive `_` arm. Phase 2 separates them for free (the join arm stops calling Slow), so
no extra counter is needed now — but do not read the current 61,403 as evidence about
the defensive arm.

**Reading the Run B census (drives the Phase 2/4/5 amendments below):**

- Within the LambdaSet1 arm the skip succeeds 62 / 61,465 times (0.1%) — optimize that
  arm for the JOIN outcome, not the skip. Part of the 61,403 is a nameable waste class:
  a concrete member write onto an already-⊤ slot FAILS today's skip (the member is not
  in the topped dict) and slow-joins into dead members-under-⊤; under `LsTop` it becomes
  a free absorb. Size unknown until Run C's re-mapped counters (§2.5).
- Zonk-side decomposition: 482,627 slot zonk-visits, of which only 106,289 (22.0%) read
  a concrete set (105,827 within-cap + 462 widened) — **78.0% of slot reads are
  ⊤/unconstrained**, and writes are 70.1% onto fresh slots. The LOAD layer mints far
  more set machinery than facts ever touch: the strongest evidence yet for Phase 5,
  recorded there.
- `completion=33,541` vs `changed=3,425` (+ `retranslations=1,010`, consistent —
  markDirty dedups and pending specs need no re-translation): the overwhelming majority
  of completion joins are presumptively no-ops. Phase 4a re-ordered accordingly.

## Phase 2 — The set representation: `LsTop | LsMembers (List Int)`, direct joins

The core change. Three sub-parts land as ONE commit (they are one coherent invariant);
the diff is confined to 7 files (exhaustive grep: `IO.elm, Store.elm, Unify.elm,
LssInfer.elm, Occurs.elm, Solve.elm, Type.elm` — nothing else mentions `LambdaSet1`).

### 2.1 The type (`IO.elm:660` + doc block :644-649)

```elm
type FlatType
    = ...
    | LambdaSet1 LambdaSet          -- was: LambdaSet1 Bool (CoreDict.Dict Int ())

{-| An LSS lambda set in a FunL slot. `LsMembers` is ascending, deduped, and
NON-EMPTY by construction (mirrors LSS_001 for the zonked form). Members are
dead under ⊤ (verified at every reader 2026-08-17), so `LsTop` carries none —
⊤-writes and ⊤-joins are allocation-free constant returns.
-}
type LambdaSet
    = LsTop
    | LsMembers (List Int)


{-| THE shared ⊤ content. All top-writes UF.set this one value. -}
lsTopContent : Content
lsTopContent =
    Structure (LambdaSet1 LsTop)
```

Add two allocation-free helpers next to it (they cannot live in `Monomorphized.elm` —
`Monomorphized` imports `IO`, so `IO` must own its own copies; note the deliberate
~15-line duplication of `Mono.unionSortedInts`, `Monomorphized.elm:1150`):

```elm
type SortedRel = SortedEqual | SortedSuper | SortedSub | SortedMixed

{-| One merge-scan over two ascending lists: Equal / m2⊆m1 (Super) / m1⊆m2 (Sub)
/ neither. O(n+m), zero allocation, early exit to SortedMixed. -}
classifySorted : List Int -> List Int -> SortedRel

{-| Ascending dedup merge; reuses the exhausted side's suffix by pointer. -}
unionSortedAsc : List Int -> List Int -> List Int
```

### 2.2 `unifySlotWithSet` — direct root-descriptor join, slow path demoted to defensive

Verified basis: the LambdaSet1 join is TOTAL (no mismatch branch, `Unify.elm:751-766`),
runs NO occurs check (occurs reachable only from comparable-super arms,
`Unify.elm:622-635`), and rank/mark are invariant on every MonoSolver path (all three
`UF.fresh` sites use `outermostRank/noMark`: `Store.elm:233,409`, `Engine.elm:629`;
`merge`'s min-rank is a no-op). `UF.set` writes the ROOT descriptor
(`UnionFind.elm:107-131`), exactly as the existing FlexVar arm already does. So the
fresh-Point-plus-`unifyStep` slow path (`Store.elm:794-801` — the fresh Point becomes a
permanently dead Chain cell one call later) is replaceable by a direct `UF.set`:

```elm
unifySlotWithSet : Bool -> List Int -> IO.Variable -> Step ()
unifySlotWithSet top members slot s0 =
    -- signature and all 4 call sites unchanged:
    -- (True, [])  = ⊤ write   (LssInfer.elm:233, Store.elm:843)
    -- (False, ms) = member write, ms ascending; non-empty at both callers
    --               (LssInfer.elm:236 guarded, LssInfer.elm:1054 = [mid])
    let ( store1, desc ) = UF.get slot s0.store
        s1 = { s0 | store = store1 }
    in
    case desc.content of
        IO.Structure (IO.LambdaSet1 IO.LsTop) ->
            bump setWriteSkip s1                 -- ⊤ absorbs everything: pure skip

        IO.Structure (IO.LambdaSet1 (IO.LsMembers cur)) ->
            if top then
                setRoot slot lsTopContent s1     -- direct join to ⊤ (was: slow path)
            else
                case classifySorted members cur of
                    SortedEqual  -> bump setWriteSkip s1
                    SortedSub    -> bump setWriteSkip s1   -- members ⊆ cur
                    _ ->
                        setRoot slot
                            (IO.Structure (IO.LambdaSet1
                                (IO.LsMembers (unionSortedAsc members cur)))) s1

        IO.FlexVar _ ->
            if top then
                setRoot slot lsTopContent s1     -- was: Dict.fromList [] + structure
            else if List.isEmpty members then
                bump setWriteSkip s1             -- (False, []) = bottom: no-op, keep FlexVar
            else
                setRoot slot
                    (IO.Structure (IO.LambdaSet1 (IO.LsMembers members))) s1
                    -- caller's list adopted AS-IS: zero conversion, pointer-shared

        _ ->
            -- Defensive only: argued dead by closure of the slot-content channels
            -- (LSS_007; mint sites Store.elm:151/510-511; mutation channels
            -- Unify.elm:732-749 + applyFactsGo slot×slot). KEEP the old
            -- freshVar+unifyStep fallback here.
            --
            -- Phase 1 CORRECTION: the original plan said "delete it when
            -- setWriteSlow reads 0". That test is void — `setWriteSlow` is
            -- bumped inside `unifySlotWithSetSlow`, which today serves BOTH this
            -- defensive arm AND the LambdaSet1-needs-a-real-join arm, and Run B
            -- measured it at 61,403. The join population is what that number
            -- counts; this arm's own count is unknown. Under the rewrite above
            -- the join arm no longer calls Slow at all, so after Phase 2 the
            -- counter isolates THIS arm — 0 there is then the evidence to
            -- delete it, in a later commit.
            unifySlotWithSetSlow top members slot s1
```

`setRoot` = the existing `{ desc | content = ... }` + `UF.set` pattern from the current
FlexVar arm (`Store.elm:786-788`), preserving the root's weight (UF.set semantics).
Note `applyFactsGo`'s **slot×slot rep-linkage** (`LssInfer.elm:213-218`) is NOT this
function and keeps full `unifyStep` — it genuinely merges two UF classes.

### 2.3 The Unify arm (`Unify.elm:751-766`) — reached via FunL×FunL `subUnify set1 set2` and the defensive path

Replaces two subsumption guards that each recompute both `Dict.size` (a full O(n) tree
walk — up to 4 discarded walks per evaluation) plus a `Dict.keys` allocation per probe,
and the wrong-direction `Dict.union` (elm/core `union t1 t2 = foldl insert t2 t1`; call
site passes `members1` to the expensive side unconditionally). Also fixes the verified
⊤-pathology: ⊤ was `True Dict.empty`, so `concrete × ⊤` failed BOTH guards and rebuilt
the entire concrete dict into a semantically dead payload.

```elm
( IO.LambdaSet1 ls1, IO.LambdaSet1 ls2 ) ->
    case ( ls1, ls2 ) of
        ( IO.LsTop, _ ) ->
            merge ctx content                    -- constant; no member work at all

        ( _, IO.LsTop ) ->
            merge ctx otherContent

        ( IO.LsMembers m1, IO.LsMembers m2 ) ->
            case classifySorted m1 m2 of
                SortedEqual -> merge ctx content
                SortedSuper -> merge ctx content        -- m2 ⊆ m1: reuse side 1 AS-IS
                SortedSub   -> merge ctx otherContent   -- m1 ⊆ m2: reuse side 2 AS-IS
                SortedMixed ->
                    merge ctx (IO.Structure (IO.LambdaSet1
                        (IO.LsMembers (unionSortedAsc m1 m2))))
```

Semantic-equivalence note for the reviewer: the old `(T,F)`/`(F,T)` general-branch
results carried dead members under `top=True`; the new arms return plain `LsTop`.
Equivalent by the members-under-⊤ audit (zonk `Store.elm:1174-1175` ignores them;
`applyFactsGo` drops them at `LssInfer.elm:232-233`; the trivial flag short-circuits at
`LssInfer.elm:540`; nothing renders them; un-topping impossible).

### 2.4 Mechanical sites (complete list)

- `Store.elm:499` `Mono.LTop ->` encode: `lsTopContent`'s inner `LambdaSet1 LsTop`
  (slots still get a FRESH VAR each — `freshVarS` per arrow at :511 stays; only the
  CONTENT value is shared).
- `Store.elm:502` `Mono.LSet members ->` encode: `LambdaSet1 (LsMembers members)` —
  the `LSet` list reused by pointer (was `Dict.fromList`, per-arrow-shared).
- `Store.elm:1164-1199` `zonkSetSlot`: `LsTop -> Mono.LTop`; `LsMembers ms ->` if
  `lengthExceeds acc.maxSetSize ms` (early-exit length probe, ≤ cap+1 steps) then
  `Mono.LTop` + `widenedBySize`/`widenedSizeHist` else `Mono.LSet ms` — **identity; the
  store list IS the annotation** (was `Dict.keys`). Ascending order is preserved by
  construction, so `LSet` output is byte-identical.
- `LssInfer.elm:565-571` `zonkSigGo`: `LsTop -> { rep, members = [], top = True }`
  (drops today's dead `CoreDict.keys` under top); `LsMembers ms -> { rep, members = ms,
  top = False }` — pointer reuse. `ArrowFact` shape (`Engine.elm:80-84`) unchanged.
- Pattern-rename only (payload unused): `Store.elm:868` (poisonGo), `Store.elm:1115`
  (zonkFlatC crash arm), `Occurs.elm:82`, `Solve.elm:705, 1165, 1214-1216`,
  `Type.elm:552, 756, 969`. `Solve.elm:1214` rebinds and reconstructs — compiles with
  the new payload unchanged.
- Update the `IO.elm:644-649` doc block and the stale `Unify.elm:757-758` comment
  ("Sets are ≤8 members" is readback-only — verified false as a store invariant;
  say so explicitly).

### 2.5 Counter re-mapping (ride-along of the Phase 2 commit; stats-only)

Phase 1's three write counters cannot express the new arm structure — with only
`skip/flex/slow`, Run C would show `slow → ~0` and hide where the 61,403 went. Re-map:

- `setWriteSkip` — ⊤-absorb (write onto `LsTop`) + `SortedEqual`/`SortedSub` skips.
- `setWriteFlex` — FlexVar adopt, unchanged (⊤-onto-flex included, as today).
- `setWriteTopJoin` (NEW) — ⊤ write onto an `LsMembers` slot (direct set of the
  constant; was slow).
- `setWriteUnion` (NEW) — real member union onto an `LsMembers` slot (direct join;
  was slow).
- `setWriteSlow` — the defensive `_` arm ONLY. **Expected ~0 in Run C**; a sustained 0
  is the evidence to delete the arm in a later commit.

Run C prediction to check: `62 + 61,403` redistributes into `skip + topJoin + union`,
with the skip growth = the write-onto-⊤ waste class from the Run B reading.

### Phase 2 risks and their answers

- **Transient in-store sets are uncapped** (cap is zonk-only, `Store.elm:1184`). List
  worst case is k DISTINCT singleton injections into one slot: O(k²/2) cons vs Dict
  O(k log k). **Decision point RESOLVED (Run B): skip the write-time collapse.** The
  measured tail is 42 sets in 81–97 and none beyond; all >8 widen to `LTop` at readback
  anyway; and the one uncapped consumer channel (signature readback, `zonkSigGo`) is
  empty in practice — all 9,581 signatures trivial — so the collapse would be
  unobservable today and its win is bounded by ~42 slots' worth of cons churn. Not worth
  a semantics-adjacent extra commit. Revisit only if Run C shows list-merge churn, or
  when the GAP-2 flow repairs populate the signature channel (which is also the moment
  `zonkSigGo`'s missing cap must be addressed — see the GAP-2 rider in the mapping doc).
- **Point-mint counts change** (slow-path fresh vars vanish) → later pointKeys shift.
  Verified self-consistent: pointKeys are used only for seen-sets and `revMemo`
  (`Store.elm:279, 1054` — written and read with the same key in the same item), and
  residual MVarIds come from `ZonkCtx.next`, not pointKeys. E9.3 precedent gated the
  same class byte-identical.
- **`(False, [])`**: no live caller produces it (`LssInfer.elm:235` guards non-empty;
  spine passes `[mid]`) — treated as an explicit no-op arm above, preserving the
  `LsMembers`-non-empty invariant.

**Gates (Phase 2):** two-binary identity byte-compare under solver+LSS + census
witnesses (below) + Run C in `benchmarks/lss-opt.md` (plain run vs Run B's row),
expecting minors down and wall judged against the ±3% band. Suites in the final sweep.

**Census gate, split precisely.** These lines are IDENTITY WITNESSES and must match the
old binary's output on the SAME tree exactly: `members`, `signatures`, `sets zonked` +
size histogram, `widened` (all three counters), `widened sizes`, `join flush`, `joins`.
These lines legitimately MOVE and are the change's evidence: `set-writes` (per §2.5's
re-mapping — slow → ~0, the old slow population redistributed into skip/topJoin/union).
Any movement in a witness line means the change was not substrate-only — stop and
diagnose before trusting the byte-compare.

### Phase 2 — LANDED 2026-08-17

Nine files; type-checked first pass. Gates: **two-binary identity byte-identical**
(`eco-lss-p1` vs `eco-lss-p2` on the same tree, 13,728,018 B outputs) and **all 7
witness lines identical** between the two binaries' runs. Suites (ran before the gate
restructure, so banked early): elm-tests 13,104/12; E2E ×3 legs 1,675/1,675 each;
bootstrap deliberately cut short → final sweep.

**The §2.5 prediction resolved, with a finding.** Set-writes old → new on the same tree:
`skip=62 flex=144,151 slow=61,380` → `skip=61,437 flex=144,151 topJoin=5 union=0
slow=0`. The old slow population went almost ENTIRELY to skip: 61,375 of the 61,380
were **concrete member writes onto already-⊤ slots** — each previously minting a fresh
Point + Dict + full `unifyStep` purely to grow dead members under ⊤. Genuine member
unions through this path: **zero** (`union=0`); ⊤-onto-members: 5. So the write path's
"real join machinery" had no real joins to do — multi-member sets form only via slot×slot
unification in Unify's arm, and the entire 61k population is now an allocation-free
skip. `setWriteSlow=0` on the full self-compile: the defensive arm is now MEASURED dead;
one more clean run (Run D) and it can be deleted.

## Phase 3 — Stop copying `S` per set operation

Verified tax: `unifySlotWithSet` copies the full ~30-field `S` on entry (even the no-op
skip) and again on adopt (`Store.elm:767-769, 788`); `Engine.liftIO` copies `S` per UF
op (`Engine.elm:609-616`); **`poisonGo` copies `S` per visited node**
(`Store.elm:833-837`). In-tree precedent for the fix: the M6.0-b `ZonkCtx` rewrite
("a full S-copy per node" → 5-field ctx threaded, one S write-back;
`Store.elm:883-896`) and `LoadCtx` on the load path.

1. **`poisonGo`** (`Store.elm:809-877`): change to thread `( IO.State, Dict Int () )`
   (store + seen) through the worklist, calling a store-level
   `unifySlotWithSetS : Bool -> List Int -> Variable -> IO.State -> IO.State` for the
   FunL arm, and write `S` back ONCE in `poisonArrowSets`. After Phase 2 the store-level
   variant needs no `S` at all on its live arms (the defensive arm is the exception —
   have `unifySlotWithSetS` return a `needsSlow : Bool` and let `poisonArrowSets` route
   those rare slots through the old Step-shaped fallback; expected count 0 by Phase 1).
2. **`spineGo`** (`LssInfer.elm:1026-1072`): same treatment — thread
   `( IO.State, seen )`, one S write-back in `injectSpineMemberId`.
3. **`unifySlotWithSet`** itself: rebuild `S` once per call maximum — the skip path
   should return `s0` with only the (possibly path-compressed) store swapped, and the
   adopt path must not copy twice.
4. `applyFactsGo` keeps Step-shape (its rep-linkage needs `unifyStep`), but its
   `unifySlotWithSet` calls get the single-copy behavior from (3) for free.
5. **Optional instrumentation rider (sizes Phase 5):** while in the load-adjacent code,
   add a `slotsMinted` counter at the `loadTypeC` arrow-slot mint (`Store.elm:146-153`;
   count in `LoadCtx`, fold once at the load boundary like `arrowSlots`). Run B can only
   bound the never-written slot population from zonk-VISITS (482,627 visits vs 205,623
   writes; visits ≠ distinct slots) — `slotsMinted` pins it exactly, which is the number
   Phase 5's case rests on.

**Gates:** pure refactor — two-binary identity + witnesses + plain benchmark run
(Run D row vs Run C). No census movement expected at all (the rider only ADDS a line).
Suites in the final sweep.

## Phase 4 — `joinAnnotationsChanged` + the mint-key `byGlobal` memo

Two independent sub-phases; land separately. Both are byte-identical by construction.

### 4a. Changed-flag annotation join (Run-K `AST_Monomorphized +12 s`)

Verified: `joinAnnotations` (`Monomorphized.elm:1014-1053`) NEVER returns a composite
by pointer — every arm calls a smart constructor (fresh node + hash re-mix; the MRecord
arm `Dict.map`-rebuilds the whole field tree); only the leaf/mismatch `_` arm returns
`a`. So a no-op join on the Registry hit path costs: failed `==` walk + full-tree
rebuild + a SECOND full `==` walk (`joined == storedType`, `Registry.elm:107` — must
traverse everything since the fresh tree shares only leaf pointers) + discard. The
completion join (`Monomorphize.elm:572`) runs UNCONDITIONALLY per completed
body-bearing spec with no short-circuit at all.

**Priority order, set by Run B: the COMPLETION site first.** `completion=33,541` is 7×
`noop=4,566`, and with only ~3.4k changed events in the whole run the completion joins
are presumptively almost all no-ops — that site's rebuild elision is 4a's dominant
payoff. Implement `joinAnnotationsChanged`, convert the completion site, land the
`completionJoinNoop` counter (free from the flag), and only then convert the Registry
site — the same helper serves both, but if anything forces a split, the Registry half
is the one to defer.

**Non-target, noted so nobody chases it:** `identical=80,869` looks like 80k successful
deep `==` walks, but K6 hash-conses zonked composites (`consC → Intern.hashCons`,
`Store.elm:908-918`), so identical demands largely settle on the kernel pointer fast
path at or near the root. Verify with a profile before ever optimizing this branch; it
is likely already cheap.

**Build** in `Monomorphized.elm`, next to `joinAnnotations` (which stays, for its one
GlobalOpt caller `MonoGlobalOptimize.elm:277` and as the spec of the semantics):

```elm
{-| joinAnnotations with pointer-preserving no-op detection.
( False, t ) means t IS the first argument BY POINTER (nothing to add).
SOUNDNESS LAW: the flag must NEVER be falsely False — a narrower stored
annotation is the LSS_010 silent-miscompile. Falsely True is sound and costs
one spurious markDirty/retranslation. Every shortcut errs toward True.
-}
joinAnnotationsChanged : MonoType -> MonoType -> ( Bool, MonoType )
```

Implementation discipline is the in-tree collect-and-patch pattern
(`TypeSubst.elm:148-196`, `listMapChanged`/`dictMapChanged`, from
`plans/dict-map-changed-efficiency.md`):

- Per composite arm: join children via a `listJoin2Changed` helper (map2 with an
  anyChanged flag, returning the ORIGINAL child list when no element changed);
  MRecord via the `dictMapChanged` discipline (fold `Dict.insert` of changed values
  into the ORIGINAL dict — key set identical by the layout-match contract, so canonical
  field ordering for the hash fold is preserved).
- Per arrow: `annoCovers annoA annoB` — allocation-free: `LTop` covers everything;
  `LSet xs` covers `LSet ys` iff sorted `ys ⊆ xs` (merge-scan); `LSet` never covers
  `LTop`. If covers AND no child changed → `( False, a )` — no smart constructor, no
  re-hash. Else rebuild that spine only (`unionAnno` as today); unchanged siblings stay
  pointer-shared, which also lets future `==` probes settle on the kernel pointer
  fast path.
- Mismatch/leaf arm: `a == b -> ( False, a )`; else `( True, widenSets a )` (rare;
  falsely-True acceptable).
- Do NOT use hash equality to skip: the packed hashes are 26-bit with a documented
  one-directional contract (`Monomorphized.elm:290-293`) — collisions are certain at
  self-compile scale and a false skip is the LSS_010 miscompile. (The sound direction —
  unequal root hash ⇒ unequal — is already free inside `==`.)

**Consume** at both call sites:

- `Registry.getOrCreateSpecIdKeyed` (`Registry.elm:104-117`): replace the join + second
  `==` with `joinAnnotationsChanged storedType storeType`; `( False, _ )` →
  `HitNoopJoin` (registry untouched); `( True, joined )` → write, `HitChangedJoin`.
  Keep the `:98` identical-`==` short-circuit (cheapest exit).
- `processItem` completion (`Monomorphize.elm:568-577`):
  `joinAnnotationsChanged actualType storedT`. **Careful — the flag does NOT mean
  "skip the write" here**: `( False, _ )` means the result is `actualType` by pointer
  (storedT contributed nothing), but the registry currently holds `storedT`, so
  `updateRegistryType` must still run with `actualType`. The win at this site is the
  rebuild elision only.

**Gates:** two-binary identity + witnesses; the Phase-1 counters now decompose:
`joinNoop` converts from "rebuild + double-walk" to near-free, and a new
`completionJoinNoop` (free from the flag) lands alongside. Run E. Suites in the final
sweep.

### 4b. Mint-key memo (Run-K `AST_TypedOptimized +13.9 s`)

Verified shape of the waste: `TOpt.toComparableGlobal` (`TypedOptimized.elm:312-314`)
allocates a fresh ~25-50-char string per call (5 concats via
`ModuleName.toComparableCanonical`); every `VarGlobal` occurrence visit builds it
**twice** (mint key at `LssInfer.elm:666` + `kernelAliasOf`'s `DMap.get` probe at
`LssInfer.elm:957`); the key is built EAGERLY before the `canTypeIsArrow` guard
(`LssInfer.elm:979`), so non-arrow occurrences pay both builds for nothing; the
Translate-side arms (`Translate.elm:3095-3108`) repeat this per argument per spec
translation and per LSS_010 re-translation; and `memberIdFor`'s `byKey : Dict String`
probe (`Engine.elm:638-655`) only avoids re-MINTING, never the string build. (Note:
spec keys are innocent — `toComparableSpecKey` is dead code; the registry has been
hash-keyed since K4, `Registry.elm:56/94`.)

1. **`TOpt.globalHash : Global -> Int`** in `TypedOptimized.elm` — mechanical twin of
   `Mono.globalHash` (`Monomorphized.elm:720-742`: name hashed char-by-char via
   `String.foldl mixHash`, canonical contributes lengths only; its doc already states
   it is cheaper than the string build).
2. **`LssMemberTable` gains two memo maps** (`Engine.elm:141-144` — a nested record,
   NOT a new top-level S field, so the 32-slot cap is respected):

   ```elm
   type alias LssMemberTable =
       { byKey : CoreDict.Dict String Int
       , sources : CoreDict.Dict Int MemberSource
       , byGlobal : HashMap TOpt.Global GlobalMint   -- VarGlobal path (g|/k| after alias fold)
       , byCtorGlobal : HashMap TOpt.Global Int      -- VarEnum/VarBox path (c| namespace)
       }

   type GlobalMint
       = MintGlobal Int                    -- g| member
       | MintKernel Int                    -- k| member (kernel-alias folded)
   ```

   Two maps because the SAME `Global` legitimately mints in two namespaces (`g|G` from
   `VarGlobal` vs `c|G` from `VarEnum`/`VarBox`) — one keyed map would conflate them.
   `HashMap` = the existing hash+eq-parameterized `Data/HashMap.elm`; hash =
   `TOpt.globalHash`, eq = `==`.
3. **One memoized resolver in `LssInfer`** (it owns `kernelAliasOf` and both phases'
   arms route through it):

   ```elm
   mintStandaloneGlobal : TOpt.Global -> Step GlobalMint
   -- probe byGlobal; on miss run TODAY'S path verbatim
   -- (kernelAliasOf → "k|"++home++"."++name → kernelMemberIdFor
   --  | else "g|"++toComparableGlobal g → standaloneMemberIdFor),
   -- then insert the result. First occurrence mints in exactly today's order
   -- ⇒ member ids unchanged ⇒ byte-identical.

   mintCtorGlobal : TOpt.Global -> Step Int   -- same shape over byCtorGlobal / "c|"
   ```

   Convert the callers: `LssInfer.elm:649-673` (VarGlobal/VarEnum/VarBox arms) and
   `Translate.elm:3095-3108` (`injectArgLambdaMember` arms). The cached `MintKernel`
   arm also eliminates the second string build (`kernelAliasOf` probe) on every hit.
4. **Move the mint below the arrow guard**: restructure `standaloneMemberWith`
   (`LssInfer.elm:971-993`) to take a request value instead of a pre-applied `Step Int`
   — `type MintReq = ReqGlobal TOpt.Global | ReqCtor TOpt.Global | ReqKernel String
   ( Name, Name, Name ) | ReqAccessor String` — resolving it only AFTER
   `canTypeIsArrow meta.tipe` passes. Today non-arrow occurrences (most data
   references) pay two string builds and zero lookups.
5. **Optional, same pattern, measure first** (skip if Phase-1 numbers say it's noise):
   `specCountByGlobal : CoreDict String Int` (`Engine.elm:337`, gkey built per enqueue
   at `Engine.elm:873-874`) → `HashMap Mono.Global Int` with the existing
   `Mono.globalHash`; `lssSignatures : CoreDict String LssSignature`
   (`Engine.elm:348`, gkey per `signatureFor` call at `LssInfer.elm:68-73`) →
   `HashMap TOpt.Global LssSignature`.

**Gates:** two-binary identity + witnesses (id-order preservation is the argument —
state it in the commit); Run F. Suites in the final sweep.

## Phase 5 — DEFERRED: lazy leaves + shared callable-free clones (own plan when picked up)

The load-layer redesign (Roc's `contains_callable` shared clones + lazy `.mono` leaves,
grounded at `roc/src/postcheck/lambda_solved/solve.zig:113-135, 1355-1376, 2943-2953`)
attacks what this plan does not: LSS_006 fresh-structure-per-load and the
load-purely-to-poison waste (`poisonCallBoundary` loads every kernel-call argument's
full type to walk it, `LssInfer.elm:860-877`). Two verified blockers make it a separate
design: the store is PER-ITEM (`resetItem` wipes it, Points are dense per-item indices —
`Engine.elm:967-969, 373` — so cross-item sharing needs a store-lifecycle change), and
`Record1×Record1` unification REBUILDS content referencing the other side's Points
(`Unify.elm:886-897`) — shared ground records are content-safe but identity-entangling.

**Run B already made the case stronger than anticipated:** 70.1% of set writes land on
fresh slots and 78.0% of slot zonk-visits read ⊤/unconstrained — the load layer mints
far more set machinery than facts ever touch, and none of Phases 2-4 reduces the mint
count. Phase 5 stays sequenced AFTER 2-4 (they are cheaper and independent), but it is
no longer speculative: draft its plan once Run C/D land, using the Phase-3 `slotsMinted`
rider to size the dead-slot population exactly.

## Measurement protocol (Phases 2-4)

**`benchmarks/lss-opt.md` is the protocol** — this track created it. Each phase lands
one PLAIN run (one cold leg, solver+LSS workload, no A/B — these are unflagged changes)
recorded as the next row: Run C = Phase 2, Run D = Phase 3, Run E/F = Phase 4a/4b.
Compare against the previous row per that file's rules (quote both rows' `out.mlir`
sizes; judge counters first, wall second; never quote a wall without its majors). The
**identity gate is separate from the benchmark**: old binary vs new binary on the SAME
tree must byte-match (the Phase-1 landing note shows the recipe) — the benchmark rows
are two different trees and prove nothing about identity.

## Final correctness sweep (once, after all phases)

Run after Phase 4b lands, against the cumulative tree:

1. elm-tests — expect the 13,104/12 baseline (12 known TYPE_007 failures).
2. Full E2E ×3 legs: default / `ECO_CSE=1` / `ECO_LIST_MAP_TEMPLATE=1`, purging
   `build/test/*/eco-stuff` between legs — expect 1,675/1,675 each.
3. Bootstrap (solver+LSS) — Stage-8c fixed point (a NEW fixed point; the corpus grew).
4. One final identity re-check: the PRE-Phase-2 binary (`eco-lss-p1`, kept) vs the
   final binary on the final tree — byte-identical proves the whole series was
   solver-internal end to end, not just each increment.

Partial credit already banked (2026-08-17, before the restructure): Phase 2's tree
passed elm-tests 13,104/12 and all three E2E legs 1,675/1,675; only the bootstrap was
cut short. Those results cover Phases 1-2; the sweep re-covers everything.

## Done when

Phases 1-4 landed, each with its identity gate green; the final correctness sweep
green; the census shows `setWriteSlow = 0` sustained, `joinNoop`/completion joins
converted to pointer-returns, and minors/GC time visibly down across Runs B→F;
findings and numbers recorded in this file per phase; Phase 5 explicitly re-scoped or
parked with the post-Phase-4 census attached.
