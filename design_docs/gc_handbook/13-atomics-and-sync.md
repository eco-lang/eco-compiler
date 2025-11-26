# 13. Atomics & Synchronization Primitives (Deep Summary)

This chapter provides the synchronization tools used by concurrent/parallel GC: spin locks, test-and-set, compare-and-swap (CAS), LL/SC, consensus, and common pitfalls. These primitives underpin barriers, concurrent marking, and lock-free queues/buffers used in GC work distribution.

---

## 13.1 Basic Primitives

- **Test-and-Set (TAS)**: returns old value, sets to locked. Used for simple spin locks. Prone to cache thrashing under contention.
- **Test-and-Test-and-Set (TTAS)**: spin-read before TAS to reduce bus traffic.
- **Compare-and-Swap (CAS)**: atomically compare memory to expected and swap if equal. Fundamental for lock-free structures and installing forwarding pointers.
- **Fetch-and-Add**: atomic increment; useful for counters and bump pointers with contention.
- **LL/SC (Load-linked/Store-conditional)**: pair enabling atomic updates without ABA but requires hardware support.

---

## 13.2 Spin Locks

- **Simple spin lock**: TAS loop; add backoff to reduce contention.
- **TTAS spin**: read then TAS; less bus traffic.
- Fairness is not guaranteed; may need queue locks (MCS) for high contention.

**Pseudocode (TTAS)**
```pseudo
lock(L):
  while true:
    while L.flag == 1: pause()
    if TAS(L.flag) == 0: return

unlock(L):
  L.flag = 0
```

---

## 13.3 CAS Patterns and Pitfalls

- ABA problem: a location changes A→B→A; CAS succeeds unexpectedly. Mitigate with version tags or hazard pointers/epochs.
- Forwarding pointer install uses CAS to avoid double-copy races in parallel compaction.
- Consensus numbers: CAS can solve consensus for any number of threads (powerful).

**CAS install forwarding pointer**
```pseudo
old = hdr_bits(obj)
new = encode_forward(new_loc)
if !CAS(obj.header_bits, old, new):
  // someone else forwarded; use their target
  new_loc = decode_forward(obj.header_bits)
```

---

## 13.4 LL/SC

- Load-linked reads a value; store-conditional succeeds only if no intervening write.
- Avoids ABA; retries on interference.
- Less portable; used in some lock-free queue algorithms.

---

## 13.5 Lock-Free Queues/Buffers

- **Single-producer/single-consumer ring buffer**: simple atomic head/tail.
- **Michael-Scott queue**: CAS-based linked queue for multi-producer/multi-consumer.
- **Work-stealing deque (Chase-Lev)**: used in GC work distribution; owner uses non-atomic fast path; thieves use CAS on top index.

---

## 13.6 Termination and Consensus

- Termination detection uses counters, barriers, or token rings; relies on atomic increments/CAS.
- Consensus algorithms (Peterson, Bakery) illustrate synchronization correctness; CAS often used instead in modern code.

---

## 13.7 Memory Ordering

- Sequential consistency vs relaxed/acquire-release; GC often uses release when publishing objects/barriers, acquire on consumption.
- Avoid data races on GC state transitions; use atomic flags with appropriate ordering.

---

## 13.8 Summary

GC implementations rely on CAS/TAS-based synchronization for locks, barriers, forwarding install, and work queues. Understanding ABA, contention, and memory ordering is critical. LL/SC variants exist but CAS is the common denominator on mainstream hardware.

