# 04 — Use cases against tiers and transports

Four communication patterns:

1. **SPSC** — single producer, single consumer.
2. **Broadcast** — single producer, multiple consumers, each gets every event.
3. **Work distribution** — single producer, multiple consumers, each event goes
   to exactly one consumer, balanced over them.
4. **Multiple producers** — several producers, to a single consumer or to
   several.

Mechanisms considered for each: tier A ring with eager or lazy copy-out,
tier B arena transfer, tier C shared memory (per-object leaves, per arena),
and the single-writer append-only log. Everything here is [E] unless tagged.

## 4.1 SPSC

The base case; every other pattern is built from it.

| Mechanism | Fit | Notes |
|---|---|---|
| A, eager | **Default for small** | One record, copied out at the start of `update`, freed at once. |
| A, lazy | Large messages only partly read | Escape scan at the end of `update` (02 §2.3). |
| B | **Default for large** | One copy, adopted by the consumer; nothing shared. |
| C | Not needed | Only one holder; sharing buys nothing. |
| Log | Streams the consumer keeps; delta streams | One copy per message; structural sharing across messages (03 §3.3). |

## 4.2 Broadcast (every consumer gets every event)

With *k* consumers, the questions are how many copies the producer makes and
who holds back reclamation.

| Mechanism | Fit | Notes |
|---|---|---|
| A, one ring per consumer | Simple, small *k* | *k* copies by the producer; consumers progress independently. |
| A, **one ring with *k* read cursors** | **Default for small events** | One copy; a record is freed when the slowest cursor passes it (the minimum of *k* cursors), as in the LMAX Disruptor [L]. Each consumer copies out on its own, eagerly or lazily. Lazy copy-out holds a record until every consumer's `update` has finished with it. |
| B | Does not fit | One owner only. Either *k* arenas (*k* copies) or switch to C. |
| C, per object | Large pointer-free payloads | The envelope travels through the ring; the body is a counted shared leaf with count *k*. |
| C, per arena | **Default for large structured events** | One arena, count *k* while in flight; consumers read in place. The longest holder pins it; copy out on long retention (02 §2.5). |
| Log with *k* readers | Broadcast streams, delta streams | Single writer, *k* readers, no exclusive owner, so the log is tier C memory: every reader's GC follows the unsealed-log rules (03 §3.3: no allocation into it, no decommit, nothing moved), and after sealing it is freed when all *k* readers release it. Structural sharing works for every reader. Like a log topic with per-consumer offsets [L]. |

**The real design question is the slow consumer.** With shared reclamation
(one ring with *k* cursors, a shared log, counted arenas) the slowest
consumer throttles the producer for everyone. Policies to choose between:
throttle (block the producer: simplest, global backpressure), bounded lag
(a consumer more than N events behind is disconnected or must resync), or
per-consumer overflow (the slow consumer's backlog moves elsewhere,
unbounded). A broadcast send is one operation: whether a full consumer parks
the whole broadcast or only its own delivery must be part of the mailbox
semantics.

## 4.3 Work distribution (each event to one consumer)

Two families: the producer chooses (**push**) or consumers take (**pull**).

| Mechanism | Fit | Notes |
|---|---|---|
| A, push: one SPSC ring per consumer | **Default when affinity matters** | Each pair is 4.1. Routing policy at send time: round robin, least loaded (ring occupancy readable by the producer as a hint), or **key hash** for affinity (consistent hashing if *k* can change). A slow event stalls only its consumer's ring, but there is no stealing without re-sending, which copies again. |
| A, pull: one ring, consumers claim records | Balancing small events | Claim via compare-and-swap on a claim cursor. Records finish out of order, so reclamation needs per-record "done" flags; the free cursor advances over the contiguous done prefix. **Use eager copy-out here:** with lazy copy-out one long `update` holds its record, the free cursor stops there, and the ring fills while other consumers idle. |
| B, pull: a queue of arena pointers | **Default for balancing large events** | Ownership transfers at claim time; the payload is copied once. Stealing or re-routing moves a pointer, not data. |
| C | Not needed | One holder per event; transfer instead of share. |
| Log | Poor fit | Consumers would each own scattered records of one log, so every consumer must follow the unsealed-log rules and the log is freed only when no consumer holds any record of it: per-arena counting with pinning across consumers. Use one log per consumer (push) instead. |

**Affinity versus balance.** Key routing (the same session, user or
connection always reaches the same consumer) requires push and gives up
stealing; pull balances well but scatters related events. A hybrid: push by
key where a key exists, pull (or stealing) for keyless events. A hot key
(one very busy session) cannot be balanced without breaking its affinity.

## 4.4 Multiple producers

### Many producers, one consumer (MPSC)

| Mechanism | Fit | Notes |
|---|---|---|
| A, **fan-in of per-producer SPSC rings** | **Default** | No contention between producers; per-producer FIFO. The consumer polls *m* rings; a doorbell bitmap (each producer sets its bit) avoids scanning idle rings. Memory: *m* rings per consumer. |
| A, one MPSC ring | Only if a single arrival order is required | Producers reserve variable-size space with fetch-and-add on the write cursor, write, then set a commit flag. The consumer reads in order and must stop at the first uncommitted record, so **one producer descheduled mid-write stalls the consumer for every producer.** The write cursor is a contended cache line. |
| B | Fits | Each producer allocates its own arenas; the consumer adopts arenas from all of them; arena pointers travel through the fan-in rings. |
| C | Fits | Producers may publish arenas that point into older shared arenas they have received; rule S3 (newer → older) holds globally, so the graph stays acyclic. Count updates now come from many threads (atomic operations). |
| Log | Per producer | Single writer is required: one log per producer→consumer pair, fanned in like the rings. |

### Many producers, many consumers (MPMC)

- **Push:** one SPSC ring per (producer, consumer) pair, *m*×*k* rings. Fine
  for tens of threads; the memory grows quickly for hundreds.
- **Pull:** each producer owns a claimable queue (rings for small events,
  arena-pointer queues for large ones) that consumers drain or steal from;
  this is the work-stealing shape.
- **Central MPMC queue:** contention and head-of-line stalls on both sides;
  not recommended.
- **Broadcast from several producers:** each producer has its own broadcast
  ring or log with *k* cursors; each consumer merges *m* sources.

### Ordering

Only per-pair FIFO is guaranteed: messages from one producer to one consumer
arrive in send order. Nothing orders messages from different producers, and
causality is not preserved (A→C and A→B→C may reach C in either order), as in
Erlang [L]. If a program needs a global order, a single sequencer thread
provides it. This must be stated in the mailbox API's documentation.

## 4.5 Summary matrix

✓ good fit · ~ works with caveats · ✗ does not fit

| | A eager | A lazy | B arena | C leaf | C per arena | Log |
|---|---|---|---|---|---|---|
| 1. SPSC | ✓ small | ✓ large, partly read | ✓ large | — | — | ✓ kept / delta streams |
| 2. Broadcast | ✓ one ring, *k* cursors | ~ holds records for the slowest `update` | ✗ (*k* copies) | ✓ large payloads | ✓ large structures | ~ shared, tier C rules |
| 3. Distribution, push | ✓ affinity | ✓ | ✓ | — | — | ✓ one log per consumer |
| 3. Distribution, pull | ✓ | ✗ stalls reclamation | ✓ best for large | — | — | ✗ |
| 4. MPSC | ✓ fan-in | ✓ fan-in | ✓ | ✓ | ✓ | ✓ one log per producer |
| 4. MPMC | ✓ push *m*×*k* or pull queues | ~ push only | ✓ pull / stealing | ✓ | ✓ | ✓ per pair |
