# M3 — parallel-minor and region-minor forwarding: model ↔ code

The model is `MinorForwarding.tla` (PlusCal plus its committed translation). `MC.tla` holds the
example heap. The plan is `plans/threaded-gc-tla-M3-minor-forwarding.md`; its §3 explains the
protocol. **This file cites code, never plan text** (parent plan §12, trap 1).

Line numbers are for the tree of 2026-09-28 (post-7c); `MinorWork.hpp`'s for 2026-09-29, after the
trace hooks (§11) moved them. Functions are named too, because lines
drift. `MW` = `runtime/src/allocator/MinorWork.hpp`; `NP` = `NurseryParallel.cpp`;
`NR` = `NurseryRegion.cpp`; `OGS` = `OldGenSpace.cpp`; `OGH` = `OldGenSpace.hpp`.
Footprint rows `P6.M1`–`P6.M15` are the 06 plan's shared-state audit (`threaded-gc-06-parallel-minor.md`
P§3.11, rows M1–M15 there), with the ids of `test/tla/footprint-greps.txt`.

## 1. Variables

| Variable | Meaning | Code counterpart |
|---|---|---|
| `hdr[o]` | a from-space object's header word: `Unfwd`, `Busy` or a copy id (the forward word) | the object's first word through `headerRef` (`MW:61-63`); `kBusy` (`MW:40`), `fwdWord` (`MW:45-48`) |
| `fld[o]` | an object's slots (from-space originals, copies, YLOS objects) | the object's `HPointer` fields |
| `roots` | root slots | `root_set` roots, stack-map slots, JIT roots, root ranges, single roots, external scanners (`NP:669-725`, `NR:817-845`) |
| `origin[d]`, `whole[d]` (ghosts) | a copy's original; body and header copied | — |
| `promo[d]` | the copy went to the old gen | `shouldPromote` (`NP:257`) |
| `grey`, `busy[w]` | the grey set and "scanning an entry" (M2's Drain contract) | worker stacks, `priv`, deques (`NP:114-226`, `NR:280-337`) |
| `started` | the gang has started | `GCMarkGang::run` (`GCHelperPool.cpp:407-431`) |
| `owner[o]` (ghost) | who may write `o`'s slots | the owner-only discipline (P6.M3) |
| `yReached[y]` | the YLOS has been reached this minor | `LargeBodyMeta::color == minor_color_` (`NP:366-367`, `NR:515-516`); stands also for `hand_ylos_reached[k]` (`NR:504-505`) |
| `yPromoted[y]` | promoted in place | `promoteYoungLarge` (`OGS:7107-7129`) |
| `yPushes[y]` (ghost) | pushes of the YLOS this minor | `pushGreyP` after the lock (`NP:382-390`, `NR:531`) |
| `recorded` | region: slots recorded for the tenure job | `rw.H` / `rw.S` (`NR:470-471`), merged after the join |
| `res[w]` | the copy just made (a procedure has no return value) | `copyClaimed`'s return value |
| procedure locals | `ehw` = `hw` in `evacuateP`; `shw`, `st`, `sprev`, `sk`, `srun`, `strunc`, `sneeds` = `hw`, `t`, `prev`, `k`, the cells from `first`, `truncated`, `needs_heads` in `spineRunP` | owner-only |

## 2. Steps (A1: one label = one atomic step of the code)

| Label | Code (function, file:line) | Atomic operation | Footprint | Invariants |
|---|---|---|---|---|
| `W_Roots`, `W_RootLoop`, `W_RootNext` | `minorGCParallel` roots `NP:669-725`; `minorGCRegion` roots `NR:817-845` | worker 0 evacuates each root slot; no other worker runs yet | P6.M3 (roots) | `SlotsAtCopy` |
| `W_Start` | distribution `NP:727-736` / `NR:853-861`, then `GCMarkGang::run` (`GCHelperPool.cpp:407`) | the gang start: a mutex release/acquire (LaunchJoin) | grey set | — |
| `W_Loop` (take) | `runMarkerLoop` → `MinorEnv::takeOwn`/`stealFrom` (`NP:152-175`), `RegionEnv` (`NR:284-295`) | atomic removal of one grey entry (Drain) | grey set | `OwnerWrites` (sets the owner) |
| `W_Loop` (exit) | `runMarkerLoop`'s termination; the fatal "work left" check `NP:754-763` / `NR:879-884` | termination (Drain) | — | `AtJoin` |
| `SC_Loop`, `SC_Next` | `scanEntryP` `NP:444-587`; `scanEntryR` `NR:580-644`; the Cons arm `NP:508-514` / `NR:605-611` (head, then `spineRunP`) | one slot per step, in field order | P6.M3 | — |
| `E_Read` | `evacuateP` `NP:315-323`; `evacuateR` `NR:429-437` | read the owner's own slot | P6.M3 | `OwnerWrites` (checked here) |
| `E_Kind` | filters `NP:323-331` (`isInFromSpace`, `mayBeYoungLarge`); `R.roleOf` switch `NR:441-489` | classify by pause-immutable state (P6.M11; the role table) | P6.M11 | — |
| `E_Kind` (region Hand) | `Role::Hand` `NR:467-472` | record the slot into `rw.H` / `rw.S` (owner-only list) | rw lists | `AtJoin` (Hand recorded) |
| `E_Kind` (region Retire) | `Role::Retire` `NR:479-481` → `resolveRetire` `NR:352-370` | slot := the shadow's tenured copy (the shadow is immutable in the pause) | P6.M3 | `SlotsAtCopy` |
| `E_Load` | `mw::loadHeader` (`MW:64-66`) at `NP:332` / `NR:450` | acquire load of the header word | P6.M1 | — |
| `E_Loop` | the `for (;;)` at `NP:333-341` / `NR:451-459` | branch on the observed word (no shared access) | — | — |
| `E_Wait` | `waitPublishedP` `NP:245-248` → `mw::waitPublished` (`MW:90-102`) at `NP:335` / `NR:453` | acquire loads until not BUSY (the model blocks on `await`) | P6.M1 | deadlock check; `Termination` |
| `E_Claim` | `mw::claim` (`MW:68-80`) at `NP:339` / `NR:457` | CAS header → BUSY; on failure the observed word is kept | P6.M1 | `CopyOnce` |
| `C_Alloc` | `copyClaimed` `NP:250-300` (size from the saved header `:255`, `shouldPromote` `:257`, `allocatePromotion` `:259` or `labAllocate` `:287`); `copyClaimedR` `NR:372-408` | allocation: a relaxed CAS on `top` or a LAB bump (disjoint claims); a canonical fresh copy id | P6.M4, P6.M6 | `SizeFaithful` |
| `C_Body` | `memcpy` of the body `NP:301-302` / `NR:420-421` | private destination, immutable source | P6.M2 | `SizeFaithful` |
| `C_Hdr` | `memcpy` of the fixed-up header `NP:303-304` / `NR:422-423` | private destination | — | `FwdComplete` |
| `C_Pub` | `mw::publish` (`MW:82-88`) at `NP:311` / `NR:424` | release store of the forward word | P6.M1 | `FwdComplete`, `AtJoin` |
| `E_Slot` | `NP:343-344` / `NR:461-464` | slot := copy (owner-only); `pushGreyP` if the tag has children | P6.M3, grey | `SlotsAtCopy` |
| `S_Init`, `S_Loop` | `spineRunP` `NP:397-407`; `spineRunR` `NR:534-546` | read our own `prev->tail`; Nil ends the run (`NP:403-405`); not from-space → `evacuateP` (`NP:407`) | P6.M3 | — |
| `S_Load` | `NP:408-421` / `NR:547-560` | `loadHeader`; forwarded → link and end (`:409-413`); not a Cons → `evacuateP` (`:414`); `k == MINOR_SPINE_RUN` → push the last copy and end (`:415-421`) | P6.M1, grey | — |
| `S_Wait` | `NP:410` / `NR:549` | `waitPublishedP`, then link the other worker's copy and end | P6.M1 | — |
| `S_Claim` | `NP:422` / `NR:561` | `mw::claim`; on failure `continue` (re-read the tail, re-load) | P6.M1 | `CopyOnce` |
| `S_Copy`, `S_Link` | `NP:423-429` / `NR:562-568` | copy (as `C_*`); `prev->tail = copy`; `needs_heads`; the cell becomes the run's own | P6.M3 | — |
| `S_Heads`, `S_HeadLoop`, `S_HeadNext` | `NP:431-441` / `NR:570-577` | the counted heads pass, `m = truncated ? k - 1 : k`, only if `needs_heads && k > 0` | P6.M3 | `OwnerWrites` (via `E_Read`) |
| `S_Walk`, `S_WalkNext` | mutant `heads_walk` only | a heads pass that walks tails "while in to-space" | — | `OwnerWrites` |
| `Y_Lock` | `reachYoungLargeP` `NP:361-381`; `reachYoungLargeR` `NR:495-530` | the whole `ylos_mu_` section: `youngLargeMeta` (`OGH:1188-1194`), colour test-and-set, then `promoteYoungLarge` (`OGS:7107-7129`) or `age++` (`NP:378`) / `age = 1` (`NR:524`) | P6.M9 | `YlosOnce` |
| `Y_Set` | mutant `ylos_unlocked` only | the colour set in a later critical section | P6.M9 | `YlosOnce` |
| `Y_Push` | `NP:382-390`; `NR:531` | `pushGreyP` after unlocking | grey | `YlosOnce` |

Not stepped (single-threaded, before the gang or after the join): the pre-drain sweep slice
(`NP:644-658`, `NR:797-802`), to-space and promotion setup (`NP:663-667`, `NR:804-812`), the LAB
close (`MW:242-266` at `NP:765-779` / `NR:886-897`), the merge and deferred large-body work
(`NP:781-827`), the validators (`NP:844-875`).

## 3. Abstractions, and why each is sound

| Real thing | Model | Argument |
|---|---|---|
| heap memory, tags, byte sizes | object ids with a sequence of fields; size = number of fields | M3 is about which object is copied where, not bytes |
| pointer values and the address tests | disjoint id ranges: from-space 1..6, copies `100 * k + o`, YLOS 7, old 9, Hand 11, Retire 12, `Nil = 0` | `isInFromSpace` (`NurserySpace.hpp:387-394`), `mayBeYoungLarge` (`OGH:1184-1186`) and `RegionState::roleOf` (`NurseryRegions.hpp:215-224`) read only state that nothing writes during the drain (P6.M11; the role table is rebuilt at `NR:724` before the drain and by `checkAndGrow` (`:1021`) and `rebuildRoles(false)` (`:1090`) after it). So membership is exact |
| `Nil` | stands for null and for every embedded constant (`ptr_ind == 1`: `[]`, `True`, `Unit`) | the filters drop both before any header load (`NP:323`, `NR:437`); a constant head never sets `needs_heads` (`NP:424`) |
| the header word | `Unfwd` (any unforwarded header), `Busy`, or a copy id | the model **assumes** the encodings never collide; CR-011's unit test must check it (§7) |
| `labAllocate`, `allocatePromotion`, `bld_bottom.fetch_sub` | `C_Alloc` picks the lowest free canonical id `100 * k + o` | each is a disjoint claim; only disjointness matters. At most one copy per worker per object even under the double-copy mutant (a worker copies only after loading `Unfwd`, which never comes back), so `k ≤ |Workers|`. No allocation-order factor |
| the copy's `memcpy`s | `C_Body`, `C_Hdr`, then `C_Pub` | the destination is private until the publish and the push; the source is immutable (P6.M2) |
| the grey set: private stacks, deques, stealing, termination | one shared set; a worker takes any entry atomically; the drain ends when the set is empty and nobody is busy | M2's **Drain** contract. Any worker may take any entry at once, so the model over-approximates who scans what (the code's pushes are private until published) |
| chunk entries (arrays over 1,024 elements) | not modelled | a chunk is an entry over a disjoint slot range of one object; ownership is per range (plan §11 Q1) |
| promotion inputs | `Promotes(v) == Mode = "legacy" /\ Age[v] >= PromoAge /\ v \notin Builders` | `shouldPromote` reads the saved header, which is immutable. The region minor never promotes (`copyClaimedR`, TV9 at `NR:381`) |
| the PM5 premise | built into the heap's ages | a promoted parent's children are at least as old (generational ageing, HEAP_005) |
| `ylos_mu_` section | one step (`Y_Lock`), then `Y_Push` | A1: one critical section is one step. Sound while nothing outside `ylos_mu_` writes the YLOS index or header during the drain: true in region mode; in legacy mode see §4 (CR-014, CR-019; both fixed) |
| `resolveRetire` | the constant map `RetireFwd` | `ThreadLocalHeap::minorGC` joins and merges the tenure job before the region minor (`ThreadLocalHeap.cpp:722-733`), and `minorGCRegion` checks `Merged` (TV1, `NR:716-718`) |
| addresses are never reused inside the pause (ids are never recycled) | ids are fixed; `C_Alloc` never returns an id in use or `YlosIds` | ABA audit, 2026-09-29 (AUDIT.md): only the mutator registers a body or YLOS in `large_body_index_` (`registerLargeBody` `OGS:7526`, reached only from `allocateYoungLarge` / `allocateLargeBody`), and no major runs inside a minor pause (the nursery never calls `majorGC`; a failed promotion aborts, `NP:263-267`). During the drain the index only loses entries (CR-014's release). A cell a sweep slice frees for a promotion was dead at the last mark, so its index entry was already erased (`retireDeadLargeBodies` `OGS:1793`, before any reuse), and no slot the drain reads names it. So `youngLargeMeta(p)` in `Y_Lock` names the object the slot names |
| Hand slots | recorded as `<<parent, index>>` | the H / S split (`NR:470-471`) is a per-entry colour, owner-only; recording completeness is M5's |
| LAB fillers (retirement inside the drain, `MW:221-224`; `closeLabs`) | not modelled | owner-only memory until the join; nothing walks to-space or the fill before it; PM3 checks the result |
| builders, PrevBuilders, the 07b Age role, the hand-over YLOS branch | not modelled | the same claim loop (only the allocator differs), or M5's (plan §3.8) |
| the n = 1 drain (`runMarkerLoop` on the mutator) | not a separate configuration | a special schedule of the two-worker model |

## 4. Footprint rows (A3)

| Row | Location | Model |
|---|---|---|
| P6.M1 | from-space header words (CAS claim, release publish, acquire load) | `hdr` |
| P6.M2 | from-space bodies (immutable) | `fld[o]` for `o \in FromIds`, never written |
| P6.M3 | slots of copies; root slots (owner-only; roots by worker 0 before the gang) | `fld`, `roots`, checked by `OwnerWrites` |
| P6.M4 | `tospace_.top` (relaxed CAS); LAB interiors (owner-only) | `C_Alloc`'s canonical ids |
| P6.M5 | worker cursor blocks | M4 |
| P6.M6 | promotion rungs 2–8 under `promo_mu_` | M4; `C_Alloc` stands for a successful `allocatePromotion` |
| P6.M7, P6.M8 | byte and stats counters (per-worker, merged after the join) | not modelled (owner-only) |
| P6.M9 | `large_body_index_`, `large_bodies_`, `nursery_owned_bodies_`, `free_large_body_ids_`; the YLOS header's age bits | `yReached`, `yPromoted` under `Y_Lock`. **Legacy mode:** two writers outside `ylos_mu_` exist (below) |
| P6.M10 | `young_large_scan_`, `promoted_buf_` | not used during the drain (per-worker logs, merged after) |
| P6.M11 | nursery bounds, `from_is_low_`, `use_hybrid_dfs_`, `minor_color_`, `ylo_lo_`/`ylo_hi_` (read-only during the drain) | constants (`FromIds`, `YlosIds`) |
| P6.M12, P6.M13 | validate-only and instrumentation globals | not modelled |
| P6.M14, P6.M15 | helper-pool jobs; 5c background markers | M6/M7; M1 |
| region | role table (`role_of_k`, `prev_k`, `prev_bld_off`) | constants (`HandIds`, `RetireIds`) |
| region | `hand_ylos` (read-only), `hand_ylos_reached` (under `ylos_mu_`) | folded into `yReached` |
| region | `rw.S`, `rw.H`, `rw.SA` (per-worker, merged after the join) | `recorded` |
| region | `bld_bottom` (relaxed `fetch_sub`) | not modelled (builders out of scope; plan §11 Q2) |
| region | the Retire extent's shadow (immutable in the pause) | `RetireFwd` |

**Writers of P6.M9 outside `ylos_mu_` during a legacy drain** (code reading, 2026-09-28; M3 cannot
see them, since it has no sweep):
- CR-014: `lazySweep`'s tail completion (`OGS:5466-5472`) → `onSweepComplete` → `maybeShrinkCapacity`
  (`OGS:5502`) → `releaseBlockToAllocator`, which iterates and erases `large_body_index_`
  (`OGS:6056-6073`) under `promo_mu_`. Every other `releaseBlockToAllocator` route also goes
  through `maybeShrinkCapacity` (`OGS:5873`, `:5890` via `releaseUnassignedBlockToAllocator`).
- CR-019 (**fixed 2026-10-01**, register-fixes §6.1): the gap sweep read the header of a marked
  young YLOS while `reachYoungLargeP` wrote its age bits (`h->age++`, `promoteYoungLarge`'s
  `age = 0`). Both sides now use one relaxed atomic whole-word access (`loadHeaderRelaxed` /
  `storeHeaderRelaxed`, `AllocatorCommon.hpp`; also region `reachYoungLargeR`'s `age = 1` and the
  validate-only V11 walk). No ordering is needed: the writer keeps tag/size/pin and is the word's
  only writer within the minor (`YlosOnce`). A footprint change only: the `ylos_mu_` section stays
  one step (`Y_Lock`), and M3 still has no sweep.
- Not writers during the drain: `lazySweep`'s header-walk erases (`OGS:5311`, `:5404`) run only
  without bitmap allocation, and the parallel minor requires it (`resolveMinorThreads`,
  `OGS:2948`); `retireDeadLargeBodies` / `classifyBlocksAfterMark` run at the mark handoff;
  `promoteLargeHeader`, `sweepNurseryLargeBodies` and `freeLargeBodyCell` run after the join.
- Region mode: `copyClaimedR` never calls `allocatePromotion`, so no sweep slice runs inside the
  drain, and `ylos_mu_` covers P6.M9.

## 5. Invariants and properties (A7)

| Name | Id | What it says | Where the code checks it |
|---|---|---|---|
| `CopyOnce` | PM1, HEAP_067 ("copied exactly once") | no from-space object has two copies | PM1, `NP:868-873`; region `NR:966-1006` |
| `FwdComplete` | MODEL_M3_2 (the design rule behind `mw::publish`'s release) | a forward word names a complete copy. **It guards a rule, not an observed reader:** no reader during the drain reads through a forward word; readers only store the address | — |
| `SizeFaithful` | HEAP_067 ("sizes the object from the SAVED header") | a complete copy has all the original's fields | the comment at `NP:255`; PM3 would see a short copy only indirectly |
| `YlosOnce` | HEAP_062 | each YLOS is pushed at most once per minor | — |
| `OwnerWrites` | MODEL_M3_1 (the 06 plan's owner-only premise, P6.M3) | at every `E_Read`, the worker owns the slot's object | — (TSan, `gc-minor-tsan`) |
| `AtJoin` | PM2 + HEAP_006 (no BUSY after the pause) + PM5 (HEAP_005) + HEAP_069 (Hand recorded) | at the join: no BUSY; every reachable from-space object forwarded; `SlotsAtCopy`; no promoted object points at a surviving copy; region Hand slots recorded | PM2 `NP:859-864`; PM5 `NP:276-283`, `:373-374` |
| `CopyOnceContract` | parent plan §5.0 **CopyOnce** | `CopyOnce`, and at the join `SlotsAtCopy` | — |
| `Termination` (deep) | — (PlusCal's) | every worker exits under weak fairness: the BUSY wait ends | — |

## 6. Contracts

- **Assumed:** Drain (M2: every pushed entry is scanned once; the drain ends only when no work is
  left); LaunchJoin (M6: the gang start publishes the root phase's writes, and the join publishes
  the workers').
- **Provided:** **CopyOnce** = `CopyOnceContract`, used by M5.

## 7. Weak memory (A4) and the header encoding

The model is sequentially consistent.

| Reliance | Code | Companion | Status |
|---|---|---|---|
| `publish` (release) → `loadHeader` / `waitPublished` (acquire): a worker that stores the forward address never needs the copy's contents, but the copy's scanner must see them | `MW:64-102` | W5 (claim → copy → publish on a header word) | W5(a) PASS; `W5_RELAXED_PUBLISH` and `W5_RELAXED_CLAIM_FAIL` are flagged (`test/genmc/AUDIT.md`, 2026-09-28) |
| the deque's release/acquire element transfer makes a pushed copy's contents visible to the thief that scans it | `MarkWork.hpp` Chase–Lev | W1 | W1 PASS, including two thieves; its four mutants are flagged (2026-09-28) |
| the gang start publishes the root phase's copies and the role table; the join publishes the workers' writes | `GCHelperPool.cpp:407-431` | LaunchJoin (M6) | M6 |
| the colour tests (`isInFromSpace`, `roleOf`, `mayBeYoungLarge`) read only state written before the gang start | P6.M11 | none needed (no W4 dependence, CR-009) | — |
| `tospace_.top` and `bld_bottom` are relaxed RMWs used only for indivisibility | `MW:179-201`, `NR:385` | none needed (SC is fine for indivisibility) | — |

The header encoding (CR-011): the model assumes `Unfwd`, `Busy` and a forward word never collide.
That is a C++ layout property, not an interleaving, so neither TLC nor trace validation can see a
mismatch (the harness decodes with `mw::fwdAddr`, which always agrees with `mw::fwdWord`). The
unit test CR-011 asks for is the guard.

## 8. Accuracy rules (A1–A9)

| Rule | M3 |
|---|---|
| A1 | §2: each label is one atomic operation on shared memory or one owner-only change. The claim compares the observed word. The copy is allocation, body, header, publish. The `ylos_mu_` section is one step. Each cell of a spine run is its own load, claim, copy and link |
| A2 | a header is one 64-bit word changed only by the CAS and the release store (colour lives inside the forward word). Slots are whole words, owner-only. The body `memcpy` is not atomic and needs no finer model: its source is immutable and its destination private until published and pushed |
| A3 | §4. The legacy P6.M9 writers outside `ylos_mu_` (CR-014, CR-019) are outside M3's scope; recorded for the register. Both are fixed (CR-014 2026-09-30: the shrink runs after the join; CR-019 2026-10-01: relaxed atomic whole-word header access) |
| A4 | §7: W5 (publish/load) and W1 (deque transfer) PASS under GenMC RC11 (2026-09-28). LaunchJoin from M6 |
| A5 | `TraceMinorForwarding.tla` over `gc-minor-trace tiny ...` (`test/gc-helper-tsan/minor_harness.cpp`, trace build; `traces.txt`): the real `MinorWork.hpp` claim / publish / wait and `runMarkerLoop` on `GCMarkGang`, through the harness's replica of `evacuateP` / `spineRunP` / `copyClaimed` / `reachYoungLargeP`. Events and hooks in §11. Not traced: the production `NurseryParallel.cpp` / `NurseryRegion.cpp` functions (the canary covers drift between them and the replica), region mode, chunk entries |
| A6 | every invariant has a mutant that TLC rejects with its name (§9); the deadlock check and `Termination` have `never_publish`. The region-only conjuncts of `AtJoin` (Hand recorded, Retire resolved) have no M3 mutant: they are sequential logic, and M5's recording mutants cover them |
| A7 | §5 |
| A8 | 2 workers (3 in deep), 6 from-space objects, a 3-cell spine with `MaxRun = 1` (a run is truncated, or ends at another worker's copy) and `MaxRun = 2` (a two-cell run to Nil), one YLOS with two parents in both modes. Copy ids `100 * k + o`, `k ≤ |Workers|`. Nothing wraps; no state constraint |
| A9 | canary lines not yet in `test/tla/manifest.txt` (later wave); proposed in AUDIT.md |

## 9. Mutant counterexamples (TLC, shortest)

The first 27 states of every counterexample are the serial root phase: worker 1 copies `1 → 101`
and `3 → 103` and pushes both. Worker names below are TLC's (1 = the mutator, worker 0 in the code).

| Mutant | Target | States | The counterexample |
|---|---|---|---|
| `size_from_busy` | `SizeFaithful` | 12 | worker 1's first root copy is sized from the BUSY word: `101` gets no fields |
| `publish_early` | `FwdComplete` | 10 | worker 1 publishes `FWD(101)` at `C_Alloc`, before the body and header are copied |
| `copy_without_cas` | `CopyOnce` | 82 | worker 1 scans `103`, reaches `7`, and its run copies `4 → 104` and stops at `5` (truncated, `104` pushed). Worker 1 takes `7` and loads `Unfwd` from `5`. Worker 2 takes `104`; its run claims `5` at `S_Claim`. Worker 1's claim ignores the BUSY word: `105` and `205` |
| `no_wait` | `AtJoin` | 134 | worker 1 (scanning `101`) claims `2`. Worker 2, scanning `105`, loads `2`'s BUSY word and stores address 0 into `105`'s head. At the join `105 = <<0, 0>>`, not `<<102, 0>>` |
| `no_wait_contract` | `CopyOnceContract` | 134 | the same behaviour |
| `heads_walk` | `OwnerWrites` | 71 | worker 1 scans `103`, reaches `7` and pushes it; its run copies `4 → 104`. Worker 2 takes `7` and copies `5 → 105`. Worker 1's run loads `FWD(105)`, links `104 → 105` and ends (not truncated). Its walk evacuates `104`'s head, then follows `104`'s tail to `105`, which worker 2 made |
| `heads_all` | `OwnerWrites` | 53 | worker 1's run from `103` copies `4 → 104`, finds `5` unforwarded at `k = MaxRun = 1`, pushes `104`, then evacuates `104`'s head |
| `ylos_unlocked` | `YlosOnce` | 60 | worker 1 scans `101`, worker 2 scans `103`; both reach `7` and pass the colour test before either sets it; two pushes |
| `never_publish` | deadlock | 100 | a claimant never publishes; worker 1 waits at `S_Wait` on `5`, worker 2 at `E_Wait` on `2` |
| `never_publish_liveness` | `Termination` | 127 | the same, as a stuttering behaviour with deadlock checking off |

## 10. Differences from the plan's sketch (all recorded in AUDIT.md)

- `Unfwd` and `Busy` are model values: TLC cannot compare the sketch's strings `"H"`/`"BUSY"` with
  the integer copy ids in `hdr[o] \in CopyIds`.
- `spineRunP` fidelity: `needs_heads`, the Nil tail that ends the run without an evacuate, and the
  header load before the Cons test.
- The heap: `4 = Cons(9, 5)`; the region heap keeps both of the YLOS's parents.
- Added: `MC_quick_legacy_run2`, `MC_deep_region3`, `MC_deep_liveness`, and mutant
  `never_publish` (deadlock and `Termination` forms).

## 11. Trace validation (A5)

`TraceMinorForwarding.tla` EXTENDS `MinorForwarding` and `common/TraceAnyOrder.tla`. The log comes
from `minor_harness.cpp`'s tiny mode in the trace build (target `gc-minor-trace`,
`-DECO_TLA_TRACE=1`, `test/tla/trace/TlaTrace.cpp` linked, no TSan):
`gc-minor-trace tiny <seed> <workers> <spine run> <pace us>`. Seed 0 is `MC.tla`'s legacy heap;
other seeds are random heaps of the same kind (5–6 objects, Cons cells, a YLOS with 1–2 parents,
old 9, three roots, acyclic, ages non-increasing in allocation order so that PM5's premise holds).
`<pace us>` adds random pauses at the protocol points, so the workers race on eight objects.
The header carries the heap (`from`, `cons`, `ylos`, `old`, `objs` = id, age, slots; `roots`;
`workers`, `maxrun`, `promoage`), and the `.cfg` takes every constant from it (`TH_*`).

Threads: `mut` (worker 0: the root phase, then member 0 of the drain) is model worker 1;
`eco-mark<i>` (gang member i, named by `GCMarkGang`) is model worker i + 1. Object ids are the
model's: an original or a YLOS logs its id (word 1), a copy logs `100 * k + id` with k its copy
number (a harness table filled at the copy), so a second copy of an object would log `200 + id`.

| Event | Hook (file, function) | Fields | Model step |
|---|---|---|---|
| `claim` ok | `MinorWork.hpp`, `claim` (after the CAS) | `obj`; `rmw h<addr>`, `old W<word>`, `new W26` | `E_Claim` / `S_Claim` succeeding |
| `claim` lost | same | `obj`; `rd h<addr>`, `val`; `w`, `to` (the observed word) | `E_Claim` (`ehw'` = the word) / `S_Claim` (back to `S_Loop`) |
| `publish` | `MinorWork.hpp`, `publish` (after the release store) | `obj`, `dst`; `rmw`, `old W26`, `new W<fwd>` | `C_Pub` (`hdr'[obj] = dst`) |
| `wait` | `MinorWork.hpp`, `waitPublished` (its first non-BUSY load) | `obj`; `rd`, `val`; `w`, `to` | `E_Wait` / `S_Wait` |
| `load` | harness `evacuate` and `spine`, after `mw::loadHeader` (not in `loadHeader`: `waitPublished` spins on it) | `obj`; `rd`, `val`; `w` (0 unforwarded, 1 BUSY, 2 forwarded), `to` | `E_Load` / `S_Load` with `hdr[obj]` = the word |
| `copy` | harness `copyClaimed`, after the allocation | `obj`, `dst` (`100 * k + id`), `promote` | `C_Alloc` (`cd'`, `promo'`) |
| `slot` | harness `evacuate`, after the store (with `put e<dst>` when the copy is pushed) | `parent` (0 = a root), `idx` (1-based), `val` | `E_Slot`, or `E_Loop` on a forward word |
| `link` | harness `spine`, after `prev[3] = c` | `prev`, `cell` | `S_Link` |
| `trunc` | harness `spine`, the bounded run's push (`put e<prev>`) | `prev` | a check after `S_Load`'s push |
| `heads` | harness `spine`, entering the heads pass | `m` | `S_Heads` → `S_HeadLoop`, `sm' = m` |
| `scan` | harness `Copier::scan` (an entry taken; `get e<addr>`) | `e` | `W_Loop`'s take, `we' = e` |
| `ylos` | harness `reachYoungLarge`, inside `ylos_mu` (`clk ylos`, `tick`) | `obj`, `won`, `promoted` | `Y_Lock` |
| `ypush` | harness `reachYoungLarge`, after unlocking (`put e<obj>`) | `obj` | `Y_Push` |
| `gang.*` | `GCHelperPool.cpp` (shared) | — | ordering only (dropped by `TraceMinorForwarding.keep`) |

**Ordering.** A header word's events chain by the raw words they read and wrote (`rd` / `rmw` on
`h<addr>`: unforwarded → BUSY by the claim, BUSY → forward by the publish); a take follows its
push (`put` / `get`); the `ylos_mu` sections are totally ordered by their clock; the gang events
order the root phase before the members. TLC matches events in any order those allow.

**Hidden** (unlogged model steps): `W_Roots`, `W_RootLoop`, `W_RootNext`, `W_Start`, the drain's
exit, `W_Scan`, `W_Idle`, `W_Exit`, `SC_*`, `E_Read`, `E_Kind`, `E_Loop` towards a claim or a
wait, `E_Copy`, `C_Body`, `C_Hdr`, `S_Init`, `S_Loop`, `S_Copy`, `S_Heads` → `S_Done`,
`S_HeadLoop`, `S_HeadNext`, `S_Done`. **Never:** `S_Walk`, `S_WalkNext`, `Y_Set` (mutants only).

**Negative controls** (`traces.txt`, on seed 0, whose root phase is serial): a second copy of 1
(`set:copy:1:dst=201`); 1 not promoted (`set:copy:1:promote=false`); a BUSY word before any claim
(`set:load:1:w=1`); the root slot never written (`drop:slot:1`); the copy before its claim
(`swap:claim:1`); a forward naming the wrong copy (`set:publish:1:dst=103`); the first YLOS reach
lost (`set:ylos:1:won=false`); a heads pass over two cells of a one-cell run (`set:heads:1:m=2`); a
take of a from-space object (`set:scan:1:e=5`). Each is rejected.

**What a trace checks, and what it cannot.** It checks that `MinorWork.hpp`'s primitives and the
harness's copy loop, under the real work distribution, only ever do what the model allows: every
claim, lost claim, wait, copy (its number and promotion), publish, slot store, spine link and
truncation, heads count, take and YLOS reach. It does not check the production
`evacuateP` / `spineRunP` / `copyClaimed` / `reachYoungLargeP` / region functions themselves (the
harness replicates them; the canary pins both sides), and it cannot see a forward-word layout
mismatch (CR-011: the harness decodes with `mw::fwdAddr`).

**Footprint note (2026-09-29):** the minor drain's `MinorWorker` slots (deque, private stack, `priv`)
and its `SliceControl` (06 P§3.11 row M17, footprint row `P6.M17`) are covered by M2 (the Drain contract);
M3 uses them only through that contract.

<!-- canary-pins begin -->
## Canary pins (A9)

The code this model describes, pinned in `test/tla/manifest.txt` (generated 2026-09-29
from this model's A9 row). A pin that fires names this model; re-audit, then write an
AUDIT.md entry quoting the new hash prefix (`test/tla/README.md`, "The canary").

| Kind | Path | Id |
|---|---|---|
| file | `runtime/src/allocator/MinorWork.hpp` | `-` |
| file | `runtime/src/allocator/NurseryRegions.hpp` | `-` |
| file | `runtime/src/allocator/TlaTrace.hpp` | `-` |
| file | `test/gc-helper-tsan/minor_harness.cpp` | `-` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.promoteYoungLarge` |
| region | `runtime/src/allocator/OldGenSpace.hpp` | `OGH.youngLargeMeta` |
| region | `runtime/src/allocator/OldGenSpace.cpp` | `OGS.registerLargeBody` |
| region | `runtime/src/allocator/NurseryParallel.cpp` | `NP.MinorEnv` |
| region | `runtime/src/allocator/NurseryParallel.cpp` | `NP.copyClaimed` |
| region | `runtime/src/allocator/NurseryParallel.cpp` | `NP.evacuateP` |
| region | `runtime/src/allocator/NurseryParallel.cpp` | `NP.reachYoungLargeP` |
| region | `runtime/src/allocator/NurseryParallel.cpp` | `NP.spineRunP` |
| region | `runtime/src/allocator/NurseryParallel.cpp` | `NP.scanEntryP` |
| region | `runtime/src/allocator/NurseryParallel.cpp` | `NP.minorGCParallel` |
| region | `runtime/src/allocator/NurseryRegion.cpp` | `NR.RegionEnv` |
| region | `runtime/src/allocator/NurseryRegion.cpp` | `NR.resolveRetire` |
| region | `runtime/src/allocator/NurseryRegion.cpp` | `NR.copyClaimedR` |
| region | `runtime/src/allocator/NurseryRegion.cpp` | `NR.evacuateR` |
| region | `runtime/src/allocator/NurseryRegion.cpp` | `NR.reachYoungLargeR` |
| region | `runtime/src/allocator/NurseryRegion.cpp` | `NR.spineRunR` |
| region | `runtime/src/allocator/NurseryRegion.cpp` | `NR.scanEntryR` |
| region | `runtime/src/allocator/NurseryRegion.cpp` | `NR.minorGCRegion` |
| census | `runtime/src/allocator/AllocatorCommon.hpp` | `-` |
| census | `runtime/src/allocator/MinorWork.hpp` | `-` |
| census | `runtime/src/allocator/NurseryParallel.cpp` | `-` |
| census | `runtime/src/allocator/NurseryRegion.cpp` | `-` |
| census | `runtime/src/allocator/NurseryRegions.hpp` | `-` |
| census | `runtime/src/allocator/NurserySpace.cpp` | `-` |
| census | `runtime/src/allocator/NurserySpace.hpp` | `-` |
| grep | `-` | `P6.M1` |
| grep | `-` | `P6.M4` |
| grep | `-` | `P6.M5` |
| grep | `-` | `P6.M6` |
| grep | `-` | `P6.M7` |
| grep | `-` | `P6.M8` |
| grep | `-` | `P6.M9` |
| grep | `-` | `P6.M11` |
| grep | `-` | `P6.M12` |
| grep | `-` | `P6.M13` |
| grep | `-` | `P6.M17` |
| grep | `-` | `F.roles` |
| grep | `-` | `F.ylobox` |
<!-- canary-pins end -->
