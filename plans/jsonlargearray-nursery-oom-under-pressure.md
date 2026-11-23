---
status: done
updated: 2026-11-23
---

# JsonLargeArray aborts with a nursery out-of-memory under the GC-pressure config

## The failure

`test/stress-elm/src/JsonLargeArray.elm`, run by the stress suite under
`benchmarks/heap-config-gc-pressure.json`, aborts with:

    eco: out of memory: cannot allocate 8184 bytes for an object in the nursery
    (old generation 18792448 of 21474836480 bytes in use)

It fails the same way in the normal tree (`build/test/stress-test --filter JsonLargeArray`) and in
the heap-validate tree, and with the sources from before
`plans/lss-capture-qualified-members.md` (snapshot `snapshots/lss-loop/cq-base`), so that plan did
not cause it. It passes at the default heap config. Found 2026-11-23 during that plan's
heap-validate gate (its §9.7).

## What is known

- The pressure config caps the nursery at 4 blocks (`nursery_block_count` = `nursery_max_block_count`
  = 4, `alloc_buffer_size` 64K) and sets `large_object_threshold` to 8K, so an 8,184-byte object is
  a nursery object, just under the threshold.
- The old generation holds 18 MB of a 20 GB cap when the allocation fails, so the failure is the
  nursery being unable to place the object, not the heap being full.

## Diagnosis (2026-11-23)

Backtrace (gdb on the stress child): `Elm_Kernel_Json_runOnString` → `jsonToHeap` →
`makeJsonArrayFrom` (the 100,000-element size, chunk 11 of 98) → `alloc::arrayFromPointers` →
`eco_alloc_with_roots` → `ThreadLocalHeap::allocateSlow` (`ThreadLocalHeap.cpp:317`) →
`heapExhausted`. The 8,184 bytes are one JSON array chunk (1,021 pointers, sized by
`jsonArrayChunkSize()` to stay below the threshold), so the largest object the nursery takes.

The cause is the nursery's geometry, not a full heap. At the abort (region nursery, minor 640):
per-heap capacity 131,072, threshold 124,518 (0.95), survivors of the minor just run `S_m` =
124,320, eden empty. In region mode eden may hold only capacity − `S_m` (`failSoftUnclamp`):
6,752 bytes, less than the chunk. Eden fills to the threshold before a minor, and with
`promotion_age` 1 every live object survives one minor in the nursery, so after a minor over an
all-live eden the room is about capacity × (1 − threshold), 6.5 KiB here. At the default config the
nursery is megabytes and that room far exceeds 8 KiB. The legacy nursery fails the same way.

Reproduced by `test/allocator/NurseryLogJamTest.cpp` (GCPressure isolated suite): an empty
nursery, rooted Ints up to the threshold, then one 8,184-byte array through `arrayFromPointers`.
Before the fix both arms (region, legacy) aborted with the stress run's message, while controls
that stopped the fill where the survivors left eden 9,216 bytes passed.

Fix candidates: another minor when the room after the first is too small (ordinary promotion:
in region mode it hands the survivors to the tenure job and leaves `S_m` = 0; legacy needs up to
`promotion_age` minors); and/or a geometry rule, capacity × (1 − threshold) ≥ the largest
nursery object (plus survivor-copy slack), enforced by `validate` or by clamping the effective
threshold. Not the YLOS (it would put small objects there).

## To do

1. Reproduce with one command and find which allocation (likely the JSON array builder's backing
   store) asks for 8,184 bytes.
2. Decide what should happen when a nursery-sized object cannot fit after a minor collection with
   the nursery at its cap: promote it, place it in the large-object space, or grow the nursery.
3. Fix, pin with a test that runs under the pressure config, and re-run the stress suite under it.

## Fix (2026-11-23): HEAP_087, the nursery reserve

The minor trigger holds back room for the largest nursery object instead of a fixed 5 %:
`threshold = min(capacity x nursery_gc_threshold, capacity - HeapConfig::nurseryReserveBytes())`
(`NurserySpace::refreshCapacityCaches`), where the reserve is the largest 8-aligned size below
`large_object_threshold`, or 4 KiB if larger. `HeapConfig::validate` requires an initial per-side
nursery of at least three reserves (after a short minor eden may fill past the trigger, and the
next survivors can reach twice the reserve). Large nurseries keep the 0.95 trigger; the pressure
config's 128 KiB per-heap nursery now triggers at 122,888 bytes (93.75 %). No YLOS placement, no
config change.

Test changes: the log-jam tests are plain tests plus a test of the validate rule;
`OldGenCapacityTest`'s config (64 KiB threshold) grew from 4 to 8 nursery blocks to meet the rule;
Utf8String S11c allocates a varying amount of garbage per iteration, as the lower trigger put
every minor of its period-5 loop on the source's allocation (its non-vacuity check failed).

Gates: unit suite 3,158/3,158; stress under `heap-config-gc-pressure.json`
(`ECO_TEST_TIMEOUT_SECONDS=5400`) 114/114 with `JsonLargeArray` passing; `bootstrap` passes (4b and
8c fixed points); TLA canary clean. Not run: `full` E2E, the heap-validate tree.
