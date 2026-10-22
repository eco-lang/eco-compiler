# Multi-threaded Eco: heap and messaging design space

**Status:** design-space exploration, 2026-10-22. Not an implementation plan.
Nothing in the runtime was changed to produce it. Decisions recorded as
**[decided]** were made by the project owner during the exploration;
everything else is an option under consideration.

**Question:** Eco's next version gets multiple threads. Each thread keeps
its own heap with one mutator (HEAP_007 stays true per heap), and threads
communicate through typed mailboxes. Any heap value can be a message: small
custom-type values usually, but also records, functions and closures,
arrays, large lists, dicts. How should messages move between heaps with low
latency and high throughput, while keeping what is shared between threads,
and so what the GCs must agree on, to a minimum?

**Evidence tags** (as in `design_docs/parallel-gc.md`):
- **[C]** checked in the code or `invariants.csv` (location named);
- **[E]** estimate or reasoning, nothing measured;
- **[L]** literature or prior art from memory; check before citing.

## Documents

| File | Contents |
|---|---|
| [01-baseline-and-boundary.md](01-baseline-and-boundary.md) | Today's single-mutator heap, the decided threading model, and the one rule every option must keep: shared memory never points into a thread's heap. |
| [02-message-tiers.md](02-message-tiers.md) | Tier A (inline in a ring, copied out), tier B (arena transfer), tier C (reference-counted shared memory, leaves and pointer-bearing). Eager versus lazy copy-out. The send-side graph copy. What may be sent. |
| [03-transport-structures.md](03-transport-structures.md) | Ring buffers, arenas, and single-writer append-only logs (incremental arena ownership): mechanics, GC rules, costs. |
| [04-use-cases.md](04-use-cases.md) | The four communication patterns (SPSC, broadcast, work distribution, multiple producers) against every tier and transport. |
| [05-http-and-runtime.md](05-http-and-runtime.md) | What this means for the HTTP server and client, the reactor, and the runtime/kernels. |
| [06-invariants-and-open-questions.md](06-invariants-and-open-questions.md) | Draft invariants, verification needs (TLA+, GenMC, validators), open questions. |

## Summary

- **[decided]** One mutator per heap. Cross-thread communication only through
  typed mailboxes.
- **[decided]** Small messages travel inside a ring buffer and are copied out
  onto the receiver's heap; larger ones need memory shared between threads.
  What is shared must be kept to a minimum.
- The governing rule (01): **shared memory is immutable, is closed (never
  points into any thread's heap), and only points to older shared memory.**
  Under it, shared memory forms a DAG, so reference counting is complete and
  Eco never needs a second tracing collector.
- Three tiers (02): **A** copy through a ring (default for small messages);
  **B** transfer ownership of an arena (large, single receiver; nothing stays
  shared); **C** reference-counted shared memory (large and genuinely shared:
  broadcast, shared read-only data), per object for pointer-free leaves, per
  arena for pointer-bearing structures.
- Copy-out can be **eager** (at the start of `update`; the slot frees at once)
  or **lazy** (the receiver reads in place; escapes are copied out at the end
  of `update`, found by scanning only what the update allocated). Recommended:
  eager below a size threshold, lazy above it, and later compiler escape
  analysis to skip the scan where a message provably never escapes.
- Three transports (03): **rings** for transient messages, **arenas** for
  ownership transfer, **single-writer append-only logs** (incremental arenas)
  for streams the receiver keeps and for delta streams that share structure
  with earlier messages.
- Use cases (04): SPSC is the base case for everything. Broadcast favours a
  single ring or log with one cursor per consumer plus per-arena reference
  counting for large events. Work distribution favours producer-side routing
  over per-consumer rings (affinity) or a claimable queue of arena pointers
  (pull balancing). Multiple producers favour fan-in of per-pair SPSC
  channels over one shared MPSC ring.
