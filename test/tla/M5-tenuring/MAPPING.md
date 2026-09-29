# M5 — the region nursery and concurrent tenuring: model ↔ code

The model is `Tenuring.tla` (PlusCal plus its committed translation). `MC.tla` only extends it:
every constant is a plain value set by the `.cfg` files. The plan is
`plans/threaded-gc-tla-M5-tenuring.md`; its §2 explains the protocol. **This file cites code,
never plan text** (parent plan §12, trap 1).

Line numbers are for the tree of 2026-09-29, before the wave-2 trace hooks (§8), which add 1 to 20
lines to `TenureWork.hpp` and `NurseryTenure.cpp` below their first hook; §8 gives the hooks' lines. The M5 files (`TenureWork.hpp`, `NurseryTenure.cpp`,
`NurseryRegion.cpp`, `NurseryRegions.hpp`, `NurserySpace.hpp`, `OldGenTenure.cpp`) match the
post-7c tree the plan cites. `ThreadLocalHeap.cpp`, `OldGenSpace.cpp` and `GCHelperPool.cpp` gained
`ECO_TLA_TRACE` hooks on 2026-09-28/29, which shifted their lines by 1 to 20; the logic is unchanged.
Functions are named too, because lines drift. Abbreviations: `TW` = `TenureWork.hpp`,
`NT` = `NurseryTenure.cpp`, `NR` = `NurseryRegion.cpp`, `NRH` = `NurseryRegions.hpp`,
`OGT` = `OldGenTenure.cpp`, `OGS` = `OldGenSpace.cpp`, `TLH` = `ThreadLocalHeap.cpp`,
`GHP` = `GCHelperPool.cpp`.

## 1. Variables

| Variable | Meaning | Code counterpart | Footprint row |
|---|---|---|---|
| `heap[a]` | cell `a`: logical id `lid` (0 = empty), `NF` pointer fields `f`, builder flag `b` | the objects; `Header.builder` | T1, T2, T3, T5, T8 |
| addresses `<<"E", c>>` | eden cells | `[eden_base, bump_.ptr)` | T8 |
| `<<"S", x, c>>` | survivor part of extent `x` | `Extent::[base, surv_top)` (`NRH:64`) | T1 (Tenuring), T2 (Fresh) |
| `<<"B", x, c>>` | builder area of extent `x` | `Extent::[bld_lo, bld_hi)` | T8 (Fresh builder area) |
| `<<"O", c>>` | old-gen cells | uniform-block cells | T5 (granted ones) |
| `<<"Y", c>>` | YLOS cells (old-gen cells, young until promoted) | `allocateYoungLarge` cells, `large_body_index_` kind 1 | T3 |
| `root[r]` | roots | RootSet roots, stack-map slots, JIT roots, root ranges, external scanners | T8 |
| `lheap`, `lroot` | **ghost** logical graph: what the mutator would see with no GC | — | — |
| `ebump` | eden bump | `bump_.ptr` | T8 |
| `xstate[x]`, `xage[x]` | extent state and age | `Extent::state`, `Extent::age` (`NRH:67-68`) | — (pause-only) |
| `gen[x]` | shadow generation | `Extent::gen` (`NRH:72`) | T4 (read by the job as `J.gen`) |
| `shadow[x][c]` | forwarding table, one entry per object start | `RegionState::shadow[x]` (`NRH:178`), words of `TW:51-95` | T4 |
| `ys[c]` | YLOS state: Free, Y0 (age 0), `Gen(x)` (joined the generation of extent `x`), Old (promoted), Dead (unlinked mid-cycle) | `Header.age`, `Extent::ylos_gen`, `LargeBodyMeta` kind/colour, `deferred_frees_` | T3 |
| `job` | state (None / Running / Merged) and extent | `TenureJob::state`, `x` (`NRH:120-123`); Built/Done fold into Running | T7 |
| `jstarts`, `jheal`, `jstack`, `ns`, `nh` | job inputs and progress | `SerialState::starts`, `heal`, `stack`, `next_start`, `next_heal` (`TW:113-122`) | T7 |
| `jreached`, `jylos`, `ny` | reached generation YLOS, pending scans, next | `SerialState::reached`, `ylos_pending`, `ylos_next` (`TW:118-126`) | T3 / T7 |
| `ageX`, `jSA`, `nsa`, `astack`, `amark`, `swept`, `zap` | 07b: the ageing extent, `age_starts`, next, `age_stack`, mark bits, sweep done, zap spans | `TenureJob::age[]`, `SerialState::age_*`, `sweep_*`, `zap` (`TW:127-138`); `Extent::mark_bits` | T7 (mark bits: job-private) |
| `grant` | old cells owned by the job | `TenureGrant` (`OGT:44`) | T5 |
| `stop` | stop request | `TenureJob::stop` (`NRH:147`); for L3 `tenure_ctl_->stop` | — |
| `running` | collector members still in the engine | `finished_` vs `members` (`GHP:605-610`), `running_` | — (LaunchJoin, M6) |
| `calive` | FALSE: the collector thread does not exist (a fork child) | thread existence | — |
| `go[c]` | a launch member `c` has not yet seen | `generation_ != seen` (`GHP:588-590`) | — |
| `S`, `H`, `SA`, `ypr` | the minor's pending start set, heal list, age sources, reached hand-over YLOS | `pend_S`, `pend_H`, `pend_SA`, `hand_ylos_reached` (`NRH:195-201`) | — (pause-only) |
| `cycle`, `grey`, `black`, `cage` | abstract mark cycle | `cycle_state_`, t0 greys, allocate-black bits, `cycle_k_` | T11 |
| `liveHand`, `liveHandY`, `liveAge` | **ghosts**: legacy's promoted set, live generation YLOS, live ageing objects, at the hand-over | the E1 legacy oracle | — |
| `cw`, `ncopy` | **ghosts**: cells the collector wrote; copies per object | TV8 range checks; TV3 | — |
| Mutator locals `slots`, `efwd`, `fill`, `hand`, `agex`, `prev`, `retire`, `ftop`, `fbot`, `cur`, `t`, `v` | the minor's slot list, eden forwarding, roles, fill tops | the drain's grey stacks, header forward words, `R.fill/hand/retire/prev`, `tospace_.top`, `bld_bottom` | — (pause-only) |
| Engine locals `tgt`, `fix`, `e`, `res`, `sc`, `si`, `scy` | the current target, the slot to fix, the observed shadow word, the copy, and `scanCopy`'s / `scanYlos`'s frame | C++ locals of `tenure`, `childOfCopy`, `scanCopy`, `scanYlos` | — (thread-private) |

## 2. Steps (A1: one label = one atomic step of the code)

| Label | Code (function, file:line) | Why one step | Footprint | Invariants checked there |
|---|---|---|---|---|
| `M_Epoch` alloc / balloc / yalloc / load / drop / bwrite / bclear | Elm code and kernels between pauses: `allocate`, `allocArrayBuilder` + writes + `clear_builder`, `allocateYoungLarge` (`TLH:460`) | one mutator operation; a load reads a field of an immutable object (P1); a builder write is one store into a young object | T1 (reads), T2 (reads), T8 | `NoDangling`, `GraphPreserved`, `YlosFreed` (in the epoch) |
| `MN_Join` → `JoinMerge` | `ThreadLocalHeap::minorGC` → `tenureJoin(…, 0)` (`TLH:726/732` region) | a call | — | — |
| `J_Wait` (join branch) | `tenureJoin` (`NT:575`): `g->join()` (`NT:618`, `:622`), the orphan test `!g->running()` (`NT:614-615`), L3 `g->join()` (`NT:588`) | the join is one blocking wait under `m_` (`joinLocked`, `GHP:639`) | — | — |
| `J_Wait` (stop branch), `J_Stop` | `g->stopAndJoin()` (`NT:625`, `:590`; `GHP:657`): store `stop`, then join | two steps: the stop store, then the join; the collector interleaves between them | — | — |
| `J_Help` → `Engine(FALSE)` | `runJobExact(nullptr)` (`NT:403`, called at `:647-648`); L3: `tenureConcFinish` (`NT:1239`) | help runs in the pause, ignoring `stop` | T4, T5, T7 | — |
| `J_Merge` | `mergeJob` (`NT:669-880`): grant return `:674-682`, YLOS promote + child resolve `:731-744`, heal `:745-800`, zap `:820-828`, `State::Merged` `:878` | exclusive pause step; nothing else runs (the collector is joined) | T2 (writes), T3 (writes), T5 (returned) | `TenuredEqualsLegacy`, `TV1_Heal`, `TV1_Ylos` (in the state where `pc = "J_Merge"`) |
| `MN_Begin` | `minorGCRegion` beginMinor (`NR:699-724`): roles fill / hand / Age / retire / prev; the TV10 and "retire merged" checks | pause-only data | — | — |
| `MN_Slot`, `MN_Classify`, `MN_Fwd`, `MN_Set`, `MN_Resolve`, `MN_Next` | roots (`NR:817-845`) and drain (`NR:853-875`) through `evacuateR` (`NR:429-490`): Eden/PrevBuilders copy (`copyClaimedR` `NR:372`; builders to the builder area `:384-391`); Hand → S or H (`:467-472`); Age → SA (`:473-478`); Retire → `resolveRetire` (`NR:352`); YLOS → `reachYoungLargeR` (`NR:492-532`) | one slot per step; the pause is exclusive (the collector was joined), so its parallel drain is sequentialised (M3's CopyOnce) | T8 | `TV1_Resolve` (at `MN_Classify`) |
| `MN_Epilogue` | epilogue (`NR:1021-1073`): retire → Free, eden cleared; the YLOS sweep `sweepNurseryLargeBodies` (`NR:1132`, `OGS:7235`, deferred mid-cycle `OGS:7313`); endMinor (`NR:1075-1090`) | pause-only | T8 | — |
| `MN_Cycle` | `TLH::minorGC` after the minor (`TLH:760-781` region): `stepMarkCycle` (`TLH:1148`) → handoff (`completeMarkCycle`), or `startMarkCycle` (`TLH:1068`): roots, `snapshotYoungLarge` (`OGS:4189`), the young walk `forEachYoung` (`NurserySpace.hpp:800-830`, called `TLH:1106`) | abstract cycle (M1's SnapshotCycle): t0 and handoff are pause steps | T11 | `YoungWalkValid` (at `MN_Cycle` when a t0 is possible), `MarkerDisjoint` (every state mid-cycle) |
| `MN_Launch` | `TenureLaunchScope` (`TLH:740`) → `tenureLaunch` (`NT:428-573`): gen bump / wrap discard `:449-455`, inputs `:456-499`, grant `:540`, launch `:572` (L3: `tenureConcLaunch` `NT:1222`) | pause-only | T4 (gen), T5 (grant), T7 (inputs) | — |
| `MN_Sync` → `Engine(FALSE)` | mode 1: `runJobExact(oldgen, nullptr)` in `tenureLaunch` (`NT:553-557`) | in the pause | T4, T5, T7 | — |
| `MJ_Join` → `JoinMerge` | `ThreadLocalHeap::majorGC` → `tenureJoin(…, 1)` (`TLH:785`, the call after `pause_had_major_`) | as for a minor | — | — |
| `MJ_Cycle` | `finishMarkCycleNow(Join)` (`TLH:800`) | pause | T11 | — |
| `MJ_Mark` | `OldGenSpace::startMark` (roots only, `OGS:2868`) with `majorRedirect` (`NR:217`, called in `greyObject` (`OGS:3074`; the nursery branch with the redirect at `OGS:3127`)), then the sweep (frees unmarked old cells and YLOS cells: `lazySweep`'s large-cell branch, `markBlockAsFreeLarge` `OGS:5340`) | STW | T11 | `TV1_Major` (at `MJ_Mark`) |
| `C_Wait` | `GCBackgroundGang::memberLoop` (`GHP:553`): wait for `generation_ != seen` under `m_` | one wait | — | — |
| `C_Run` → `Engine(TRUE)` | `tenureEntry` (`NT:415`) → `runJobExact(…, &J.stop)`; L3 `tenureConcEntry` (`NT:1209`) → `runMarkerLoop` | a call | — | — |
| `C_Fin` | `++finished_` under `m_` (`GHP:605-610`) | one critical section | — | — |
| `E_Loop` | `SerialEngine::run` (`TW:218-236`): the `stop` check first (`TW:220`), then `step()`; so a stop seen with no work left returns Stopped, not Done (found by trace validation, AUDIT.md 2026-09-29 wave 2) | one relaxed load | — | — |
| `E_Item` | `SerialEngine::step` (`TW:277-320`): pop a copy / next start / next heal slot's value (`TW:310`) / next reached YLOS; `scanCopy`'s next child (`TW:446-466`); 07b `markOrSweepStep` (`TW:323-337`): `scanAge` (`TW:379`), `markTarget` (`TW:352`), `sweepStep` (`TW:394`) | the item bookkeeping is job-private; a heal value is immutable under P1; a mark item reads only immutable objects and writes job-private state | T1, T2 (reads), T7 | — |
| `E_Load` | `tenure` (`TW:248-256`): relaxed load of the shadow word; L3 `TenureParEnv::tenure` (`NT:969-981`): acquire load; `reachYlos` (`TW:421`, L3 `NT:1005`) | one load | T4 | — |
| `E_Claim` | `tw::claim` (`TW:79-82`): CAS observed → BUSY (L3 only) | one CAS | T4 | — |
| `E_WaitBusy` | `tw::waitPublished` (`TW:89-95`) | an acquire load per round; modelled as a wait for "not BUSY" | T4 | — |
| `E_Copy` | `TenureHeapEnv::copy` (`NT:87-106`) = `grantAllocate` (`OGT:153`) + `memcpy` + fixup; L3 `grantAllocateShared` (`OGT:197`) | the copy writes only the job's own grant cell (T5), invisible to the mutator | T5 | `ExactlyOnce`, `MarkerDisjoint` |
| `E_Pub` | `tw::publish` (`TW:84-86`), then `stack.push_back` (`TW:265-266`) | the release store; the private push is merged into it (see AUDIT.md) | T4, T7 | — |
| `E_Fix` | `childOfCopy`'s `*s = word(tenure(t))` (`TW:434`), L3 `NT:1017` | one store into the job's own copy | T5 | `CollectorPrivate`, `OldPointsOld` |
| `E_Ret` | `run` returns | guarded by `calive` | — | — |
| `F_Maybe` | a fork on another thread: `atforkPrepare` (`GHP:684`) → `stopAllForFork` (`GHP:669`) → `stopAndJoin`; mutant `fork_mid_item`: the collector thread is absent from the child | one store of `stop`; or the thread vanishing | — | — |

## 3. Abstractions, and why each is sound

| Real thing | Model | Argument |
|---|---|---|
| objects at byte addresses, headers, tags, sizes | cells with a logical id, `NF` pointer fields and a builder flag | only pointer structure matters to forwarding; cell reuse is kept, which makes stale shadow entries (plan timeline (c)) reachable |
| the shadow indexed by granule | `shadow[x][c]`, one entry per cell | one entry per object start, as the granule index gives for objects that do not overlap |
| a shadow word (state, dst, gen in 64 bits) | a record written whole | `make` builds the word; every access is one 64-bit atomic (A2) |
| headers of tenuring objects | not modelled; `heap[t]` is copied whole | headers of survived objects are never written (FORBID_HEAP_004, P1) |
| phase 6's parallel eden copy in the pause | sequential `MN_Slot` loop | the pause is exclusive: the collector is joined first (`TLH` minorGC → `tenureJoin`), so the Retire shadow the drain reads is immutable. The pause's own parallelism is M3's (**CopyOnce**) |
| the exact engine's item = one copy's whole scan | the same; `sc`/`si` are `scanCopy`'s frame | exact: `stop` is checked only at `E_Loop` with `sc = Nil` (`TW:218`) |
| spine runs (`spineRun`, cons cells) | not modelled (no cons cells) | `spineRun` tenures the tail chain and fixes the same slots `childOfCopy` would; its only difference is item order, which the invariants do not see (trace validation will: plan §9) |
| L3 members' deques, steals and termination | one shared bag: any pending copy, start, heal target or YLOS entry may be taken next by any member; `running` counts members still in the engine | M2's **Drain** contract: every entry is taken exactly once and a stop leaves the rest where help finds it. M2 checks the real loop |
| L3 heal values read at launch (`tenureParDistribute`, `NT:1121-1127`) | read when the item is taken (`E_Item`) | the slot is immutable until the merge (P1, heal slots are Fresh or young-YLOS slots), so both reads return the same value |
| the grant (uniform blocks in `kAllocTenure`, per-class cursors, chunk claims) | `grant` = every free old cell at launch; exact: `CHOOSE` (deterministic), L3: any | placement determinism of the exact engine is kept. Byte-level bitmap races and the skip rule (no mutator path selects a granted block, T6) are M4's (**BitFaithful**). `OC >= MaxLid` rules out exhaustion (each object is tenured at most once) |
| 5c marking | abstract cycle: t0 greys (roots' and walked objects' old targets), `black` (copies mid-cycle, young YLOS at t0, YLOS allocated mid-cycle), the handoff frees what is outside `OldClose(grey) ∪ black` | M1's **SnapshotCycle** contract. M5 checks the interface M1 assumes (**TenureDisjoint**) |
| `grantAllocate`'s mark bit (set always, `OGT:174-176`) | `black` only mid-cycle | outside a cycle the bit is the allocation record and means nothing to a marker |
| help of a large extent (`runJobParallel`, `NT:1168`, allocates from `PromoCtx`) | not modelled; `Collectors = 1` help is `runJobExact` | the plan's §11 Q2: at the cell level it is the claiming engine over free old cells; its allocate-black decision is phase 6's (CR-001, M4) |
| mode 1 with `tenure_sync_threads > 1`, and the `!granted` fallback (`NT:522-552`) | not modelled | pause-only `runJobParallel` |
| Built / Done job states | folded into `Running` | the join treats Done as "nothing to wait for" (`running = 0`) |
| `finishedApprox()` | the join branch may always be taken | an over-approximation: `finishedApprox` only decides whether to stop first |
| builders (`kColBuilder`) | `BC` builder cells per extent; kernels allocate, write held plain values into, and clear their builders; builders hold only plain values | HEAP_BUILDER_003: a builder is reachable only from its kernel's root until cleared. Builder → builder nesting is not modelled |
| generation YLOS (`kColYoungYlos`, `kColHandYlos`, `hand_ylos`) | `YC` Y cells with `ys` | the pause's colour test is `ys`; the minor's sweep frees Y0 cells not reached and unreached cells of the retiring generation (deferred to the handoff mid-cycle) |
| large bodies (`lb_bodies`, `lb_promoted`, `promoteLargeHeader`), YLOS builders, ageing YLOS | not modelled | pointer-free bodies do not affect forwarding; the H-body trap (07 trap 14) is a colour bug in the pause |
| 07b ageing (k = 2) | `K = 2`: four extents; Age role → `SA`; the job's mark and sweep items; the merge's zap | exact engine only (`age_forced_exact`, `NT:533-534`); one sweep item covers a whole extent (the code's item is one bitmap word) |
| eden flip (quarantine) | not modelled: eden is cleared at every minor | eden cells are never read after the minor |
| a fork child | `calive := FALSE`; the model keeps the same mutator and launches no new collector | the child as if it had a mutator (CR-004's open question); `atforkChild` would start fresh threads on the next launch |
| old objects that predate the model | `OldSeed = 1`: one old object at Init, held by a root | every behaviour from it is a real one |

## 4. Footprint rows (A3): the 07 plan's T1–T11

| Row | Location | Model |
|---|---|---|
| T1 | tenuring objects `[base, surv_top)` | `heap` S cells of `job.x`: read by the collector (`E_Item`, `E_Copy`), written by nobody while the job runs (P1) |
| T2 | heal slots `*heal[i]` in Fresh objects and generation YLOS | `heap[jheal[·]]`: read by the collector (`E_Item`), written only in `J_Merge`; `HealYoungOnly` |
| T3 | generation-YLOS objects, `reached[]` | Y cells and `ys` (pause), `jreached` (job-private); read-only in the job (`E_Item` scanYlos); promoted and resolved in `J_Merge` |
| T4 | the tenuring extent's shadow | `shadow[job.x]`: `E_Load`, `E_Claim`, `E_Pub`; read by the pause after the join (`MN_Classify` resolve, `J_Merge`, `Redir`) |
| T5 | granted blocks: cells, bitmap bytes, cursors | `grant`, `E_Copy`, `E_Fix`; bitmap bytes and cursors: M4 (BitFaithful) |
| T6 | `blocks_`, page index, `partial_`, free lists, sweep state | abstracted: the grant is fixed at launch and the model's mutator never allocates old cells. The skip rule is M4's (`grant_t0_block`, `grant_includes_cursor`, `shrink_ignores_tenure`) |
| T7 | job-private state | `jstarts`, `jheal`, `jstack`, `ns`, `nh`, `jreached`, `jylos`, `ny`, 07b `jSA`, `nsa`, `astack`, `amark`, `swept`, `zap` |
| T8 | eden, the Fresh builder area, roots, off-heap stores | E cells, B cells, `root`: mutator and pause only; `CollectorPrivate` checks the collector never writes what the mutator reaches |
| T9 | allocator globals, config | constants |
| T10 | helper-pool jobs | M7 |
| T11 | 5c background markers | the abstract cycle; `MarkerDisjoint` |

Census (2026-09-28, re-checked 2026-09-29) of `TW`, `NT`, `OGT`, `NRH`: every atomic is a shadow
word (T4), `J.stop`, a grant chunk-claim word (`OGT:234-249`, M4), a `reached[]` byte (T3, L3's
exchange `NT:1008-1009`), an ageing-mark word in the pause-only gang (`AgeParEnv`), `bld_bottom`
(pause-only), a worker's `priv`, or a stats counter (`J.cpu_ns`, `NT:1218`). None is outside T1–T11.

## 5. Invariants (A7)

| Invariant | Id | Where the code checks it |
|---|---|---|
| `NoDangling` | TV7 + HEAP_069's retirement premise | `regionAssertValidPointer` (`NR:234`, validate builds) |
| `GraphPreserved` | E1 (the legacy oracle) at graph level; FORBID_HEAP_005 | — (`tg7-compare.py`, the E1/E2 experiments) |
| `CollectorPrivate` | FORBID_HEAP_004 | `gc-heap-tsan` (TSan) |
| `ExactlyOnce` | TV3 | `mergeJob` TV3/TV4 (`NT:686-707`, validate builds) |
| `OldPointsOld` | HEAP_005 (as amended for 7c) | TV6: `childOfCopy` (`TW:436`, every build), `mergeJob` (`NT:801-815`, validate builds) |
| `HealYoungOnly` | 07 row T2, FORBID_HEAP_004 (M1's open question 3) | — |
| `MarkerDisjoint` | TV8 + IM3 | `greyObject`'s young abort (`OGS` `greyObject`), TV5 in `grantTenure` (`OGT:101-108`) |
| `YoungWalkValid` | CR-017; the k = 1 form of 07b's TV2Y | — (IM4 / IM6 fire later, validate builds) |
| `TenuredEqualsLegacy` | TV2, E1 promoted-set equality; 07b's marked set | `regionEndMinorValidate` (TV2, validate builds) |
| `TV1_Heal`, `TV1_Ylos`, `TV1_Resolve`, `TV1_Major` | TV1 (every build) | `resolveT` in `mergeJob` (`NT:725-729`, `:771`), `resolveRetire` (`NR:361-367`), `majorRedirect` (`NR:225-226`) |
| `BuilderYoung` | HEAP_BUILDER_001, 07 trap 13 | `minorGCRegion`'s fill walk ("a builder in the fill's survivor part", `NR:989`, validate builds) |
| `YlosFreed` | MODEL_M5_1: an unreached generation YLOS is freed with its extent | — |

## 6. Contracts (parent plan §5.0)

**Provided: TenureDisjoint** (used by M1 in region mode):
- `HealYoungOnly`: the merge heals only slots of young objects (a Fresh copy, a marked ageing
  object, a young YLOS);
- `MarkerDisjoint`: mid-cycle the markers' closure holds only old cells, none granted, none black
  (young YLOS are black from t0, so the merge's step-3 writes into promoted YLOS never meet a
  marker), and every copy made mid-cycle is black;
- `YoungWalkValid`: the t0 walk reads only allocated cells. **Fails today** (CR-017):
  `MC_cycle_major`, `MC_deep`.

**Used:**
- **SnapshotCycle** (M1): the abstract cycle's handoff frees exactly what is outside
  `OldClose(grey) ∪ black`;
- **CopyOnce** (M3): the sequential `MN_Slot` stands for the parallel drain;
- **BitFaithful** (M4): one `black` bit per cell, grant cells never shared with a marker's byte;
- **Drain** (M2): L3's bag of entries;
- **LaunchJoin** (M6): `go`, `running` and the join; M5 checks the "stop at the next item
  boundary" obligation on the tenure engines (`E_Loop`).

## 7. A1–A9

| Rule | M5 |
|---|---|
| A1 | The collector's steps are one shadow load, one CAS (L3), one grant allocation plus copy, one publish (with the private push), one slot fix, one ageing mark or sweep item. An item is one start, one heal slot, one reached YLOS scan, or one popped copy's whole scan, and `stop` is checked only between items. Pause steps are sequential and exclusive. §2 lists each step's code |
| A2 | Shadow entries are whole 64-bit words. Heal slots are whole pointer slots written only in the pause. Mark-bitmap bytes are M4's |
| A3 | §4: T1–T11 and the census |
| A4 | The model is SC. Relies on: **W5** (claim → copy → publish on a shadow word, the exact engine's relaxed load and release publish, the pause's acquire `lookup` after the join) — **PASS**: W5(b) (help after the join; stale entries claimed by the observed word) and `w5_parallel_tenure` (case p), with `W5_RELAXED_PUBLISH`, `W5_RELAXED_CLAIM_FAIL`, `SHADOW_RELAXED_PUBLISH` and `HELP_WITHOUT_JOIN` flagged; **W1** (the Chase–Lev deques of L3 and the ageing gang) — **PASS** (two thieves included); the gang launch/join publication (M6's LaunchJoin; `w_running_chain` for the orphan test) — **PASS**, covering both `!running()` sites of `tenureJoin` (the L3 branch `NT:584-585` and `NT:611-631`), with `RUNNING_RELAXED_STORE`, `RUNNING_RELAXED_LOAD`, `RUNNING_JOIN_EARLY` flagged. GenMC RC11, `test/genmc/AUDIT.md`, 2026-09-28 |
| A5 | §8: `TraceTenuring` (the engine storm, `gc-tenure-trace`) and `TraceTenurePause` (the pause projection on the real allocator, `gc-heap-trace tenure`); rows in `test/tla/traces.txt` |
| A6 | Every invariant has at least one mutant that TLC rejects with its name (AUDIT.md). `YoungWalkValid`'s are `skip_zap` and CR-017 itself (`MC_cycle_major`) |
| A7 | §5 |
| A8 | 3 survivor extents (4 with k = 2) of 1–3 cells, 1–2 fields, 3–6 minors, 1–4 mutator operations per run. The 21-bit generation shrinks to 3 bits (`GenMod = 8`) and to 1 bit in `MC_wrap` (every hand-over after the first discards). Unbounded claims: none are proved; the deep tier stretches one dimension at a time |
| A9 | Not pinned yet (the canary is a later wave). Proposed lines: AUDIT.md "What is left" |

## 8. Trace validation (A5)

Two trace specs, both `EXTENDS Tenuring, TraceAnyOrder` (`test/tla/README.md`, "Trace
validation"), with rows in `test/tla/traces.txt`. Hooks are `ECO_TLA_TRACE` calls, compiled out of
production builds (each is `((void)0)`).

**(a) The engine storm: `TraceTenuring.tla`** (`.cfg`, `.keep`). Harness: `gc-tenure-trace tiny
<seed> <jobs> <nten> <nfresh> <nold> <nylos> <nf> <stop %> <pace us>`
(`test/gc-helper-tsan/tenure_harness.cpp`, `tinyMain`; target in that directory's CMakeLists under
`option(ECO_TLA_TRACE)`). The real `SerialEngine` on the real `GCBackgroundGang`, over tiny heaps of
node objects rebuilt at the same addresses for every job (the shadow keeps earlier generations'
entries); the pause joins or stops and joins, helps, and replays `mergeJob`'s YLOS resolve and heal.
The header carries every job's heap and inputs.

| Event | Where | Model step |
|---|---|---|
| `job` k | harness, before `launch` | `TJob` (the trace spec's): the job's heap and inputs, then `MN_Launch`'s generation bump (or wrap discard) and launch, in place of the minor the harness does not run |
| `gang.start` / `gang.exit` | `GHP` `memberLoop` | `C_Wait` / `C_Fin` |
| `tstopreq` | harness, before `stopAndJoin` (put `S<flag>.<gen>`) | `J_Wait`'s stop branch |
| `gang.join` | `GHP` `joinLocked` | `J_Wait`'s join branch, or `J_Stop` |
| `titem` start / heal | `step()` (`TW:316`, `:326`) | `E_Item` (a start, a heal slot's value) |
| `tchild` | `childOfCopy` (`TW:449`), `scanYlos` (`TW:530`) | `E_Item` (a copy's or a reached YLOS object's slot; the first slot pops the stack or takes the next reached YLOS) |
| `tload` | `tenure` (`TW:265`): state, gen, current-gen destination | `E_Load` (tenuring target): the model's entry must be the same |
| `treach` | `reachYlos` (`TW:439`) | `E_Load` (a YLOS target) |
| `tcopy` / `tpub` | `tenure` (`TW:274`, `:278`) | `E_Copy` / `E_Pub`; the copy's model cell is recorded (`cmap`) |
| `tfix` | `childOfCopy` (`TW:455`) | `E_Fix` (the store into the copy's slot) |
| `tstop` / `tend` | `run` (`TW:222`, get `S<flag>.<gen>`; `:230`) | `E_Loop`'s return / exit |
| `tmerge`, `theal`, `tyres`, `tshadow` | harness, after help | `J_Merge`, then checks of the healed slots, the resolved YLOS slots and every shadow entry |

Hidden: the control steps, and `E_Load` / `E_Fix` when they do nothing. Ids: tenuring object i is
`<<"S", 1, i + 1>>`, fresh j `<<"S", 2, j + 1>>`, old k `<<"O", k + 1>>`, YLOS y `<<"Y", y + 1>>`;
copies are named by their log id and mapped to the cell the model's exact engine chose.

**(b) The pause projection: `TraceTenurePause.tla`** (`.cfg`, `.keep`). Harness: `gc-heap-trace
tenure <seed> [steps [jitter_us [major %]]]` (`test/gc-heap-tsan/tiny_tenure.cpp`): the REAL
allocator's region nursery (k = 1, tenure mode 2, one exact collector, help on, no incremental
marking), at most 8 Tuple2 objects whose payload is the model's logical id, two roots, explicit
minors and STW majors.

| Event | Where | Model step |
|---|---|---|
| `alloc` / `load` / `drop` | the driver | `M_Epoch`'s branches (logical ids) |
| `minor` / `major` | `TLH` `minorGC` / `majorGC` (M1's hooks) | `M_Epoch`'s minor / major branch |
| `tj.launch` x gen starts heal path | `tenureLaunch` (`NT:519-528` helper, called on each path `NT:535`-`:588`) | `MN_Launch` with a Tenuring extent: extent x + 1, the new generation, the distinct starts, the heal slots |
| `gang.join` | `GHP` `joinLocked` | `J_Wait`'s join branch, or `J_Stop` |
| `tj.help` | `tenureJoin` (`NT:615`, `:660`) | `J_Help` calling the engine (the job is not done) |
| `tj.merge` tenured healed | `mergeJob` (`NT:898`) | `J_Merge`: the forwarded objects and the slots healed |
| `gang.start` / `gang.exit` | `GHP` | `C_Wait` / `C_Fin` |
| `troots` | the driver, after each collection | a check: each root's id and whether it is old; the reachable ids |

Hidden: the minor's and the major's own steps (computed by the model from its heap; the code's slot
order and cell placement are not compared), `J_Wait`'s stop store, `J_Help` when the job is done,
and every engine step (the storm checks those one by one).

<!-- canary-pins begin -->
## Canary pins (A9)

The code this model describes, pinned in `test/tla/manifest.txt` (generated 2026-09-29
from this model's A9 row). A pin that fires names this model; re-audit, then write an
AUDIT.md entry quoting the new hash prefix (`test/tla/README.md`, "The canary").

| Kind | Path | Id |
|---|---|---|
| file | `runtime/src/allocator/TenureWork.hpp` | `-` |
| file | `runtime/src/allocator/NurseryRegions.hpp` | `-` |
| file | `runtime/src/allocator/TlaTrace.hpp` | `-` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.snapshotYoungLarge` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.greyObject` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.sweepNurseryLargeBodies` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.promoteYoungLarge` |
| region | `runtime/src/allocator/OldGenTenure.cpp` | `OGT.grantTenure` |
| region | `runtime/src/allocator/OldGenTenure.cpp` | `OGT.grantAllocate` |
| region | `runtime/src/allocator/OldGenTenure.cpp` | `OGT.grantAllocateShared` |
| region | `runtime/src/allocator/OldGenTenure.cpp` | `OGT.returnTenureGrant` |
| region | `runtime/src/allocator/ThreadLocalHeap.cpp` | `TLH.minorGC` |
| region | `runtime/src/allocator/ThreadLocalHeap.cpp` | `TLH.majorGC` |
| region | `runtime/src/allocator/ThreadLocalHeap.cpp` | `TLH.startMarkCycle` |
| region | `runtime/src/allocator/NurserySpace.hpp` | `NSH.forEachYoung` |
| region | `runtime/src/allocator/NurseryRegion.cpp` | `NR.resolveRetire` |
| region | `runtime/src/allocator/NurseryRegion.cpp` | `NR.copyClaimedR` |
| region | `runtime/src/allocator/NurseryRegion.cpp` | `NR.evacuateR` |
| region | `runtime/src/allocator/NurseryRegion.cpp` | `NR.reachYoungLargeR` |
| region | `runtime/src/allocator/NurseryRegion.cpp` | `NR.minorGCRegion` |
| region | `runtime/src/allocator/NurseryRegion.cpp` | `NR.majorRedirect` |
| region | `runtime/src/allocator/NurseryTenure.cpp` | `NT.TenureHeapEnv` |
| region | `runtime/src/allocator/NurseryTenure.cpp` | `NT.AgeParEnv` |
| region | `runtime/src/allocator/NurseryTenure.cpp` | `NT.tenureEntry` |
| region | `runtime/src/allocator/NurseryTenure.cpp` | `NT.runJobExact` |
| region | `runtime/src/allocator/NurseryTenure.cpp` | `NT.tenureLaunch` |
| region | `runtime/src/allocator/NurseryTenure.cpp` | `NT.tenureJoin` |
| region | `runtime/src/allocator/NurseryTenure.cpp` | `NT.mergeJob` |
| region | `runtime/src/allocator/NurseryTenure.cpp` | `NT.tenureTeardown` |
| region | `runtime/src/allocator/NurseryTenure.cpp` | `NT.TenureParEnv` |
| region | `runtime/src/allocator/NurseryTenure.cpp` | `NT.tenureParDistribute` |
| region | `runtime/src/allocator/NurseryTenure.cpp` | `NT.tenureParCollect` |
| region | `runtime/src/allocator/NurseryTenure.cpp` | `NT.runJobParallel` |
| region | `runtime/src/allocator/NurseryTenure.cpp` | `NT.tenureConcEntry` |
| region | `runtime/src/allocator/NurseryTenure.cpp` | `NT.tenureConcLaunch` |
| region | `runtime/src/allocator/NurseryTenure.cpp` | `NT.tenureConcFinish` |
| census | `runtime/src/allocator/NurseryRegion.cpp` | `-` |
| census | `runtime/src/allocator/NurseryRegions.hpp` | `-` |
| census | `runtime/src/allocator/NurserySpace.hpp` | `-` |
| census | `runtime/src/allocator/NurseryTenure.cpp` | `-` |
| census | `runtime/src/allocator/OldGenTenure.cpp` | `-` |
| census | `runtime/src/allocator/TenureWork.hpp` | `-` |
| grep | `-` | `T1` |
| grep | `-` | `T2` |
| grep | `-` | `T3` |
| grep | `-` | `T4` |
| grep | `-` | `T5` |
| grep | `-` | `T9` |
| grep | `-` | `F.allocTenure` |
| grep | `-` | `F.zapFiller` |
<!-- canary-pins end -->
