# Plan: Per-site nursery zeroing (retire the bulk to-space memset)

## Goal

Replace the whole-to-space `memset` after every minor GC with zeroing attached to the
allocation sites that actually need it.

`clearToSpaceFreeRegion` (`NurserySpace.cpp`) memsets
`[copy_ptr_, toBase() + slice_.capacity)` after every minor GC — **the single largest
measured GC cost in the runtime: `libc memset (clearToSpaceFreeRegion)` is 5.6 % of total
process CPU** (`guides/cpp-prof-hints.md:293`). At the current defaults (nursery cap 256 MiB,
so 128 MiB per semi-space, ~1,924 minor GCs per self-compile) that is on the order of 240 GB
of memset traffic per run, and it works out to roughly one byte zeroed per byte allocated.

Two phases, deliberately separated so the correctness question and the performance question
are never confounded:

- **Phase 1 — correctness.** Add a per-site "zero the payload" mark, set it on **every**
  allocation, then turn the bulk clear off. Prove nothing breaks. No performance claim.
- **Phase 2 — optimisation.** Remove the mark from sites that provably fill before any GC
  can run. Prove nothing breaks, and benchmark.

---

## Why the bulk clear exists (verified, 2026-09-23)

**Allocation zeroes only the 8-byte header.** `initHeaderForTag`
(`ThreadLocalHeap.cpp:109`) is exactly:

```cpp
void initHeaderForTag(Header* hdr, Tag tag, size_t size) {
    std::memset(hdr, 0, sizeof(Header));   // 8 bytes, that is all
    hdr->tag = tag;
    switch (tag) { ... hdr->size = <full field count> ... }
```

It then sets `hdr->size` to the object's **full field count**. So from the instant the
object exists, the collector will trace all of its slots while the mutator may have written
none of them. A GC in that window reads two things as raw stale bytes:

1. the payload slots `values[i]`; and
2. the **per-object kind bitmap word at offset 8** — `Custom.ctor|unboxed`,
   `Record.unboxed`, `Closure.unboxed`, `ListBacking.hd` — which sits OUTSIDE the 8 bytes
   `initHeaderForTag` clears.

(2) is the dangerous one: garbage there does not merely produce a bad pointer, it can tell
the collector that an unboxed `Int` slot is boxed and must be traced.

Pre-zeroed, both degrade safely — slots read as the null HPointer and are discarded at
`evacuate`'s null check; the bitmap reads 0, meaning "all slots boxed", which combined with
null slots is harmless. `clearToSpaceFreeRegion`'s own comment records the failure mode when
it is absent: *"stale bytes in the free tail decode as out-of-range raw pointers at the next
cycle and abort in evacuate with 'Pointer above heap end!'"*.

### The window is "filling ACROSS allocation points", not "between alloc and first store"

For a single allocation there is no window. Under HEAP_034 the compiler emits a bump diamond
whose slow path `eco_alloc_inline_slow` is the ONLY statepoint, and it returns
**uninitialised** storage — so a GC runs strictly before the object exists.

The window opens when obtaining a later field value itself allocates or calls anything
(RS4GC puts a statepoint at calls):

```
allocate A            ; header claims N fields, slots unwritten
compute A.field[1]    ; <-- allocates B, which can trigger a minor GC
store A.field[1]
```

`HeapHelpers.hpp:663-674` states the discipline in exactly these terms: *"For boxed element
kinds the backing's slots are ZEROED at allocation, so a GC between backing allocation and
the fill scans null HPointers (skipped) rather than garbage. **Callers that fill across
allocation points** must root the backing (StackRootGuard or builder bit) exactly like any
fresh object."*

---

## Corrections to beliefs that look plausible and are WRONG

Recorded because each cost time in the 2026-09-22/23 GC loop
(`benchmarks/gc-opt-loop.md`).

1. **"The fill-later runtime allocators already zero the payload."** FALSE. `initHeaderForTag`
   zeroes 8 bytes and nothing else (verified above). When
   `inline-nursery-allocation.md:127` says classes 2/3/4/12 are *"alloc-now, fill-later —
   fields may be stored across later safepoints, so the zero-init done by the runtime is
   load-bearing"*, "the zero-init done by the runtime" means **the GC's bulk to-space
   clear**, not any zeroing inside the allocator. **These sites free-ride on the bulk clear
   and are the ones Phase 1 must cover.**
2. **"A high-water clear gets most of the win."** FALSE — it gets ~5 %. `nursery_gc_threshold`
   is 0.95 and `bump_.end` is pre-clamped to it, so the mutator fills a semi-space to 95 % of
   capacity before triggering a GC; the watermark therefore sits near the end and the skip is
   the top 5 %. Measured as item 6 in the loop: wall FLAT, max RSS **-6,452 kB**, which is
   almost exactly 5 % of a 128 MiB semi-space (6.55 MiB) — the untouched tail never faulting
   in, and the entire effect. Item 6 also failed its correctness gate twice, on two different
   watermark placements. See **THE HIGH-WATER VARIANT IS DEAD** below.
3. **"Turning the bulk clear off is already safe because inline classes store every field."**
   UNPROVEN, and it is precisely what Phase 1 tests. Even if true for classes 1/5-11, the
   fill-later classes and the kernel builders are not covered.

---

## THE HIGH-WATER VARIANT IS DEAD — do not revive it

Clearing only up to a per-extent high-water watermark (tier-1 plan item 6;
`nursery-ghost-data-and-stale-pointer-debug.md` decision Q1, *"optimize later with
high-water-mark clear in Release"*) is **abandoned**. It is not deferred, not a fallback and
not a stepping stone to anything in this plan. Decision Q1 is **superseded**.

Two independent reasons, either sufficient:

1. **The ceiling is ~5 % of the memset, so it cannot matter.** The mutator fills a semi-space
   to `nursery_gc_threshold` = 0.95 before a GC fires, so the watermark is always near the end
   of the extent. Against a cost of 5.6 % of process CPU the ceiling is ~0.3 % of CPU — below
   the measurement noise floor. Measured exactly that: wall flat, and an RSS move of
   6,452 kB that is simply 5 % of a 128 MiB semi-space never being faulted in.
2. **It failed its correctness gate twice**, on two different watermark placements, and the
   second failure was NOT an ordering slip. "Everything above the last write is still zero"
   requires a complete model of every writer into to-space, and the only enumerated writer is
   the mutator's bump pointer; the evacuation copiers (plain, JIT-root, list-spine) and the
   nursery-owned split-header bodies are unaccounted for.

Anyone tempted to retry it should read `benchmarks/gc-opt-loop.md` entry `W1.1` first, then
reconsider: even a fully correct implementation is worth ~0.3 % of CPU. **The bytes are not
in the tail, they are in the 95 % the mutator actually uses — which is what this plan
targets.**

---

## Phase 1 — conservative per-site zeroing (CORRECTNESS ONLY)

**Change**

1. Add a mark to the `eco.*` allocation ops meaning "zero this object's payload at
   allocation" — an MLIR attribute, or a distinct lowering variant, whichever is cheaper to
   thread. It must reach BOTH lowering paths:
   - the inline path, expanded by `expandInlineAllocs` (`EcoBackend.cpp`) off the
     `__eco_alloc_inline(size)` marker; and
   - the runtime-call path (`eco_alloc_ctor`, `eco_alloc_closure`, …).
2. **Set the mark on every allocation site.** No analysis in this phase.
3. Zero `[obj + sizeof(Header), obj + size)` — everything past the 8-byte header, which
   covers the offset-8 kind word as well as the slots. Confirm the exact offset per tag
   against `Heap.hpp`; `composeHeader` writes one 64-bit word at offset 0 and is not the
   kind bitmap for every tag.
4. **Disable `clearToSpaceFreeRegion`** behind a flag (`ECO_NURSERY_BULK_CLEAR`, default
   off once Phase 1 lands) so the two configurations can be A/B'd and so the old behaviour
   is one env var away for bisection.

### Phase 1a RESULT (2026-09-23) — passed its gate, and is a large WIN

Built as `bin/eco-p1zero` (the `keep-W7` compiler MLIR lowered against the changed runtime,
so the compiler source is untouched and the binary must reproduce `bin/ecoghash.mlir`).

| stat | W7 reference | Phase 1a | delta |
|---|---|---|---|
| wall | 194.64 s | **184.79 s** | **-9.85 s** |
| Total GC/Alloc | 82.42 s | **68.73 s** | **-13.69 s** |
| Minor GC (incl. promotion alloc) | 77.29 s | 60.00 s | -17.29 s |
| True mutator | 112.10 s | 115.59 s | +3.49 s |
| minor / major cycles | 1924 / 6 | 1924 / 6 | identical |
| promoted | 19861 MiB | 19861 MiB | identical |
| max RSS | 10,805,292 kB | 10,785,628 kB | -19.7 MB |

E2E `--target check` 1731/1731; `out.mlir` byte-identical to `bin/ecoghash.mlir`.

The arithmetic is consistent: the bulk clear wrote roughly 1924 x 128 MiB ~ 246 GB, which at
this machine's memset bandwidth is the ~17 s that left minor GC; the per-site memsets put
~3.5 s back on the mutator side. **The saving is not "a smaller byte count" — Phase 1 zeroes
MORE eagerly than before. It is that the bulk clear zeroed the WHOLE semi-space every cycle
while the mutator only ever allocates into part of it, and zeroed bytes that the object's
own fields immediately overwrite anyway.**

### Phase 1a was INCOMPLETE — four allocation paths, not two

`emitInlineAllocWithHeader` + `initHeaderForTag` cover only two of the four ways an object
is born. Audited 2026-09-23, the alloc-now-fill-later classes on the other two paths are:

| path | function | what was left unzeroed |
|---|---|---|
| runtime fast call | `eco_alloc_custom_fast` | `field_count` slots, `hdr->size` already set |
| runtime fast call | `eco_alloc_record_fast` | `field_count` slots |
| runtime fast call | `eco_alloc_string_fast` | the UTF-16 payload |
| runtime fast call | `eco_alloc_closure_fast` | capture slots up to `max_values` |
| region / group | `eco_init_record_at` | `field_count` slots |
| region / group | `eco_init_custom_at` | fields + scalar bytes |
| region / group | `eco_init_string_at` | the UTF-16 payload |
| closure group | `eco_alloc_closure_group_slow` per-sibling init | capture slots |
| PAP extend | the `allocateFast` arm | capture slots |

All of them did `memset(hdr, 0, sizeof(Header))` -- 8 bytes -- and free-rode on the bulk
clear for the rest, exactly as `initHeaderForTag` did. The scalar classes
(`int`/`float`/`char`/`cons`/`tuple2`/`tuple3`, fast and `_at`) write every payload byte and
need no change. The generic exports (`eco_alloc_record`, `eco_alloc_custom`, ...) all route
through `eco_alloc_with_roots` -> `initHeaderForTag` and were already covered. Kernel C++
never allocates directly -- it calls these exports.

Phase 1b = Phase 1a plus those nine sites. **Phase 1a's numbers above are therefore an
upper bound on the win**; 1b adds memsets back.

**Pass condition: nothing breaks.** Explicitly NOT a performance claim — the byte count is
unchanged by construction, and per-object zeroing may well be slower than one large memset
because every field that is about to be written is now written twice. That is Phase 2's
problem.

---

## Phase 2 — remove the mark where the fill is provably immediate

### SUPERSEDED THE SAME DAY — the closure scan was fixed, so the answer is NOTHING

Bounding the closure trace loops on `n_values` instead of `hdr->size` removes the payload
zeroing requirement **entirely**, on both paths. Re-running the census after the fix:

| arm | before the scan fix | after |
|---|---|---|
| `ECO_INLINE_NO_ZERO=1` | 2,704 hits, 76/100 failing | **0 hits, 95/100 (= baseline)** |
| `ECO_DISABLE_PERSITE_ZERO=1` | 420 hits | **0 hits** |
| both suppressed | — | **0 hits, 1,032 cycles** |

Six trace loops changed: `NurserySpace::scanObject`, its two validate pre-walks,
`OldGenSpace` mark and fix/forward, and `PermanentSpace::visit`. `hdr->size` stays the
capacity everywhere it means a SIZE (`getObjectSize`, `initHeaderForTag`).

**The scan bound is half a contract.** It asserts: *at every safepoint, slots
`[0, n_values)` are written and live; `[n_values, max_values)` is dead space.* Two failure
directions, and under the tightened bound BOTH are fatal:

| `n_values` | collector | result |
|---|---|---|
| too low | skips a written live capture | untraced -> reclaimed -> use-after-free |
| too high | traces an unwritten slot | follows garbage |

The old `hdr->size` bound is the maximum, so it can never be too low — it bought that by
being permanently too high, and **the payload zeroing was what made the over-scan
harmless.** The zeroing was never memory hygiene; it was compensation for a scan bound
that did not match what the writers guarantee.

**Writers, and what they actually guarantee**

| writer | behaviour | verdict |
|---|---|---|
| `closureCapture` | `values[idx] = v` then `n_values++` | correct; ascending order is structural |
| generated code (`papCreate`) | stores the packed word (`n_values = numCaptured`) at +8, THEN the captures at +24 | transiently too high, no safepoint in the window (HEAP_034) |
| `eco_pap_extend` | `n_values = new_n_values` then the copy loop | transiently too high, no safepoint |
| `eco_store_field/_i64/_f64` | writes the slot, never touches `n_values` | **permanently too low — this is the one that breaks** |

**Generated code never under-counts.** It publishes the final count up front and fills
after, and the compiler emits `eco_store_field*` only for `CustomConstructOp`, never for a
closure. No kernel calls it on a closure either. The `Tag_Closure` arm of `eco_store_field*`
has ZERO production callers — it existed only for tests, and it now asserts.

**Two corrections to earlier attempts at this, both wrong:**

1. *Do not "harden" `eco_store_field` by raising `n_values` to `index + 1`.* Tried and
   REJECTED. `RuntimeExportsTest` stores at a RANDOM index: a store at 3 with slots 0-2
   unwritten then sets `n_values = 4` and the scan traces three uninitialised slots. It
   passes today only because the payload is still zeroed — i.e. it is a trap that detonates
   exactly when the zeroing is removed. `closureCapture` is the correct API precisely
   because it appends.
2. *Do not reorder `eco_pap_extend` to publish `n_values` after the copy loop.* Tried and
   REVERTED. There is no safepoint in the window, so the original order is already
   guaranteed; the reorder merely swaps an over-count for an under-count, and neither is
   safe against a future safepoint. Only the absence of one is.

**The two tests were corrected, not the invariant.** `GCPressureTest.cpp:452`
("Pressure: eco_alloc_closure captures stay valid across minor and major GCs") and
`RuntimeExportsTest`'s `test_eco_store_field_closure` now fill captures via
`closureCapture`.

**Gates after the change:** release E2E `--target check` **1731/1731**; validator
**1731/1731**; release stress **100/100** at 1,263 minor GCs; validator stress 95/100
(the same 5 pre-existing JSON-kernel failures).

**The validator suite is SEED-FLAKY — pin the seed.** Its heap-graph generator can emit a
0-field `Tag_Custom`, which HEAP_044 forbids, and the run aborts in the from-space
pre-walk. Verified pre-existing: the same seed aborts identically on the pre-change tree.
Use `--seed 1790156644220971348` for a gate, or a run may fail for reasons unrelated to
the change under test.

**NOT YET MEASURED:** deleting the zeroing. Phase 1's per-site memsets are still compiled
in and still cost ~3.5 s of mutator time on the self-compile; removing them means flipping
`kZeroPayloadDefault` to `false` and reverting the runtime memsets to header-only as
SHIPPED defaults, then re-lowering and running a timed triple.

---

### (superseded) MEASURED 2026-09-23 — the answer is CLOSURES, and only closures

Phase 2 no longer needs to trust the HEAP_034 contract; it was tested directly. Two knobs
suppress per-site zeroing on one path each, with the free region poisoned so any slot the
site fails to write is caught in `evacuate()`, and `ECO_POISON_NONFATAL=1` nulls the slot
and carries on so ONE run yields the whole census instead of stopping at the first hit:

| arm | knob | cycles | poison hits | classes |
|---|---|---|---|---|
| inline codegen path | `ECO_INLINE_NO_ZERO=1` | 903 | **2,704** | **`Tag_Closure` — 100 %** |
| runtime path | `ECO_DISABLE_PERSITE_ZERO=1` | 933 | **420** | **`Tag_Closure` — 100 %** |
| both off (shipped) | — | 1,032 | **0** | — |

**Not one hit from Cons, Tuple2/3, Record, Custom, String or any other tag, on either
path.** The blanket claim "the inline classes store every payload field via straight-line
code, so Phase 2 can pass `false`" is REFUTED for closures and CONFIRMED for everything
else.

**Why closures are the exception** (`NurserySpace.cpp:1535`):

```cpp
case Tag_Closure: {
    Closure *cl = static_cast<Closure *>(obj);
    for (u32 i = 0; i < hdr->size; i++) {        // hdr->size == max_values
```

The scan walks the closure's full **capacity**, not `n_values`. A closure is allocated with
room for `max_values` captures, only `n_values` are stored at creation, and the rest are
filled later by `papExtend` — across safepoints. So the collector traces slots the mutator
has not written yet, and their contents must be zero.

**What Phase 2 should therefore do**

1. Drop the mark for every inline class EXCEPT `Tag_Closure`. That is 12 of the 13 inline
   sites, evidenced rather than assumed.
2. For closures, do not zero the whole payload — zero only the unfilled tail
   `[n_values, max_values)`. At creation `n_values` is usually the whole point of the
   allocation, so the tail is often empty and the memset disappears.
3. The deeper fix, if it is wanted later, is to make the scan respect `n_values` instead of
   `hdr->size`, which removes the requirement rather than narrowing it. That touches the
   PAP-extend protocol and is a bigger change than Phase 2.

**Bound on this evidence.** Absence of a hit is evidence, not proof: it covers the shapes
the stress suite allocates over ~900 cycles. The stronger sample is the self-compile
(1,924 cycles, far more shapes), which needs a compiler lowered by a validator-built
`eco-boot-native`. Run that before deleting a mark permanently.



**The analysis is narrower than "prove every object is initialised before the next
safepoint".** `inline-nursery-allocation.md:118-131` already partitions every allocation
site in the backend:

| class | sites | fill shape |
|---|---|---|
| 1, 5-11 | box / cons / tuple2 / tuple3 / record / custom / `eco.make.closure` / `eco.papCreate` | *"statically-sized, lowering emits ALL stores contiguously"* |
| 2, 3, 4, 12 | `allocate_ctor`, string, `eco.allocate_closure` | *"alloc-now, fill-later — fields may be stored across later safepoints"* |
| 13, 14, 15 | interned closure0, `papCreateGroup`, string literals | interning / own machinery |

So Phase 2 reduces to **verifying the contiguity claim for classes 1 and 5-11 against the
emitted IR** — confirming no statepoint can land between the `__eco_alloc_inline` marker and
the last `emitFreshFieldStore` (`EcoToLLVMInternal.h:714-743`) — and then clearing the mark
for the classes that hold. **That claim is an assertion in another plan and has NOT been
verified here.** In SSA the field values are operands materialised before the allocation, so
it is very likely true; verify it, do not assume it.

**Sites that can NEVER have the mark cleared:**

- **Builder-bit objects (HEAP_BUILDER_001)** — deliberately traced while half-built. No
  safepoint analysis can close these; they need the zeroing (or the `listBacking`
  treatment).
- **`closureCapture`** (`HeapHelpers.hpp:1968-2013`) — capture kinds are *"written
  incrementally across GC points"*, so boxedness is not final until all captures land.
- **`ElmArray` / JsArray** — `allocArray` writes `unboxed = 0` as a placeholder; the kind is
  bound lazily on first push and patched at 16 `JsArrayExports.cpp` sites.
- **`listBacking`** — already memsets its own element area; leave it, or let the mark
  subsume it, but do not remove both.

**Already safe by construction, needs no mark either way:** `Tag_Array`'s payload —
`getObjectSize` strides by **capacity** while `scanObject` iterates **`arr->length`**, and
`allocArray` sets `length = 0`, so the uninitialised tail is stepped over and never read.
That is the pattern the exposed tags lack, and it is worth considering whether any other tag
can be given it instead of zeroing.

**Pass condition: nothing breaks AND it is faster.** Benchmark per
`benchmarks/gc-opt-loop.md` §2 — three cold Stage-7a self-compiles, census-off, judged on GC
time first and wall second, with GC counters and `out.mlir` required identical.

---

## Gates (both phases)

The E2E suite alone is NOT sufficient — it passed on a change that the heap-validate build
then rejected (loop entry `W1.1`).

1. **E2E** `cmake --build build --target check` — 1731/1731.
2. **Self-compile fixed point** — `out.mlir` byte-identical, GC counters (minors, majors,
   promoted MiB) bit-identical.
3. **Heap-validate build** `-DECO_HEAP_VALIDATE=ON`. **REPAIRED 2026-09-23 — now GREEN,
   1731/1731, measured WITH the bulk clear off.** Two defects, both in validate-only code,
   so the shipped runtime is untouched:

   - **The assertion was armed over the wrong loop.** `minorGC` sets `in_phase3_` once
     around an alternation of TWO inner drains — the to-space Cheney drain and the
     promoted-objects queue — but the invariant it asserts ("every child of a promoted
     object is at least as old as its parent") only holds for the second. A young child of
     a to-space parent is the ordinary case, and the same function's own comment says so.
     The report even printed the to-space parent as `parent(old-gen)`. W5 item 33 deleted
     the preliminary drain that used to empty to-space BEFORE the flag was raised, which
     turned a latent mislabel into a reliable abort. Fix: toggle `in_phase3_` per inner
     loop. The test was never at fault -- `buildUnboxedList` conses correctly, each cell's
     tail being the older cell.
   - **The diagnostic killed the process before it could report.** It dumped
     `parent[-1]`, one word BEFORE the object; the parent sat at the first address of an
     old-gen block, so the read faulted and the backtrace it exists to print never
     appeared. That SIGSEGV is what earlier runs recorded. Fix: start the dump at 0.

   Build it in its own directory so the bootstrap tree is left alone, and build BOTH
   targets -- `test` alone leaves `ecoc` missing and 12 `elm/*.elm` cases fail with
   `exit 127`, which looks exactly like a codegen regression and is not one:

   ```
   cmake -S /work -B /work/build-validate -G Ninja \
     -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
     -DCMAKE_EXE_LINKER_FLAGS_INIT=-fuse-ld=lld -DCMAKE_BUILD_TYPE=RelWithDebInfo \
     -DCMAKE_C_FLAGS_RELWITHDEBINFO="-O2 -g -UNDEBUG" \
     -DCMAKE_CXX_FLAGS_RELWITHDEBINFO="-O2 -g -UNDEBUG" -DECO_HEAP_VALIDATE=ON
   cmake --build /work/build-validate --target test --target ecoc -j 10
   ./build-validate/test/test
   ```

   (Superseded description: this gate was previously believed RED for reasons that predate
   this work — the `NurserySpace` property-based test
   generates an old-gen parent holding a younger nursery child and segfaults
   (`INVARIANT VIOLATION: phase 3 child not old enough to promote`). It reproduces at both
   `promotion_age=1` and `promotion_age=2`, so it is independent of the shipped defaults.
   That reading was WRONG about the cause -- the generator is fine. It is the only gate
   that inspects heap shape.)
4. **Poison instrumentation WITH A POSITIVE CONTROL. DONE 2026-09-23 — tripwire
   demonstrated, then silent over 1,032 minor GCs.**

   - **Poison byte is `0xD8`, and the choice is load-bearing.** Bit 2 of an HPointer is
     `ptr_ind`: 0 = follow this as a heap pointer, 1 = embedded constant, skip. `0xDD` —
     the byte this plan originally specified — has bit 2 SET, so every poisoned word
     decodes as a constant and is never followed. A `0xDD` run reports zero hits no matter
     how broken the zeroing is. That is almost certainly why the 2026-09-22 `W1.3` run came
     back clean. **`0xD8` has bit 2 clear**, so poison is followed into `evacuate()` and
     caught there by an explicit `ECO_POISON_WORD` comparison. (Written, then verified the
     hard way: the first build of this gate used `0xDD` anyway, and its positive control
     tripped a *different* assertion instead of the poison check.)
   - `ECO_NURSERY_POISON=1` makes `clearToSpaceFreeRegion` fill `0xD8` instead of zero,
     overriding the Phase-1 early return. A gate configuration only — it pays a full bulk
     memset per cycle.
   - `ECO_DISABLE_PERSITE_ZERO=1` (validator builds only) reverts `initHeaderForTag` to the
     pre-Phase-1 8-byte memset. **This is the positive control, and it fires:**
     `POISON READ AS A BOXED SLOT ... slot raw=0xd8d8d8d8d8d8d8d8, parent obj=... tag=11
     size=2`.
   - **Result with zeroing on: zero poison reads** across the stress suite at
     `benchmarks/heap-config-gc-pressure.json` (1,032 minor GCs).

   - **Inline-path control DONE too** (`ECO_INLINE_NO_ZERO=1`, added to
     `emitInlineAllocWithHeader`). It fires hard: **72 poison hits, 76 of 100 stress cases
     failing**. Both paths are therefore demonstrated to be under the tripwire, and gate 4
     is complete. It needed NO compiler lowering — `stress-test` links `EcoRunner`
     whole-archive and JIT-compiles each Elm program in-process, so a codegen knob reaches
     the emitted code directly. That is much cheaper and more precise than lowering a whole
     compiler, because it isolates the inline path instead of mixing both.

   **Coverage limit that remains.** 5 stress cases abort before finishing under the
   validator (below), so the gate covers 95 of 100.

   (Original wording:) Fill the free region with `0xDD`
   instead of zero and trip on any slot or kind word read as poison. **A zero-hit result is
   worthless without first demonstrating the tripwire fires**: deliberately allocate an
   object, leave a slot unwritten, force a minor GC, confirm the trip. The 2026-09-22 run
   (`W1.3`) reported zero hits and was inconclusive for exactly this reason.


---

## The stress suite is the workload for any zeroing gate — but only under pressure

`cmake --build build --target stress` (100 long-running Elm programs,
`test/stress-elm/src/`) is the right breadth for this work: it allocates far more per case
than the 632 small `elm/*.elm` E2E cases. **At the shipped heap config it is nonetheless
USELESS for a zeroing gate: 1.94 M allocations, ~62 MB, against a 256 MB semi-space —
ZERO minor GCs.** No collection means the free region is never re-used, so nothing can
observe a missed zeroing and the suite passes vacuously.

`benchmarks/heap-config-gc-pressure.json` fixes that: `alloc_buffer_size` 64K,
`nursery_block_count` = `nursery_max_block_count` = 4 (256 KB nursery, growth pinned off).
The same suite then runs **1,263 minor GCs**. Results on the kept Phase-1 tree:

| build | config | poison | bulk clear | result |
|---|---|---|---|---|
| `build` | shipped defaults | - | off | 100/100, **0 minor GCs** (vacuous) |
| `build` | gc-pressure, 4 blocks | - | off | **100/100, 1,263 minor GCs** |
| `build-validate` | gc-pressure, 4 blocks | off | off | 95/100, 1,032 cycles |
| `build-validate` | gc-pressure, 4 blocks | **on** | off | 95/100, **zero poison reads** |
| `build-validate` | gc-pressure, 4 blocks | off | **on** | 95/100 — **identical** |

The last row is the bisection: the 5 validator aborts reproduce with the bulk clear fully
restored, so **they are not caused by per-site zeroing**.

**Do not set `nursery_block_count` to 2.** One block per semi-space is degenerate and
fails two cases in the RELEASE build too (`BytesRoundtripNestedBytes` aborts in
`OldGenSpace::allocateFromBagPage`; `JsonRoundtripNestedTree` returns a WRONG ANSWER).
Both pass at 4 blocks and above, and both reproduce with the bulk clear on, so they are
separate pre-existing edge-case bugs, not zeroing bugs. They are worth chasing on their
own.

### Pre-existing finding: the JSON kernel does not survive minor GC (NOT this work)

Under the validator at GC pressure, the aborts cluster hard:

```
stress-elm/JsonRoundtripInt.elm          stress-elm/JsonRoundtripNullable.elm
stress-elm/JsonRoundtripNestedTree.elm   stress-elm/JsonRoundtripObject.elm
stress-elm/JsonRoundtripOneOf.elm        stress-elm/SpawnThenAndThenChain.elm
```

all on `debugAssertValidNurseryPointer`: *"HPointer into nursery free region (stale
pointer into unallocated space)"*, with slots holding stale addresses
(`0xffffffff98e3c8a3`), **not poison**. Six of the seven are the JSON decoder kernel. The
signature is a kernel holding an unrooted HPointer across an allocation that collects.
It persists at 16 blocks (4 fail, 224 cycles) and is identical with the bulk clear on.

This was invisible until now because **the stress suite had never been run at a heap size
that collects.** It is a real bug, it is not Phase 1's, and it deserves its own plan.

---

## Relationship to existing plans

- `plans/gc-tier1-constant-factors.md` W1 items 6-9. This plan **supersedes** the W1.2
  design (chunked zeroing ahead of the bump pointer via a `zeroed_end_` watermark clamping
  `bump_.end`). W1.2 keeps the byte count identical and buys locality only; this plan
  attacks the byte count. W1.2 remains the fallback if Phase 2's analysis shows too few
  sites can drop the mark — the two mechanisms should **not** be combined, since chunked
  zeroing is not attached to a site and cannot be skipped per-site.
- `plans/nursery-ghost-data-and-stale-pointer-debug.md` — origin of the bulk clear. Its
  decision Q1 pre-authorised the high-water variant; **Q1 is SUPERSEDED and that variant is
  dead** (see "THE HIGH-WATER VARIANT IS DEAD").
- `plans/inline-nursery-allocation.md:118-131` — the class partition Phase 2 keys on.
- `plans/allocation-group-single-safepoint.md`, HEAP_031 `FreshStoreNoForward` — existing
  compiler reasoning about freshly-allocated objects; check before writing new analysis.

## Files expected to change

`runtime/src/codegen/EcoBackend.cpp` (`expandInlineAllocs`),
`runtime/src/codegen/Passes/EcoToLLVMHeap.cpp`, `EcoToLLVMValueAgg.cpp`,
`EcoToLLVMClosures.cpp`, `EcoToLLVMInternal.h` (`emitFreshFieldStore`),
`runtime/src/allocator/NurserySpace.{hpp,cpp}` (`clearToSpaceFreeRegion` + flag),
`runtime/src/allocator/ThreadLocalHeap.cpp` (`initHeaderForTag`),
`runtime/src/allocator/AllocatorCommon.hpp` (flag), `design_docs/invariants.csv`
(HEAP_044 amendment if the zeroing contract moves).
