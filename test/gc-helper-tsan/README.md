# GC helper TSan harness (threaded-gc-03, gate G7)

Standalone ThreadSanitizer harness for `runtime/src/allocator/GCHelperPool.cpp`
and `PageWork.cpp`. Those two files include nothing from the allocator, which is
what makes this build possible and what keeps helper threads away from heap
objects.

```bash
cmake -S test/gc-helper-tsan -B build-tsan -DCMAKE_CXX_COMPILER=g++ -G Ninja
cmake --build build-tsan
timeout 900 build-tsan/gc-helper-tsan 2>&1 | tee /tmp/tsan_output.txt
grep -c "WARNING: ThreadSanitizer" /tmp/tsan_output.txt   # must print 0
```

Requires g++ with libtsan (the repo's clang 14 lacks `libclang_rt.tsan`).

Scenarios, each with 1, 2 and 4 workers and jitter 0 / 300 us:

- **H1** pool protocol: 3 poster threads, mixed `wait` / `drain`.
- **H2** `PageWork` over fake ops: a random release / reuse / fresh-bump /
  sync-point script over 1,024 extents. The fake discard asserts the extent is
  free for the whole call; the fake populate asserts no extent in its range is
  free (released) while it runs.
- **H3** the same script over real memory with the real ops (`MADV_DONTNEED`,
  `MADV_POPULATE_WRITE`, `mmap MAP_FIXED`). Every acquired extent gets a
  pattern written into every 4 KiB page and verified before release: a zeroed
  word means a discard hit memory the mutator owned.

Pass: exit 0, no ThreadSanitizer warning.
