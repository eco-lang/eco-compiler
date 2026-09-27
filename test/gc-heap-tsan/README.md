# Heap-level TSan harness (threaded-gc-05c D9)

The real allocator (`runtime/src/allocator/*.cpp`, validate + stats on) under
g++ `-fsanitize=thread`, driven by `heap_driver.cpp`: an old graph plus a
churning set of rooted young, large-string and replaced values; a cycle is
forced every ~40 minors with `conc_mark = 2` (B = 2/4/3, T = 4/16/8, assist
lag 1) so background markers overlap minor GCs, promotions (allocate-black)
and assists. Every rooted value is checked periodically.

```bash
cmake -S test/gc-heap-tsan -B build-heap-tsan -DCMAKE_CXX_COMPILER=g++ -G Ninja
cmake --build build-heap-tsan
timeout 3600 build-heap-tsan/gc-heap-tsan 2>&1 | tee /tmp/heap_tsan.txt
grep -c "WARNING: ThreadSanitizer" /tmp/heap_tsan.txt     # must print 0
ECO_GC_HELPER_JITTER_US=50 build-heap-tsan/gc-heap-tsan  # jitter arm
```

Notes: `StackUnwind` is stubbed (no frames: every value is a RootSet root), and
`reserveAddressSpaceBelow` probes TSan's low application range [64 GB, 512 GB)
first under `__SANITIZE_THREAD__` (TSan's shadow occupies 1 TB and up).
