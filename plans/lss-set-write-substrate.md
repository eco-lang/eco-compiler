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

**Gate structure (restructured again 2026-08-17, v2 — supersedes the per-phase-gate
structure Phases 1-2 ran under):** phases land back-to-back with NO per-phase
correctness gates. Per phase, only: type-check/build, the phase's single plain benchmark
run (its row in `benchmarks/lss-opt.md`), and a `cp` of the built binary to `eco-lss-pN`
— then straight on to the next phase. ALL correctness gates — the two-binary identity
byte-compare (OLD-binary output vs NEW-binary output on the same tree; byte-identity
across a SOURCE change is unsatisfiable), the census witness-line compare, elm-tests,
E2E ×3 legs, bootstrap Stage-8c — run ONCE in the **final gate sweep** (section at the
end) after Phase 4b lands. Rationale: minimum wall-clock to a fully-benchmarked stack;
every phase is designed byte-identical, so ONE end-to-end identity proof (pre-series
binary vs final binary on the final tree) covers the whole series, and the kept
per-phase binaries form the bisection ladder if it fails. Accepted trade-off: a defect
surfaces only at the sweep and is attributed by bisection, not immediately. Precedent
that Point-mint elision passes the identity gate: E9.3 v1.1 shipped fresh-var elision
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

**Per-phase (fast):** type-check/build; Run D row vs Run C; `cp` the binary to
`eco-lss-p3`. All correctness gates are in the final sweep. Note for the sweep: this is
a pure refactor, so NO census movement is expected at all (the rider only ADDS a line) —
any witness-line or set-write/join-counter movement at the sweep bisects to this phase.

### Phase 3 — LANDED 2026-08-17

All five items in. `SetWriteCtx` (`Store.elm:829-841`) is the shared vehicle —
`{ store, skip, flex, topJoin, union, needSlow }` — folded into `S` exactly once per
traversal by `foldSetWrites` (`Store.elm:847-874`). `poisonGoC` (`Store.elm:1002`) and
`spineGoC` (`LssInfer.elm:1044`) thread it through their worklists, so the S copy per
VISITED NODE is gone; `unifySlotWithSet` is now a one-line wrapper over
`unifySlotWithSetC` rebuilding `S` once per call; `applyFactsGo` keeps Step-shape as
planned. The rider is `LoadCtx.slotsMinted` (`Store.elm:73`, bumped at the FunL mint
`:199`) folded into `LssStats.slotsMinted` at all four `loadTypeC` boundaries, each
guarded by `if c.slotsMinted == 0` so the lss-off path pays nothing.

Two semantics notes for the reviewer. (1) The defensive `_` arm no longer runs inline —
it defers via `needSlow` to the Step-shaped fallback at the traversal boundary, which
REORDERS such writes to traversal end. Unobservable while the arm stays dead, and Run C
measured `setWriteSlow=0` across the full self-compile. (2) `unifySlotWithSetC` splits
Phase 2's single union arm into `SortedSuper` (adopt the caller's `members` list by
pointer — the union IS that list when `cur ⊆ members`, so no merge allocation) and
`SortedMixed` (`unionSortedAsc`). Same set, one fewer allocation on the superset case.

**Run D verdict: cost-neutral, and the wall move is not the refactor.** Wall
319.7→331.1 s (+3.6%) sits just above the band but is entirely major GC (majors 12→14,
major GC time 33.78→46.61 s), while **minor GC time FALLS (84.75→83.60 s) and true
mutator is flat at 200.81→200.57 s**. Minors (1375→1378) and promoted (+1.0%) barely
move. So the eliminated S copies do not register at this granularity: the ~32-field copy
per visited node was real, but this workload is not bound by it. This is the third
datapoint in the same pattern as the kernel-boundary and compare-elision series —
**removing work the workload is not bound by buys nothing.** Keep Phase 3 on structural
grounds (it makes these traversals cheap to extend and is a prerequisite for touching the
load layer), not as a measured win.

**The rider is the real finding, and it is large.** `slotsMinted=957,478` against 205,646
total set writes: **78.5% of minted arrow slots are never written at all.** That
independently corroborates Run B's 78.0% ⊤/unconstrained zonk reads from the opposite
side (mint vs read), and pins the number Phase 5's case rests on — the load layer mints
~4.7 arrow slots for every one that ever receives a fact. Phases 2-4 all optimize the
write and join paths; none of them reduces this. **Phase 5 is where the remaining
substrate cost lives**, and Run D says the write-side well is now dry.

## Phase 4 — `joinAnnotationsChanged` + the mint-key `byGlobal` memo

Two independent sub-phases; land separately. Both are byte-identical by construction.
(4c added 2026-08-17 after Run F: the string-build class 4b targeted is real but its
owner is `env.toptNodes` — see 4b's landing note and 4c below.)

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

**Per-phase (fast):** type-check/build; Run E; `cp` the binary to `eco-lss-p4a`. The
Phase-1 counters decompose here — `joinNoop` converts from "rebuild + double-walk" to
near-free, and a new `completionJoinNoop` (free from the flag) lands alongside — so read
those in Run E's census. Correctness gates in the final sweep; this is the phase whose
SOUNDNESS LAW (never falsely False) the sweep's identity gate actually tests, so if the
sweep fails, bisect here first.

### Phase 4a — LANDED 2026-08-17

`joinAnnotationsChanged` (`Monomorphized.elm`, next to `joinAnnotations`, which stays for
its GlobalOpt caller and as the spec) with `joinListChanged` / `joinFieldsChanged` /
`joinWidened` / `annoCovers` / `sortedSubsetOf`. Consumed at both sites: the registry hit
path (`Registry.elm`, replacing the join + second `==` walk) and the `processItem`
completion join (`Monomorphize.elm`, where the flag does NOT gate the write — the registry
holds `storedT`, so `updateRegistryType` still runs; the win is the elided rebuild only).
The completion join is now computed ONCE and its flag feeds both the write and the census.

**Stronger than the plan asked for: the flag is EXACT, not merely never-falsely-False.**
The returned tree is structurally what `joinAnnotations` returns and the flag is exactly
`result /= a`. Two design points make that hold: `annoCovers annoA annoB` decides precisely
`unionAnno annoA annoB == annoA` (`LTop` covers all; `LSet` never covers `LTop`; otherwise
an ascending subset merge-scan), and every mismatch arm routes through `joinWidened`, which
compares its widened result against `a` rather than assuming widening changed something —
`widenSets` is identity on leaves and on already-`LTop` trees. Exactness is deliberate and
load-bearing: the plan's "falsely True is sound, it just costs one spurious
markDirty/retranslation" is TRUE per event but NOT safe as a steady state — a falsely-True
flag at the registry site writes and marks dirty on *every* hit of that spec, and the join
flush would never converge. Do not relax this to a conservative approximation.

**Run E verdict: the census is the result.** `completionNoop=33,543` of `completion=33,547`
— **99.99% of completion joins add nothing; exactly FOUR change the stored type in the whole
self-compile.** That site was rebuilding a full type tree (fresh nodes, re-mixed hashes) and
discarding it, unconditionally, once per completed body-bearing spec. The registry path's
`noop=4,565` sheds its rebuild-plus-second-`==`-walk as well. Measured effect: **promoted
13,071 → 12,818 MiB (−1.9%)**, the lowest of Runs C/D/E, which is what rebuild elision should
do; majors 14→12 and wall −4.3%, but true mutator is FLAT (200.57→199.70 s), so the wall
figure is mostly the major-count lottery reverting and should not be banked.

**Note for the final sweep.** Run B/D's `completion` counts made this look like a
33.5k-event *join* population; it is really a 4-event join population wearing 33.5k
rebuilds. If the sweep's identity gate ever fails, this is the first phase to bisect — it is
the only one in the series whose correctness rests on a flag rather than on a
representation.

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

**Per-phase (fast):** type-check/build; Run F; `cp` the binary to `eco-lss-p4b`.
Correctness gates in the final sweep — id-order preservation is the identity argument
(first occurrence mints in exactly today's order), so state it in the commit and expect
the sweep's `members` witness line to carry the proof.

### Phase 4b — IMPLEMENTED AND MEASURED 2026-08-17: **NO-GO as specified**

Built exactly as planned: `TOpt.globalHash`, `LssMemberTable.byGlobal`/`byCtorGlobal`
(nested record, no new S field), `mintStandaloneGlobal`/`mintCtorGlobal` in `LssInfer`,
the `MintReq` restructure moving key construction BELOW the `canTypeIsArrow` guard, and
the `Translate` arg-side arms converted to share the same memo. Item 5 (specCountByGlobal
/ lssSignatures) deliberately not attempted. Type-checks clean; **Run F says revert it.**

**Run F, and it is the cleanest comparison in the series: majors are 12 in BOTH E and F**,
so nothing here is the trigger lottery. Promoted 12,818 → 13,073 MiB (+2.0%), minors
1377→1385, true mutator 199.70 → 204.43 s (+2.4%), wall +1.9%. `out.mlir` grew +15,073 B
(+0.11%) — real, since the memo is new compiler source — but 0.11% more corpus cannot buy
2.4% more mutator.

**Why, and it is a flaw in the plan's premise, not the implementation.** §4b counted TWO
`toComparableGlobal` builds per `VarGlobal` occurrence (the mint key and `kernelAliasOf`'s
probe) and memoized both away. It missed a THIRD on the same path:
`spineDepthForGlobal` → `declaredArityOf` calls
`DMap.get TOpt.toComparableGlobal g s.env.toptNodes`, once per occurrence and again per
`Link` hop. `DMap` re-derives its comparable key on EVERY operation — that is the whole
reason `Data.HashMap` exists (K4) — so the dominant build survives the memo untouched,
while the memo adds two `HashMap` probes and an insert per occurrence on top. The net is
the measured 2.4%.

**The real target is `env.toptNodes`.** It is a `DMap` keyed by `toComparableGlobal` and it
is consulted on every occurrence by `declaredArityOf`, `kernelAliasOf`, `signatureFor`, and
the node lookups at `LssInfer.elm:85/185/319`. Converting THAT to
`HashMap TOpt.Global` with `TOpt.globalHash` (which 4b already built and which is the one
piece worth keeping) removes every build on the path at once, and makes the mint-key memo
either unnecessary or nearly free. That is a different, larger change than 4b as written —
give it its own plan entry and its own run rather than tuning this one.

**Disposition: REVERTED 2026-08-17** (user decision), fully — including `TOpt.globalHash`,
so the corpus returns to exactly the Run E tree and later rows stay comparable. Do NOT
carry 4b into the final sweep: it was a measured 2% regression on promoted with the major
count held constant, and the sweep's identity gate would only have told us it was
*correct*, not that it was worth having.

`globalHash` is the one piece the `toptNodes` conversion will want back, and there is no
git in this container, so it is preserved here verbatim rather than lost:

```elm
{-| A cheap structural hash of a `Global`, for `Data.HashMap` keys. Mechanical twin of
`Monomorphized.globalHash` (deliberately duplicated — `Monomorphized` imports
`TypedOptimized`, so the hash cannot be shared from there). Hashes the NAME char-by-char
but takes only the LENGTHS of the canonical's parts: the module path is what makes
`toComparableGlobal` expensive. Collisions are resolved by `Data.HashMap`'s per-bucket
`eq`, so a coarse hash costs performance, never correctness.
-}
globalHash : Global -> Int
globalHash g =
    case g of
        Global (IO.Canonical ( author, project ) modName) name ->
            globalMixHash
                (globalMixHash
                    (globalMixHash (globalMixHash 21 (String.length author)) (String.length project))
                    (String.length modName)
                )
                (String.foldl (\c h -> globalMixHash h (Char.toCode c)) 23 name)


globalMixHash : Int -> Int -> Int
globalMixHash h x =
    -- 2^26, matching Monomorphized.hashBase: two of these pack into 2^52, inside the
    -- exact-integer range of both the native i64 and the JS double.
    modBy 67108864 (h * 33 + modBy 67108864 x + 7)
```

### 4c. Convert `env.toptNodes` from `DMap` to `HashMap TOpt.Global` (supersedes 4b)

**The finding that motivates it (Run F forensics, all verified 2026-08-17):**
`Data.Map` re-derives its comparable key on EVERY operation —
`get toComparable targetKey (D dict) = Dict.get (toComparable targetKey) dict`
(`Data/Map.elm:get`) — and `env.toptNodes` is a `DMap.Dict String TOpt.Global (TOpt.Node
TypeIds.MVarId)` (`Engine.elm:335`) consulted on the hottest occurrence paths. So every
probe builds a fresh ~25-50-char `toComparableGlobal` string. 4b memoized two builds per
`VarGlobal` occurrence and missed the `declaredArityOf`/`kernelAliasOf` probes entirely;
converting the MAP kills every build at once and needs no memo, no `MintReq` restructure,
and no per-occurrence bookkeeping.

**The change is one field type, one construction fold, and nine mechanical get sites.**
Exhaustive grep (2026-08-17): `env.toptNodes` is **get-only** in the solver — no
`foldl/keys/values/toList/map/filter/union` anywhere — which is what makes this
byte-identical by construction (`HashMap` iteration is insertion-ordered, but nothing
ever iterates this map). The subst pipeline's `state.ctx.toptNodes`
(`Compiler/Monomorphize/State.elm:179`, consumers in `Specialize.elm`) is a DIFFERENT
map and stays untouched; `TOpt.GlobalGraph`'s own `Data.Map` and the pre-`initState`
consumers (`EntryPrep.insertFlagsDecoderNode`, `findEntryPointId`, `seedFlagsDecoder` —
all on the raw `nodesWithIds` value, `Monomorphize.elm:70-105, 332-338`) also stay on
`DMap`; only the solver Env field converts.

1. **Restore `TOpt.globalHash`** exactly as preserved verbatim above (in
   `TypedOptimized.elm` next to `toComparableGlobal`; add `globalHash` to the exposing
   list). `globalMixHash` stays private.
2. **`Engine.elm:335`**: field becomes
   `toptNodes : HashMap.HashMap TOpt.Global (TOpt.Node TypeIds.MVarId)`; re-add
   `import Data.HashMap as HashMap`.
3. **Construction** — `initState` (`Monomorphize.elm:254`) converts ONCE at init, O(n)
   over ~10-20k globals (noise against 100k+ occurrence probes saved):

   ```elm
   { toptNodes =
       DMap.foldl TOpt.compareGlobal
           (\g node acc -> HashMap.insert TOpt.globalHash (==) g node acc)
           HashMap.empty
           nodes
   ```

   (`DMap.foldl` ignores its ordering argument — `Data/Map.elm:240-242` — it is passed
   for documentation only. `initState`'s `nodes` PARAMETER keeps its `DMap` type;
   `seedFlagsDecoder` consumes that raw value, not the Env field.)
4. **The nine get sites**, each
   `DMap.get TOpt.toComparableGlobal g s.env.toptNodes` →
   `HashMap.get TOpt.globalHash (==) g s.env.toptNodes`:
   - `LssInfer.elm:85` (`signatureFor` Link chase — cold, per signature miss)
   - `LssInfer.elm:319` (`resolveUnit` — cold)
   - `LssInfer.elm:937` (`declaredArityOf` — **HOT: per arrow-typed occurrence via
     `spineDepthForGlobal`, again per `Link` hop; the Run-F culprit**)
   - `LssInfer.elm:964` (`kernelAliasOf` — **HOT: per `VarGlobal` occurrence, both the
     inference walk and the Translate arg arm**)
   - `Monomorphize.elm:719` (Link chase in node dispatch)
   - `Monomorphize.elm:783` (`resolveGlobalNode` — D13 memo MISS path only)
   - `Monomorphize.elm:1124` (`ctorBackedGlobal` — finalization; it and `globalOrigin`/
     `buildMemberOrigins` take `toptNodes` as a PARAMETER (`:1044, 1054, 1110`), so
     their parameter types change with it)
   - `Translate.elm:2177` (`isCtorNode`), `Translate.elm:2199` (`isBodyNode`)

**Identity argument (state it in the commit).** (a) Get-only: no iteration, so
`HashMap`'s insertion order never leaks. (b) Key equivalence: `toComparableGlobal` is
injective — module paths may contain dots but Elm value/ctor NAMES cannot, so the final
`"." ++ name` segment parses unambiguously — hence string-equality ⟺ structural
`(==)` on `TOpt.Global`, and every lookup returns exactly what it returned before.
(c) `nodeResolution`, `lssSignatures`, and every other string-keyed memo are untouched.
Byte-identical by construction; the sweep's identity gate verifies it.

**What this deliberately does NOT do** (each a separate decision AFTER Run G):

- The mint-key build (`"g|" ++ toComparableGlobal g` at `LssInfer.elm:673/677/680` and
  Translate's arg arms) still runs per occurrence, and `memberIdFor`'s
  `byKey : Dict String` probe still hashes that string. 4c kills two of the three
  builds on the occurrence path. If Run G moves, re-try the two cheap remnants of 4b
  ON TOP of 4c — the below-the-guard `MintReq` move (costless by construction) first,
  the `byGlobal` memo only with Run G evidence that the remaining build still shows.
- `resolveGlobalNode` builds its `gkey` per CALL for the `nodeResolution` memo probe
  (`Monomorphize.elm:773-776`) — per spec resolution, not per occurrence; convert that
  memo to `HashMap TOpt.Global` only if a profile ever names it.
- `signatureFor`'s per-call `gkey` (`LssInfer.elm:70-73`) — same deferral (4b item 5).

**Per-phase (fast):** type-check (`build/toolchain/bin/elm make` — seconds); build;
**Run G** row vs Run E (Run F's tree is reverted; the comparison base is E). `cp` the
binary to `eco-lss-p4c`. Quote both rows' `out.mlir` (this adds compiler source; expect
a few KB). **Run G is the clean test of the whole string-build thesis**: if promoted and
true mutator do not move against E, the `toComparableGlobal` cost class is noise at this
workload's scale — retire it, do NOT proceed to the 4b remnants, and strike the
`env.toptNodes` conversion from the sweep set by reverting it too. Correctness gates in
the final sweep.

#### Phase 4c — IMPLEMENTED AND MEASURED 2026-08-17: thesis REFUTED, memory win only

Built exactly as specified above: `TOpt.globalHash` restored, `Env.toptNodes` retyped, the
one-shot `DMap.foldl` conversion in `initState`, and all nine get sites converted (plus the
three `toptNodes`-parameter signatures in `Monomorphize.elm`). Type-checked first pass.
Re-verified before building: the map is still **get-only** — no `HashMap.foldl/keys/values/
toList` anywhere — so insertion order cannot leak and the identity argument holds.

**Run G: a net win, but NOT by the mechanism this phase was designed around.** Majors are 12
in both E and G, so nothing here is lottery. Wall 317.0 → 311.5 s decomposes cleanly as
**GC −6.26 s against mutator +0.85 s** — the entire gain is GC, split major −4.18 s (−12.4%
at an unchanged major count) and minor −2.08 s, alongside **max RSS −4.1% (−259 MB)**.

**TWO mechanisms were proposed for this phase and BOTH are refuted. Read this before
building on Run G.**

(1) The *per-probe build* thesis — that rebuilding `toComparableGlobal` on every `DMap`
operation was a live cost — is **REFUTED**. `Minor GC cycles` is this track's stated
allocation-pressure proxy and it moved 1377 → 1376 (0.07%), so the ~100k+ discarded key
strings were never meaningful nursery pressure; promoted moved −0.3% for the same reason
(they die young and are never promoted). Do NOT attempt the 4b remnants (the `MintReq` move,
the `byGlobal` memo) or the `nodeResolution`/`lssSignatures` conversions (4b item 5).

(2) The *key-retention* thesis — that `Data.Map`'s `Dict comparable (k, v)` holding a
materialized 25-50-char key per entry was the memory win — was this note's first explanation
for RSS −4.1% and major GC −12.4%, and it is **ALSO REFUTED**, on two independent counts.
**Arithmetic:** ~15-50k globals × ~50-100 B of retained key is **1-5 MB**, two orders of
magnitude short of the observed 259 MB. **Lifetime:** `initState` converts a COPY into the
Env, and `Builder/Generate.elm:794-801` holds `typedGraph` — hence the original `DMap` and
every one of its key strings — live across the entire monomorphization call. Nothing is
freed; if anything 4c ADDS a second copy of the key set to the live heap.

**So the RSS and major-GC movement is UNEXPLAINED.** With both candidate mechanisms dead,
the likeliest cause is heap-growth/GC-timing variance, which peak RSS is well known to be
sensitive to at n=1. **Treat Run G as FLAT** — consistent with the whole `toComparableGlobal`
cost class being noise at this workload's scale. Before anyone cites Run G's memory numbers,
run the SAME `eco-lss-p4c` binary a second time and compare RSS against itself; a swing of
the same order settles it as variance. That is a purpose-built variance check, not a
"run until it looks good" — record it as such.

**Run H RESOLVED this (2026-08-17): not variance.** The re-leg reproduced max RSS to 0.007%
with identical counters and byte-identical output — RSS is deterministic per (binary × tree).
Run G's −259 MB vs Run E is REAL; its mechanism remains unknown (the retention arithmetic
still caps that story at 1-5 MB; plausibly a small live-heap change moving a heap-growth
quantization step). The TIME verdict is unchanged — flat — and the disposition stands.
Parked; do not spend further runs on it.

**Disposition: KEPT (user decision, 2026-08-17)** — on code-quality grounds (the Env no
longer re-derives a key it does not need), NOT on measured performance. The phase's
performance conclusion is FLAT.

**Do NOT generalize this to other string-keyed `DMap`s on the strength of Run G.** Beyond the
dead mechanism there is a hard correctness gate: `Data.HashMap` iterates in INSERTION order
while `DMap` iterates lexicographically, and the large per-global maps ARE folded —
`TypedOptimized.elm:1704-1716` folds both `nodes` and `annotations` to build the serialized
string table, and `Builder/GraphAssembly.elm:135,155` folds nodes — so converting them
changes artifact bytes. The only conversions that are byte-safe are get-only Env-side views
like this one, and those are exactly the ones that free nothing.

## Phase 5a — Load-layer sizing census (measure BEFORE designing Phase 5)

**Why this phase exists (added 2026-08-17, after Runs F and G).** Every argument for
Phase 5 so far is a RATIO: 70.1% of set writes land on fresh slots (Run B), 78.0% of
slot zonk-visits read ⊤/unconstrained (Run B), 78.5% of minted arrow slots are never
written (Run D). None is a MAGNITUDE. This track has now had four consecutive phases
where a compelling ratio met a magnitude and lost (2/3 cost-neutral-or-flat on time,
4b a regression, 4c's both proposed mechanisms refuted) — and the repo precedent is the
kernel-boundary census, which measured the whole boundary at 3.26% of CPU and retired
the activity before more work was spent. 5a buys the magnitudes: against Run G's own
denominators, 957,478 dead slots stand against 1,065,588,259 copied-in-nursery objects
— possibly ~0.1% of allocation, possibly several percent once all load-path Points are
counted. Nobody knows today, and Phase 5 is a store-lifecycle redesign — the most
expensive thing this plan could green-light. Counters first.

**The three questions, pre-registered so the answers cannot be argued around:**

- **Q1 (Points):** how many Points does a run mint in total, and what share is the load
  path? (`slotsMinted` counts only arrow SLOTS — a bare `a -> b` mints 4 Points of
  which the slot is 1, and data-heavy types mint many with no slot at all.)
- **Q2 (allocation share):** what fraction of the run's OBJECTS is that? Denominators
  from the same leg's GC dump (`copied-in-nursery`, `promoted`).
- **Q3 (time share):** how much of the ~200 s true mutator — flat across every run
  C→G — is monomorphization AT ALL, and what does the profiler name inside it?

### Work items (all stats-only; census lines ADD, no witness line is mutated)

0. **Run H — variance re-leg, rides along free.** Before building the census binary,
   re-run the UNCHANGED `eco-lss-p4c` binary once, cold, and record the row. This is
   the purpose-built variance check the 4c note demands: if max RSS / major-GC time
   swing by the same order as Run G's unexplained −259 MB, Run G's memory movement is
   settled as noise. One leg, pre-committed — not "runs until it looks good".
1. **`pointsMinted` (load path):** bump per `freshVarC` (`Store.elm:275-281`) via a
   `LoadCtx` field, folded into `LssStats` at the four `loadTypeC` boundaries in the
   SAME S write each boundary already makes (`slotsMinted` discipline,
   `Store.elm:82-95`). Verify at edit time that `loadVarC` and `structC` both route
   through `freshVarC` (they appear to; if any arm mints directly, bump there too).
   Unlike `slotsMinted` this is nonzero on ~every load, so the `== 0` guard never
   saves the `lssStats` sub-record copy — accepted, one copy per load CALL, the same
   cost class Phase 1 accepted on the D2 path.
2. **`pointsTotal` + `items`:** the store's Point indices are dense —
   `newPointCell` returns `Array.length s.ioRefsPoint` (`Data/IORef.elm:56-61`) — so
   `Array.length store.ioRefsPoint` at each store WIPE is the finished item's exact
   total including every Unify-internal mint, at O(1) per item and no per-mint cost.
   Sample at all places `S.store` is replaced by `freshStore` (exhaustive grep:
   `resetItem` `Engine.elm:1063-1065`, both swap and restore in `withScratchStore`
   `Engine.elm:756-775`) plus once at drain end; accumulate `pointsTotal` and bump
   `items`. Then `pointsTotal − pointsMinted` = the unify/demand-encode residual.
3. **`poisonLoads` / `poisonPoints`:** at the two load-purely-to-poison sites
   (`poisonCallBoundary` and `poisonArgList`, `LssInfer.elm` ~850-885 — re-verify
   lines), count the loads and capture each load's minted Points as the O(1)
   `Array.length` delta around the `Store.loadType` call. This is the exact size of
   the class Phase 5's shared clones would eliminate FIRST.
4. **Load entry-point counts:** one bump in each of the four wrappers
   (`loadType`/`loadTypeWithArrows`/`loadTypeIsolated`/`loadTypeIsolatedWithArrows`,
   `Store.elm:77/104/129/157`). The isolated variants are the LSS_006
   fresh-per-call-site population; the memo-shared variants are not — the split says
   which of Phase 5's two mechanisms (sharing vs laziness) the workload actually wants.
5. **Render** as NEW lines in `renderLssReport`:
   `points: total=N load=N slots=N poisonLoads=N poisonPoints=N items=N` and
   `loads: shared=N sharedArrows=N isolated=N isolatedArrows=N`.
6. **Time split, two instruments, separate legs** (never mixed into a benchmark row):
   coarse — re-run the census binary with `--stats` (`Terminal/Make.elm:101,135`;
   `FEStats.PhaseMono`, `Builder/Eco/FEStats.elm:61-67`) to split mutator wall into
   Deps/Local/Mono/InlineSimplify/GlobalOpt/Mlir for free; fine — ONLY if PhaseMono is
   large, the sampled census per `design_docs/kernel-boundary-reduction.md:45`
   (`perf record -F 997 --call-graph dwarf`; traps from that census: build-vs-workload
   config, pgrep self-match) attributing within-mono samples to load/unify/zonk/
   translate.

**Benchmark:** Run H (variance re-leg, unchanged binary) then Run I (census binary,
plain run) in `benchmarks/lss-opt.md`; census lines quoted in the Run I entry.

**Decision gate, pre-registered.** Phase 5 gets a design plan ONLY if BOTH hold:
(a) load-path Points are a material share of run allocation — using
`loadShare ≈ pointsMinted × k / copied-in-nursery` with k = objects per Point (≥2:
array cell + descriptor; pin k via an `ECO_INLINE_ALLOC=0` census leg only if the
answer is borderline), with ~5% as the working materiality bar (the kernel boundary
was retired at 3.26%); AND (b) PhaseMono is a material share of mutator wall AND the
profile names load-side symbols inside it. If either fails, Phase 5 is RETIRED, the
outline below stands as the record of why, and the profile's actual top entries become
the next lead instead. No implementation may start from an unmet gate.

### Phase 5a — EXECUTED 2026-08-17. Gate verdict: **Phase 5 RETIRED.**

All legs ran: Run H (variance re-leg — resolved separately, see the 4c note), Run I
(census, `benchmarks/lss-opt.md`), the `--stats` leg, and a perf-sampled leg
(169,007 samples at 497 Hz, dwarf call-graphs, over the full workload).

**The census (Run I):** `points: total=27,931,402 load=23,826,311 slots=958,411
poisonLoads=140 poisonPoints=345 items=41,887` / `loads: shared=973,097
sharedArrows=8,948 isolated=5,304 isolatedArrows=123,125`. Readings: the load path
mints **85.3% of all Points** (~21.5 per load, ~667 per item); the never-written arrow
slots that motivated this phase are only **4.0% of load-path mints** — the dead-slot
ratio rode on a much larger, mostly-necessary mint population; and the
**load-purely-to-poison class is 140 loads / 345 Points in the entire self-compile** —
NIL, refuting this plan's `poisonCallBoundary` claim outright (`widenedByKernel=4,109`
poisons walk already-loaded types; mechanism 2's headline motivation is gone).

**Gate clause (a) — allocation share: FAIL (borderline at best).** Total Points are
2.6% of copied-in-nursery events (27.9M / 1,087.8M); load-path Points 2.2%. Even at
k=4-5 objects per mint the band is ~9-13% of copy events, and the series' own natural
experiment says that scale does not buy wall: Run I's instrumentation itself added
~+2.8% promoted and moved wall ~3% with a major-count change — and 4c/4b showed
allocation removals of similar scale buying nothing.

**Gate clause (b) — time share: FAIL on its second half.** `--stats` proved BLIND on
this workload — `monomorphization 0 ms`; the kernel-package path never routes through
`FEStats.withPhase` (finding worth its own fix someday). The perf leg answered instead
(recipe: `sudo sysctl kernel.perf_event_paranoid=1`, then
`perf record -F 497 --call-graph dwarf` on the workload leg). Time-slicing by the
first/last samples carrying MonoSolver frames: the mono window spans **149.8 s = 44.0%
of wall** — material, clause (b) first half passes. But the profile does NOT name the
load layer: load-path frames appear in **16.3% of window samples = 7.2% of wall**
(inclusive, memo probes and allocation included), and the load path's own compiled
code (`Store_*` self) is **3.1% of the window ≈ 1.4% of wall**. Within the mono
window, self-time decomposes as: **GC/alloc ≈ 43%** (incl. the nursery-clear memset in
libc and GC helpers), **closure-dispatch machinery ≈ 29%** (`eco_apply_closure_eval`,
`invokeSaturatedTyped`, and — the single largest line — the per-call
`RootSet::StackRootRange` vector push at **17.4% of the window**), `Dict_*` 6.6%,
string compares 2.0%, solver Elm code (Store/LssInfer/Translate/Unify) **≈ 5.9%
combined**. Caveat recorded: dwarf unwinding breaks at closure trampolines, so
symbol-level INCLUSIVE numbers for high-level drivers undercount; the window-slice
method is the trustworthy one.

**Verdict: both clauses fail → Phase 5 is RETIRED as pre-registered.** Best case for
its two mechanisms was bounded by the 7.2%-of-wall inclusive load layer, against a
store-lifecycle redesign with three blockers. The outline below stands as the record.

**What the profile names instead (next leads, in order of measured size):**
1. **Per-call root registration** — `eco_gc_push_stack_range` /
   `StackRootRange` push_back is ~17% of the mono window and the dispatch family is
   ~20% of TOTAL wall (`eco_apply_closure_eval` 8.1% + `invokeSaturatedTyped` 4.7% +
   push_stack_range 3.8% + splice/saturated-call helpers). A runtime-side cheapening
   of root registration pays everywhere, not just in mono.
2. GC itself (43% of the mono window, 37% of wall) — the standing target.
3. `ENABLE_GC_STATS` clock overhead — vdso `clock_gettime` ≈ 3.1% of the window; a
   build-config cost, already a known open item from the kernel-boundary census.
4. Generic `Dict_*` traffic (6.6% of window) + string compares (2.0%) — the true
   residue of the string-key story: COMPARING keys inside `Dict String`, not building
   them.

**Census-cost note:** Run I vs Run H shows the instrumentation's own price (+10.3 s
wall, +2.8% promoted), dominated by the now-unconditional per-load `lssStats` fold.
If the counters stay in-tree, consider re-guarding that fold; if they are removed, the
`points`/`loads` lines above are the archival record.

## Phase 5 — OUTLINE ONLY: lazy leaves + shared callable-free clones (gated on 5a)

Deliberately not a spec. If 5a's gate passes, this becomes its OWN plan document;
nothing below is implementation-ready, and nothing may be built from it directly.

- **Goal.** Cut the load-layer mint multiplier. The load path mints fresh structure
  per load (LSS_006); Run D measured ~4.7 arrow slots minted per slot ever written,
  and 5a will say how many total Points that ratio rides on.
- **Mechanism 1 — shared callable-free clones** (Roc's `contains_callable` split,
  `roc/src/postcheck/lambda_solved/solve.zig:113-135, 1355-1376, 2943-2953`): a type
  containing no arrows loads to ONE shared instance instead of a fresh copy per load.
  The SAFE first increment: no arrows ⇒ no slots ⇒ no set writes and no slot aliasing,
  so blockers 2 and 3 below are sidestepped; even a per-item share (no store-lifecycle
  change) may pay if 5a's `loads` counters show high loads-per-item.
- **Mechanism 2 — lazy leaves**: defer materializing a loaded type's structure until
  something demands it (the poison-only loads walk structure merely to find slots —
  `poisonPoints` in 5a sizes exactly this).
- **Blocker 1 — store lifecycle.** The store is per-item: `resetItem` swaps in
  `freshStore` wholesale and Points are dense per-item Array indices
  (`Data/IORef.elm:56-61`, `Engine.elm:1063-1065`), so any CROSS-item sharing needs a
  store-lifecycle redesign — the expensive part, and the reason 5a gates this phase.
- **Blocker 2 — identity entanglement of shared records.** `Record1×Record1`
  unification mints fresh Points and cross-links both sides (`Unify.elm:886-897`), so
  a shared ground clone that reaches unification entangles unrelated items.
  Callable-free sharing must therefore be confined to types that cannot reach a
  unification that rebuilds them, or cloned-on-unify.
- **Blocker 3 — slots carry identity, not just content.** `FunL×FunL` runs
  `subUnify set1 set2` (`Unify.elm:732-736`): two arrows that unify SHARE a slot, and
  later facts through one are visible through the other. A lazily-absent slot has
  nowhere to record that aliasing — lazy slots must materialize on unification as
  well as on write, or facts are silently dropped (the LSS_010 miscompile class).
  (Found in this session's review; the original Phase-5 paragraph did not list it.)
- **Non-mechanism, recorded so nobody re-derives it:** "skip ⊤-writes onto
  unconstrained slots" is UNSOUND — ⊤ is information (absorb-everything-later); Run C
  measured 61,375 subsequent concrete writes absorbed by poisoned slots. Poison must
  always materialize.
- **Sequencing.** After 5a, and only through its gate. Evidence inventory at gate
  time: 5a's `points`/`loads`/`poison` lines, PhaseMono share, profile attribution,
  plus the standing ratios (70.1% / 78.0% / 78.5%) — ratios argue SHAPE, the census
  argues SIZE, and the gate is decided on size.

## Measurement protocol (Phases 2-4)

**`benchmarks/lss-opt.md` is the protocol** — this track created it. Each phase lands
one PLAIN run (one cold leg, solver+LSS workload, no A/B — these are unflagged changes)
recorded as the next row: Run C = Phase 2, Run D = Phase 3, Run E/F = Phase 4a/4b
(F = the 4b NO-GO, reverted), Run G = Phase 4c, Run H = variance re-leg of the
unchanged Run-G binary (Phase 5a item 0), Run I = Phase 5a census binary. The `--stats`
and perf legs of Phase 5a are NOT benchmark rows — separate passes, per this section's
testing rule.
Compare against the previous row per that file's rules (quote both rows' `out.mlir`
sizes; judge counters first, wall second; never quote a wall without its majors). The
benchmark is NOT a correctness gate: its rows are two different trees and prove nothing
about identity — that argument lives entirely in the final sweep.

**Keep every phase binary.** After each phase's build, `cp` the compiler to
`eco-lss-pN` (`p1` from Phase 2's landing already exists and is the series baseline —
do not delete it). These are the bisection ladder: if the sweep's identity gate fails,
run the same tree through successive `eco-lss-pN` to attribute the divergence to one
phase, instead of re-deriving it from a four-phase diff.

## Final gate sweep (once, after Phase 4b)

Every correctness gate for Phases 3-4b runs here, against the cumulative tree. Order is
cheapest-and-most-decisive first — stop and bisect on the first failure rather than
collecting a full failure set.

1. **Two-binary identity byte-compare** — `eco-lss-p2` (last fully-gated binary) vs the
   final binary on the SAME tree; outputs must byte-match. This is THE gate: every phase
   3-4b is byte-identical by construction, so a mismatch means one of them is not
   substrate-only. Bisect via the `eco-lss-pN` ladder (4a first — see its note).
2. **Census witness lines** — same recipe, comparing the two runs' `lss.report`. These
   must be IDENTICAL: `members`, `signatures`, `sets zonked` + size histogram, `widened`
   (all three counters), `widened sizes`, `join flush`, `joins`. These legitimately MOVE
   and are the series' evidence: `set-writes`, `joinNoop`/`completionJoinNoop`, and the
   Phase-3 `slotsMinted` line (new).
3. elm-tests — expect the 13,104/12 baseline (12 known TYPE_007 failures).
4. Full E2E ×3 legs: default / `ECO_CSE=1` / `ECO_LIST_MAP_TEMPLATE=1`, purging
   `build/test/*/eco-stuff` between legs — expect 1,675/1,675 each.
5. Bootstrap (solver+LSS) — Stage-8c fixed point (a NEW fixed point; the corpus grew).
6. One final identity re-check against the series baseline: `eco-lss-p1` (PRE-Phase-2,
   kept) vs the final binary on the final tree — byte-identical proves the whole series
   was solver-internal end to end, not just the Phase 3-4b increment.

Partial credit already banked (2026-08-17, under the old per-phase structure): Phases
1-2 each passed their own two-binary identity + witness gates at landing, and Phase 2's
tree passed elm-tests 13,104/12 and all three E2E legs 1,675/1,675; only the bootstrap
was cut short. That is why step 1 uses `eco-lss-p2` as its reference — steps 3-5 are
un-run for Phases 3-4b only, but the sweep re-covers everything regardless.

## Done when

Phases 1-4 landed/settled, each with its own row (Runs C-G; 4b measured NO-GO and
reverted, 4c kept on code-quality grounds); the final gate sweep green end to end; the
census shows `setWriteSlow = 0` sustained and `joinNoop`/completion joins converted to
pointer-returns; findings and numbers recorded in this file per phase; Phase 5a
executed (Runs H-I + time legs) and Phase 5's gate decided GO (own plan drafted) or
NO-GO (retired with the census attached) strictly on 5a's numbers.
