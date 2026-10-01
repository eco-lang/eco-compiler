# Threaded GC: fixing the concurrency register

**Status:** Phases 0-3 built (2026-09-30; §11, §12, §13), Phases 4 and 5 built (2026-10-01; §14, §15): every guarded register entry is Fixed or Won't-fix and `ECO_TEST_XFAIL=strict ... register-guards` is green. Owed at the close-out: the §8 performance comparison and G8. Decisions recorded in §0: CR-012 option F; the wider CR-038 variant row runs first; correctness before performance.

**Parents:**
- `plans/threaded-gc-concurrency-register.md`: the register. Every status change is recorded there.
- `plans/threaded-gc-register-repros-impl.md` (§13): the guards that reproduce every defect.
- `plans/threaded-gc-tla-verification.md`: the model rules (A6, GC_MODEL_001).

**Tree.** Line numbers are from the tree of 2026-09-30. Functions are named too, because lines drift. `OGS` = `runtime/src/allocator/OldGenSpace.cpp`, `OGH` = `OldGenSpace.hpp`, `CRT` = `test/allocator/ConcurrencyRegisterTest.cpp`, `AL` = `Allocator.cpp`.

---

## 0. Goal, scope and the definition of done

**Goal.** Fix every open register defect that has a guard. Each fix is the model-checked candidate wherever the models already have one, so that every fix:
1. makes its guard XPASS, and the guard is then converted to a permanent regression guard;
2. flips the model rows that reproduced it from `violates:` to `pass`, with the old behaviour kept as a mutant (rule A6);
3. comes with the invariant text that states the new rule.

| Area | Entries | Phase |
|---|---|---|
| Old-gen block lifecycle (serial) | CR-033, CR-018 (+ CR-001's S1 half), CR-035, CR-016, CR-036 | 1 |
| Sweep and parallel promotion | CR-014, CR-001 (race), CR-002, CR-028 | 2 |
| Region nursery and snapshot marking | CR-037, CR-017, CR-038 | 3 |
| Page supply, mutators, YLOS header | CR-019, CR-012, CR-007 | 4 |
| Fork, exit, gangs | CR-003, CR-004, CR-005, CR-013, CR-015, CR-023, CR-031, CR-032 | 5 |

**Definition of done:**
- `ECO_TEST_XFAIL=strict cmake --build build --target register-guards` is **green**. Every register guard is either a fixed guard that passes, or a documented won't-fix guard (CR-012, §6).
- Every M1-M8 quick and deep row, `tla-trace`, `genmc-check` and the canary give their expected verdicts.
- GC time on the benchmark set is within the per-phase budget (§8).

**Out of scope:** the benign M2 epoch-ABA witness (`MC_quick_wrap`), and CR-029 options (b) and (c). Both options are recorded in §2.6 as follow-ups.

**Decisions (2026-09-30, the user):**
1. **CR-012: option F.** A second live mutator is **forbidden**: `initThread` aborts, except under an explicit opt-in used only by the benchmark driver and the test harnesses (§6.2). Option S is not pursued.
2. **The wider CR-038 variant gets a model row, run first** (Phase 0, Step 0.4). If it violates, it is registered as CR-039 before any fixing starts.
3. **Correctness first, performance second.** Every fix ships even when it is over its performance budget. The budgets in §8 are targets: an overrun is recorded, and it is optimised in a follow-up where the fix names a mitigation.

---

## 1. How every step is done (common procedure)

Every fix follows these seven steps, in this order. The per-fix sections only list what differs.

1. **Re-read the invariants.** Before editing, read the `design_docs/invariants.csv` rows named in the fix (a CLAUDE.md rule), and add the amended text in the same change as the code.
2. **Model first.** Edit the model:
   - make the fixed behaviour the spec's default;
   - turn the old behaviour into a mutant;
   - flip the rows in `test/tla/models.txt`;
   - update MAPPING.md;
   - re-translate PlusCal where a `.tla` has a translation.

   Run `python3 test/tla/run_models.py --model Mn` (quick tier) and get every row to its expected verdict **before** editing the runtime. A rule that no model has checked yet (marked **NEW RULE** below) must pass TLC first.
3. **Code.** Make the change as specified. Keep the runtime compiling at every step.
4. **Flip the guards.**
   - In CRT, change `runXfailGuard` to `runFixedGuard` and drop `[xfail CR-NNN]` from the test name.
   - In `test/gc-heap-tsan/fork_arms.txt`, change `xfail` to `clean` and delete `match=`.
   - Converted guards must pass; a NOT REACHED result means the guard needs the precondition rework noted in the fix.
5. **Run the gates:**
   - `ulimit -c 0`;
   - `build/test/test --filter "CR-0"` in `build` and `build-validate`;
   - the full unit suite once;
   - `ECO_TEST_XFAIL=strict cmake --build build --target register-guards`: fewer rows fail, and the converted ones pass;
   - the model rows named in the fix;
   - `python3 test/tla/run_traces.py` when a traced path changed;
   - `test/genmc/run_drivers.py` when a W-driver pin changed.
6. **Canary (GC_MODEL_001).**
   - Run `bash test/scripts/check-tla-manifest.sh .`.
   - For each fired pin, write a dated AUDIT.md entry in **every** model it names (for W1-W5, `w_pool_done` and `w_running_chain`: in `test/genmc/AUDIT.md`), quoting the new hash prefix. Each entry gives the verdict: model updated, or no model change, and why.
   - Only then run `--update`.
   - Never repair a hash without the audit.
7. **Record it.** In the register, set Status to Fixed and fill in the Fix row with the change and the guard. Add a History line. Update the summary table.

**Taking snapshots.** Git is unusable in this worktree. Before each phase, run `tar czf snapshots/register-fixes/pre-phaseN.tgz runtime/src/allocator test/allocator test/gc-heap-tsan test/tla test/genmc design_docs/invariants.csv plans/threaded-gc-concurrency-register.md`.

**Traps that apply everywhere:**
- Abort-based guards write core dumps into /work, so always run them with `ulimit -c 0`.
- Read each child's message before recording a PASS or an XPASS: a guard can pass or fail for the wrong reason.
- The unit binary does not build in `build-nostats` (a pre-existing problem, repros §13.3).
- GC_DET_001 reference counters shift in Phases 1-2. Re-baseline them once per phase, and record why in AUDIT.md.

---

## 2. Phase 0: guard infrastructure (before any fix)

### Step 0.1: a won't-fix guard kind

`runWontFixGuard(id, scenario)` goes in CRT, next to `runXfailGuard`:
- `kDefect` or SIGABRT prints `WONTFIX <id>` and **passes in both modes**;
- `kCorrect` fails as `XPASS: the accepted behaviour changed`;
- `kNotReached` fails.

`run_fork_arms.py` gets the matching expectation `wontfix`:
- exit 1 gives WONTFIX, which passes in both modes;
- exit 0 gives XPASS, which fails;
- anything else is an ERROR.

CR-012's opt-in guards use this kind (§6.2 step 7), so strict mode can go green while they keep documenting the accepted behaviour.

### Step 0.2: `runDeathGuard(id, scenario)` in CRT

- A SIGABRT in the child is a **pass**; anything else fails.
- Do not call `abortMeansNotReached()` in these scenarios.
- It is used by CR-012 (the "forbid" check).

### Step 0.3: test accessors

Add to `OldGenSpaceTestAccess` (`OGH` ~:2059):
- `static uint64_t sweepTailInPromotion(const OldGenSpace& og)`, which returns `alloc_stats_.bm.sweep_tail_in_promotion` (stats builds). CR-014's fix makes `sweepCompleteDeferred` true on both completion paths, so the guards need this counter to prove the tail path.
- `static void setIdleUncounted(OldGenSpace& og, bool on)`, which sets the CR-018 negative-control hook (§3.2 step 3).

These fire the footprint greps. Their audit entry says "test accessor, no model change".

### Step 0.4: the model row for the wider CR-038 variant (decision 2)

This is run before any fix, because its verdict can add a register entry.

**The suspected chain (k = 2):**
- YLOS Z joins at minor 1 (X1's generation), and YLOS Y → Z joins at minor 2 (X2's generation).
- Both die in epoch 2.
- Z is unreached at its hand-over (minor 3) and is freed at minor 4's merge.
- The dead Y is still indexed at minor 4, so minor 4's `snapshotYoungLarge` runs `markChildren(Y)`.
- `greyObject` drops young targets by address range, but Z is no longer young. So t0 greys a **freed old-gen cell**, which is CR-017 R1's hazard.

No row covers this today: M5's rows use one YLOS cell at k = 2 (`MC_k2_ylos_walk` has YC = 1).

**Steps**
1. **Config.** Copy `test/tla/M5-tenuring/MC_k2_ylos_walk.cfg` to `MC_k2_ylos_walk2.cfg`. Set the YLOS cell count to 2 (the constant `MC_k2_ylos_walk.cfg` sets to 1; follow MAPPING.md's name for it) and add `INVARIANT T0GreyAllocated` next to `YoungWalkValid`.
2. **Registry row.** Add to `test/tla/models.txt`, after `MC_k2_ylos_walk`: `M5  M5-tenuring  MC  MC_k2_ylos_walk2.cfg  quick  tlc  <verdict>  # CR-038 wider variant (Step 0.4)`. Enter the observed verdict: `violates:T0GreyAllocated`, `violates:YoungWalkValid` or `pass`.
3. **Run it.** `python3 test/tla/run_models.py --model M5 --config MC_k2_ylos_walk2`. If it runs past the quick budget, move the row to the deep tier and record the state count.
4. **Record the result.**
   - **If it violates `T0GreyAllocated`:**
     - Register **CR-039** (S1-class, region mode, opt-in k ≥ 2), with the counterexample trace and the step `snapshotYoungLarge` → `markChildren(Y)` → a freed cell.
     - Add a code guard `cr038Z` to CRT, modelled on `cr038`: Z is freed at minor 4's merge, and t0 marks Z's cell. It is an xfail guard with a negative control. Add it to the repros plan (§13).
     - §5.3's fix covers it: the slots are cleared at the merge that frees Z's generation.
   - **If it only violates `YoungWalkValid`:** it is CR-038 again. Add the row and nothing else.
   - **If it passes:** record in M5 AUDIT.md why (for example, Z's freeing always comes after Y's clearing). §5.3 still fixes CR-038 as designed.
5. **Audit.** Write an M5 AUDIT.md entry with the date, the row, the verdict and the state count. No code changes, so the canary does not fire.

---

## 3. Phase 1: the old-gen block lifecycle (M8, M4)

**Order:** 1.1 CR-033, then 1.2 CR-018, then 1.3 CR-035 with 1.4 CR-016 (one canary audit: both edit `allocateFromEmptyRegularBlocks`), then 1.5 CR-036. Tell the Phase 2 owner when 1.2 lands, because 1.2 closes CR-001's S1 half.

### 3.1 Fix CR-033: every nonzero bag-page tail gets a header

**Fix.** This is the TLC control `controls/cr033_tail_header`.
- `pushSpanOnFreeLists`'s mixed branch (`OGS:5373-5392`) already writes an unlinked `Tag_Free` header for a sub-`MIN_FREE_CELL_SIZE` tail. The carve now does the same.
- Absorbing the tail into the object as slack has no model row, so it is not used.

**Steps**
1. **Carve** (`OGS:2678`, `allocateFromBagPage`'s fresh-page carve):
   - change `if (remainder >= MIN_FREE_CELL_SIZE)` to `if (remainder != 0)`;
   - add `assert((remainder & 7) == 0);` (the request is 8-aligned by the assert at `:2570`);
   - update the comment;
   - leave `age_sentinel` at its default.
2. **Invariant.** Amend **HEAP_024**: "every byte of [start, end_of_objects) of a mixed block is covered by an object or a Tag_Free header (the bag-page carve included, CR-033)."
3. **Model (M8).**
   - Invert `"bag_tail_header"` into the mutant `"bag_tail_headerless"`.
   - `MC_quick_cr033` becomes `mutants/bag_tail_headerless.cfg` (`violates:BlockParseable`), and the plain row passes.
4. **Guards.** CR-033 parse and the legacy S1 guard (`CRT` ~:2370, ~:2378) become `runFixedGuard`. The two controls stay as they are.
5. **Performance.** None: the path runs once per page.

### 3.2 Fix CR-018: count live bytes in every phase (this also closes CR-001's S1 half)

**Fix.** Option (a), TLC-checked as M8 `controls/cr018_count_idle`, `fixed_all` and `MC_deep_fixed` (14.5M states). Every allocation that goes through `initObjectHeaderWithSize` with `cell_bytes > 0` (free-list pop, split, bag-page carve) adds its bytes to `live_bytes` **in every phase**. `finalizePoppedCellW` does the same.

This makes `live_bytes` independent of the phase that a stash finalize reads. It closes CR-001's S1 half and is a strict superset of M4's `count_until_shrink`. It also fixes an existing asymmetry: `freeLargeBodyCell` subtracts at Idle (`OGS:7803-7806`, `:7863-7866`) bytes that the Idle carve never added.

**Why it is safe:**
- `resetBufferMetaForMark` (`OGS:4034-4052`) zeroes `live_bytes` at every mark.
- Every reader between a sweep's completion and the next mark treats `live_bytes` as an upper bound: the flip (`:2862`), shrink passes 1 and 2 (`:6181`, `:6197`), and stats.
- V8/IM6 check only uniform blocks, and in bitmap mode no free-list cell lies in a uniform block.

**Steps**
1. **`initObjectHeaderWithSize`** (`OGS:512-559`). Restructure it:
   ```cpp
   void OldGenSpace::initObjectHeaderWithSize(void* obj, size_t cell_bytes) {
       Header* hdr = reinterpret_cast<Header*>(obj);
       std::memset(hdr, 0, sizeof(Header));
       const bool black = marking_active || gc_phase_ != GCPhase::Idle;   // under promo_mu_ or serial: stays plain (§4.2)
       hdr->color = static_cast<u32>(black ? Color::Black : Color::White);
       if (!black && cell_bytes == 0) return;          // Idle large paths: nothing to do
       if (!contains(obj)) return;
       const BlockId block_id = blockIdFor(obj);
       if (!block_id.valid()) return;
       if (black) { /* existing TV5, IM4, setMarkBitAtomic/setMarkBitInBlock block, unchanged */ }
       if (cell_bytes > 0 && (black || !test_idle_uncounted_)) {   // CR-018: every phase
           if (black || par_promo_active_)   // stash finalizers and flushCursorW add lock-free
               std::atomic_ref<uint64_t>(blocks_.meta(block_id).live_bytes)
                   .fetch_add(cell_bytes, std::memory_order_relaxed);
           else
               blocks_.meta(block_id).live_bytes += cell_bytes;   // the owner; nothing concurrent
       }
   }
   ```
2. **`finalizePoppedCellW`** (`OGS:1124-1157`). Move the `live_bytes` `fetch_add` out of the black branch so it runs **unconditionally**, guarded by `contains` and `blockIdFor` and skipped only under `test_idle_uncounted_`. The black branch keeps only the colour and the mark bit, which CR-001's race half settles in §4.2. There must be exactly one `live_bytes` add per path.
3. **Negative-control hook.** In `OGH` ~:1502 add `bool test_idle_uncounted_ = false;`, set through `OA::setIdleUncounted` (Step 0.3).
4. **Comments.** Correct `OGS:505-510`, `:2564-2566` and `:875-877`.
5. **Invariants:**
   - **New HEAP_073 LiveBytesUpperBound:** "Outside [resetBufferMetaForMark, finalizeMetaAfterMark], `BufferMetadata::live_bytes` of a non-large block is ≥ the bytes of every object allocated into it since the last mark. Every allocator writer adds in every phase (`initObjectHeaderWithSize`, `finalizePoppedCellW`, `flushCursor[W]`). `freeLargeBodyCell`'s clamped subtraction removes only bytes that were added. Readers that treat 0 as empty (the flip, the shrink, the reclaim) rely on it (CR-018, CR-001)."
   - Amend **HEAP_051:** "the allocator side writes BufferMetadata in every phase (HEAP_073), atomically while a parallel promotion is active."
6. **Model M8.** Invert `"count_mixed_idle"` into the mutant `"idle_uncounted"` (the `Gate` in `BlockLifecycle.tla` ~:272-281).
   - `MC_quick_cr018` and `MC_quick_cr018_flip` become `pass`.
   - Add `mutants/idle_uncounted.cfg` (`violates:NoOverwriteLive`) and `mutants/idle_uncounted_flip.cfg` (`violates:FlipTrustsTruth`).
   - Retire `controls/cr018_count_idle`.
7. **Model M4.** Split `Counts(p)` into `CountsBit(p) == p # "Idle"` (colour and bit) and an unconditional live count.
   - In `FinPhase`'s Idle branch (`PromoBitmap.tla:283-295`) and in `W_PopAfterSweep` (`:527`), add `liveBytes[BlkOf(c)] := @ + 1` with `Acc1("live", FALSE, TRUE)`. Re-translate.
   - `MC_quick_sweep_release` becomes `pass` (CR-001 S1).
   - Add `mutants/idle_uncounted_release.cfg` (`violates:ReleasedSafe`).
   - Delete `controls/count_until_shrink.cfg` and its row.
   - `TracePromoBitmap`: the Idle finalize also adds `live`, and the `m4.fin` event carries the count.
   - Phase 2 edits the same `Counts` split; make it **once**, here.
8. **Guards:**
   - CR-018 (`CRT:356`) becomes `runFixedGuard`, asserting that P's `live_bytes == 3*mid`.
   - CR-001 (a) and (b) become `runFixedGuard`: they now XPASS.
   - **The CR-035 guards stop reaching their precondition,** because P's `live_bytes` is no longer 0. Set `OA::setIdleUncounted(og, true)` in `cr035Scenario` so they still isolate CR-035, and add a plain run without the hook that expects `live_bytes > 0`.
9. **Performance.** Idle mixed-block pops, splits and carves each gain `contains`, a page-index load and one add. The uniform cursor fast path is unchanged. Budget: ≤ 1 % of GC time (§8).

### 3.3 Fix CR-035: the empty-block flip purges the large-body index

**Fix.** This is the TLC control `controls/cr035_flip_purges` (and `_lost`). After 3.2 the precondition is gone; the purge stays as defence in depth, because M8 shows it closes the S1 on its own.

Use **retire** semantics (the id is **not** recycled), as `retireDeadLargeBodies` does at `OGS:1793-1810`. Release's semantics (`free_large_body_ids_.push_back`, `:6449-6450`) would not work: the caller's `registerLargeBody` would then take the dead body's id, which is still listed in `nursery_owned_bodies_`, and create a duplicate owned entry.

**Steps**
1. **New private helper**, declared next to `retireIndexEntry` (`OGH:1281`):
   ```cpp
   // Retires every index entry whose body lies in [lo, hi) (HEAP_026/056 semantics: the id is
   // NOT recycled; sweepNurseryLargeBodies drops its stale owned entry). Returns the count.
   size_t OldGenSpace::retireIndexRange(char* lo, char* hi) {
       size_t n = 0;
       for (auto it = large_body_index_.begin(); it != large_body_index_.end();) {
           char* b = static_cast<char*>(it->first);
           if (b >= lo && b < hi) { retireIndexEntry(it->second); it = large_body_index_.erase(it); ++n; }
           else ++it;
       }
       return n;
   }
   ```
2. **The flip.** In `allocateFromEmptyRegularBlocks`, after `removeFreeCellsForBlock(i)` (`OGS:2876`), call `retireIndexRange(blk.start, blk.end);`. In validate builds, add the post-check loop from `:6457-6474` with the message "flip".
3. **Invariants:**
   - Amend **HEAP_056:** "…and allocateFromEmptyRegularBlocks retires every entry inside the flipped block before placing the new object (CR-035)."
   - Amend **HEAP_026:** "an index key names at most one live meta."
4. **Model M8.** Invert `"flip_purges_index"` into the mutant `"flip_keeps_index"`.
   - `MC_quick_cr035` and `MC_quick_cr035_lost` become `mutants/flip_keeps_index{,_lost}.cfg` with `MUTANT = {"idle_uncounted","flip_keeps_index"}` (`violates:IndexFaithful` / `violates:NoLostObject`).
   - The `controls/cr035_flip_purges*` rows keep `MUTANT = {"idle_uncounted"}` and expect `pass`: they show the purge alone closes the chain.
5. **Guards.** Both CR-035 guards (stale index and lost object) become `runFixedGuard`, with `setIdleUncounted`.
6. **Performance.** One O(|index|) scan per flip. A flip needs an allocation of exactly one page, so it is rare. Count flips in the stats to confirm.

### 3.4 Fix CR-016: no empty-block flip in a parallel minor with more than one worker

**Fix.** When `par_promo_active_ && promo_ctx_->n > 1`, `allocateFromEmptyRegularBlocks` returns `nullptr`. `allocateLargeBlock` then takes a fresh block (`OGS:2933-2975`); `allocateFromFreeLargeBlocks` still runs first, and no worker holds a dead large block, so that is safe.

Why not the alternatives:
- Reading the workers' cursors or stashes under `promo_mu_` is a data race: workers update them without the lock (`claimChunkW` `:1249`, lock-free finalize).
- A per-block "held" count would put an atomic RMW on every chunk claim and every stash push or pop, a hot-path cost for a precondition that the default geometry cannot reach.
- n = 1 keeps the flip: it has no stash and no chunks, and it flushes before it retires a block (`:1236-1239`).
- The 7c tenure engine also uses `beginParallelPromotion(ctx, n)`, so the rule covers it.

**Steps**
1. **Model first (M4, which has no CR-016 control today):**
   - Add a MUTANT-gated guard in `W_Large` (`PromoBitmap.tla:607`): `with f \in (IF NWorkers > 1 /\ "flip_skips_parallel" \in MUTANT THEN {} ELSE FlipCands) \cup {"none"}`.
   - Add `controls/flip_skips_parallel.cfg` (a copy of `MC_quick_sweep_large` plus the name) and `controls/flip_skips_parallel_chunk.cfg` (a copy of `MC_quick_minor_large`), both expected `pass`.
   - Add `controls/flip_one_worker.cfg` (`minor_virgin`, `NWorkers = 1`, `large_promo`, with the CR-018 count on), expected `pass`.
   - **NEW RULE:** TLC must pass all three before step 2.
2. **Code.** Make this the first statement of `OGS:2855`:
   ```cpp
   // CR-016: with N > 1 workers a block's live_bytes == 0 is not a fact: its cells may sit in
   // another worker's claimed chunk (unflushed pending_live, retired shared block) or stash.
   if (par_promo_active_ && promo_ctx_ && promo_ctx_->n > 1) return nullptr;
   ```
   Keep the Current skip at `:2866`, which n = 1 still needs. Optionally add a stats counter `alloc_stats_.bm.flip_skipped_parallel++`.
3. **Model default.** Invert the name into the mutant `"flip_in_parallel"`.
   - `MC_quick_sweep_large` and `MC_quick_minor_large` become `pass`.
   - Add `mutants/flip_in_parallel_stash.cfg` and `mutants/flip_in_parallel_chunk.cfg` (`violates:ReleasedSafe`).
   - Update M4 MAPPING's `FlipCands` row.
4. **Invariant.** Amend **HEAP_054** (the worker-cursor paragraph): "Inside a parallel minor with N > 1, allocateFromEmptyRegularBlocks flips nothing (CR-016): chunks and stashes are invisible to it."
5. **Guards.**
   - CR-016 chunk and stash become `runFixedGuard`. Each also asserts that `big` is not V's or D's start **and** lies in a newly created block.
   - Stress `promo <seed> 40 {4,6,8} 0 1` (exact arrays): expect 0 "Invalid tag" aborts over at least 7 seeds per worker count (4 of 7 today).
6. **Performance.** None at the defaults. In test geometries, large promotions take fresh blocks, so there are more `acquireOldGenBlock` calls under `promo_mu_`, which is CR-007's route. §6.3's no-wait policy covers `allocateLargeBlock`.

### 3.5 Fix CR-036: a per-id generation counter makes IM5 see a same-id re-issue

**Steps**
1. **`BlockTable.hpp`:** add `ReservedArray<uint32_t> gen_;`.
   - Reserve, release and commit it next to `live_`: in `reserve()` (`:110-118`), in `releaseStorage`, and in the `ensureCommitted` list in `add()`.
   - In `add()`, after the id is chosen: `++gen_[id.v];` (fresh commits are zero, so the first incarnation is 1). `clear()` does **not** reset `gen_`: the counter is monotone.
   - Accessor: `uint32_t generation(BlockId id) const { return gen_[id.v]; }`.
   - `storageBase`: `case 6: return free_.data(); default: return gen_.data();` with `kStorageArrays = 8`. `OGH:537` and `OGS:301` follow automatically.
   - Do **not** grow `BlockInfo` (the `static_assert` of 40 at `:67`).
2. **T0Block.** Change it to `struct T0Block { uint32_t id; uint32_t gen; char* start; size_t size_class; bool is_large; };` (`OGH:1492`). `t0Blocks()` (`OGS:5150-5159`) pushes `blocks_.generation(id)`.
3. **IM5 check.**
   - Refactor `checkT0BlocksUnchanged` (`OGS:5161-5169`) into `const char* t0BlocksChangedWhy() const`, which returns nullptr when nothing changed.
   - Add the check: `blocks_.generation(id) != t.gen` gives "IM5: a t0 block id was released and re-issued mid-cycle".
   - The old function calls the new one and aborts through `cycleValidateFail`.
   - `isT0Block` (`OGS:4615-4620`) fails immediately when the id matches but the generation differs.
4. **Test access** (validate builds): `OA::captureT0Blocks(og)` and `OA::t0BlocksChangedWhy(og)`.
5. **Invariants:**
   - Amend IM5 (`plans/threaded-gc-05a-incremental-marking.md:591,983`) and HEAP_063: "…the key includes the id's BlockTable generation, so a same-id, same-start re-issue is caught."
   - Amend **HEAP_048:** "each id carries a generation, incremented at every materialization."
6. **Models.** No state change. M8's `MC_quick_reissue_witness` stays a `witness:` row: the allocator still re-issues ids LIFO. Update M1 MAPPING's IM5 row.
7. **Guards:**
   - Extend `cr036Witness`: `sameKey` also requires `generation(E) == genD`. It then returns `kCorrect`, so switch it to `runFixedGuard`.
   - Add a validate-only guard: capture T0 with D live, release D, re-issue E, and require `t0BlocksChangedWhy` to be non-null.
   - Negative control: with the generation compare disabled by a hook, it must report "unchanged".
8. **Performance.** One increment per materialize; nothing on any allocation path.

### 3.6 Phase 1 gates, and the follow-ups left out

**Gates** (on top of §1):
- the validate tree `--filter threaded-gc-0` and `CR-0`, with V8, IM6, PM6, IM5, H9 and class-4 all silent;
- the exact-arrays stress run (§3.4);
- M8 and M4 at the quick and deep tiers;
- `run_traces.py` (TracePromoBitmap);
- `genmc run_drivers.py --only w3d`, still `race` until Phase 2.

**Expected canary pins:**
- the regions `OGS.initObjectHeaderWithSize`, `OGS.finalizePoppedCellW`, `OGS.allocateFromBagPage` and `OGS.allocateFromEmptyRegularBlocks`;
- the `BlockTable.hpp` file;
- the OGS atomic census;
- the greps `F.parPromoActive` and P6.M16.

**CR-029 follow-ups (not in this plan):**
- (b), retrying the exact pop, is an efficiency tweak only;
- (c), where the publisher reserves its first chunk, needs an M4 `W_Virgin` change.

Record both in the register as open proposals.

---

## 4. Phase 2: the sweep and parallel promotion (M4, W3)

**Order:** CR-014 first. After it, every completion defers and there is one write site for the CR-001 store. Then CR-001 (race), then CR-002, then CR-028. Land each one separately so each flip can be traced to its fix; one canary audit may cover the batch.

### 4.1 Fix CR-014: every sweep completion defers inside a promotion

**Fix.** This is the M4 control `tail_defers`. TLC passes it against `sweep_tail`, `sweep_tail_release`, `sweep_tail_live` and `sweep_tail_reuse` (`controls/tail_defers_reuse`). It also closes CR-014 C (the double allocation), the M3 `large_body_index_` race, and the M7 release route out of the drain, for N > 1.

**Steps**
1. **`lazySweep`** (`OGS:5561-5849`). At the top, next to `flushRun` and so still **inside** `TLA-REGION(OGS.lazySweep)`, add one completion lambda:
   ```cpp
   // CR-014: every completion inside a promotion defers like the in-loop one did.
   auto completeSweep = [&](int path) {
       ECO_TLA_TRACE_ONLY(const int m4_old = static_cast<int>(gc_phase_);)
       gc_phase_ = GCPhase::Idle;                       // §4.2 makes this an atomic_ref store
       ECO_M4_TRACE("m4.swend", "cb", target_class < NUM_SIZE_CLASSES ? classToSize(target_class) : 0,
                    "path", path, "par", par_promo_active_, "rmw", "phase", "old", m4_old, "new", 0);
   #if ENABLE_GC_STATS
       if (path == 3) {
           alloc_stats_.bm.sweep_tail_completions++;
           if (par_promo_active_) alloc_stats_.bm.sweep_tail_in_promotion++;
       }
       auto t0_shrink = GC_STATS_TIMER_START();
   #endif
       if (par_promo_active_) sweepCompleteInPromotion();
       else onSweepComplete();
   #if ENABLE_GC_STATS
       alloc_stats_.total_post_sweep_shrink_ns += GC_STATS_TIMER_ELAPSED_NS(t0_shrink);
   #endif
   };
   ```
   Then replace the two completion blocks:
   - in-loop (`:5588-5606`): `completeSweep(2); return work_done;`
   - tail (`:5829-5847`): `if (sweep_buffer_index_ >= blocks_.size()) completeSweep(3);`

   Keep the path numbers: the trace spec keys on them.
2. **Tripwire, in every build.** Make this the first statement of `onSweepComplete` (`OGS:5860`):
   ```cpp
   if (__builtin_expect(par_promo_active_, 0)) {
       std::fprintf(stderr, "[gc] FATAL: onSweepComplete inside a parallel promotion (CR-014)\n");
       std::abort();
   }
   ```
   It is valid because both legitimate callers clear the flag first (`:1487`, `:1536`).
3. **N = 1.** The 7c pause engine and the serial identity now go through `sweepCompleteInPromotion`'s one-worker branch (`:1476-1493`), which hands worker 0's cursors back before the shrink. That closes CR-014 A (N=1). Serial-identity counters change on runs that used to hit the tail path; re-baseline and record why.
4. **Invariant.** Append to **HEAP_067:** "Every completion of lazySweep inside a parallel promotion (in-loop or tail, via completeSweep) goes through sweepCompleteInPromotion: with N > 1 onSweepComplete is deferred to endParallelPromotion after the join and the stash return; with N = 1 worker 0's cursors are handed back first. onSweepComplete aborts if par_promo_active_ (CR-014)." Add the tripwire as **PM7** in the 06 plan's §3.13.
5. **Model M4.**
   - Change the tail branch (`:511`) to `await "tail_immediate" \in MUTANT`.
   - `MC_quick_sweep_tail`, `_tail_release`, `_tail_live` and `_tail_reuse` become `pass`.
   - New A6 mutants: `mutants/tail_immediate.cfg` (`violates:DetachNotCurrent`), `tail_immediate_release` (`ReleasedSafe`), `tail_immediate_live` (`NoRaceLive`), and `tail_immediate_reuse` (plus `reuse_released` and `CONSTRAINT MC_NoFatal`; `NoDoubleAlloc`).
   - Delete `controls/tail_defers*.cfg` and their rows.
   - `TracePromoBitmap.tla:95-96`: path 3 maps to `W_SweepEnd(w) /\ phase' = "Idle" /\ deferred' /\ pc'[w] = "W_PopAfterSweep"`.
6. **Guards.**
   - CR-014 A (N=2) and A (N=1) become `runFixedGuard`.
   - **B and C need their preconditions reworked.** Today they require `!sweepCompleteDeferred()` (`CRT:~1001`, `~1083`). Replace that with `OA::sweepTailInPromotion(og)` rising by exactly 1 across W2's call.
     - B: D live at its old start is `kCorrect`. Then `runFixedGuard`.
     - C: "D was not released inside the minor" is now `kCorrect`. Pop the stash (safe now), run `endParallelPromotion`, and check `byteBufIntact` and `allocStateConsistent`. Then `runFixedGuard`.
   - `fork_arms.txt`: `det-cr014-live` becomes `clean`. It must still print REACHED (the phase is Idle after the join).
   - Stress tail mode: `promo <seed> 40 4 0 0 8 1` still hits the tail path (`tail_hits > 0`), and no `computeFragmentationStats`/`flushCursorW` pair appears.
7. **Performance.** Nothing on the hot path: the shrink moves to the merge, where the in-loop path already runs it.

### 4.2 Fix CR-001 (the race half): atomic access to `gc_phase_` at the racing sites

**Fix.** This is the M4 control `phase_atomic`, which TLC passes on `NoRacePhase`.
- Its companion `phase_atomic_release` failed only because its `Counts` depended on the phase. CR-018's count in every phase (§3.2) removes that dependence, so `phase_atomic` plus CR-018 covers what `MC_quick_sweep_fixed` covered.
- Rejected: `finalize_in_lock` (rung 1's `finalizeBitmapCellW` still reads the phase outside the lock), and a pause-start snapshot (TLC has not checked it, and it needs a refresh to keep the N = 1 identity). Record the snapshot as a follow-up in case GC_DET_001 ever has to cover header colour.

**Steps**
1. **Write.** The one in-minor write, in `completeSweep` (§4.1), becomes `std::atomic_ref<GCPhase>(gc_phase_).store(GCPhase::Idle, std::memory_order_relaxed);`. The writes at `:431` and `:4578` run during a pause and stay plain. Next to `gc_phase_` (`OGH:833`) add `static_assert(std::atomic_ref<GCPhase>::is_always_lock_free);`.
2. **Reads made without the lock:**
   - `finalizePoppedCellW` `:1130`: `const bool black = marking_active || std::atomic_ref<GCPhase>(gc_phase_).load(std::memory_order_relaxed) != GCPhase::Idle;`, then `if (black) { bit + colour }`. The `live_bytes` add stays unconditional (§3.2).
   - `finalizeBitmapCellW` `:1198-1199`: the same load, for the colour.
   - Reads under `promo_mu_` stay plain. `:1688` (N = 1 only) and `NurseryParallel.cpp:660` (before begin) stay plain.
3. **Invariant.** Append to **HEAP_067:** "Promotion workers read gc_phase_ outside promo_mu_ only with relaxed atomic_ref loads; its in-minor write is a relaxed atomic_ref store (CR-001)." In **HEAP_051**, cross-reference HEAP_073 for the S1 half.
4. **Model M4.**
   - Change to `PhasePlain == "phase_plain" \in MUTANT`.
   - `MC_quick_sweep_race_phase` becomes `pass`.
   - New mutant `mutants/phase_plain.cfg` (`violates:NoRacePhase`).
   - Delete `controls/phase_atomic*.cfg` and `controls/finalize_in_lock_phase.cfg`.
   - Confirm `MC_quick_sweep_fixed` passes with `MUTANT = {}`.
5. **GenMC W3.**
   - Case d: the write becomes a relaxed `atomic_ref` store and the read a relaxed `atomic_ref` load. `w3d_CR001_gc_phase` becomes `pass`.
   - New mutant row `W3_CR001_PLAIN_PHASE` expects `race:phase_idle`.
6. **Guards.**
   - `fork_arms.txt`: the four `det-cr001:*` rows become `clean`, each still REACHED.
   - Add the tail variants `cr001(arm, /*tail=*/true)` to CRT: B = 8, proven by the tail counter, as `runFixedGuard`.
7. **Performance.** A relaxed `atomic_ref` load compiles to a plain `mov`/`ldr`; no change expected.

### 4.3 Fix CR-002: finalize a cell of the block under the sweep cursor before the unlock

**Fix.** A narrowed form of the TLC control `finalize_in_lock`, which passes `NoRaceBitmap`.
- The only block whose mark words the sweeper still reads or clears is the one under `sweep_cursor_`. Blocks behind it are `fully_swept`, blocks ahead of it have no free cells (HEAP_055), and mark slots are 64-byte strided (HEAP_050).
- So only cells of a block that is not `fully_swept` need the lock.
- Finalizing every stash cell inside the lock would undo Step 7b (the N = 8 worst minor went from 110 to 79 ms, 06 plan §10.4).
- Making the sweeper's accesses atomic would mix 8-byte and 1-byte atomics over the same memory, which C++ does not define.

**Steps**
1. **Model first (NEW RULE).** In `W_Locked`'s batch: if `~swept[BlkOf(h)]`, finalize `h` under the lock (the existing `W_Fin`/`W_StUnlock` route); otherwise stash only the prefix of the list whose cells lie in swept blocks.
   - New mutant `finalize_outside_lock` (today's batch) must give `violates:NoRaceBitmap`.
   - `MC_quick_sweep_race_bitmap` becomes `pass`. Delete `controls/finalize_in_lock.cfg`.
   - TLC must pass the rule on **every** sweep row and on `MC_quick_sweep_fixed` and the deep rows **before** any code changes.
   - Trace: `m4.batch` with `inlock` maps to an in-lock `W_Fin`.
2. **Helper, in `OGH`** after `parallelPromotionActive()`:
   ```cpp
   // Under promo_mu_. CR-002: a cell of a block the gap sweep has not finished
   // shares mark words with the sweeper's plain nextSetBit/clearBit.
   bool cellInUnsweptBlock(const void* cell) const {
       const BlockId id = contains(cell) ? blockIdFor(cell) : NO_BLOCK_ID;
       return id.valid() && !blocks_.meta(id).fully_swept;
   }
   ```
3. **The rung-2 batch** in `allocatePromotion` (`OGS:1748-1758`) becomes:
   ```cpp
   if (result == nullptr && promo_ctx_->n > 1) {
       popped = tryPopFromFreeList(cls);
       if (popped != nullptr && cellInUnsweptBlock(popped)) {
           result = finalizePoppedCellW(popped, cls, size, pw);   // CR-002: before the unlock
           popped = nullptr;
       }
       while (popped != nullptr && pw.stash_n[cls] < PromoWorker::kStash) {
           FreeCell* head = free_lists_[cls];                      // peek: never stash an unswept cell
           if (head == nullptr || cellInUnsweptBlock(head)) break;
           pw.stash[cls][pw.stash_n[cls]++] = tryPopFromFreeList(cls);
       }
       /* existing m4.batch hook; add "inlock", result != nullptr */
   }
   ```
   `:1759` (the ladder, when both are null) and `:1768` are unchanged. PM6 is unaffected (`finalizePoppedCellW` charges `pw`).
4. **Validate check (PM8)** in the stash branch (`:1708-1711`): abort with `[heap-validate] CR-002: stashed cell of an unswept block` if the popped cell's block is not `fully_swept`.
5. **Invariant.** Append to **HEAP_055:** "Inside a parallel promotion the gap sweep's plain word reads and clearBit on the block under the cursor are exclusive under promo_mu_: a free cell of a block that is not fully_swept is finalized before promo_mu_ is released and is never stashed; only cells of fully swept blocks are finalized outside the lock (CR-002)."
6. **GenMC W3.**
   - Case c: `c_finalizer` calls `allocateBlack` before `unlock`. `w3c_CR002_gap_sweep` becomes `pass`.
   - New mutant row `W3_CR002_UNLOCKED_FINALIZE` expects `race:bits`.
7. **Guards.**
   - `det-cr002` becomes `clean`, and must still be REACHED (`r1 == g1`).
   - Check that the preconditions of CR-014 B/C, CR-001 and CR-016 (stash) still hold: their stashed cells lie in fully swept blocks. Check that CR-028's `p1 == av` still holds.
8. **Performance: the only real risk in this phase.** It lengthens the rung-2 critical section while the block under the cursor has listed cells.
   - Measure `pw.mutex_acquires`, `mutex_wait_ns`, `list_pops`, minor GC time and the worst minor, at N = 8 and N = 16, on `benchmarks/heap-config-gc-pressure[-incremental]-parallel.json`.
   - Budget: 3 % of minor GC time.
   - If it goes over: raise `kStash`, or skip the peek when the phase read under the lock was Idle (that read is exact).

### 4.4 Fix CR-028: V11 for blocks completed inside a parallel promotion runs after the join

**Fix.** Defer V11 for such blocks to `endParallelPromotion`. At that point every promoted cell is fully written and every stashed cell has been re-pushed as `Tag_Free`, so the walk is exact. Skipping V11 instead would lose coverage of every block completed inside a parallel minor. CR-002 does not fix this race: the body is still written after the unlock.

**Steps**
1. **Factor** the V11 body (`OGS:5784-5805`) into `void validateV11(BlockId id) const` (validate builds only).
2. **In `lazySweep`** at the block boundary:
   ```cpp
   #if ECO_HEAP_VALIDATE
       if (gap_sweep) {
           if (par_promo_active_ && promo_ctx_->n > 1) v11_deferred_.push_back({cur_id, block.start}); // CR-028
           else validateV11(cur_id);
       }
   #endif
   ```
   `v11_deferred_` is a validate-only `std::vector<std::pair<BlockId, char*>>`, written under `promo_mu_` and cleared in `beginParallelPromotion`.
3. **In `endParallelPromotion`**, after the stash return (`:1570`) and **before** the deferred `onSweepComplete` (`:1652`):
   ```cpp
   #if ECO_HEAP_VALIDATE
       for (auto [id, start] : v11_deferred_)
           if (blocks_.isLive(id) && blocks_.info(id).start == start && !blocks_.info(id).is_large) validateV11(id);
       v11_deferred_.clear();
   #endif
   ```
4. **Invariant.** HEAP_055: "…parses exactly (validator V11), walked when the block completes, or, for a block completed inside a parallel promotion with N > 1, in endParallelPromotion after the join (CR-028)."
5. **Guard.** CR-028 becomes `runFixedGuard`, validate builds only (the guard formats `p1` before `endParallelPromotion`).

### 4.5 Phase 2 gates

On top of §1:
- the unit suite at `gc_minor_threads` 1, 4 and 8;
- the validate tree unit and stress runs (a deferred V11 firing is a real finding);
- `build-heap-tsan` default, `pool` and `ylos`: 0 warnings;
- `run_fork_arms.py --tier quick`;
- M4 quick and deep;
- `tla-trace` M4, where `TraceRace.cfg` should now pass: promote it to an accept row;
- `genmc-check` W3.

**Expected canary pins:**
- the regions `OGS.lazySweep`, `OGS.onSweepComplete`, `OGS.finalizePoppedCellW`, `OGS.finalizeBitmapCellW`, `OGS.allocatePromotion` and `OGS.begin/endParallelPromotion`;
- the OGS census (new `atomic_ref` lines);
- the greps `F.gc_phase` (the count of `gc_phase_ =` drops by 2; re-derive the grep) and P6.M6.

---

## 5. Phase 3: the region nursery and snapshot marking (M1, M5)

**Order:** CR-037 first, then CR-017, then CR-038. CR-037 is one line, and it removes CR-037 noise from CR-017's R1 (k=2) cleanup and from the `lbaba` TV7 failures.

### 5.1 Fix CR-037: `markLargeBodySeen` colours only kind-0 (body) entries

**Fix.** This is the M5 control `lb_kind`; the `MC_deep_boundary*` rows already run with `LbKey = "kind"` at k = 1 and 2.
- It is stateless and correct at every caller (the preps at `NurseryRegion.cpp:752` and `:777`, `lb_seen` at `:961`, `NurseryParallel.cpp:833`, `NurserySpace.cpp:2137` and `:2143`): each passes a large header's body, which is a kind-0 entry.
- What it leaves: a reused address that holds another body gets re-coloured for at most k minors, which is bounded floating garbage.

Rejected alternatives:
- `lb_drop` would prune every extent at four retirement sites. It has CR-034's problem with the lazy sweep after the mutator resumes.
- `lb_stamp` would need a per-entry stamp in `NurseryRegions.hpp` (a pinned file), and one body can be shared by headers copied at different minors.

**Steps**
1. **Code.** In `OGS` ~:7563, wrap `markLargeBodySeen` in `TLA-REGION(OGS.markLargeBodySeen)` (a new pin for M5):
   ```cpp
   LargeBodyId id = it->second;
   if (id >= large_bodies_.size()) return;
   LargeBodyMeta& m = large_bodies_[id];
   // HEAP_072 (amended, CR-037): lb_bodies names BODIES by address; a STW major may
   // free the body and a YLOS (kind 1) may take the cell. Never colour a YLOS here:
   // its first reach would return "already reached" (reachYoungLargeR), unscanned.
   if (m.kind != 0 || m.body_base != body) return;
   m.color = minor_color;
   ```
   Update the comments above `NurseryRegion.cpp:751` and `:776`.
2. **Invariant.** Amend **HEAP_072:** "The same holds for `Extent::lb_bodies`: `markLargeBodySeen` colours kind-0 (body) entries only, so a YLOS at a reused body address is reached and scanned as young (CR-037)."
3. **Model M5.**
   - Rename the `LbKey` value `"code"` to `"addr"` (the pre-fix behaviour, as the `YlosGen` precedent does). `"kind"` is THE CODE.
   - `MC_lb_aba` and `MC_deep_boundary_k2_lb` stay `violates:NoDangling`, re-commented as "regression mutant of HEAP_072 (lb)".
   - Annotate `controls/lb_kind.cfg` as THE CODE. MAPPING's `LbKey` row points at `OGS.markLargeBodySeen`.
4. **Guards.** CR-037 (k=1) and (k=2) become `runFixedGuard`; the control is unchanged.

### 5.2 Fix CR-017: a region-mode STW major zaps the dead survivors of every Young extent

**Fix.** After the major's mark, every survivor-part object of every **Young** extent that the major did not reach becomes a `Tag_Free` filler, before the mutator resumes. It reuses 07b's mechanism (`writeFiller`), and the liveness it needs already exists: a STW major records every nursery object it reaches in `nursery_visited_` (`OGS:3360`), which is cleared only at `prepareMark` (`:3051`).

**Scope, and why it is exactly this:**
- **Young extents' survivor parts `[base, surv_top)`, ages 1..k.** At k = 1 that is the extent handed over at the next minor. At k ≥ 2 it also covers the ageing extents, which t0 reads before their first ageing mark.
- **Not Tenuring:** its job is merged at the major's `tenureJoin` (`ThreadLocalHeap.cpp:801`), and `resolveRetire` still reads its forwarded originals. The M5 mutant `zap_tenuring` shows why.
- **Not builder areas:** kernels hold builders. **Not eden:** eden is empty at t0 (IM7).

Rejected alternatives:
- Marking and zapping at the hand-over minor misses k ≥ 2.
- Having the t0 walk skip objects the major did not mark needs reached-bitmaps kept alive from the major to the next t0, and the census and validators would still read the dangling slots.

**Steps**
1. **Model first.**
   - **M1** (`SnapshotMark.tla`, the PlusCal source; re-translate). In `J_STW`, when `RegionMode /\ MUTANT # "no_cr017_fix"`, zap `Z == {o ∈ YoungObjs \ Live : age[o] = 1 /\ o ∉ YlosIds}`: `alloc \ Z`, scrub `fld`/`age`/`builder`, and `zombie := zombie \ Z`.
     - `MC_quick_region` and `MC_quick_region_reuse` become `pass`.
     - New mutants: `mutants/no_cr017_fix.cfg` (`violates:MarkerFootprint`) and `mutants/no_cr017_fix_reuse.cfg` (`violates:MarkerNoYoungKid`).
     - Re-run `MC_deep_region` and the Apalache `step5_Major*` lemma rows.
   - **M5** (`Tenuring.tla`, `MJ_Mark`), unless `MUTANT = "no_cr017_fix"`:
     ```
     heap := [a \in Addr |-> IF ((IsO(a) \/ IsY(a)) /\ a \notin MajorLive)
                               \/ (IsS(a,a[2]) /\ xstate[a[2]] = "Young" /\ a \notin MajorLive)
                            THEN Empty ELSE heap[a]]
     ```
     - `MC_cycle_major`, `MC_k2_cycle_major`, `MC_cycle_major_t0grey` and `MC_deep` become `pass`.
     - `MC_deep_boundary_cr017` and `_k2_cr017` become regression mutants (`MUTANT = "no_cr017_fix"`, same verdicts).
     - New mutants:
       - `mutants/no_cr017_fix{,_k2,_t0grey}.cfg` (`YoungWalkValid` / `YoungWalkValid` / `T0GreyAllocated`), which the M5 plan's A6 row promises (`plans/threaded-gc-tla-M5-tenuring.md:1037`);
       - `zap_tenuring` (expect `TV1_Resolve` or `NoDangling`);
       - `zap_fresh_only` (hosted on `k2_cycle_major`, `YoungWalkValid`).
     - Set `Cr017Oracle = FALSE` in `MC_deep_boundary`, `_k2` and `_k2_m2`, and re-run them (about 12, 3 and 5 min).
2. **`OGH`**, public, next to `youngLargeMember`:
   ```cpp
   // CR-017 (HEAP_074): valid from a STW major's mark end until the next prepareMark.
   bool majorReachedNursery(const void* p) const {
       return nursery_visited_.count(const_cast<void*>(p)) != 0; }
   ```
3. **`NurserySpace.hpp`:** declare `void zapDeadAfterMajor(OldGenSpace& og);`. Fix the `forEachYoung` comment (`:826-827`) to read: "dead objects are zapped fillers (07b merge; HEAP_074 STW major)".
4. **`NurseryRegion.cpp`**, a new function after `majorRedirect` (`:230`), inside `TLA-REGION(NR.zapDeadAfterMajor)` (a new pin for M1 and M5):
   ```cpp
   void NurserySpace::zapDeadAfterMajor(OldGenSpace& og) {
       RegionState& R = *rg_;
       if (R.in_minor || (R.job.state != region::TenureJob::State::None &&
                          R.job.state != region::TenureJob::State::Merged))
           regionFatal("HEAP_074: zap with the tenure job unmerged or inside a minor", nullptr, nullptr,
                       static_cast<uint64_t>(R.job.state));
       const uint64_t t0 = nowNs();
       uint64_t n = 0, bytes = 0;
       auto flush = [&](char* lo, char* hi) {
           writeFiller(lo, static_cast<size_t>(hi - lo));
   #if ECO_HEAP_VALIDATE   // a resurrected reference then hits POISON / the Free check in evacuateR
           if (hi - lo > (ptrdiff_t)sizeof(Header)) std::memset(lo + sizeof(Header), 0xD8, (hi - lo) - sizeof(Header));
   #endif
       };
       for (unsigned u = 0; u < R.n_surv; ++u) {
           region::Extent& X = R.x[u];
           if (X.state != region::XState::Young) continue;   // Tenuring: merged, retires next minor
           char* gap = nullptr;
           for (char* p = X.base; p < X.surv_top;) {
               const size_t sz = getObjectSize(p);
               const bool is_free = getHeader(p)->tag == Tag_Free;
               if (is_free || !og.majorReachedNursery(p)) {
                   if (!is_free) { ++n; bytes += sz; }
                   if (gap == nullptr) gap = p;
               } else if (gap != nullptr) { flush(gap, p); gap = nullptr; }
               p += sz;
           }
           if (gap != nullptr) flush(gap, X.surv_top);
       }
       R.census.clear();   // defensive: detector N re-hashes only at a join, which precedes this
       R.rs.major_zapped += n; R.rs.major_zapped_bytes += bytes; R.rs.major_zap_ns += nowNs() - t0;
       ECO_TLA_TRACE("mzap", "n", n);
   }
   ```
   Add `major_zapped`, `major_zapped_bytes` and `major_zap_ns` to the region stats (`GCStats.hpp:316`, with the merge at `:342`). Do **not** touch `NurseryRegions.hpp` (a whole-file pin).
5. **Hook.** In `ThreadLocalHeap::majorGC` (`ThreadLocalHeap.cpp` ~:904), right after the `finishMarkAndSweep` block and before `t_done`:
   ```cpp
   // CR-017 / HEAP_074: nursery_visited_ is exactly the young objects this major reached;
   // every other survivor of a Young extent is dead and its old children may now be free.
   if (nursery_.regionMode()) nursery_.zapDeadAfterMajor(old_gen_);
   ```
6. **Validate tripwire.** In `evacuateR` (`NurseryRegion.cpp` ~:481), in the `Role::Hand` and `Role::Age` cases, under `ECO_HEAP_VALIDATE`:
   `if (getHeader(obj)->tag == Tag_Free) regionFatal("HEAP_074: a reference to a survivor a STW major found dead (resurrected?)", obj, &slot);`
7. **Invariants:**
   - **New HEAP_074 MajorZapsDeadSurvivors:** "In region mode a STW major, after its mark, turns every survivor-part object of every Young extent that it did not reach (`nursery_visited_`) into Tag_Free fillers, before the mutator resumes. The Tenuring extent (merged, retiring at the next minor) and builder areas are not touched. Consequence: no object that `forEachYoung` walks has a slot naming a cell freed by a major (CR-017). Premise: the major's young reachability is a superset of the minor's (the root enumerations `minorGCRegion:843-868` and `collectRoots` + `forEachMajorRoot` are the same set), and no runtime code holds an unrooted reference to a survivor across `majorGC`."
   - Amend **HEAP_069**'s zap rule: "…was live at the last hand-over mark, copied at the last minor, **and reached by every STW major since**."
   - **HEAP_063:** after "every young object", add "(dead survivors are zapped: HEAP_070 merge, HEAP_074 major)".
   - **HEAP_SNAPSHOT_001:** add zap fillers to the list of excluded GC writes. IM3 and IM13 are unchanged: their premise is restored.
   - **Plans:** correct plan 07's "conservative and safe" (`plans/threaded-gc-07-concurrent-tenuring.md:834`) and 07b §2.5's "same roots" argument (`:131-134`).
8. **Guards:**
   - CR-017 (k=1) and (k=2) become `runFixedGuard`: the scenario already returns `greyed ? kDefect : kCorrect`.
   - **R1 and R1 (k=2):**
     - Change `!control && !greyed → NOT REACHED` to `if (!control && greyed) return kDefect;`, and let the scenario run on to B and the marker release, ending in `kCorrect`.
     - Add a route witness: `deadBodyAfterMajor` also returns the header's address, and before the trigger the guard asserts `getHeader(hdr)->tag == Tag_Free` (the zap happened), or returns NOT REACHED.
     - Then `runFixedGuard`.
   - **R2:** `control && greyed` gives NOT REACHED and `!control && greyed` gives `kDefect`. Then `runFixedGuard`. The controls are unchanged.
   - Update the README row for `lbaba` to PASS, including seeds 1 and 7 (the old IM4 failures) at ages 1 and 2.
9. **Performance.** One hash lookup per survivor object in at most k extents, only on STW majors (explicit, or on allocation failure).
   - Measure `rs.major_zap_ns` against `MajorGCEvent.total_ns` on the gc-opt-loop LB set plus an explicit-major workload, at k = 1 and 2.
   - Budget: median zap ≤ 2 % of the major pause.
   - If it goes over: set per-extent bits in `greyObject`'s nursery branch (reuse `Extent::mark_bits`) instead of hashing. That touches the `OGS.greyObject` pin (M1, M5).
10. **Traps:**
    - **Resurrection.** Audit the callers of `allocateYoungLarge`/`allocateLargePinned` (`ThreadLocalHeap.cpp:469`, `:491`) for unrooted survivors held across the call. The validate poison and the Free check (step 6) detect one.
    - **Ordering.** Zap after the mark, before the mutator resumes, never inside a minor.
    - **Census.** Keep both zaps after the join.
    - **`MC_deep` may no longer finish within the deep budget.** If so, re-host it on the `deep_boundary` bounds and record that in AUDIT.md.
    - **CR-017 does not remove CR-037's precondition.** The body address stays in `lb_bodies`, so both fixes are needed.

### 5.3 Fix CR-038: the merge clears the slots of dead ageing-generation YLOS

**Wider variant.** Phase 0's Step 0.4 has already run the model row `MC_k2_ylos_walk2`, and its verdict decides whether CR-039 exists (and whether the guard `cr038Z` does). The fix below covers both variants either way. If CR-039 was registered, it flips together with CR-038 in step 4.

**Fix.** In `mergeJob`, clear every heap-pointer slot of each ageing-generation YLOS that the job's ageing mark did not reach. The object stays walkable, but its slots name nothing.
- **Why it is sound:** the same argument as the 07b survivor zap. The ageing mark is exact (M5 checks `amark = liveAge`, and `AgeCells` includes the generation's YLOS), and `st.age_ylos` is built through `youngLargeMember` (HEAP_072).
- **Rejected alternative:** resetting `join_minor` so that the minor-end sweep frees Y early. It interacts with `deferred_frees_` during a cycle.

**Steps**
1. **Model first (M5, `J_Merge` (5b)).** For `y ∈ YAddr` with `ys[y[2]] = Gen(ageX)` and `y ∉ amark`, set `heap[y].f := [i ↦ Nil]`, unless `MUTANT = "skip_ylos_zap"`.
   - `MC_k2_ylos_walk` becomes `pass`, and so does `MC_k2_ylos_walk2`.
   - New mutants: `mutants/skip_ylos_zap.cfg` (`violates:YoungWalkValid`), plus `skip_ylos_zap_2` (`T0GreyAllocated`) if the wider variant holds.
   - Put `YoungWalkValid` back into `MC_deep_boundary_k2`'s invariants.
2. **Code.** In `NurseryTenure.cpp` `mergeJob`, add a new step (5c) right after the 07b zap (`:862`), still inside `NT.mergeJob` (no change to the pinned `TenureWork.hpp`):
   ```cpp
   // (5c) CR-038 (HEAP_070 amended): a dead ageing-generation YLOS keeps its slots until its
   // own hand-over; a slot may name a Tenuring object (retired next minor) or an older-generation
   // YLOS freed by this merge's sweep. The t0 snapshot walks it (snapshotYoungLarge): clear its slots.
   if (heal && !test_skip_zap_) {
       HPointer nil{}; nil.ptr_ind = 1; nil.constant = Const_Empty;
       for (size_t k = 0; k < st.age_ylos.size(); ++k) {
           if (st.age_ylos_marked[k]) continue;
           void* y = const_cast<char*>(st.age_ylos[k].obj);
           if (oldgen.youngLargeMeta(y) == nullptr) tenureFatal("an ageing YLOS left the index before the merge", y);
           forEachChildSlot(y, [&](HPointer& hp) { if (hp.ptr_ind == 0 && hp.ptr != 0) hp = nil; });
           ++R.rs.zapped_ylos;
       }
   }
   ```
   Count the time in `zap_ns`.
3. **Invariants:**
   - **HEAP_070:** "the merge zaps dead ageing survivors (fillers) **and clears the pointer slots of ageing-generation YLOS the mark did not reach**."
   - **HEAP_SNAPSHOT_001:** add this write to the excluded GC writes.
   - Correct 07b §2.6 ("every holder that is dead at the hand-over is zapped" was false for YLOS holders).
4. **Guards.** CR-038 becomes `runFixedGuard`: Y is still walked, and its slot is now `Empty`. Add `cr038Z` if CR-039 is registered.

### 5.4 Phase 3 gates

On top of §1:
- `ConcurrentTenureTest` at k = 1, 2 and 3;
- the validate tree, including the E2 test at `MAJOR_GC_LIVE_BUDGET = 3.0` (many majors) and the HEAP_074 tripwire;
- gc-heap-tsan default (the region scenarios), `ylos`, `tenure-storm`, and `lbaba 200 1`, which must now PASS;
- M1 and M5, quick and deep (including `MC_deep_region`, the lemma rows, `MC_deep_boundary{,_k2,_k2_m2}` and the regression mutants);
- `tla-trace` M1 (`cycle,region-b2`) and M5 (`TraceTenurePause`, `TraceTenuring`), mapping `mzap` into `MJ_Mark` if the projection reads major events.

**Canary pins:**
- the regions `TLH.majorGC`, `NT.mergeJob` and `NR.evacuateR`, and the `NSH.forEachYoung` comment;
- new pins for `NR.zapDeadAfterMajor` (M1, M5) and `OGS.markLargeBodySeen` (M5).

---

## 6. Phase 4: page supply, mutators, and the YLOS header (M7, M3)

**Order:** CR-019 (it stands alone), then CR-012 (`AL.initThread` and `AL.acquireOldGenRegion`), then CR-007 (`AL.acquireOldGenBlock`, PageWork, M7). Run the canary after each.

### 6.1 Fix CR-019: relaxed atomic whole-word access to YLOS headers

**Diagnosis.** In `Header` (`Heap.hpp:164-175`), `tag`, `color`, `pin`, `age`, `unboxed`, `refcount` and `builder` are adjacent bit-fields, so they form one C++ memory location.
- The writers do a plain read-modify-write: `h->age++` (`NurseryParallel.cpp:385`, `reachYoungLargeP`) and `age = 0` (`OGS:7513`, `promoteYoungLarge`).
- `lazySweep` reads `tag`, `pin` and `age` from the same word.
- The writer never changes `tag`, `size` or `pin`, so making both sides atomic is enough; no ordering is needed.

**Steps**
1. **Helpers**, in `AllocatorCommon.hpp` next to `getObjectSize` (`:570`); they need `<bit>` and `<atomic>`:
   ```cpp
   // CR-019: a header word read/written while another thread may touch the same word
   // (a YLOS header under ylos_mu_ vs a sweep slice under promo_mu_).
   inline Header loadHeaderRelaxed(const void* obj) {
       auto* w = static_cast<uint64_t*>(const_cast<void*>(obj));
       return std::bit_cast<Header>(std::atomic_ref<uint64_t>(*w).load(std::memory_order_relaxed));
   }
   inline void storeHeaderRelaxed(void* obj, Header h) {
       std::atomic_ref<uint64_t>(*static_cast<uint64_t*>(obj))
           .store(std::bit_cast<uint64_t>(h), std::memory_order_relaxed);
   }
   ```
   A load and a store are enough, not a CAS: `ylos_mu_` plus the colour test make the writer the only writer of this word within the minor (M3 `YlosOnce`), and no marker writes header bits in bitmap mode (HEAP_065).
2. **Writers:**
   - `reachYoungLargeP` (`NurseryParallel.cpp:374-385`): `Header hv = loadHeaderRelaxed(obj);`, test `hv.builder`/`hv.age`, and in the else branch `if (!hv.builder) { ++hv.age; storeHeaderRelaxed(obj, hv); }`.
   - `promoteYoungLarge` (`OGS:7513`): `Header hv = loadHeaderRelaxed(obj); hv.age = 0; storeHeaderRelaxed(obj, hv);`.
   - Region mode's `h->age = 1` (`NurseryRegion.cpp:537`): the same pattern.
   - Leave the serial `NurserySpace.cpp:1813` and the fresh-copy fixups unchanged.
3. **Readers in `lazySweep`:**
   - gap sweep `:5712`/`:5715`: `const Header lh = loadHeaderRelaxed(live_obj);`, then `getObjectSizeFromHeader(&lh)`;
   - the linear loop `:5726-5755`: one `loadHeaderRelaxed(sweep_cursor_)`, reusing its `tag`, `isFreeCellSentinel` and `pin`;
   - V11 `:5790`: the same load.
   - Do **not** change `getObjectSizeFromHeader`/`getObjectSize`: they are the copy-path helpers.
4. **Invariants:**
   - Append to **HEAP_062:** "A YLOS header's `age` is written during a parallel minor only with a relaxed atomic whole-word store under `ylos_mu_` (`storeHeaderRelaxed`), leaving `tag`/`size`/`pin` unchanged; a sweep slice reads any header word only by a relaxed atomic load (`loadHeaderRelaxed`) (CR-019)."
   - Cross-reference it from HEAP_067.
   - In M3 MAPPING A3, move CR-019 to "fixed".
5. **Model.** No behaviour change (M3 has no sweep): add a footprint note in M3 AUDIT.
6. **Guards.**
   - `det-cr019:t1first` and `:t2first` become `clean`.
   - The `ylos-sweep` arm becomes expected-clean; add it to the default gc-heap-tsan run (about 3 s).
   - Register: Fixed, with the det arm as the guard.
7. **Performance.** A relaxed 64-bit `atomic_ref` access is a plain `mov`/`ldr`, and the linear loop now loads the header once instead of three or four times. Budget: ≤ 1 % of GC time, legacy nursery, `gc_minor_threads ≥ 2`.
8. **Traps.**
   - Every concurrent writer must be converted, or TSan still reports a plain/atomic mix; `match=promoteYoungLarge` names the one that was missed.
   - `atomic_ref<const T>` is not valid C++20, hence the `const_cast`.

### 6.2 Fix CR-012: multiple mutators (DECIDED: option F, a second mutator is forbidden)

**Facts.** No production entry point creates two live heaps:
- `eco_entry.cpp:104/138`, `eco_embed.cpp:190/221`, `EcoRunner.cpp:231/285` and `ecoc.cpp:341` each create one heap and clean it up before any relaunch.
- Only the benchmark driver (`main.cpp:720-729`, `num_program_threads`) and test harnesses create more.

**Option S (support multiple mutators).**
- It needs per-heap trigger accounting, and therefore per-heap old-gen sub-reservations with per-heap caps (the cap `nursery_offset` is process-wide today).
- It also needs per-heap `old_gen_free_blocks_` and `PageWork` (epochs, pending, window) over the shared pool, a heap-scoped `validatePageWork`, and M7 extended to K heaps.
- Cost: about 1-2 weeks, 8+ pinned regions, and a new model tier, all to serve only the benchmark driver.

**Option F (forbid a second live mutator): CHOSEN (2026-09-30).**
- Enforce one live `ThreadLocalHeap` per process, with an explicit opt-in for the benchmark driver and test harnesses, documented as unsupported.
- Cost: about a day, and no runtime cost.
- Option S is not pursued. If multiple mutators are ever wanted, it needs its own plan, and the won't-fix guards (step 7) will XPASS and flag the change.

**Steps (option F)**
1. **`Allocator.hpp`**, near `:409`:
   - `void allowMultipleMutators(bool on) { std::lock_guard<std::recursive_mutex> l(thread_mutex_); multi_mutator_opt_in_ = on; }`
   - the member `bool multi_mutator_opt_in_ = false; // guarded by thread_mutex_; benchmark/test only (CR-012)`
   - `Allocator::reset` (`AL:1037`) resets it to `false`.
2. **`Allocator::initThread`** (`AL:320-353`), after the double-check at `:335-338` and before `make_unique`:
   ```cpp
   if (!thread_heaps_.empty() && !multi_mutator_opt_in_) {
       std::fprintf(stderr, "[eco] FATAL: a second mutator thread called initThread while "
           "another ThreadLocalHeap is live (HEAP_007: one mutator per process; CR-012). "
           "Only benchmark/test harnesses may call Allocator::allowMultipleMutators(true).\n");
       std::fflush(stderr);
       std::abort();
   }
   ```
   Sequential mutators (thread 1 cleans up, then thread 2 starts) stay legal.
3. **`acquireOldGenRegion`** (`AL:1002-1032`): route it through the commit-ahead window. This is needed in **both** options, because sequential mutators still hit item (d).
   ```cpp
   char* commit_from = region_base; size_t commit_bytes = initial_size;
   if (page_work_) commit_bytes = page_work_->onFreshBump(region_base, initial_size, &commit_from);
   void* result = region_base;
   if (commit_bytes > 0 && Elm::platform::commitAt(commit_from, commit_bytes) == nullptr) result = nullptr;
   ```
4. **`main.cpp`**, after `alloc.initialize(config)` (`:696`): `if (num_program_threads > 1) { alloc.allowMultipleMutators(true); std::cerr << "warning: >1 program thread is unsupported (CR-012); GC determinism is per process\n"; }`
5. **Opt in the harnesses:** CRT `HeapB`/`cr012Init`, the spawning test in `ConcurrentTenureTest` (`:433-450`), `fork_harness.cpp` `trialTwoHeap`, and `cr012_two_heap.cpp`. Then run the full unit suite: any new SIGABRT carrying the CR-012 message marks a harness that still needs the opt-in.
6. **Optional hardening:** make `old_gen_in_use_bytes_` a `std::atomic<size_t>` with relaxed accesses. That makes the TSan row `cr012:a` clean even under the opt-in.
7. **Guards:**
   - `CR-012 forbid` as a `runDeathGuard`: `initAllocator(default)`, then `std::thread([&]{ a.initThread(); }).join();`.
   - Two `runFixedGuard` controls: `CR-012 opt-in` (the same, with `allowMultipleMutators(true)`) and `CR-012 sequential` (clean up the main heap first, then thread 1 inits and cleans up, then thread 2 inits).
   - `CR-012 (d) sequential` as a `runFixedGuard`: after a pause opened the window, the mutator cleans up, a new thread inits, and `mincore` shows the window still resident.
   - (a)-(d) become `runWontFixGuard`, renamed `[won't-fix CR-012: opt-in only]`.
   - `fork_arms.txt` `cr012:a` and `cr012:e` get the expectation `wontfix`; `cr012:a` becomes `clean` if step 6 lands.
8. **Invariants:**
   - **HEAP_007**, merged with §7's fork contract; see §7.1 for the full text.
   - **GC_DET_001:** "per process = per heap under HEAP_007."
   - **HEAP_060:** "`acquireOldGenRegion` also goes through `onFreshBump`."
   - M7 MAPPING (`:103`, `:122`): multiple heaps are forbidden by HEAP_007.
9. **Register.** CR-012 becomes Won't-fix, with the death guard as its guard. Item (d) is Fixed (step 3).

### 6.3 Fix CR-007: a promotion worker never waits on a helper job while holding `promo_mu_`

**Constraints:**
- The M7 mutant `skip_posted_extents` violates `DetChoice`, so a skip keyed on job state is timing-dependent and **forbidden**.
- Membership in `pending_` is job-blind: it changes only in `onRelease`, in `onReuse`, and at `syncPoint` aging, which depends only on epochs and bytes.
- With decommit on, a free-list extent is either Pending or discard-issued. "Not Pending" therefore covers every extent whose reuse *might* wait.

**Design.** A promotion holder with n > 1 takes, in this order:
1. the first-fit **Pending** extent (its discard is cancelled; it never waits);
2. otherwise a **fresh bump**;
3. otherwise, when the cap is exhausted, today's first fit, which may wait.

At n = 1 the policy is unchanged, to keep the one-worker identity.

**Steps**
1. **`PageWork.hpp/.cpp`:**
   - `bool isPending(char* p) const { return pending_.count(p) != 0; }`
   - `bool decommitOn() const { return cfg_.decommit; }`
   - the counters `nowait_pending_reuse_bytes`, `nowait_skipped_extents`, `nowait_fresh_bytes` and `nowait_fallback_waits`.
2. **`Allocator.hpp:512`:** `enum class AcquireWait : uint8_t { Allowed, AvoidUnderPromo }; char* acquireOldGenBlock(size_t size, AcquireWait w = AcquireWait::Allowed);`. `AllocatorTestAccess::acquireOldGenBlock` keeps the default.
3. **`Allocator::acquireOldGenBlock`** (`AL:759-893`). Factor the loop body at `:790-841` into `char* takeFreeAt(iterator)`. Before today's scan:
   ```cpp
   const bool avoid = w == AcquireWait::AvoidUnderPromo && page_work_ && page_work_->decommitOn();
   if (avoid) {
       for (auto it = old_gen_free_blocks_.begin(); it != old_gen_free_blocks_.end(); ++it) {
           if (page_request && (it->first == heap_base || it->second % kPageSize)) continue;
           if (it->second < size) continue;
           if (!page_work_->isPending(it->first)) { ++page_work_->counters_mut().nowait_skipped_extents; continue; }
           return takeFreeAt(it);                        // onReuse -> Cancelled, never waits
       }
       if (old_gen_committed + size <= nursery_offset) goto fresh_bump;   // skip the waiting scan
       ++page_work_->counters_mut().nowait_fallback_waits;               // cap: fall through (may wait)
   }
   ```
   - Label the existing bump path `fresh_bump:`.
   - Validate builds: assert that `reuse_waits` did not change in the avoid case before the fallback.
4. **`OldGenSpace`:**
   - add `Allocator::AcquireWait acquireWaitPolicy() const { return (par_promo_active_ && promo_ctx_ && promo_ctx_->n > 1) ? AcquireWait::AvoidUnderPromo : AcquireWait::Allowed; }`;
   - pass it at `ensureBagPageAvailable` (`:922`), at `allocateFromBagPage`'s fresh fallback (`:2618`), and at `allocateLargeBlock` (`:2936`, which CR-016's fix now uses);
   - validate builds: assert `acquireWaitPolicy() == Allowed` in `releaseBlockToAllocator` and `releaseUnassignedBlockToAllocator` (`:6376`, `:6519`).
5. **GC_DET_001.** The choice depends only on free-list order, `pending_` membership, the bump position and n. `testDecommitModesAgreeOnCounters` and gate G8 must stay green.
6. **CR-025 accounting stays:** a fallback wait still counts as a pause stall.
7. **Invariants:**
   - Append to **HEAP_059:** "In a parallel promotion with more than one worker, `acquireOldGenBlock` takes only Pending free extents (cancelled, no wait), else a fresh bump; it reuses a discard-issued extent (and may wait) only when the old-gen cap leaves no bump room. The skip test is membership in `pending_`, which is job-blind (GC_DET_001)."
   - **HEAP_058:** "A `promo_mu_` holder waits on a helper job only in that cap fallback, or with one worker."
8. **Model M7:**
   - **`PageWork.tla`:**
     - ghost `gPend`;
     - a caller branch `M_AcqNoWait`: Pending first, then fresh, then a fallback that sets `nwFallback`;
     - invariant `NoWaitUnlessCap`;
     - mutants `nowait_skip_posted` (must violate `DetChoice`) and `nowait_first_fit` (must violate `NoWaitUnlessCap`);
     - MAPPING rows;
     - `TracePageWork` gets an `"nw"` field.
   - **`LockOrder.tla`:**
     - `CONSTANT CapExhausted`; at `P_Pick`, with `~CapExhausted`, never `PoolWait`;
     - `lock_order_stall.cfg` (`CapExhausted = TRUE`) stays a `witness:` row;
     - new `lock_order_nostall.cfg` (`pass`);
     - mutant `mutants/nowait_off.cfg` (`violates:MODEL_M7_StallWitness`).
   - **`models.txt`:** 5 new rows.
9. **Guard (`CRT` ~:1816-1917).** After the fix, member 1 holds the locks only for microseconds, so change the guard to:
   - time **member 1's** `allocatePromotion` while the latch is held; ≥ H/2 is `kDefect`;
   - the route counts as reached when `nowait_skipped_extents` rose by at least 1 (or `reuse_waits` rose, before the fix);
   - also check that member 1's page is not b;
   - then `runFixedGuard`, renamed "CR-007: …never waits…".
   - Add a fixed guard `CR-007 cap fallback`: `max_heap_size` leaves no bump room, and it expects `nowait_fallback_waits == 1` with a correct allocation.
10. **Performance.** Inside parallel minors, fresh bumps replace reuse of discard-issued extents. RSS is unchanged, but `old_gen_committed` rises faster; no trigger reads it.
    - Measure pause and GC time, `stall_max`, the `nowait_*` counters and peak `old_gen_committed`, with `gc_thread_mode = 2`, `gc_minor_threads ≥ 2` and decommit on, plus `gc-heap-tsan pool 20000 3 2`.
    - Expect GC time the same or lower.
11. **Traps.**
    - At n = 1 the policy breaks the one-worker identity.
    - Any predicate that reads `posted_discard_`, `isDone` or `isPendingOrPosted` breaks DetChoice.
    - Touch `counters_mut()` only under `thread_mutex_`.
    - Check that the skipped extents do not starve: the mutator path still reuses them.

### 6.4 Phase 4 gates

On top of §1:
- `testDecommitModesAgreeOnCounters`;
- gc-heap-tsan `pool`, `ylos` and `ylos-sweep`, and the default run;
- `tla-check` M7 (quick and deep) and M3;
- GenMC `w_pool_done`;
- self-compile gate G8.

**Canary pins:**
- `NP.reachYoungLargeP` (M3);
- `OGS.promoteYoungLarge` (M1, M3, M5, M8);
- `OGS.lazySweep`;
- `AL.acquireOldGenRegion` (M7);
- `AL.acquireOldGenBlock` (M6, M7, M8);
- the `PageWork.cpp` file (M7, `w_pool_done`);
- the Allocator, OldGenSpace, NurseryParallel and AllocatorCommon censuses.

---

## 7. Phase 5: fork, exit and gangs (M6, M5, M2, M7)

### 7.1 The unified fork design (covers CR-003, 004, 005, 013, 015, 023, 031, 032)

**Lock order during prepare** (checked against M6 and M7):
```
registry → each bg m_ (+ set fork_hold_) → stopAllForFork → each bg m_ held
        → mark run_m_ → mark m_ → Allocator::thread_mutex_ → p1 census mu → pool m_ (drained under it)
```
- **`thread_mutex_` before the pool.** The other order deadlocks the parent: M6 `pool_host_fork_tm_last` violates `MutatorProgress`. The forker holds the pool `m_` and waits for `thread_mutex_`, while the mutator holds `thread_mutex_` (HEAP_058) and waits for the pool `m_`.
- **`thread_mutex_` after the gangs.** Otherwise the forker waits for `run_m_` while gang members block on `thread_mutex_` under `promo_mu_` (M7 `LockOrder`, the mutant `collector_takes_tm`).
- **The census mutex is a leaf** after `thread_mutex_`, and **the pool is the innermost leaf**.
- **Parent handlers** release in reverse order. **Child handlers** re-create everything in place.

**One registration.** Today three `pthread_atfork` calls (`GCHelperPool.cpp:131`, `:384`, `:566`) register lazily, and glibc runs prepare handlers in reverse registration order, so the prepare order depends on the data.

New files `runtime/src/allocator/GCFork.{hpp,cpp}`, in namespace `gc`, with no allocator includes (HEAP_058's include-graph rule):
```cpp
enum ForkLayer : unsigned { kForkGangs = 0, kForkAllocator = 1, kForkCensus = 2, kForkPool = 3, kForkLayers = 4 };
struct ForkHooks { void (*prepare)(); void (*parent)(); void (*child)(); };
void registerForkLayer(ForkLayer, const ForkHooks&);   // idempotent; the first call runs pthread_atfork once (std::call_once)
// GCFork.cpp
static std::atomic<const ForkHooks*> g_layers[kForkLayers];
static void prep()   { for (unsigned i = 0; i < kForkLayers; ++i) if (auto* h = g_layers[i].load(std::memory_order_acquire)) h->prepare(); }
static void parent() { for (unsigned i = kForkLayers; i-- > 0;)   if (auto* h = g_layers[i].load(std::memory_order_acquire)) h->parent(); }
static void child()  { for (unsigned i = kForkLayers; i-- > 0;)   if (auto* h = g_layers[i].load(std::memory_order_acquire)) h->child(); }
```

Who registers each layer:
- **`kForkPool`:** `GCHelperPool::configure`. Delete `:127-133`.
- **`kForkGangs`:** `GCMarkGang::configure` and the `GCBackgroundGang` constructor. Delete `:380-387` and `:565-567`. The layer's prepare calls `GCBackgroundGang::atforkPrepare()` and then `GCMarkGang::atforkPrepare()` (a fixed `bg_first` order).
- **`kForkAllocator`:** `Allocator::initialize` (`AL:236`).
- **`kForkCensus`:** the first construction of `p1::census()` (`P1Census.cpp:86`).

A layer that is registered but not configured returns at once.

**Trap:** every old registration must go in the same change. A leftover one makes the forker lock the same `std::mutex` twice.

**The fork contract.** HEAP_007 is merged with §6.2's rule. Full text:
> "At most one live `ThreadLocalHeap` per process; `initThread` aborts on a second unless `allowMultipleMutators(true)` (benchmark driver and test harnesses only, unsupported: CR-012). `fork()` from any thread is safe for the parent. In the child every runtime lock is free, and only heaps owned by the forking thread (the `thread_heaps_` key equals the forker's `std::thread::id`) are live; the others are dead: never collected, never torn down (leaked at exit), never read. A child may exec/_exit, call exit(), continue its own heap, or call initThread for a fresh heap. Validate builds abort a heap's use by a non-owner (CR-031)."

**How ownership is detected:**
- `fork()` keeps the forking thread's `pthread_t`, so its `std::thread::id` is the same in the child.
- The allocator's child hook records `fork_child_ = true` and `fork_owner_ = std::this_thread::get_id()`.
- Validate builds add `ThreadLocalHeap::owner_`, set in `initThread`. `minorGC` and `majorGC` abort with "HEAP_007: heap used by a non-owner". `AllocatorTestAccess::adoptThreadHeap` sets `owner_`.

**What child handlers may do:** re-create mutexes in place (`new (&m) std::mutex()`), store flags, and read `pthread_self`.
- **Never unlock the recursive `thread_mutex_` in the child.** glibc checks the owner TID, which differs in the child, so the unlock fails with EPERM.
- Optional hardening: make the `new std::vector<std::thread>()` calls in the child handlers (`:325`, `:535`, `:757`) lazy.

**New invariant HEAP_075 ForkSafety:** "One `pthread_atfork` registration (`GCFork.cpp`). Prepare lock order: registry → bg `m_` (hold set before `stopAllForFork`) → `run_m_` → mark `m_` → `thread_mutex_` → census `mu` → pool `m_`. No path holds `thread_mutex_` while it takes a gang lock, `run_m_` or the registry. Child handlers only re-create mutexes in place and set flags."

### 7.2 Step order for Phase 5

**Step 1.** Add `GCFork.{hpp,cpp}` and remove the three old registrations **in the same change**.

**Step 2. No teardown path holds `thread_mutex_` while it takes a gang lock** (a prerequisite for CR-015's handler).
- `cleanupThread` (`AL:357-380`): under `thread_mutex_`, move the `unique_ptr` out of the map and erase the entry. Release the lock, then call `doomed->getNursery().tenureTeardown(doomed->getOldGen())`. Re-lock only for `accumulated_stats_.combine(...)`. Then `doomed.reset()` outside the lock, then `setThreadHeap(nullptr)`.
- `finishTenureForExit` (`AL:387-391`): drop the `lock_guard`.
- `reset` (`AL:1037`, test-only): swap `thread_heaps_` out under the lock and destroy it after unlocking.
- `~Allocator`: see step 7.
- Grep all `lock_guard<std::recursive_mutex> lock(thread_mutex_)` sites and check that none reaches `GCMarkGang::run`/`configure`, `GCBackgroundGang` construction/`launch`/`join`/`stopAndJoin`, or the registry.
- **Model M7 `LockOrder`.** Remove the `T_Tm` hold around `T_Join`, and add a `Forker` process (collector `m_`, then `run_m_`, then `thread_mutex_`, then the pool).
  - New row `lock_order_fork` must pass.
  - Mutants `teardown_under_tm` and `fork_tm_first` must deadlock.
  - Check these **before** step 3.

**Step 3. CR-003 and CR-015: pool and allocator layers.**
- **`GCHelperPool::post`** (`:168-204`), Concurrent mode: the Idle→Posted CAS, the trace and probe, the `started_` check, the enqueue and `++outstanding_` all go inside the existing `lock_guard(m_)`. The Sync branch keeps its CAS outside.
- **The pool prepare**, replacing `atforkPrepare` `:299-307`, drains and locks in one section:
  ```cpp
  p.m_.lock();
  if (p.configured_.load(std::memory_order_acquire) && p.mode_ == HelperMode::Concurrent) {
      std::unique_lock<std::mutex> lk(p.m_, std::adopt_lock);
      p.cv_done_.wait(lk, [&] { return p.outstanding_ == 0; });   // Running jobs finish: workers need only m_
      lk.release();                                                // m_ stays held across fork
  }
  ECO_TLA_TRACE_ONLY(if (tla_m6) probe("m6.pool.drained");)       // now inside m_
  ```
- **The allocator layer:**
  - prepare: `thread_mutex_.lock()`;
  - parent: `unlock()`;
  - child: `new (&thread_mutex_) std::recursive_mutex(); fork_child_ = true; fork_owner_ = std::this_thread::get_id();`.
- **Invariant.** Amend **HEAP_058:** "`post` does the Idle→Posted CAS and the enqueue in one `m_` section; the fork prepare holds `thread_mutex_`, then drains the pool and keeps `m_` held in one section (CR-003/015)."

**Step 4. CR-013 and CR-004: the fork hold (refuse, never block).**
- **`GCHelperPool.hpp`** (`GCBackgroundGang`): add `bool fork_hold_ = false; // guarded by m_`, add `std::atomic<uint64_t> fork_refusals{0};` to `Stats`, and change `launch` to return `bool`.
- **`launch`** (`:662-681`), first thing under `m_`:
  ```cpp
  if (fork_hold_) { stats_.fork_refusals.fetch_add(1, std::memory_order_relaxed);
      ECO_TLA_TRACE("gang.refuse", "gang", key("B", this), "gen", generation_); return false; }
  ```
  After `++generation_`, call `cv_done_.notify_all()`.
- **`atforkPrepare`** (`:735-744`). The hold must be set **before** the stops:
  ```cpp
  bgRegistryMutex().lock();
  for (GCBackgroundGang* g : bgRegistry()) { std::lock_guard<std::mutex> lk(g->m_); g->fork_hold_ = true; }
  stopAllForFork();
  ECO_TLA_TRACE_ONLY(... "m6.bg.stopped" ...)
  for (GCBackgroundGang* g : bgRegistry()) g->m_.lock();
  ```
  The parent and child handlers clear `fork_hold_`.
- **Callers handle a refusal:**
  - **`OldGenSpace::launchBackground`** (`:4757-4759`):
    ```cpp
    bg_ep_ = BgEpisode::Running;
    if (!bg_->launch(&OldGenSpace::bgEntry, this, &bg_ctl_->stop)) {
        bg_ep_ = BgEpisode::None;      // CR-013/004: a fork's prepare holds the gang; the work stays in the
        return;                        // background deques; the next step relaunches, the closing drains
    }
    ```
    Count `episodes_launched` only on success, and add `cm.episodes_refused`. On a refusal, the M1 trace logs the events of a fork-stopped episode; check them with the M1 `run_traces.py` rows.
  - **`NurserySpace::tenureLaunch`** (`:598`) and **`tenureConcLaunch`** (`:1284`): `(void)R.collector->launch(...)` plus `++R.rs.fork_refusals`. `tenureJoin`'s orphan branch (`:642-644`) finishes the exact job, and for L3 `tenureConcFinish` runs (`:626-631`).
- **Invariant.** Amend **HEAP_065:** "A launch while a fork's prepare holds the gang (`fork_hold_`) is refused and treated as a stopped episode." Note in **HEAP_070** that the join's orphan path finishes a refused tenure launch.

**Step 5. CR-023: `stopAndJoin` waits only for its own generation.** It no longer shares `joinLocked`:
```cpp
std::unique_lock<std::mutex> lk(m_);
if (!running_.load(std::memory_order_relaxed)) return;
if (stop_ != nullptr) stop_->store(true, std::memory_order_release);
const uint64_t my_gen = generation_;
/* existing M6_TRACE gang.stop + probe m6.stopset */
const uint64_t t0 = GCHelperPool::nowNs();
cv_done_.wait(lk, [&] { return generation_ != my_gen || finished_ >= opt_.members; });
if (generation_ == my_gen) {                     // we join our own episode
    ECO_TLA_TRACE("gang.join", ..., "gen", generation_, "stop", true, ...);
    running_.store(false, std::memory_order_release);
}   // else the owner joined my_gen and relaunched: never clear the new episode's running_
/* stats: join_wait_ns_*, stop_wait_ns_max as in joinLocked */
```
`join()` keeps `joinLocked`. **Invariant (HEAP_065):** "a foreign `stopAndJoin` waits only for the generation it stopped."

**Step 6. CR-005: `closingFinish` accepts a stopped episode.** At `OGS:4925-4926`:
```cpp
reapBackground(/*wait=*/true);
// CR-005: a foreign stop (a fork's prepare, stopAllAtExit, reset) can end the episode without done;
// its work is still in the deques and the drain below completes the mark (M2 episode_stop_drain).
assert(bg_ep_ == BgEpisode::Finished || bg_ep_ == BgEpisode::None);
```
The drain (`:4928-4931`) and `assert(markStackEmpty())` stay. The fork hold does not remove CR-005, so this is needed on its own. **Invariant (HEAP_065):** "`closingFinish` accepts a stopped episode and drains."

**Step 7. CR-031: `~Allocator` skips heaps the forker does not own.** This must land with or after step 4: once the hang is fixed, the child's `exit()` reaches the tenure teardown. Rewrite `AL:219-231`:
```cpp
std::unordered_map<std::thread::id, std::unique_ptr<ThreadLocalHeap>> doomed;
{
    std::lock_guard<std::recursive_mutex> lock(thread_mutex_);
    if (page_work_) page_work_->drainAll(false);
    if (fork_child_) {                                  // CR-031 / HEAP_007: other threads' heaps are dead here
        for (auto it = thread_heaps_.begin(); it != thread_heaps_.end();) {
            if (it->first != fork_owner_) { (void)it->second.release(); it = thread_heaps_.erase(it); }
            else ++it;
        }
    }
    doomed.swap(thread_heaps_);
}
doomed.clear();                                         // teardown outside thread_mutex_ (HEAP_075)
```
Keep the `releaseReservation` block. Audit the `std::atexit` handlers (`eco_entry.cpp:261`, `NurserySpace.cpp:2717/2840`, `RuntimeExports.cpp`, `GCStats.cpp:2621`): none may read another thread's heap.

**Step 8. CR-032: a census layer** (`P1Census.cpp`, compiled only when `P1_CENSUS_COMPILED`):
- prepare: `census().mu.lock()`;
- parent: `unlock()`;
- child: `new (&census().mu) std::mutex(); census().forked_child = true;`.

Add `bool forked_child = false;` to `Census` (`:65-73`). `atexitReport` (`:263`) starts with `if (g.forked_child) return;`.

**Step 9. Models, harness, guards.**
- **M6 `HelperPool.tla`.** The fixed behaviour becomes the default (`DrainHoldsLock`, `PostUnderLock` and `TmFirst` are TRUE unless a mutant turns them off).
  - `pool_host_fork_stranded`, `pool_host_fork_locks` and `pool_host_child_hang` become `pass`.
  - The old `fix_*` and `tm_*` rows become A6 mutants: `pool_no_tm_cas_outside` and `pool_no_tm_drain_split` (`ChildNoStranded`), `pool_no_tm` (`ChildLocksFree`/`HostChildProgress`), `pool_tm_last` (`MutatorProgress`), and `pool_as_built_2026_09` (`ChildNoStranded`).
- **M6 `Gangs.tla`.**
  - New pieces: a `hold` variable and a `G_Hold` label after `G_Reg`. `L_Lock` refuses while `hold[lg]` (CM: `bgEp := "None"`; TN: `work[TN]` stays and is finished by `U_TFinish`). `SJ_Wait` awaits `finished ≥ NM ∨ gen ≠ sgen` and clears `running` only when `gen = sgen`. `ClosingFinished` accepts `None`. The prepare order is fixed at `bg_first`.
  - Rows that become `pass`: `gangs_host_fork`, `_1cpu_closing`, deep `mark_first`, `gangs_host_fork_window`, `gangs_two_gangs_window` and `gangs_host_fork_stall`.
  - Add a `ForeignStop` action and the constant `RelaunchWaitsStopper`; new row `gangs_foreign_stop` must pass `ParentProgress`.
  - New mutants: `no_fork_hold` and `hold_after_stop` (both `ChildHeldTenure`), `no_stop_gen` (`ParentProgress`), `stop_gen_clears_running` (`LJ_RunningExact`) and `closing_asserts_finished` (`ClosingFinished`).
- **M2.** `ClosingFinished` (`SliceControl.tla:2366`) becomes `word.done ∨ stop`. `MC_quick_episode_stop` becomes `pass`. New mutant `member_exits_undone`.
- **M5.** Move `MC_fork`, `MC_fork_orphan_copy` and `MC_fork_l3` to `mutants/`, with verdicts unchanged, labelled "pre-fix launch window; closed by fork_hold_".
- **Trace specs:**
  - `TracePool`: `pool.cas` and `pool.enq` come from one `m_` section; `pool.drained` and `pool.plock` merge into one step.
  - `TraceGangs`: add `fork.bghold`, `gang.refuse`, and a `gang.stop` with no `gang.join`.
  - Record new `.keep` logs.
- **Harness (`fork_harness.cpp`).** Bound the spins that a fix can block:
  - `:797`, `:801` and `:813` become `spinFor(…, 3000)`;
  - on a timeout set `g_det_closed` and print `window=closed`;
  - det13 and det-cr004 read "closed" as `ho.det_forked || collector->stats().fork_refusals > r0`.
- **Guards.**
  - In `fork_arms.txt`, these become `clean`: `det-cr003`, `det-cr005`, `det-cr015`, `det-cr013-{start,copy,copy-scan,l3-exit,l3-minor}` (the `-minor` arms annotated "outside contract: checks the refused launch + orphan path"), `det-cr031` and `det-cr032`. `det-cr004` goes from `reach` to `clean`.
  - The stress rows stay `flaky`.
  - CRT CR-023 becomes `runFixedGuard`, and also checks `gang.running()` right after F returns (it catches `stop_gen_clears_running`).
- **Register.** CR-003, 004, 005, 013, 015, 023, 031 and 032 become Fixed.

### 7.3 Phase 5 gates and traps

**Gates:**
- `fork-det`, and `run_fork_arms.py --tier quick` for the plain, trace and tsan flavours; report `--tier stress`;
- the unit suite in `build` and `build-validate`;
- `tla-check` M6, M5, M2 and M7, and `tla-check-deep` M6;
- `run_traces.py` M6 (`TraceGangs`, `TracePool`) and M1 (the refusal events);
- GenMC `w_pool_done` and `w_running_chain`;
- the `gc-helper-tsan` pool harness;
- the `gc-heap-tsan` default run.

**Canary pins:**
- the files `GCHelperPool.{cpp,hpp}`;
- the regions `AL.destructor`, `AL.cleanupThread`, `AL.finishTenureForExit`, `OGS.launchBackground`, `OGS.closingFinish`, `NT.tenureLaunch` and `NT.tenureConcLaunch`;
- the `pthread_atfork` grep (three sites become one) and `F.threadMutex`;
- add a **new file pin** for `GCFork.cpp`.

**Traps:**
- **Refuse, never block.** A `launch` that waits for the fork can hold the mutator while the forker asks for `thread_mutex_`.
- **Probes now fire under locks** (`m6.post.cas` under `m_` and `thread_mutex_`, `m6.pool.drained` under `m_`), so every harness pause point must be bounded.
- **`Process.cpp:70,124`** forks then execs, and now pays for the full prepare. Suggest `posix_spawn`, which runs no atfork handlers.
- **`~GCBackgroundGang`** (`:574-590`) takes the registry: it blocks while a fork is in prepare. That is expected.

---

## 8. Performance gates (every phase)

**Priority: correctness first, performance second (decision 3).** Every fix lands even when it is over its budget. The budgets below are targets.

Lab rule: judge a GC change on **GC time**, not wall time; wall is noisy.
- Use `heap-profile.py` A/B runs (the sweep harness, N = 3 medians) on the gc-opt-loop LB benchmark set.
- Use the parallel stress configs (`benchmarks/heap-config-gc-pressure[-incremental]-parallel.json`) at N = 8 and 16.
- Record minor and major GC time, the worst pause, and the per-fix counters named below.

| Phase | Budget | Counters to watch |
|---|---|---|
| 1 | ≤ 1 % GC time | flips, `live_bytes` add sites (Idle pops, splits, carves) |
| 2 | ≤ 3 % minor GC time (CR-002 is the risk) | `mutex_acquires`, `mutex_wait_ns`, `list_pops`, `stash_returned`, `sweep_ns_sum` |
| 3 | median zap ≤ 2 % of the major pause | `major_zap_ns`, `zap_ns`, `zapped_ylos` |
| 4 | ≤ 1 % GC time (CR-019); CR-007 same or lower | `nowait_*`, `stall_max`, peak `old_gen_committed` |
| 5 | none on GC paths | fork prepare latency (`Process.cpp` forks) |

- **Over budget:**
  - Ship the fix anyway.
  - Record the measured overrun in the fix's register entry and in this plan's as-built notes.
  - If the fix names a mitigation (CR-002: raise `kStash`, or skip the peek on an Idle read; CR-017: per-extent mark bits instead of hashing), try it as a follow-up step. It is a follow-up with the same gates, and it lands only if it keeps every guard and model row green.
  - A mitigation that weakens a fix is never acceptable.
- **At the end of the plan:** run the self-compile gate G8 and a full `heap-profile.py` comparison against the pre-phase-1 snapshot. Also the validate unit suite, stress and E2E (**not** a validate self-compile, a lab rule).

## 9. Guard flips (all phases)

| Guard | Phase | Becomes |
|---|---|---|
| CR-033 parse, CR-033 legacy S1 | 1 | fixed |
| CR-018; CR-001 (a), (b) | 1 | fixed |
| CR-035 stale, lost | 1 | fixed, with `setIdleUncounted` |
| CR-016 chunk, stash | 1 | fixed |
| CR-036 witness, plus the new IM5 guard | 1 | fixed |
| CR-014 A (N=2, N=1), B, C; `det-cr014-live` | 2 | fixed / clean (B and C with the tail-counter witness) |
| `det-cr001` ×4, plus the CR-001 tail variants | 2 | clean / fixed |
| `det-cr002` | 2 | clean |
| CR-028 | 2 | fixed (validate) |
| CR-037 k=1, k=2 | 3 | fixed |
| CR-017 k=1, k=2, R1, R1 (k=2), R2 | 3 | fixed (R1 and R2 oracles reworked) |
| CR-038 (+ CR-039's `cr038Z` if Step 0.4 registered it) | 3 | fixed |
| `det-cr019` ×2, `ylos-sweep` | 4 | clean |
| CR-012 (a)-(d); `cr012:a`, `cr012:e` | 4 | won't-fix (opt-in); plus a death guard and fixed controls |
| CR-007, plus the cap-fallback guard | 4 | fixed |
| `det-cr003/005/015/013-*/031/032` | 5 | clean |
| `det-cr004` | 5 | `reach` → clean |
| CR-023 | 5 | fixed |

**Final check:** `ECO_TEST_XFAIL=strict cmake --build build --target register-guards` is green. The only remaining non-fixed rows are the WONTFIX rows, which pass in both modes.

## 10. Order summary

1. **Phase 0:** won't-fix and death guard kinds, test accessors, then the `MC_k2_ylos_walk2` row (Step 0.4, which may register CR-039).
2. **Phase 1:** CR-033, then CR-018, then CR-035 with CR-016, then CR-036.
3. **Phase 2:** CR-014, then CR-001 (race), then CR-002, then CR-028.
4. **Phase 3:** CR-037, then CR-017, then CR-038 (and CR-039 if it was registered).
5. **Phase 4:** CR-019, then CR-012 (option F: forbid), then CR-007.
6. **Phase 5:** GCFork and the registrations, then no teardown under `thread_mutex_` (with M7 first), then CR-003/015, then CR-013/004, then CR-023, then CR-005, then CR-031, then CR-032, then the models, harness and guards.
7. **Close-out:** the performance comparison, G8, and the register summary.

**Dependencies:**
- Phase 2 requires Phase 1's CR-018, which closes CR-001's S1 half, and Phase 1 makes the M4 `Counts` split once.
- CR-016 (Phase 1) sends large promotions to fresh blocks; CR-007 (Phase 4) keeps them from waiting.
- CR-017 and CR-037 are independent, and both are needed.
- CR-031 must land with or after CR-013's fork hold.
- Phases 3 and 5 are independent of each other and of Phase 4, so they can run in parallel if different people own them, with one canary audit per landing.

---

## 11. As built: Phase 0 and Phase 1 (2026-09-30)

Snapshots: `snapshots/register-fixes/pre-phase0.tgz`, `pre-phase1.tgz` (also holds `test/scripts`,
`test/main.cpp` and the two plans).

### 11.1 Phase 0

- **Step 0.1** `runWontFixGuard` in CRT (kDefect or SIGABRT → `WONTFIX <id>`, passes in both
  modes; kCorrect → `XPASS: the accepted behaviour changed`; kNotReached fails).
  `run_fork_arms.py` gained the `wontfix` expectation (exit 1 → WONTFIX, exit 0 → XPASS, else
  ERROR; a tsan `wontfix` row needs `match=` like an xfail row); `fork_arms.txt`'s legend documents
  it. Both kinds were exercised by throw-away self-tests (removed): WONTFIX for kDefect and abort in
  both modes, XPASS for kCorrect; death guard passes on abort, fails on exit 0.
- **Step 0.2** `runDeathGuard` in CRT (SIGABRT passes; any exit or other signal fails).
- **Step 0.3** `OA::sweepTailInPromotion` (0 outside stats builds), `OA::setIdleUncounted`, and the
  field `test_idle_uncounted_` (declared here, read by §3.2). Canary: H12 (M2) audited.
- **Step 0.4** `MC_k2_ylos_walk2` (quick): **violates `T0GreyAllocated`** (1,859,910 states, 20 s;
  `T0GreyAllocated` is listed first in the cfg so the verdict names it). The trace is the suspected
  chain exactly. Registered **CR-039**; guard `cr038Z` (`cr038ZScenario`, test names
  `CR-039 [xfail CR-039]` and `CR-039 control (Z live)`) reproduces it in `build` and
  `build-validate` (t0 marks Z's `Tag_Free` cell), without a validate abort. §5.3 covers it; its
  mutant `skip_ylos_zap_2` goes on this row.

### 11.2 Phase 1 — results per fix

| Fix | Model (first) | Code | Guards |
|---|---|---|---|
| 3.1 CR-033 | M8 `bag_tail_headerless` mutant (43 states); `MC_quick_cr033` pass | `allocateFromBagPage`: `remainder != 0` + alignment assert | parse + legacy S1 fixed; revert → both fail |
| 3.2 CR-018 | M8 `idle_uncounted{,_flip}`; M4 `Counts` split (once), `idle_uncounted_release`, `count_until_shrink` deleted | `initObjectHeaderWithSize`, `finalizePoppedCellW` | CR-018 fixed + hook control; CR-001 (a)/(b) fixed; CR-035 hooked + plain run |
| 3.3 CR-035 | M8 `flip_keeps_index{,_lost}`; controls pass with `idle_uncounted` | `retireIndexRange` at the flip + validate post-check + stats | stale/lost fixed; revert → both fail |
| 3.4 CR-016 | NEW RULE passed first (3 controls); then mutant `flip_in_parallel_{stash,chunk}` | early return in `allocateFromEmptyRegularBlocks` + stats | chunk/stash fixed with a new-block + counter witness; revert → both fail |
| 3.5 CR-036 | none (MAPPING only); M8 witness row unchanged | `BlockTable::gen_`, `T0Block.gen`, `t0BlocksChangedWhy`, `isT0Block` | witness fixed; new validate IM5 guard + hook control; revert → both fail |

### 11.3 Deviations from §3 (all faithful to intent)

1. **`controls/cr033_tail_header` and the two `controls/flip_skips_parallel*` were deleted** once
   their rule became the default (they were identical to the plain rows). The plan named only
   `cr018_count_idle`'s retirement.
2. **M4 `controls/phase_atomic_release` now passes** (was `violates:ReleasedSafe`): its failure was
   the phase-dependent count, exactly as §4.2 argues; its row is flipped with a note. Phase 2 deletes
   it with the other `phase_atomic*` controls.
3. **`count_until_shrink` was dropped from every M4 config that named it** (it no longer exists;
   the default counts a superset). `count_mixed_idle`, `bag_tail_header`, `flip_purges_index` were
   likewise dropped from M8's `fixed_all`, `MC_deep_fixed` and `coverage.cfg` (now `MUTANT = {}`).
4. **Between §3.2 and §3.3 the CR-035 rows carried `MUTANT = {"idle_uncounted"}`** so they kept
   reproducing CR-035 on CR-018's pre-fix precondition until §3.3 moved them to mutants.
5. **M4 `MC.tla`** gained `NWorkers = 1 -> {1}` for `flip_one_worker`; `Cardinality(Workers) > 1`
   stands for `promo_ctx_->n > 1`. A scratch `released = {}` witness confirmed a flip is reachable at
   N = 1 (40 states), so the control is not vacuous.
6. **CR-001 (a)/(b)** have no dedicated control: defaulting `test_idle_uncounted_` to true (a scratch
   revert) makes both fail. CR-018's own control is a permanent test.
7. **CR-016 guards** also check, in stats builds, that `flip_skipped_parallel` rose by exactly one.
8. **CR-036**: the scenario became `cr036Scenario(mode)` (witness / IM5 / IM5 without generation);
   the IM5 hook is `test_im5_ignore_gen_` (validate builds), with `OA::captureT0Blocks`,
   `t0BlocksChangedWhy`, `clearT0Blocks`, `blockGeneration`.
9. **`run_register_guards.sh`** step 1 now runs `--filter "CR-0"` (was `"xfail CR-"`), so converted
   (fixed) guards, controls and future won't-fix guards are gated too; step 2 runs `CR-028` and
   `CR-036` in the validate tree (was `xfail CR-028`).
10. **`m4.fin` trace event** carries `cnt` (the code emits it); `TracePromoBitmap` checks
    `cnt = IdleCounts` and the `liveBytes` rise on a not-black finalize.
11. **GenMC could not be run here** (`genmc` is not installed; the eco-dev-genmc image has it). The
    W3 pin (`OGS.finalizePoppedCellW`) was audited by reading: W3 does not model `live_bytes`.

### 11.4 Phase 1 gates (2026-09-30)

- `--filter "CR-0"`: 47/47 pass in `build` and in `build-validate` (19 XFAIL rows = the still-open
  entries, plus CR-028 in validate); `build-validate --filter threaded-gc-0`: 168/168.
- Full unit suite (once, `build`): 1,995 run; 1,932 passed and the 63 `codegen/*.mlir` tests failed
  only because the suite was started from the scratch directory (they spawn
  `build/runtime/src/codegen/ecoc` by a relative path: "not found"); re-run from `/work`:
  302/302 codegen tests pass. So 1,995/1,995.
- `ECO_TEST_XFAIL=strict ... register-guards`: unit step 28 pass / 19 fail, and the 19 are exactly
  the open xfail guards (CR-017 ×5, CR-014 ×4, CR-037 ×2, CR-007, CR-023, CR-012 ×4, CR-038,
  CR-039); every converted guard and control passes. Validate step: CR-028 fails (open), CR-036's
  three pass in both modes (the first strict run stopped after CR-028; the script now runs both).
  Harness arms: 20 FAIL (all open xfail rows; no fork/TSan row belongs to Phase 1) + 3 PASS.
- TLA+: M1, M4, M5, M8 quick 163/163 as expected; M8 deep 2/2 (`MC_deep_fixed` and
  `MC_deep_broad`, 1,509 s at 2 workers); M4 deep 8/8; `run_traces.py --model M4` 12/12 (twice:
  after §3.2 and at the end). Canary green after each fix's audit.
- Exact-arrays stress (`build-heap-tsan/gc-heap-tsan promo <seed> 40 {4,6,8} 0 1`, seeds 1-7):
  **0 "Invalid tag" aborts in 21 runs** (was 4 of 7). Every run still exits 66 with TSan warnings;
  the reports name the open Phase-2 races (`lazySweep`'s `loadWord`/`nextSetBit` vs
  `setMarkBitAtomic`: CR-002; header reads vs `finalizePoppedCellW`'s header write), none a Phase-1
  site.
- `genmc run_drivers.py --only w3d`: not runnable here (`genmc` missing; see 11.3 item 11).

### 11.5 Performance (§8, Phase 1 budget ≤ 1 % GC time): NOT MEASURED

The §8 method is a same-sitting `heap-profile.py` A/B (N = 3 medians) of the LB self-compile. It was
impractical in this environment: it needs a pre-fix runtime tree built from
`pre-phase1.tgz` (the only phase-timer tree, `build-phasetimers`, dates from 2026-09-29 and predates
the repros work, so it is no baseline), a relink of the compiler against each tree, and six
~110 s self-compiles at ~13 GB RSS on a 15 GB machine with 9 GB of disk free. By construction the
added work is: at Idle, one `contains` + page-index load + add per mixed-block pop, split and carve
(the uniform cursor fast path is untouched); one index scan per empty-block flip (counted:
`empty_block_flips`, `flip_index_retired`); one branch at the top of `allocateFromEmptyRegularBlocks`
(`flip_skipped_parallel`); one increment per block materialization. Owed: the A/B at the next
phase's performance sitting (or the plan's close-out comparison against `pre-phase1.tgz`).

## 12. As built: Phase 2 (2026-09-30)

Snapshot: `snapshots/register-fixes/pre-phase2.tgz`. Order as planned: CR-014, CR-001 (race), CR-002,
CR-028; model first each time (M4 re-translated after each step), then code, guards, revert check.
One canary audit covers the batch (M1, M2, M4, M6, M7, M8 AUDIT.md; `test/genmc/AUDIT.md` for W3/W4).

### 12.1 Results per fix

| Fix | Model (first) | Code | Guards (build / build-validate) | Revert check |
|---|---|---|---|---|
| 4.1 CR-014 | tail branch `await "tail_immediate" \in MUTANT`; `sweep_tail{,_release,_live,_reuse}` pass; mutants `tail_immediate{,_release,_live,_reuse}` violate DetachNotCurrent / ReleasedSafe / NoRaceLive / NoDoubleAlloc; `controls/tail_defers*` deleted; trace path 3 = deferred | `completeSweep` lambda inside `TLA-REGION(OGS.lazySweep)` (paths 2 and 3); PM7 tripwire first in `onSweepComplete` (every build) | A (N=2), A (N=1), B, C fixed and pass in both trees; `det-cr014-live` clean, REACHED | old tail path + tripwire off: all four unit guards fail (A abort, B release, C double allocation), `det-cr014-live` reports `flushCursorW` |
| 4.2 CR-001 | `PhasePlain == "phase_plain" \in MUTANT`, reads under `promo_mu_` plain (`PhLocked`); `sweep_race_phase` pass; mutant `phase_plain` (NoRacePhase); `controls/phase_atomic*`, `finalize_in_lock_phase` deleted | relaxed `atomic_ref<GCPhase>` store in `completeSweep`, loads in `finalizePoppedCellW` / `finalizeBitmapCellW`; `static_assert(is_always_lock_free)` | four `det-cr001` arms clean, REACHED; new `CR-001 (a, tail)`, `(b, tail)` (B = 8, tail counter) fixed and pass | plain accesses: all four TSan arms report `finalizeBitmapCellW` again |
| 4.3 CR-002 | NEW RULE passed first on every sweep row, `sweep_fixed` (`MUTANT = {}`) and 8/8 deep rows; in-lock branch reachable (witness); mutant `finalize_outside_lock` (NoRaceBitmap, intended story); `controls/finalize_in_lock` deleted | `cellInUnsweptBlock`, rung-2 batch rewrite (in-lock finalize, peek), PM8 | `det-cr002` clean, REACHED (`r1 == g1`); CR-014 B/C, CR-001, CR-016 (stash) and CR-028 (`p1 == av`) preconditions still hold | no in-lock finalize / no peek: `det-cr002` reports `setMarkBitAtomic` |
| 4.4 CR-028 | none (M4 has no validator steps) | `validateV11(BlockId)`; `v11_deferred_` (validate, under `promo_mu_`, cleared at begin); walked in `endParallelPromotion` after the stash return, before the deferred shrink | CR-028 fixed, passes in `build-validate` | deferral off: V11 aborts again; and leaving W1's cell unformatted to the merge makes the deferred walk abort there (the walk really runs) |

### 12.2 Deviations (all faithful to intent)

1. **`cellInUnsweptBlock` also requires `gc_phase_ == Sweeping`** (read plain under `promo_mu_`).
   The plan's helper tested `!fully_swept` only, but `fully_swept` is false for EVERY block during a
   mark cycle (`resetBufferMetaForMark`) and for blocks materialized at Idle, so it would have
   forced every rung-2 pop of a Marking-phase minor into the lock (undoing Step 7b), and the
   matching PM8 aborted falsely in `threaded-gc-06: the parallel engine reproduces the serial object
   counters` (validate, N = 1, 4, 8). The gap sweep reads and clears mark words only while
   `gc_phase_ == Sweeping`, and nothing sets Sweeping inside a minor, so the conjunct is exact, not a
   weakening (it is §4.3 step 8's "skip the peek on an Idle read", extended to Marking and applied
   from the start). The model carries it literally (`Unswept(c) == phase = "Sweeping" /\ ~swept[BlkOf(c)]`,
   with the batch's plain phase read recorded), and every quick and deep row passed with it before the
   code. **PM8** checks the same predicate at the stash pop (the phase by a relaxed `atomic_ref` load:
   it runs outside the lock).
2. **M4 models the reads under `promo_mu_` as plain** (`PhLocked`: `Ladder`, `W_PopAfterSweep`, the
   batch) and the unlocked ones and the completion write as atomic, exactly as the code (the plan
   flipped one flag for all accesses).
3. **`W_StLk` is gone**: with `finalize_in_lock` retired, the stash never finalizes under the lock; the
   in-lock finalize is `W_Fin` with the lock held → `W_StUnlock`. The trace spec: `m4.batch` carries
   `inlock` (logged before the in-lock finalize), `m4.unlock` also matches `W_StUnlock`.
4. **Guards.** CR-014 A also checks the tail counter; B also merges and checks `allocStateConsistent`;
   C, once D is not released, pops the stash, merges, and checks both objects intact. The
   `det-cr014-live` and `det-cr001 … tail` arms needed the same rework (`sweepCompleteDeferred()` no
   longer tells the paths apart): they prove the path by `sweep_tail_in_promotion`.
5. **`TraceRace.cfg` became five accept rows** (every registered run), and `run_traces.py` names a row
   with a non-default config `…:<config stem>` so the rows do not collide (this also renames the
   existing `TraceEpisode.cfg` / `TraceSlices.cfg` rows; names are used for display, filters and log
   file names only).
6. **Canary grep `F.gc_phase` re-derived** as `gc_phase_ =|atomic_ref<GCPhase>` (the plan said "re-derive
   the grep"). M7's MAPPING route census now records that the tail-completion release route exists
   only with one worker.
7. **No new stats counter** for in-lock finalizes: a `PromoWorker` / `GCStats` layout change would force
   relinking every runtime library (a stale `libEcoEntryStatic` crashes at exit), and nothing gates on it.
8. **GC_DET_001**: nothing to re-baseline. The N = 1 tail completion now hands worker 0's cursors
   back first, and the identity tests (`promotion through worker 0 … reproduces allocate() exactly`,
   `the parallel engine reproduces the serial object counters (1..8 workers)`) pass in both trees.
9. **GenMC was not run** (`genmc` is not installed). W3 cases c and d were changed as §4.2/§4.3 say,
   rows `w3c`/`w3d` flipped to `pass`, mutants `W3_CR001_PLAIN_PHASE` (`race:phase_idle`) and
   `W3_CR002_UNLOCKED_FINALIZE` (`race:bits`) added; both variants compile and the registry parses;
   audited by reading (`test/genmc/AUDIT.md`). Owed: a `genmc-check` W3 run.

### 12.3 Phase 2 gates (2026-09-30)

- `--filter "CR-0"`: 49/49 in `build` and in `build-validate` (15 XFAIL = the open Phase 3-4 entries).
- Full unit suite (once, `build`, from `/work`): **1,997/1,997**.
- `build-validate --filter threaded-gc-0` at `ECO_GC_MINOR_THREADS` = 1, 4, 8: 168/168 each (after
  deviation 1; the first run found PM8's false positive).
- `ECO_TEST_XFAIL=strict … register-guards`: unit step 34 pass / 15 fail — exactly the open xfail guards
  (CR-017 ×5, CR-037 ×2, CR-007, CR-023, CR-012 ×4, CR-038, CR-039); validate step CR-028 1/1 and CR-036
  3/3; harness arms 9 PASS (the six Phase-2 rows now `clean`, `mut`, `det-cr004`, the CR-013 control)
  and 14 FAIL (the open xfail rows).
- TSan: `run_fork_arms.py --tier quick --flavor tsan`: PASS 6, XFAIL 4 (CR-019 ×2, CR-012 ×2).
  `gc-heap-tsan` default (6 min), `pool`, `ylos`: 0 warnings, `heap_driver PASS`. Tail mode
  `promo {1,2,3} 40 4 0 0 8 1`: 36 tail hits each, 0 warnings, no `computeFragmentationStats`.
  Exact arrays `promo {1,2} 40 {4,8} 0 1`: 0 warnings, 0 "Invalid tag" (Phase 1 saw exit 66 on every run).
- TLA+: M4 quick 48/48 and deep 8/8; `run_traces.py --model M4` 17/17. Canary green after the audit.

### 12.4 Performance (§8, Phase 2 budget ≤ 3 % minor GC time): NOT MEASURED

The §4.3 step 8 measurement (pmin `mutex_acquires`, `mutex_wait_ns`, `list_pops`, minor time and the
worst minor at N = 8 and 16 on `benchmarks/heap-config-gc-pressure[-incremental]-parallel.json`) has no
readily usable path here: those configs are exercised by `stress-test` / `heap-profile.py`, which run
compiled Elm programs (E2E-class work, excluded for this phase), and an A/B needs a second, pre-fix
runtime tree (from `pre-phase2.tgz`) on a disk with ~9 GB free. By construction: CR-014 moves the
tail completion's shrink to the merge (where the in-loop path already ran it); CR-001 turns two reads
and one write into relaxed `atomic_ref` accesses (plain `mov`s on x86-64); CR-002 adds, per rung-2 pop
and per peeked cell, one plain phase compare, and only while Sweeping a `contains` + page-index + meta
load, and finalizes the head under the lock only when it lies in a not-fully-swept block (the block
under the sweep cursor, or a sentinel cell ahead of it) — in which case nothing is stashed. The trace
harness, whose geometry sweeps a mixed block of alternating live and dead cells (the worst case), took
the in-lock branch in about half of its batches. Owed with Phase 1's: the A/B at the next performance
sitting or the close-out comparison; if over budget, §4.3's mitigation (raise `kStash`) is the next step.

## 13. As built: Phase 3 (2026-09-30)

Snapshot: `snapshots/register-fixes/pre-phase3.tgz`. Order as planned: CR-037, CR-017, then CR-038 (with
CR-039); model first each time (M5 re-translated after each step, M1 for CR-017), then code, guards,
revert check. One canary audit covers the batch (M1, M3, M5, M8 AUDIT.md).

### 13.1 Results per fix

| Fix | Model (first) | Code | Guards (build / build-validate) | Revert check |
|---|---|---|---|---|
| 5.1 CR-037 | `LbKey` `"code"` renamed `"addr"`; `"kind"` = the code (`controls/lb_kind` pass); `MC_lb_aba`, `MC_deep_boundary_k2_lb` stay `violates:NoDangling` as regression mutants | `markLargeBodySeen` in new pin `OGS.markLargeBodySeen`: `kind != 0 \|\| body_base != body` returns; prep comments | `CR-037 (k=1)`, `(k=2)` fixed, pass in both trees | kind check off: both fail (B unaged, slot into eden) |
| 5.2 CR-017 | NEW RULE passed first: M1 `J_STW` zap (`MC_quick_region`, `_reuse` pass every invariant; mutants `no_cr017_fix{,_reuse}`); M5 `MJ_Mark` `MajorZapX` (`cycle_major`, `k2_cycle_major`, `cycle_major_t0grey` pass; mutants `no_cr017_fix{,_k2,_t0grey}`, `zap_tenuring` NoDangling, `zap_fresh_only` YoungWalkValid; `_cr017` boundary rows = `MUTANT no_cr017_fix`; oracle off in `MC_deep_boundary{,_k2,_k2_m2}`, all pass) | `OGH::majorReachedNursery`; `NurserySpace::zapDeadAfterMajor` (new pin `NR.zapDeadAfterMajor`); hook in `TLH.majorGC` after `finishMarkAndSweep`; validate tripwire in `evacuateR` Hand/Age; stats `major_zaps`, `major_zapped{,_bytes}`, `major_zap_ns{,_max}`; trace event `mzap` | k=1, k=2, R1, R1 (k=2), R2 fixed, pass; new validate death guards `HEAP_074 tripwire (k=1)`, `(k=2)` + control | hook off (and R1's zap witness off, so R1 reaches its oracle): all five fail on their oracles |
| 5.3 CR-038 (+ CR-039) | M5 `J_Merge` step 5c (`Gen(ageX) \notin amark` → slots `Nil`): `MC_k2_ylos_walk` and `MC_k2_ylos_walk2` pass every invariant; mutants `skip_ylos_zap` (YoungWalkValid), `skip_ylos_zap_2` (T0GreyAllocated); `YoungWalkValid` back in `MC_deep_boundary_k2{,_m2}` | `mergeJob` (5c) as sketched (`zapped_ylos`, time in `zap_ns`) | `CR-038`, `CR-039` fixed, pass in both trees | 5c off: both fail (Y's slot into retired X1; Z freed and marked by t0) |

**CR-039 outcome:** the planned 5c fix closes it (model `MC_k2_ylos_walk2` pass, code guard `cr038Z`
pass); no separate design was needed.

### 13.2 Deviations (all faithful to intent)

1. **R1 route witness** is "the header's address lies inside a `Tag_Free` filler" (`insideFiller`),
   not `getHeader(hdr)->tag == Tag_Free`: the zap coalesces a dead run into one filler, so the header
   copy may be inside it. R1's k = 2 cleanup no longer sets `test_no_body_remark_` (CR-037 is fixed).
2. **CR-039's control** sets `test_skip_zap_` at minor 4: with the fix, a dead Y's slots are cleared in
   the control too, so the control (Z live) needs the pre-fix merge to keep showing that t0 greys an
   *allocated* Z through Y's slot. The guards' own slot reads now handle the `Empty` constant.
3. **Zap details:** the fillers are split at 2 GiB (`Header::size` is u32); a malformed object in a
   Young extent aborts (`HEAP_074: a bad object…`); `R.census.clear()` is under `P1_CENSUS_COMPILED`
   (the field exists only there); the tripwire also catches a target inside a coalesced filler (the
   0xD8 header word); the trace field is `zapped` (`n` is reserved by the merger).
4. **New validate death guard** for the tripwire (not in the plan): resurrect an unrooted survivor
   across an explicit major; the next minor aborts in `evacuateR` (k = 1 Hand, k = 2 Age); control
   rooted. Registered in `test/main.cpp`.
5. **MC_deep re-hosted** (the plan's trap fired): the plan §6 bounds exceeded 58.8M states / 9.5 GB of
   TLC state files (the disk filled); the boundary bounds at 4 minors reached 122.4M states, depth 92,
   4.7 GB, unfinished, and at 3 minors 156.5M states (killed by a disk watchdog). It now runs EC 2,
   SC 2, OC 4, MaxLid 4, NF 1, 3 minors, 2 operations, still Collectors = 2 (the only L3 + majors +
   cycles row); see 13.3.
6. **M5 trace:** `TraceTenurePause` maps `mzap` into `MJ_Mark` (removed from `Hidden`), checking the
   zapped S-cell count; `tiny_tenure.cpp` records `mzap`; two new reject rows. M1's `TraceCycle` keeps
   only cycle events (`.keep`), so `mzap` is not mapped there.
7. **"ConcurrentTenureTest at k = 1, 2, 3":** the unit binary has no tenure-age override, so k = 1 is
   `ConcurrentTenureTest` and k = 1..3 is `TenureAgeingTest` (E1 oracle, modes agree at k = 2, 3);
   both run under the `threaded-gc-07` filter (40/40 in `build`) and `threaded-gc-0` (validate).
8. **"E2 at MAJOR_GC_LIVE_BUDGET = 3.0":** 3.0 is the compiled-in default since 2026-09-29, so the
   validate `threaded-gc-0` runs (incl. ConcurrentTenureTest's HEAP_072 test) are at 3.0.
9. **Resurrection audit** (`allocateYoungLarge` / `allocateLargePinned`): they run a major only on
   allocation failure; every caller reaches them through `allocate`/`allocateSlow`, which are GC
   points (a minor may run on the same paths), and HeapHelpers' Pattern 1 roots every stored pointer
   across such a call (e.g. `arrayFromPointers`' `StackRootRangeGuard`). No unrooted survivor is held
   across `majorGC`; `allocateYoungLarge`'s comment now says so. The validate tripwire detects one.

### 13.3 Phase 3 gates (2026-09-30)

- `--filter "CR-0"`: 50/50 in `build` (the tripwire test prints "skipped" there) and in `build-validate`. XFAIL now
  only CR-007, CR-023, CR-012 ×4.
- Full unit suite (once, `build`, from `/work`): **1,998/1,998**.
- `build-validate --filter threaded-gc-0` at `ECO_TEST_MINOR_THREADS` = 1, 4, 8: 168/168 each.
- Full unit suite (once, `build`, from `/work`): **2,003/2,003** (no harness needed a further CR-012 opt-in).
- `ECO_TEST_XFAIL=strict … register-guards`: unit step 44 pass / 6 fail — exactly the open xfail guards
  (CR-007, CR-023, CR-012 ×4); validate step CR-028 and CR-036 pass; harness arms 9 PASS / 14 FAIL (the
  open Phase 4/5 rows; no Phase-3 row exists there).
- TSan (`build-heap-tsan`): **`lbaba 200 1` PASS** (16 runs: ages 1, 2 × B 1-4 × lengths 1600/4500,
  seeds 1-16, so seeds 1 and 7 at age 1; 0 TSan warnings, 14.4 min); default run (region scenarios)
  PASS, 0 warnings; `ylos` PASS, 0 warnings; `tenure-storm` (stress, flaky): 20 trials, 3,447 forks,
  0 CR-013 TV aborts, 2 CR-005 aborts (open, Phase 5), 0 other failures.
- TLA+: M1 quick 24/24; `MC_deep_region` pass (9,354,285); Apalache `step5_MajorIdle` pass (the lemma
  is legacy-only, unchanged). M5 quick 72/72; M5 deep 18/18 other rows as expected (state counts in
  M5 AUDIT.md); `MC_deep` (re-hosted, final bounds EC 2, SC 2, OC 4, MaxLid 4, NF 1, 3 minors, 2 ops, Collectors 2): pass, 18,313,899 states, 120 s; its `no_cr017_fix` twin (scratch) violates `YoungWalkValid` (105,978 states), so the bounds still reach CR-017.
- `run_traces.py`: M1 18/18, M5 29/29 (2 new `mzap` reject rows).
- Canary: pins `TLH.majorGC`, `NR.evacuateR`, `NT.mergeJob`, greps `T1`, `T2` audited in M1, M3, M5, M8
  (no change for M3/M8; models updated for M1/M5); new pins `OGS.markLargeBodySeen` (M5) and
  `NR.zapDeadAfterMajor` (M1, M5) added and filled; `NSH.forEachYoung` did not fire (comment only);
  canary green (230 pins).
- Invariants: HEAP_074 new; HEAP_072 (lb_bodies), HEAP_069 (zap rule), HEAP_070 (5c), HEAP_063,
  HEAP_SNAPSHOT_001 amended. Plans 07 (§3.16 "conservative and safe") and 07b (§2.5 "same roots",
  §2.6 YLOS holders) corrected.

### 13.4 Performance (§8, Phase 3 budget: median zap ≤ 2 % of the major pause): PARTLY MEASURED

The §5.2 step 9 measurement on the gc-opt-loop LB set (self-compile, k = 1 and 2) was not run (same
constraints as 11.5/12.4: no pre-fix tree, ~13 GB RSS, little disk). The only numbers are from the
unit binary (`threaded-gc-07` filter, stats build): 20 region-mode zap passes, 2,140 dead survivors,
mean 0.065 ms, max 0.196 ms per major, against a mean STW major pause of 6.05 ms over the run's 98
majors (≈ 1.1 % mean; the per-major median was not separable from the aggregate, and these are small
test heaps). The zap is one `unordered_set` lookup per survivor in at most k extents, on STW majors only.
Owed: the LB A/B (`rs.major_zap_ns` vs `MajorGCEvent.total_ns`) at the close-out comparison; if over
budget, §5.2 step 9's mitigation (per-extent mark bits in `greyObject`, touching `OGS.greyObject`).

## 14. As built: Phase 4 (2026-10-01)

Snapshot: `snapshots/register-fixes/pre-phase4.tgz`. Order as planned: CR-019, CR-012 (option F), CR-007;
the canary was run and audited after each (three batches). Model first where the plan names one: M3
footprint note (CR-019), M7 MAPPING (CR-012), M7 `PageWork` + `LockOrder` + `TracePageWork` (CR-007,
TLC green before the code).

### 14.1 Results per fix

| Fix | Model (first) | Code | Guards (build / build-validate) | Revert check |
|---|---|---|---|---|
| 6.1 CR-019 | M3 footprint note (AUDIT, MAPPING §4/A3); M3 quick 12/12 | `loadHeaderRelaxed` / `storeHeaderRelaxed` (`AllocatorCommon.hpp`); writers `reachYoungLargeP`, `promoteYoungLarge`, region `reachYoungLargeR`; readers in `lazySweep` (gap sweep, header walk, large-block pin read) and `validateV11` | `det-cr019` t1first/t2first `clean` (REACHED, 0 warnings); `ylos-sweep` clean and now in the default run | the three pre-fix files: both det arms report `promoteYoungLarge`, `ylos-sweep` 6 warnings |
| 6.2 CR-012 (F) | M7 MAPPING (`M_Choose` fresh row, `thread_mutex_` row, "outside the model") | `allowMultipleMutators` + `initThread` abort; `acquireOldGenRegion` via `onFreshBump`; `main.cpp` opt-in; harness opt-ins (CRT `cr012Init`, `ConcurrentTenureTest` spawn loop, `fork_harness` `trialTwoHeap`, `cr012_two_heap.cpp`); step 6 hardening (`old_gen_in_use_bytes_` relaxed atomic) | `CR-012 forbid` (death) passes; `opt-in`, `sequential`, `(d) sequential`, `(d)` (two heaps) fixed and pass; (a)-(c) WONTFIX; TSan `cr012:a` clean, `cr012:e` `wontfix` | abort and `onFreshBump` disabled: the death guard and both (d) guards fail |
| 6.3 CR-007 | M7 quick 24/24 (new `pw_nowait`, `lock_order_nostall` pass; mutants `nowait_skip_posted` → DetChoice, `nowait_first_fit` → NoWaitUnlessCap, `nowait_off` → MODEL_M7_StallWitness); deep `pw_deep` 13,561,819 / `pw_deep_liveness` 1,956,641 pass; `run_traces.py` M7 20/20 | `acquireOldGenBlock(size, AcquireWait)` policy, `takeFreeAt` lambda; `PageWork::isPending`, `decommitOn`, `noteNoWait`, `noteNoWaitSkip`, four `nowait_*` counters; `OldGenSpace::acquireWaitPolicy()` at `ensureBagPageAvailable`, `allocateFromBagPage`, `allocateLargeBlock`; validate checks | `CR-007` (member 1: 0.5 ms, fresh page, 1 skip) and new `CR-007 cap fallback` (b via the fallback, `nowait_fallback_waits` 1) pass | policy forced `Allowed`: `CR-007` takes 201 ms and b, the fallback guard sees no fallback — both fail |

### 14.2 Deviations (all faithful to intent)

1. **CR-019:** `lazySweep`'s large-block branch's `pin` read (legacy only) is converted too; V11 now lives
   in `validateV11` (Phase 2's refactor), which gets the load. `ylos-sweep` joins the default run by a call
   to `ylosSweepMain` at its defaults at the end of `heap_driver`'s default list. `AllocatorCommon.hpp` now
   has concurrency lines, so the canary's coverage check required a new **census pin** (M3, M4).
2. **CR-012 (d) two-heap guard is a `runFixedGuard`, not `runWontFixGuard`:** §6.2 step 7 lists (a)-(d) as
   won't-fix, but step 3 fixes (d) in both options, so a won't-fix guard would XPASS. Only (a)-(c) are
   won't-fix; (d) and the new `(d) sequential` are fixed guards. Step 6 (hardening) landed as a relaxed
   load + relaxed store under `thread_mutex_` (no RMW). `acquireOldGenRegion` also calls the commit
   observer, like the bump path. **HEAP_007**: only the CR-012 sentence was prepended; §7.1's fork contract
   lands with Phase 5.
3. **CR-007 counters** are bumped by PageWork methods (`noteNoWait`, `noteNoWaitSkip`) instead of a
   `counters_mut()` accessor (same counters, still under `thread_mutex_`), and `noteNoWait` emits the M7
   trace event. The trace gets a separate **`nw` event** (announcing the next `acq` / `fresh`), not a
   field on `acq`: `acq` is logged inside `onReuse`, which does not know the policy. The gc-helper
   harness gained a 12th argument (share of reuses under the policy) so the policy is traced; older rows
   replay unchanged.
4. **No `goto fresh_bump`:** a `skip_reuse` flag skips the first-fit scan. The fallback is counted only
   when a fitting extent exists (else the request runs out of space as before).
5. **M7 model details:** constant `NoWait` (TRUE in the pass rows, FALSE in the nine older mutants, whose
   verdicts and reachable sets are unchanged — with `NoWait = FALSE` the new spec reaches exactly the old
   22,518 `pw_basic` states); an extra invariant **`PendGhost`** (the skip test's input is job-blind);
   `CapExhausted = TRUE` kept in `lock_order`, `lock_order_3` and the four lock mutants (their deadlock /
   AllFinish verdicts keep covering the waiting path). New rows: 2 + 3 in `models.txt` as planned, plus 2
   accept and 3 reject trace rows.
6. **CR-007 guard:** member 0 no longer promotes (only member 1 is timed, as §6.3 step 9 says); the cap
   guard uses `max_heap_size = 64 MiB` and spends the reservation through the test accessor.
7. **Release checks** are validate-only aborts (`[heap-validate] CR-007: a … release inside a parallel
   promotion with n > 1 workers`), not `assert`s, as the plan's "validate builds" says.
8. **GC_DET_001 at N > 1 (found by running `testDecommitModesAgreeOnCounters` at
   `ECO_TEST_MINOR_THREADS` = 2, 4, 8):** modes 1, 2, 2+jitter and 2+ahead stay identical in every
   counter, the `nowait_*` sums included (2,097,152 in each), but **mode 0 now differs** from them in
   placement counters (hiwater 589,824 → 1,867,776, fresh 524,288 → 1,802,240, reuse 1,867,776 →
   589,824) because mode 0 has no PageWork and so no policy; object-level counters are identical. Before
   the fix m0 == m1 held at N = 2 too (checked on a scratch revert). The default suite (N = 1) is
   unchanged. The test now compares mode 0 on object-level quantities when the policy ran, and asserts
   the `nowait` sums agree across modes 1/2; GC_DET_001 records it.
9. **`ecor` (the benchmark driver) does not link** (`Elm::PermanentSpace::instance()` undefined: its
   `EXCLUDE_FROM_ALL` source list lacks `PermanentSpace.cpp`). Pre-existing and unrelated; `main.cpp`'s
   opt-in compiles.

### 14.3 Phase 4 gates (2026-10-01)

- `--filter "CR-0"`: 55/55 in `build` and in `build-validate` (XFAIL: CR-023 only; WONTFIX: CR-012 (a)-(c)).
- `build-validate --filter threaded-gc-0` at `ECO_TEST_MINOR_THREADS` = 1, 4, 8: 168/168 each.
- `testDecommitModesAgreeOnCounters` (GC_DET_001): passes at the default and at N = 2, 4, 8 (item 8).
- `ECO_TEST_XFAIL=strict … register-guards`: unit step 54 pass / 1 fail (CR-023, Phase 5); validate steps
  CR-028 1/1 and CR-036 3/3; harness arms 12 PASS, 1 WONTFIX (`cr012:e`), 10 FAIL — exactly the Phase 5
  rows (`det-cr003`, `-cr005`, `-cr015`, `-cr013-{start,copy,copy-scan,l3-exit,l3-minor}`, `-cr031`,
  `-cr032`).
- TSan (`build-heap-tsan`): `run_fork_arms.py --tier quick --flavor tsan`: PASS 9, WONTFIX 1. Default run
  (now ending with `ylos-sweep`) PASS, 0 warnings, 375 s; `pool` PASS 0 warnings; `ylos` PASS 0 warnings;
  `ylos-sweep` 0 warnings; `pool 20000 3 2` PASS 0 warnings — reuse waits 7-8 per scenario, all outside a
  pause (before: 21-25, 9 of them inside a parallel minor), `nowait:` about 2,000 skipped extents and
  9-11 MiB fresh per scenario, 0 cap fallbacks, stall_max 15.6 / 18.2 ms (19.6 before), old-gen hiwater
  12.2 / 14.4 MiB (12.3 / 14.0 before).
- TLA+: M3 quick 12/12; M7 quick 24/24, deep 2/2; `run_traces.py --model M7` 20/20.
- Canary: three audited batches (CR-019: `OGS.promoteYoungLarge`, `OGS.lazySweep`, `NP.reachYoungLargeP`,
  `NR.reachYoungLargeR`, grep `T3`, new census `AllocatorCommon.hpp`; CR-012: `AL.acquireOldGenBlock`,
  `AL.releaseOldGenBlock`, `AL.acquireOldGenRegion`, censuses `Allocator.{cpp,hpp}`, greps `F.threadMutex`,
  `F.pageWorkCalls`; CR-007: files `PageWork.{hpp,cpp}`, `gc-helper-tsan/harness.cpp`, regions
  `OGS.allocateFromBagPage`, `OGS.ensureBagPageAvailable`, `OGS.allocateLargeBlock`,
  `OGS.releaseBlockToAllocator`, `OGS.releaseUnassignedBlockToAllocator`, `AL.acquireOldGenBlock`, greps
  `F.parPromoActive`, `F.pageWorkCalls`, `F.oldGenFreeBlocks`), AUDIT entries in M1, M3, M4, M5, M6, M7,
  M8 and `test/genmc/AUDIT.md` (W3, W4, `w_pool_done`); green, 231 pins.
- Invariants: HEAP_062 (CR-019) and HEAP_067 (cross-reference); HEAP_007 (one mutator per process),
  GC_DET_001 (per process = per heap; CR-007's mode-0 note), HEAP_060 (`acquireOldGenRegion`); HEAP_059,
  HEAP_058 (CR-007).
- **Not run:** GenMC `w_pool_done` (`genmc` is not installed; audited by reading, as in Phases 1-2); the
  self-compile gate **G8** (a ~110 s self-compile at ~13 GB RSS on a 15 GB machine with ~9 GB disk free,
  plus a relink of the compiler against this runtime: impractical here, owed at the close-out).

### 14.4 Performance (§8, Phase 4 budget: ≤ 1 % GC time for CR-019; CR-007 same or lower): NOT MEASURED

No benchmark A/B (same constraints as 11.5-13.4). By construction CR-019 turns plain header accesses into
relaxed 64-bit `atomic_ref` loads/stores (plain `mov`s on x86-64) and the header walk now loads the
header once instead of three or four times. CR-007 adds, per page acquire inside a parallel promotion
with n > 1, one scan of the free list with a `pending_` hash lookup per fitting extent (the `pool 20000 3
2` arm skipped about 2,000 extents per scenario); in exchange no promotion holder waits on a helper job
outside the cap fallback (in-pause reuse waits 9 → 0 per scenario there) and the old-gen high-water stays
within ±3 % in that arm. Owed with Phases 1-3: the LB A/B at the close-out comparison.

## 15. As built: Phase 5 (2026-10-01)

Snapshot: `snapshots/register-fixes/pre-phase5.tgz`. Order: models first (M7 `LockOrder` for step 2, checked
before step 3; then M6 `HelperPool` / `Gangs`, M2, M5), then the code in §7.2's step order, the harness,
the guards, the revert checks, the traces, one canary audit (M1-M8 AUDIT.md and `test/genmc/AUDIT.md`), the
register and `invariants.csv`.

### 15.1 Results per fix

| Fix | Model (TLC, first) | Code | Guards | Revert check |
|---|---|---|---|---|
| Step 1 GCFork | — | `GCFork.{hpp,cpp}` (layers gangs / allocator / census / pool; one `pthread_atfork` under `std::call_once`); the three old registrations deleted in the same change; `GCFork.cpp` added to the top-level `ecor` list, the three `runtime/src/codegen` lists and every `test/gc-helper-tsan` target (`test/gc-heap-tsan` globs) | all fork arms | — |
| Step 2 no teardown under `thread_mutex_` | M7 `lock_order_fork` pass (1,188); mutants `teardown_under_tm` deadlock (1,176), `fork_tm_first` deadlock (600) | `cleanupThread` (move out, tear down outside, re-lock for the stats fold), `finishTenureForExit` (no lock), `reset` (swap out, destroy unlocked, re-lock), `~Allocator` (step 7) | M7 rows | (model mutants) |
| CR-003 / CR-015 | M6 `pool_host_fork_stranded`, `_locks`, `pool_host_child_hang` pass; mutants `pool_as_built_2026_09`, `pool_no_tm_cas_outside`, `pool_no_tm_drain_split`, `pool_no_tm`, `pool_no_tm_child_hang`, `pool_tm_last` | `post` CAS+enqueue in one `m_` section; pool prepare drains and keeps `m_`; allocator layer (`Allocator::forkPrepare/Parent/Child`, `fork_child_`, `fork_owner_`) | `det-cr003`, `det-cr015` clean (`window=closed`) | allocator layer off: `det-cr015` hang_tm 3/3; layer and pool fix off: `det-cr003` hang_drain 3/3 |
| CR-013 / CR-004 | M6 `gangs_two_gangs_window`, `gangs_host_fork_window` pass; mutants `no_fork_hold`, `hold_after_stop` (ChildHeldTenure), `no_fork_hold_window` (ChildHeldAny); M5 `MC_fork*` moved to `mutants/` | `fork_hold_` (set under each `m_` before `stopAllForFork`), `launch` returns bool (`fork_refusals`), `launchBackground` / `tenureLaunch` / `tenureConcLaunch` handle a refusal (`cm.episodes_refused`, `rs.fork_refusals`) | `det-cr004` reach → clean; `det-cr013-{start,copy,copy-scan,l3-exit,l3-minor}` clean | hold off: `det-cr004` window 3/3, start/copy/copy-scan/l3-minor reproduce 3/3 (l3-exit stays clean through CR-031; with both off it hangs 3/3) |
| CR-023 | M6 `gangs_host_fork_stall`, new `gangs_foreign_stop` (+ deep `gangs_deep_b2_foreign_stop`) pass; mutants `no_stop_gen` (ParentProgress), `stop_gen_clears_running` (LJ_RunningExact) | generation-based `stopAndJoin`; `launch` notifies `cv_done_` | CRT `CR-023` → `runFixedGuard`, also checks `running()` and `stop2` | generation-blind: still blocked after 200 ms; unconditional clear: `running() == false` |
| CR-005 | M2 `MC_quick_episode_stop` pass, mutant `member_exits_undone`; M6 `gangs_host_fork`, `_1cpu_closing`, deep `mark_first` pass, mutant `closing_asserts_finished` | `closingFinish` accepts `None` | `det-cr005` clean | old assert: aborts 3/3 |
| CR-031 | (contract; M6) | `dropForkDeadHeapsLocked` in `~Allocator` (teardown outside the lock) and `initThread`; `getCombinedStats`, `validatePageWork` skip dead heaps; validate `ThreadLocalHeap::owner_` + `assertOwner` in `minorGC`/`majorGC`; `adoptThreadHeap` sets `owner_` | `det-cr031` clean | drop off: foreign teardown 3/3 |
| CR-032 | (M6) | census layer (`Census::forked_child`, `atexitReport` returns) | `det-cr032` clean (`window=closed`) | layer off: the child hangs in `atexitReport` 3/3 |

### 15.2 Deviations (all faithful to intent)

1. **`det-cr015` pauses at a new trace-only probe `m6.tm.held`** (`Allocator::onGCPauseEnd`, under
   `thread_mutex_` only). Its old pause point, `post`'s CAS, is under the pool's `m_` since CR-003's fix,
   so the arm could no longer show CR-015 on its own (with the allocator layer reverted it stayed clean:
   the forker blocked on `m_`). With the new point the revert fails 3/3 as it must.
2. **CR-003's pool fix is masked in code by the allocator layer** (every post holds `thread_mutex_`, which
   the forker now takes first: M6 `pool_host_fork_tm_first`'s prediction). Its pieces are checked by the
   M6 mutants; the code revert check reverts both.
3. **M7 `LockOrder`:** `MUTANT` became a set; the parallel minor is modelled as a `GCMarkGang` run
   (`R_Run`/`R_Join`, `run_m_`), the forker as GCFork's prepare (pool drain = the job Done). With the
   teardown out of `thread_mutex_`, `collector_takes_tm` alone deadlocks nothing: its row now also sets
   `teardown_under_tm` (still deadlock).
4. **M6 `HelperPool`:** the `FIX` constant was removed (the fixed handlers are the default; `MUTANT` names
   the pre-fix pieces). The plan's mutant `pool_no_tm` (two properties) is two configs, `pool_no_tm`
   (ChildLocksFree) and `pool_no_tm_child_hang` (HostChildProgress). Rows identical to the flipped ones
   (`pool_host_fork_fix_both`, `_tm_first`, `pool_host_child_fix_all`, `pool_deep_tm_first_2workers`) were
   deleted; `pool_guard_after_tm` runs with `no_tm` (its design); the `no_start` mutant also gates the
   merged post step; the host-fork rows now check every invariant.
5. **M6 `Gangs`:** `FIX` removed too; besides `RelaunchWaitsStopper` a constant `ForeignStop` enables the
   `ForeignStop` action. `StopWaitsOwnEpisode` became "same generation, or the stopper's wake-up is
   ENABLED" (with the fix the waiting state is reachable but no longer blocked). `gangs_host_fork_stall`
   passes through the hold as well (no relaunch during a fork's stop), so `gangs_foreign_stop` carries the
   generation fix's check. `PrepareOrder` stays: the code always runs `bg_first`, and `mark_first` is kept
   as the pre-GCFork order the fix must also pass. Extra mutant `no_fork_hold_window` (CR-004 as built);
   extra deep row `gangs_deep_b2_foreign_stop`.
6. **M1 trace for refusals:** a refused launch is logged as M1 sees it, an episode a fork stopped at once:
   the t0 refusal logs `stop` after `launch`; a refused relaunch logs its `step` with `ep = running` and
   field `refused`, then `stop` (M6's `TraceGangs` reads `refused`: `bgEp = None`). New scenario
   `cycle,refuse-b2` (a test hook `GCBackgroundGang::setForkHoldForTesting` around chosen minors; 15
   refusals) accepted, plus the negative control `drop:stop:1`.
7. **HEAP_007's "never read" is enforced beyond `~Allocator`:** `initThread` drops dead heaps first (a child
   may start a fresh heap; otherwise CR-012's one-mutator abort would count the dead heap), and
   `getCombinedStats` (reached by `atexitPrintStats`) and `validatePageWork` skip them.
8. **The census layer also holds detector N's survivor-write census mutex** (`NurserySpace.cpp`, the same
   P1 family, `P1_CENSUS_COMPILED`): another runtime lock the child would otherwise inherit. Its hooks read
   the census through an atomic pointer, never through `census()`'s static guard.
9. **GCFork robustness:** `prep` records which layers it ran and the parent/child handlers run only those (a
   layer registered between a fork's prepare and its handlers is skipped). The mark gang's prepare locks
   its mutexes even when unconfigured (harmless; the plan's "returns at once" was for a configured check),
   and the pool prepare locks `m_` always and drains only when configured in Concurrent mode (as §7.2
   step 3 writes it). Registration: the census registers inside `census()`'s first construction; this is
   safe because the first `registerForkLayer` runs `pthread_atfork` before any GCFork handler exists, and
   every later call is an atomic store (HEAP_075 states this instead of "no runtime lock held").
10. **Harness:** `det-cr004`'s loop also stops at a refusal; `det-cr003/015/004` return 4 when a trial
    neither reproduced nor closed the window; `driverRegister` now checks the oracle before "window
    closed", so a closed window still needs a sound child (the `-minor` arms check the orphan path). The
    `gangs` trace header records `bg_first` for both registration orders. `pool_trace.cpp` registers a
    GCFork allocator layer for its `thread_mutex_` stand-in. `TracePool`'s negative control
    `drop:pool.enq:1` matched nothing once the enqueue joined the CAS's step; it became
    `set:pool.enq:1:out=7`; `TraceGangs` gained `drop:fork.bghold:1`.
11. **`launch`** notifies `cv_done_` after the unlock, next to `cv_start_` (the generation changed under `m_`).
12. Optional hardening (lazy `new std::vector<std::thread>()` in the child handlers) was not done.

### 15.3 Phase 5 gates (2026-10-01)

- `--filter "CR-0"`: 55/55 in `build` and in `build-validate` (XFAIL: none; WONTFIX: CR-012 (a)-(c)).
- Full unit suite (once, `build`, from `/work`): **2,003/2,003**.
- `build-validate --filter threaded-gc-0` at `ECO_TEST_MINOR_THREADS` = 1, 4, 8: 168/168 each.
- **`ECO_TEST_XFAIL=strict cmake --build build --target register-guards`: GREEN** — unit step 55/55 (WONTFIX
  CR-012 (a)-(c)); validate CR-028 1/1, CR-036 3/3; harness arms PASS 22, WONTFIX 1 (`cr012:e`).
- `run_fork_arms.py --tier quick` (plain, trace, tsan): PASS 22, WONTFIX 1. `--tier stress` (report only):
  all 5 rows exit 0: `host-exit` 1,709 forks / `host` 850 / `tenure-storm` 3,710 / `tenure-storm-l3` 4,436 children all
  clean (0 CR-013 TV aborts, 0 hangs), `relaunch` 5,156 forks with 0 CR-004 windows and 0 CR-023 stalls (the
  `launch_in_prepare` counts, 2 / 17 / 34, are launches before the hold was set, which the stops then end).
- TLA+: M1, M2, M5, M6, M7 quick 205/205; M6 deep 18/18; `run_traces.py` M6 29/29 and M1 20/20.
- TSan: `gc-helper-tsan` (pool) ALL PASSED, `gc-mark-tsan`, `gc-tenure-tsan` PASS, 0 warnings;
  `gc-heap-tsan` default run PASS, 0 warnings.
- Canary: one audited batch (M1-M8 AUDIT.md, `test/genmc/AUDIT.md` for `w_pool_done` / `w_running_chain`);
  new pins: file + census `GCFork.cpp`, census `ThreadLocalHeap.{cpp,hpp}` (the validate `owner_`); M6 added
  to the `P1Census.cpp` and `NurserySpace.cpp` census pins; green, 235 pins.
- Invariants: HEAP_075 ForkSafety new; HEAP_007 (the fork contract), HEAP_058 (CR-003/015), HEAP_065
  (refusal, generation stop, closing), HEAP_070 (orphan path of a refused tenure launch) amended.
- **Not run:** GenMC `w_pool_done` / `w_running_chain` (`genmc` is not installed; audited by reading, as in
  Phases 1-4); G8 (owed at the close-out).

### 15.4 Performance (§8, Phase 5 budget: none on GC paths; fork prepare latency): NOT MEASURED

No GC fast path changed: `post` already took `m_` (the CAS moved inside it), `launch` gained one
`notify_all` per episode launch, and the teardown paths changed only their lock scope. The fork prepare now
holds every layer (gangs, `thread_mutex_`, census, pool drain) for each `fork()`; `Process.cpp`'s
fork-then-exec pays it — `posix_spawn` (which runs no atfork handlers) is the suggested follow-up.

