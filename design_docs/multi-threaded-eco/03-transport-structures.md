# 03 — Transport structures: rings, arenas, append-only logs

The tiers (02) say what a message is made of and who owns it. The transport
says how messages flow between a producer and a consumer and when their
memory is reclaimed.

## 3.1 Ring buffers

A fixed-size circular buffer of variable-size records.

- **Records:** a length header, padding at wraparound, a commit word written
  with a **release** store; the reader uses an **acquire** load. Apple Silicon
  (ARM64) is weakly ordered, so the orderings are load-bearing; the existing
  weak-memory TLA+ model and GenMC are the tools to check them.
- **SPSC per producer–consumer pair** is the building block: no
  compare-and-swap between producers, per-producer FIFO for free (Erlang's
  ordering guarantee [L]). Multi-producer and multi-consumer rings are
  discussed per use case in 04.
- **Reclamation is in order.** The read cursor frees records in sequence; with
  in-order processing there is no fragmentation.
- **Wakeups without a syscall per message:** spin briefly, then park behind a
  "consumer sleeping" flag (eventfd on Linux, kqueue on macOS). The flag and
  fence form the classic lost-wakeup race and need a model check.
- **Full ring:** the sending *task* parks (a send is a `Cmd`/`Task`); the
  thread never blocks. Spilling to tier B is a possible second option.
- **Sizing:** a ring must hold the largest record it accepts, or large records
  go elsewhere (tier B, or a separate large-record ring).

Best for: transient messages that are read, acted on and dropped. With lazy
copy-out (02 §2.3) a record is held for the duration of one `update`.

## 3.2 Arenas (sealed, single owner)

A block filled by bumping a pointer and freed as a whole. As a transport it
carries one message (or a batch) whose ownership moves to the consumer
(tier B). The ring or queue then carries only the arena's address.

- One copy, by the producer; nothing shared after adoption.
- Reclamation is the consumer's GC's business (02 §2.4).
- Needs size classes or chained blocks for large messages; wasteful for small
  ones.

Best for: large messages with exactly one consumer.

## 3.3 Single-writer append-only logs (incremental arena ownership)

An arena that the producer keeps appending to, while the consumer's ownership
grows to cover everything published so far:

```
arena block
┌─────────────── owned by consumer ─────────┬── producer writing ──┬── unused ──┐
│ msg1 │ msg2 │ msg3 │ ...                   │ msg7 (in progress)   │            │
└───────────────────────────────────────────┴──────────────────────┴────────────┘
                                            ↑ published write pointer
```

- **Publishing:** complete objects and record headers first, then the write
  pointer with a release store; the consumer reads it with an acquire load.
- **Ownership:** at any moment the consumer owns `[start, published pointer)`;
  the producer owns everything above it.

Rules for the consumer's GC while the log is **unsealed** [E]:

1. A collection reads the published pointer once, at its start, and treats it
   as the arena's end for that collection.
2. The consumer never allocates into the arena; its allocators must not see
   the space above the pointer as free.
3. Sweeping and page decommit (`madvise`) stop at the last page boundary
   strictly below the pointer.
4. Nothing in the prefix is moved or freed until the producer **seals** the
   log (see sharing below).

**Sharing between later and earlier messages.** The main reason to use a log
instead of a ring: the producer may write message 7 with pointers into
message 3 (successive versions of a large `Dict`, each costing O(log *n*) new
nodes: delta streams). That requires rule 4 (the consumer must not evacuate
or free message 3 while the producer may still point at it) and a
producer-side map from "objects already copied" to their copies in the log.
The producer's own GC moves its young objects, so that map must not be keyed
on movable addresses: map only old-generation objects (non-moving unless the
old generation compacts) and drop entries for young objects at each of the
producer's minor GCs. The alternative, forbidding back-references, frees the
consumer's GC from rule 4 but loses structural sharing.

**Seal and rotate.** An unsealed log never shrinks. The producer seals it
after N MB or at the end of the stream and starts a new one. New messages may
point into the previous log, which therefore needs a reference count (acyclic
by rule S3; 02 §2.5 per-arena counting). Once sealed and no longer
referenced by a newer log, the log is ordinary memory of the consumer: its
GCs copy out what is reachable and free the block. Backpressure: cap the
number of unsealed or unfreed logs per stream; the producer parks when the
cap is reached. Accounting: every published byte is allocation on the
consumer's budget.

Best for: streams the consumer keeps (an upload stored whole), and delta
streams sharing structure across messages.

## 3.4 Comparison

| | Ring + copy-out (eager or lazy) | Arena transfer | Append-only log |
|---|---|---|---|
| Best for | Transient messages | Large, one consumer | Kept streams; delta streams |
| Copies | 1 in, 0–1 out | 1 | 1 |
| Memory reuse | Immediate, in order | After the consumer's GC | After seal + the consumer's GC |
| Structural sharing across messages | No | No (each arena closed) | Yes, if back-references are allowed |
| Consumers per item | 1 per cursor; several cursors possible (04) | Exactly 1 | 1 owner; several readers only as tier C (04) |
| Work for the consumer's GC | Lazy: end-of-update escape scan; minor GC evacuates held records | Adopt entry point | Unsealed-region rules 1–4; seal; per-log counts |
| Main risk | Lost wakeups; missed escapes (lazy) | Pinning if adopted old | Freeing or decommitting the producer's in-progress range |
