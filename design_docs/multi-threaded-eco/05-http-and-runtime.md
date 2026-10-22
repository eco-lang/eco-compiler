# 05 — HTTP, the reactor and the runtime

How the heap and messaging model maps onto networking, and what the runtime
and kernels must change. Related plans: `plans/native-http-client.md`,
`plans/mac-keychain-trust.md`.

## 5.1 The reactor as a producer

The eco/system I/O reactor is not a mutator and never allocates on an Elm
heap (G1). It can, however, write raw memory, so it can write **ring records
and arena contents in the message layout** directly (02 §2.1 rule 4: final
absolute addresses, heap object layout). Then:

- **Requests:** the reactor parses the request (llhttp, nghttp2) and writes a
  request message into the chosen worker's ring (tier A) or an arena (tier B).
- **Bodies:** streamed as chunk messages (the existing `Http.Stream` channel
  unit is 64 KiB) through the ring with copy-out, or appended to an
  append-only log (03 §3.3) when the handler keeps the body (an upload stored
  whole): each published chunk is immediately a `Bytes` value the worker owns,
  with no copy-out.
- **Responses:** the worker's kernel copies the response out of its heap into
  plain data and submits it to the reactor (the existing G2/G3 discipline). A
  large response body could become a tier C leaf the reactor writes to the
  socket in place.
- **Today's main-thread event queues become mailboxes.** Socket events, HTTP
  events and client responses are messages to the thread that owns the
  request.

## 5.2 Use-case mapping

| HTTP situation | Pattern (04) | Suggested mechanism |
|---|---|---|
| Connection pinned to one worker (all its requests) | 1. SPSC | Ring (A); log for kept bodies |
| Requests spread over workers, affinity by session/user key | 3. Distribution, push | Per-worker rings, key hash at the reactor after parsing headers |
| Requests spread over workers, pure balancing | 3. Distribution, pull | Claimable queue; arenas (B) for large requests |
| Many workers answering through one reactor | 4. MPSC | Fan-in of per-worker rings into the reactor |
| Several reactors, several workers | 4. MPMC | Per-pair rings (push) |
| WebSocket pub/sub fan-out (one event to many connections' threads) | 2. Broadcast | One ring with *k* cursors; tier C for large payloads |
| HTTP client: requests from many workers into the connection pool | 4. MPSC | Fan-in into the pool's reactor; responses routed back per requester |

Behind a reverse proxy or cloud load balancer, traffic may arrive on a few
long-lived HTTP/2 connections, so per-connection affinity collapses onto a
few threads; request-level dispatch (push by key, or pull) is required there.
[E]

## 5.3 Per-connection parallelism (HTTP/2, HTTP/3)

- nghttp2, ngtcp2 and nghttp3 sessions are not thread-safe: one connection's
  framing, header compression and flow control are serial on its reactor.
  Only request processing fans out to workers; responses return as commands
  to the connection's reactor (as `Http2.hpp` already does).
- **Backpressure:** a full worker ring is the signal to stop reading the
  socket or withhold HTTP/2 or HTTP/3 flow-control window, so the system is
  bounded end to end without separate queues.
- **Fairness:** cap how many of one connection's requests are with workers at
  once (distinct from `maxConcurrentStreams`, which limits what the client may
  open).
- **HTTP/1.1 pipelining** must answer in order: parallel handling needs a
  reorder buffer with a memory bound.
- **HTTP/3 with several reactors:** packets for one QUIC connection must reach
  its owning reactor; address-hash `SO_REUSEPORT` breaks on NAT rebinding and
  migration. Options: encode the owner in server-chosen connection IDs and
  forward misrouted packets, one receive thread that dispatches, or eBPF
  steering (Linux).
- **Request handles move with the request** (01 §1.4 transfer semantics): a
  request delivered to worker 3 is answered from worker 3 unless explicitly
  transferred.

## 5.4 Runtime and kernel changes

- **Event routing:** every reactor event carries its owning thread (mailbox)
  instead of an implied main thread. Queues, Scheduler async sources and
  liveness holds (`plans/program-liveness-rule.md`) become per thread; a
  thread waiting on a mailbox with live senders is alive.
- **Kernel tables and singletons:** `HttpServerManager`, `WsManager`, the
  stream and channel tables and the `HttpService` result lanes are
  main-thread-only or process-wide today; each becomes per thread or
  synchronized. Audit every `static` in the kernels.
- **Cross-thread cancellation:** RST_STREAM must kill a task on another
  thread; a kill from Elm must reach the reactor; both race with completion.
- **CR-012:** process-wide committed bytes, decommit clocks and the
  released-extent list must be made safe for several heaps.
- **GC accounting:** adopted arenas and owned log prefixes count as
  allocation on the receiving heap.
- **The JavaScript backend:** workers with `postMessage` (structured clone)
  correspond to tiers A/B; `ArrayBuffer` transfer and `SharedArrayBuffer`
  correspond to tier C leaves. The sendable rule keeps both backends
  consistent. [L]

## 5.5 Readiness requirements for the native HTTP client plan

Choices to make now in `plans/native-http-client.md` so threading is not
blocked later:

1. Reactor events are messages to a mailbox, written in the message layout,
   with the target thread stamped when the request is created.
2. Request and response bodies go through a reference-counted off-heap buffer
   type (the future tier C leaf), not plain heap copies.
3. Every protocol session is owned by exactly one reactor; work for it is
   posted as commands, never done under a lock.
4. No new process-wide singletons in `EcoNet`; where one is unavoidable (the
   pool, the Alt-Svc cache) it belongs to a reactor.
5. The reactor count is a parameter (one by default).
6. Backpressure lives in the protocol (flow-control windows, not reading the
   socket), never in unbounded queues.
