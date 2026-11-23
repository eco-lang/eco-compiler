---
status: not-started
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

## To do

1. Reproduce with one command and find which allocation (likely the JSON array builder's backing
   store) asks for 8,184 bytes.
2. Decide what should happen when a nursery-sized object cannot fit after a minor collection with
   the nursery at its cap: promote it, place it in the large-object space, or grow the nursery.
3. Fix, pin with a test that runs under the pressure config, and re-run the stress suite under it.
