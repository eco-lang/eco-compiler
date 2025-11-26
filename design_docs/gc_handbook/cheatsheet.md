# GC Cheatsheet (ultra-brief)

- Collector types: mark-sweep (space efficient, fragments), mark-compact/sliding (low fragmentation, longer pauses), copying (fast alloc, 2× space), refcount (prompt, cycles need help), generational (fast minor, write barrier needed), concurrent/parallel (needs barriers/invariants).
- Key invariants: tri-colour safety; new allocations Black during concurrent mark; forwarding pointers self-heal reads.
- Write barriers: card table or remembered sets for old→young/inter-thread; snapshot-at-beginning vs incremental update vs deletion (Dijkstra/Baker/Steele).
- Promotion: avoid age=1 en masse; survivor spaces or age counters reduce promotion churn and nepotism.
- Locality: copying/compaction improves cache; size classes and segregated fits reduce fragmentation.
- Tuning levers: nursery size vs pause frequency; promotion age; block size; compaction trigger (occupancy thresholds); TLAB size; remember-set/card size.
- Concurrency: concurrent marking needs barrier; pause budget via incremental marking/quanta; compaction often stays STW or incremental by region.
- Large objects: separate space; pinning hurts compaction; consider chunked or treadmill for big/pinned.
