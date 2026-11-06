---
status: done
updated: 2026-11-06
---

# Native bytes ports 2: borrowed bytes out, emitted bytes in

## Problem

`plans/native-bytes-ports.md` (PORT_008) gave native ports an interim bytes channel:

- **Outgoing:** a host callback gets `(const uint8_t* data, size_t length)` pointing into the Elm
  Bytes value, valid only for the call. A host that needs the bytes later has to copy them itself,
  and nothing in the API helps it do that safely.
- **Incoming:** `eco_port_send_bytes` queues a host buffer, which the eco thread copies into a new
  heap Bytes value. That is one copy, plus whatever copy the host made to produce the buffer.

A host that transforms a stream (frames in, frames out) pays a copy per message per direction.

## Goals

1. **Borrowed outgoing bytes.** A host callback gets a handle. The handle reads the bytes at zero
   copy for the whole call. `retain()` turns it into an owned, refcounted value that may be kept
   anywhere and released on any thread.
2. **Emitted incoming bytes: one call, two paths.**
   `eco_port_emit(port, capacity, fill, user)` asks the host to fill a buffer, then sends the
   result to an incoming bytes port.
   - **Direct path:** called on the eco thread inside an outgoing-port callback, it allocates the
     Bytes value on the heap without collecting, and `fill` writes straight into it (zero copy).
     When the heap cannot supply the memory without a collection, it falls back to the off-heap path.
   - **Off-heap path:** called anywhere else, `fill` writes into a malloc'd buffer, which the eco
     thread copies in later. This is the existing lent-buffer path of `eco_port_send_bytes`.
3. **An async path for buffers filled later** (OS reads, network completions). The host fills its
   own stable buffer and hands it over with the existing `eco_port_send_bytes`. The C++ layer wraps
   this as a move-only `eco::Buffer`.
4. **A header-only C++20 layer**, `runtime/include/eco/eco_embed.hpp`, over the C ABI. It gives C++
   hosts RAII, `std::span` and lambdas, and the runtime owns subscriber lifetimes so that
   unsubscribing never frees a running callback.
5. **Nothing existing breaks.** The interim `eco_port_subscribe_bytes` callback keeps its guarantee:
   its `data` stays valid for the whole call.
6. **Port handles: no string lookups per message.** A host resolves a port name once with
   `eco_port_get(name)`, which returns an `eco_port*` that stays valid for the life of the process.
   Every new operation takes the handle. The runtime itself stops using names after registration:
   port managers, deliveries and queued sends all carry the handle. In C++ the port kind is part of
   the type (`eco::BytesInPort`, `eco::BytesOutPort`, `eco::JsonInPort`, `eco::JsonOutPort`) and is
   checked once, when the handle is made.
7. **Shipped headers.** `eco_embed.h` and `eco_embed.hpp` are installed with every release bundle
   at `<prefix>/include/eco/`, so a host writes `#include <eco/eco_embed.hpp>`. A user doc explains
   embedding, and the glibc smoke test builds its C and C++ hosts against the installed headers.

**Non-goals:**
- A binary format for non-Bytes payloads.
- Bytes nested inside payloads or in flags.
- Changes to the Node addon.
- Pinning heap objects for retained bytes (see "Later").
- Changing when an incoming message is delivered (divergence D5, §2.10).

## 1. Facts the design rests on (verified 2026-11-06 against the code)

- **F1. Where callbacks run.** Outgoing callbacks run synchronously on the eco thread, inside the
  port manager's `onEffects`. The path is `portOutgoingOnEffectsEvaluator` or
  `portOutgoingBytesOnEffectsEvaluator`, then `PortRuntime::deliverOutgoing{,Bytes}`
  (`runtime/src/platform/PortRuntime.cpp`). Subscribers are called with no lock held. The one
  exception is the flush of payloads buffered before the first subscriber: it calls the
  subscriber on the *subscribing* thread, with copies.
- **F2. What can move an object.** A pause starts only on the mutator: at an allocation slow path,
  at `__eco_safepoint_poll`, or at an explicit collection. Background GC threads (concurrent
  markers, the threaded-gc-07 tenure job, helper jobs) never change a location the mutator can see
  outside a pause (HEAP_006, HEAP_058, HEAP_070). So while the eco thread runs host code and does
  not collect, no Elm object moves or dies.
- **F3. One mutator.** There is one mutator per process (HEAP_007), so a host thread can never
  allocate on the heap.
- **F4. Allocating without collecting.** `Allocator::allocateFast(size)` → `ThreadLocalHeap::allocateFast`
  bump-allocates in the nursery or returns null. It never collects, and it writes no header
  (`RuntimeExports.cpp:251` relies on this). `OldGenSpace::allocateLargeBody` allocates a
  header-less large body or returns null, and also never collects. Its colour follows
  allocate-black during a mark. `ThreadLocalHeap::noteDirectAlloc` only *requests* a minor
  collection at the next nursery miss.
- **F5. The stack walk.** `ThreadLocalHeap::collectStackRootsFromStackMap` walks the eco thread's
  stack with libunwind (or `RtlVirtualUnwind`) and **stops silently** at a frame it cannot unwind
  (`ThreadLocalHeap.cpp:1364-1404`, `StackUnwind.hpp:62-67`). A host frame without unwind tables
  (cgo, JNI or LuaJIT thunks, `-fno-asynchronous-unwind-tables`, Windows code without `.pdata`)
  would hide every compiled Elm frame below it from the collector. **So no collection may ever run
  while host code is on the eco thread's stack.** Today none does. This design keeps it that way and
  makes it enforced (§2.1).
- **F6. Locks and queues.** The port root scanner (PORT_004) takes `portsMutex_`. External root
  scanners run on the mutator inside a pause (`NurserySpace.cpp:597`, `NurseryParallel.cpp:716`,
  `NurseryRegion.cpp:959`). `pendingMutex_` is only ever held around deque operations, by threads
  that do not allocate or wait for a GC. `portsMutex_` and `pendingMutex_` are never nested.
- **F7. When incoming payloads are handled.** Queued incoming payloads are handled by
  `drainPendingSends`, a scheduler async source run from `processReadyAsync`. That happens after
  the run queue has drained, so after the current dispatch and its sibling tasks
  (`Scheduler.cpp:686-692`).
- **F8. Bytes forms.** A Bytes value is the empty constant, a flat `Tag_ByteBuffer`
  (`header.size` = length, which is also the object's extent), a `Tag_LargeByteHeader` (16 bytes,
  `header.size` = logical length only, `body` → a header-less, pointer-free pinned body whose size
  is its cell size), or a slice. `allocByteBuffer(n)` produces the large form exactly when
  `roundup8(sizeof(ByteBuffer) + n) >= large_object_threshold` (8 KiB by default).
- **F9. Names on the hot path.** Every host port call takes `portsMutex_` and does
  `ports_.find(name)` on an `unordered_map<std::string, PortInfo>`. Each outgoing `onEffects` turns
  the captured Elm name into a `std::string` (`elmStringToStd`, which allocates) and then looks it
  up again in `deliverOutgoing*`. Each queued `PendingSend` carries a `std::string name` that the
  drain looks up. Entries of `ports_` are never erased (a test heap reset only marks them
  unregistered), and `unordered_map` element addresses survive rehashing, so `&ports_[name]` is
  stable for the life of the process. None of the shipped bundles installs `eco_embed.h`; the
  glibc smoke test copies it from the source tree (`docker/static-build.Dockerfile`).

## 2. Design

### 2.1 The rule: no collection inside a host callback

There is a new per-thread counter, `ThreadLocalHeap::no_collect_depth_`, with an RAII
`NoCollectScope` that increments and decrements it. `PauseEndHook`'s constructor, which every
`minorGC`, `majorGC` and `majorGCAndShrink` enters, aborts in every build if the counter is
nonzero:

    [gc] FATAL: a collection started inside a host callback (HEAP_083)

`PortRuntime` holds a `NoCollectScope` around every host callback it makes on the eco thread: each
subscriber call in `deliverOutgoing` and `deliverOutgoingBytes`. Everything the runtime does inside
a callback on the host's behalf (`eco_borrowed_*`, `eco_port_emit`, `eco_port_send*`) is
therefore built from non-collecting operations only. The cost is one integer compare per pause.

This one rule replaces the first draft's "re-resolve the borrowed pointer after an emit". **A
borrowed pointer stays valid for the whole callback, emits included**, and the interim callback's
PORT_008 guarantee holds unchanged.

### 2.2 Borrowed outgoing bytes

```c
typedef struct eco_borrowed_bytes eco_borrowed_bytes;      // opaque; valid only during the call
typedef void (*eco_port_borrowed_callback)(const eco_borrowed_bytes* bytes, void* user);
typedef void (*eco_destroy_fn)(void* user);

int eco_port_subscribe_borrowed(eco_port* port, eco_port_borrowed_callback cb, void* user,
                                eco_destroy_fn destroy);
int eco_port_unsubscribe_borrowed(eco_port* port, eco_port_borrowed_callback cb, void* user);

const uint8_t* eco_borrowed_data(const eco_borrowed_bytes* b);   // NULL when size is 0
size_t         eco_borrowed_size(const eco_borrowed_bytes* b);
```

The pointer from `eco_borrowed_data` is valid until the callback returns. The `eco_borrowed_*`
functions may be called only during the callback, on the thread that runs it.

**Lifetime of `user`.** `destroy` (which may be NULL) is called exactly once, after the subscription
has been removed and no delivery can call `cb` again. It may run on the eco thread right after a
delivery returns, or on the thread that unsubscribed. It never runs with a runtime lock held. If the
subscribe call fails, `destroy` is not called and `user` stays the caller's. Removing a subscription
from inside its own callback is legal: `destroy` then runs after the callback returns.

**Delivery order.** Interim and borrowed subscribers live in one list per port, in subscription
order, and a delivery calls them in that order. Both kinds refuse a JSON port, count toward
`everSubscribedBytes`, and receive the buffered payloads when they subscribe.

### 2.3 Retained (owned) bytes

```c
typedef struct eco_owned_bytes eco_owned_bytes;               // refcounted, immutable
eco_owned_bytes* eco_borrowed_retain(const eco_borrowed_bytes* b);  // NULL only on out of memory
const uint8_t*   eco_owned_data(const eco_owned_bytes* o);   // NULL when size is 0
size_t           eco_owned_size(const eco_owned_bytes* o);
void             eco_owned_ref(eco_owned_bytes* o);           // any thread
void             eco_owned_unref(eco_owned_bytes* o);         // any thread; frees at zero
```

The v1 implementation copies the bytes into one malloc'd block: `{std::atomic<size_t> refs; size_t
size; uint8_t bytes[];}`. It has no GC interaction, so it is safe on any thread and inside `fill`.
Retaining an empty payload returns a valid block with size 0. Because the ABI hides whether retain
copies or pins, a later version may pin large bodies without hosts changing.

### 2.4 Emitted incoming bytes

```c
#define ECO_FILL_CANCEL ((size_t)-1)
typedef size_t (*eco_bytes_fill)(uint8_t* out, size_t capacity, void* user);

int eco_port_emit(eco_port* port, size_t capacity, eco_bytes_fill fill, void* user);
```

`eco_port_emit` takes a handle (§2.11). Like every new function in this plan it has no name-based
form: a C host calls `eco_port_get` once.

| result | meaning | was `fill` called? |
|---|---|---|
| 0 `ECO_EMIT_QUEUED` | the payload is queued | yes |
| 1 `ECO_EMIT_NOT_A_PORT` | null `port`/`fill`, `capacity > UINT32_MAX`, or `port`'s kind is not `ECO_PORT_IN_BYTES` (including not registered yet) | no (but see the note below) |
| 2 `ECO_EMIT_CANCELLED` | `fill` returned `ECO_FILL_CANCEL` | yes |
| 3 `ECO_EMIT_OVERRUN` | `fill` returned more than `capacity`; nothing is sent | yes |
| 4 `ECO_EMIT_NESTED` | called from inside a `fill` | no |
| 5 `ECO_EMIT_NO_MEMORY` | the off-heap buffer could not be malloc'd, or (after `fill`) a short direct fill found neither heap nor malloc memory for its copy | no, except in that case |

Note on result 1: it can also come back *after* `fill` ran, when the program stopped between the
check and the queueing (the queue refuses items once the stop hook has run, so no lent buffer is
left unreleased), and in one test-only case. The port check
passes, the test heap is reset, and then the queueing step refuses the payload. The buffer is
freed, and this is documented as the single exception.

`fill` writes at most `capacity` bytes to `out` and returns how many it wrote, or
`ECO_FILL_CANCEL` to send nothing. With `capacity` 0, `out` may be NULL. Eco is 64-bit only, so
`ECO_FILL_CANCEL` (`SIZE_MAX`) can never be a legal length, which is at most `UINT32_MAX`.

**Path choice.** A thread-local `t_inHostCallback` is set *only* by `deliverOutgoing` and
`deliverOutgoingBytes` around their subscriber calls, which run on the eco thread. A flush on a
subscribing thread never sets it. Every emit made while it is set tries the direct path, and every
other emit takes the off-heap path. As a backstop, the direct path also asserts that
`Allocator::instance().getCurrentThreadHeap()` is non-null.

**Direct path:**
1. Check the port, and refuse if a fill is already running (result 4).
2. Allocate `capacity` bytes **without collecting** (§4 step 2, `tryAllocByteBufferNoCollect`).
   This uses the same small/large split as `allocByteBuffer`. Small: `allocateFast` +
   `initHeaderForTag`. Large: an `allocateFast` header plus `allocateLargeBody`, with the body not
   zeroed. If the allocation fails, or a test hook forces it to, go to the off-heap path. The port
   check is already done.
3. Set `t_inFill`, call `fill(bytes, capacity, user)`, then clear `t_inFill`. Nothing can collect,
   so the object stays where it is (F2).
4. On a cancel or an overrun, abandon the object (it is unreachable garbage) and return 2 or 3. In
   `ECO_HEAP_VALIDATE` builds, treat an overrun as fatal, since the host has probably written past
   the buffer.
5. Turn a short fill into the canonical form for its length (§2.5).
6. Queue the result as a Heap pending send (§2.6), and return 0.

**Off-heap path:**
1. Check the port, and refuse if a fill is already running.
2. `malloc(max(capacity, 1))`, or return 5 if that fails.
3. Set `t_inFill`, run `fill`, then clear it. On a cancel or an overrun, free the buffer and return 2 or 3.
4. Call `sendIncomingBytes(port, buf, n, free_release, buf)`. If it refuses (the test-only reset),
   free the buffer and return 1.

The off-heap path copies once, on the eco thread. It must not be used from the scheduler idle hook,
which runs with the scheduler lock held; the same restriction already applies to `eco_port_send`.

### 2.5 Short fills (direct path)

The rule: **the payload's form is the one `allocByteBuffer(n)` would have made.** Let `large(k)`
mean `roundup8(sizeof(ByteBuffer) + k) >= large_object_threshold`.

| case | result |
|---|---|
| `n == capacity` | the object as allocated |
| `n == 0` | `emptyBytes()` (a constant, so nothing is allocated) |
| the object is large, `large(n)` and `2n >= capacity` | shrink in place: set the young `LargeByteHeader`'s `header.size = n` |
| any other case | allocate an exact object for `n` without collecting, and `memcpy` `n` bytes into it from the filled object |

Why shrinking in place is legal for the large form: the header's `header.size` is only the logical
length, and the body's extent is its cell size (F8). The header has not survived a GC (no collection
has run since it was allocated), so HEAP_SNAPSHOT_001 allows the write.

The flat form can't shrink in place, because its `header.size` is the object's extent; the old
object becomes garbage instead.

If the exact allocation fails, copy the `n` bytes into a malloc'd buffer and send that through the
off-heap queueing step. The source pointer is still valid there, because nothing has collected.

### 2.6 Heap pending sends

`PendingSend` gains a kind:

| kind | made by | the drain does |
|---|---|---|
| `Json` | `eco_port_send` | decode, then taggers |
| `Bytes` | `eco_port_send_bytes`, the off-heap emit | `allocByteBuffer` copy, release, then taggers |
| `Heap` | the direct emit | taggers only |

A Heap item carries `uint64_t value` (an encoded HPointer) and `uint64_t generation` (the
`Allocator::heapGeneration()` it was made in).

- **Scanner.** The port root scanner also evacuates `value` for every queued Heap item of the
  current generation. It takes `pendingMutex_` in a separate block after releasing `portsMutex_`,
  never nested.
- **Drain.** The drain pops an item under the lock. For a Heap item it decodes `value` into a local
  that is placed in a `StackRootGuard` before anything allocates. It skips the item (releasing its
  hold) if its generation is not current.
- **Bounded drain.** `drainPendingSends` handles only as many items as were queued when it started.
  Items queued during the drain (for example by a callback in the program's reaction to a message)
  wait for the next event-loop turn, so a ping-pong between ports cannot starve the stop check or
  timers.
- **Stop.** A scheduler stop hook drops every still-queued item, calls the `release` of each lent
  Bytes item, and releases each item's hold. This fixes an existing gap in PORT_008's "release is
  called exactly once, also when dropped".

Queue order is FIFO across all kinds.

### 2.7 Subscriber lifetime

`PortInfo::byteSinks` becomes `std::vector<std::shared_ptr<BytesSink>>`. A `BytesSink` holds the
kind (interim or borrowed), the callback, `user`, and `destroy`. Its destructor calls
`destroy(user)` when `destroy` is set.

- A delivery copies the vector (adding a reference to each sink) under `portsMutex_`, then calls
  the sinks with the lock released.
- Unsubscribe *moves* the matching `shared_ptr` out of the vector under the lock and drops it after
  unlocking.
- So `destroy` runs when the last reference goes. That is either at the end of an in-progress
  delivery (on the eco thread) or in `unsubscribe` itself (on the unsubscribing thread), and never
  under a runtime lock.

JSON sinks are unchanged.

### 2.8 Async incoming

There is no new ABI. The host owns a stable buffer, fills it whenever it likes, and calls
`eco_port_send_bytes(port, data, n, release, ctx)`. The C++ `eco::Buffer` and `eco::BytesInPort::send`
(§2.9) wrap this.

### 2.9 The C++ layer (`runtime/include/eco/eco_embed.hpp`)

It is header-only C++20 and depends only on `eco_embed.h`. Every port is a typed handle, a small
copyable value holding an `eco_port*`. Its constructor resolves the name once and checks the kind
(§2.11).

| type | what it is |
|---|---|
| `eco::BytesOutPort` | `subscribe(F) -> Subscription`, where `F` is `void(const BorrowedBytes&)`. |
| `eco::BytesInPort` | `emit(capacity, F) -> EmitResult`, where `F` is `size_t(std::span<std::byte>)` or `std::optional<size_t>(std::span<std::byte>)` (nullopt cancels); `send(Buffer&&) -> EmitResult`. |
| `eco::JsonOutPort` | `subscribe(F) -> Subscription`, where `F` is `void(std::string_view json)`. |
| `eco::JsonInPort` | `send(const std::string& json) -> SendResult` (`Queued`, `NotAPort`, `Rejected`, with the reason from `eco_last_error`). |
| `eco::BorrowedBytes` | Cannot be copied or moved; only the subscriber trampoline makes one. `view()` returns `std::span<const std::byte>`; also `size()` and `retain()` (throws `std::bad_alloc` on NULL). |
| `eco::OwnedBytes` | Copyable (ref/unref), movable, default-constructible (empty); `view()`, `size()`. |
| `eco::Subscription` | Move-only. The destructor (or `reset()`) unsubscribes. The functor is deleted through `destroy`, by the runtime, when it can no longer be called. |
| `eco::Buffer` | Move-only owned bytes with a capacity and a size. |

The trampolines follow two rules:
- A subscriber trampoline catches any exception, prints it, and calls `std::abort()`: an
  exception must never unwind through runtime or compiled Elm frames.
- A fill trampoline catches an exception, cancels the emit, and rethrows the exception when
  `eco_port_emit` returns. Inside a subscriber that rethrow reaches the subscriber trampoline,
  which aborts, unless the subscriber catches it.

Hosts that load the program with `dlopen` (like `test/aot_port_host.cpp`) can't use this header,
because it calls the C functions directly. They use the C ABI through `dlsym`.

### 2.10 Divergence D5 (predicted, not observed)

Reading elm/core 1.0.5 suggests a divergence. On the JS backend, `app.ports.x.send(v)` inside an
outgoing subscriber runs `update` at once, re-entrantly, and only the resulting effects are queued
(`_Platform_enqueueEffects`). Natively, an incoming payload sent from a callback is handled after
the current run queue has drained (F7).

**Measured (2026-11-06, `embed_host.js` scenario `order`):** with `Cmd.batch [ orderOut (),
Task.perform … ]` and a subscriber on `orderOut` that sends on `orderIn`, the program records the
order of its `update` calls in its model. Both the JS backend and the Node addon record
`task,in`. So the predicted divergence does not show here. The scenario stays as a parity test that
pins the shared order. The native behaviour can't change anyway without running Elm inside a host
callback, which §2.1 forbids (F5).

### 2.11 Port handles

```c
typedef struct eco_port eco_port;            // opaque; valid for the life of the process
#define ECO_PORT_UNREGISTERED 0
#define ECO_PORT_IN_JSON      1
#define ECO_PORT_IN_BYTES     2
#define ECO_PORT_OUT_JSON     3
#define ECO_PORT_OUT_BYTES    4

eco_port*   eco_port_get(const char* name);       // the one lookup; NULL only for a NULL name
int         eco_port_kind(const eco_port* port);  // one of ECO_PORT_*; -1 for NULL
const char* eco_port_get_name(const eco_port* port);

int eco_port_send_json(eco_port* port, const char* json_utf8);             // as eco_port_send
int eco_port_send_buffer(eco_port* port, const uint8_t* data, size_t length,
                         eco_port_release release, void* ctx);             // as eco_port_send_bytes
int eco_port_subscribe_json(eco_port* port, eco_port_callback cb, void* user, eco_destroy_fn destroy);
int eco_port_unsubscribe_json(eco_port* port, eco_port_callback cb, void* user);
// and, from §2.2 and §2.4: eco_port_subscribe_borrowed, eco_port_unsubscribe_borrowed, eco_port_emit
```

**What a handle is.** The handle is the port's registry entry itself. `PortInfo` becomes `struct
eco_port`, declared at global scope so that its C name matches `eco_embed.h`, with
`using PortInfo = ::eco_port;` inside the namespace. Entries are never erased, and `unordered_map`
element addresses survive rehashing (F9), so the pointer is valid for the life of the process.

**Before and after registration.** `eco_port_get` may be called at any time, from any thread.
Before the program registers the port, it creates the placeholder entry that subscribe-before-start
already creates, and the kind is `ECO_PORT_UNREGISTERED`. Registration fills in the kind. A test
heap reset sets it back to unregistered, and the next registration sets it again; the handle
survives both.

**Kind checks without a lock.** The kind is a `std::atomic<int>`, stored with release ordering
during registration (still under `portsMutex_`) and loaded with acquire ordering by every handle
operation. So an operation checks the kind without the mutex and without a string compare. An
operation on the wrong kind fails, as the name-based functions do today:
- sends and emits return 1;
- subscribing to a port registered as the other kind fails;
- a subscription made while unregistered is kept, and is called only if the port registers as the
  matching kind.

**The name-based functions stay, as wrappers.** `eco_port_send`, `eco_port_send_bytes`,
`eco_port_subscribe`, `eco_port_unsubscribe`, `eco_port_subscribe_bytes` and
`eco_port_unsubscribe_bytes` keep their exact contracts. Each becomes `eco_port_get(name)` followed
by the handle operation. The interim bytes callback (`eco_port_subscribe_bytes`) gets no handle
form, because it is the interim API.

**The runtime stops using names after registration.**
- `buildPortManager` captures the port's `eco_port*` as an unboxed Int (`PK_Int`) instead of the
  name string. The outgoing evaluators read it back and call `deliverOutgoing{,Bytes}(eco_port*, …)`,
  so there is no `elmStringToStd` and no find. The incoming evaluator calls
  `setIncomingSubs(eco_port*, …)`.
- `PendingSend` carries `eco_port* port` instead of `std::string name`, and the drain reads the
  decoder and tagger list from it under `portsMutex_`, with no find.
- The effect-manager registry in `PlatformRuntime` is still keyed by name; that lookup happens
  once, at registration.

**What is still locked.** A delivery copies the port's sink list under `portsMutex_`, and a queued
send takes `pendingMutex_`. A lock-free sink snapshot is listed under Later.

### 2.12 Shipped headers

- **Home.** Both headers move to `runtime/include/eco/eco_embed.h` and
  `runtime/include/eco/eco_embed.hpp` (moved from `runtime/src/embed/`). Every in-tree user
  includes `<eco/eco_embed.h>` with `runtime/include` on its include path, which is the same
  spelling a host uses against the installed tree.
- **Install.** Both headers are installed at `<prefix>/include/eco/eco_embed.h` and
  `<prefix>/include/eco/eco_embed.hpp`, from the `install()` blocks of all three bundles in the
  top-level `CMakeLists.txt` (components `Bundle`, `BundleDarwin` and `BundleWindows`).
  `eco_embed.hpp` includes `"eco_embed.h"` (same directory), so it works from the installed tree
  and from the source tree alike.
- **Where they land.** The tarball unpacks to `<prefix>` with `bin/eco` beside `include/`. The
  `.deb` installs under `/usr/local` (`cmake/CPackProjectConfig.cmake`), so
  `#include <eco/eco_embed.hpp>` works there with no `-I`. For a tarball:
  `-I <dir of bin/eco>/../include`.
- **Docs.** A new `docs/embedding.md` covers building a `.so`, the headers, the C and C++ APIs,
  the threading rules (callbacks on the eco thread, borrowed data valid for the call, no emit or
  send from the idle hook), and both the synchronous and asynchronous patterns. It is linked from
  `docs/options.md`'s host C API row and from `docs/getting-started.md`.
- **Smoke test.** `docker/static-build.Dockerfile`'s glibc-smoke stage stops copying
  `runtime/src/embed/eco_embed.h` from the source tree. It compiles `echo_host.c` with
  `-I/opt/eco/include`, and `echo_host.c` changes to `#include <eco/eco_embed.h>`; in-tree builds
  use `-I runtime/include`. It also builds and runs a new C++ host,
  `test/embed/bytes_host.cpp`, against `/opt/eco/include` and a `.so` of
  `test/embed/BytesEchoService.elm`.

## 3. Invariants

**New HEAP_083, NO COLLECTION INSIDE A HOST CALLBACK** (Runtime_Heap; NoCollectScope; enforced):
> While ThreadLocalHeap::no_collect_depth_ > 0 no pause may start: PauseEndHook's constructor
> aborts in every build with "[gc] FATAL: a collection started inside a host callback (HEAP_083)".
> PortRuntime holds a NoCollectScope around every host callback it makes on the eco thread
> (deliverOutgoing, deliverOutgoingBytes), because the stack walk stops silently at a frame it
> cannot unwind (StackUnwind), and a host frame without unwind information would hide the
> compiled Elm frames below it. Everything the runtime does on a host's behalf inside such a
> callback uses non-collecting operations only (Allocator::allocateFast,
> OldGenSpace::allocateLargeBody, malloc).
> Source: runtime/src/allocator/ThreadLocalHeap.hpp|runtime/src/allocator/ThreadLocalHeap.cpp|runtime/src/platform/PortRuntime.cpp

**New PORT_010, BORROWED AND EMITTED BYTES** (CrossPhase; Ports; enforced):
> **Borrowed subscribers.** An outgoing bytes port's borrowed subscriber
> (eco_port_subscribe_borrowed) gets an eco_borrowed_bytes whose data is valid for the whole call
> (HEAP_083). eco_borrowed_retain returns a refcounted, immutable copy that may be released on any
> thread. Interim and borrowed subscribers share one list per port, called in subscription order.
> A subscriber's destroy(user) runs exactly once, after the subscription is removed and no
> delivery can reach it, never under a runtime lock.
>
> **Emitting.** eco_port_emit takes the direct path only on the eco thread inside
> deliverOutgoing or deliverOutgoingBytes (t_inHostCallback). It allocates the Bytes value without
> collecting (tryAllocByteBufferNoCollect), runs fill with the object fixed in place, gives a short
> fill the form allocByteBuffer(n) would make (an in-place logical shrink of a young large header,
> or an exact non-collecting copy), and queues the value as a Heap PendingSend. When the
> allocation fails it falls back to the off-heap path. Every other emit fills a malloc'd buffer
> that goes through sendIncomingBytes.
>
> **The queue.** Heap PendingSends are rooted by the port root scanner, which takes pendingMutex_
> after, never inside, portsMutex_, and are skipped in a later heap generation.
> drainPendingSends handles only the items queued when it started. A stop hook drops queued items,
> calling their release functions and releasing their holds.
> Source: runtime/src/platform/PortRuntime.cpp|runtime/include/eco/eco_embed.h|runtime/include/eco/eco_embed.hpp

**New PORT_011, PORT HANDLES** (CrossPhase; Ports; enforced):
> A port's registry entry (struct eco_port, PortRuntime::ports_) is its handle. Entries are never
> erased and their addresses survive rehashing, so an eco_port* from eco_port_get is valid for the
> life of the process; a test heap reset only sets its kind back to ECO_PORT_UNREGISTERED. The kind
> is an atomic, published with release ordering at registration and read with acquire ordering by
> every handle operation. After registration the runtime never looks a port up by name: port
> managers capture the eco_port* (PK_Int), deliveries take it, and queued sends carry it. The
> name-based host functions are wrappers over eco_port_get plus the handle operation.
> Source: runtime/src/platform/PortRuntime.hpp|runtime/src/platform/PortRuntime.cpp|runtime/include/eco/eco_embed.h

**Amendments:**
- **PORT_004:** the scanner also evacuates queued Heap pending sends (lock order as above). "All
  strings crossing the host C ABI ... no GC interaction off the eco thread" gains: "and so do
  borrowed and owned bytes. A direct emit allocates on the eco thread inside a callback, but never
  collects (HEAP_083)."
- **PORT_006:** a callback may re-enter through eco_port_send, eco_port_send_bytes,
  eco_port_emit, the eco_borrowed_* functions and eco_owned_*. The scheduler idle hook may
  call none of the queueing functions.
- **PORT_008:** "Nothing allocates on the Elm heap between taking the view and the callbacks'
  return, so no collection moves the bytes" becomes "Nothing *collects* between taking the view
  and the callbacks' return (HEAP_083), so the bytes do not move; a direct emit may allocate
  without collecting." Also: "release is called exactly once, also when the payload is dropped,
  including at program stop."
- **HEAP_SNAPSHOT_001:** no change. Fills write young objects that have not survived a GC. A large
  body is pointer-free and owned by a young header (HEAP_026), as encoders already rely on
  (`BytesOps.cpp:172`).

## 4. Implementation steps

Before touching `runtime/src/allocator/`, read `design_docs/invariants.csv` (the HEAP rows above)
and `test/tla/README.md`. The changes in step 1 sit outside every `TLA-REGION` block. If
`tla-canary` fires anyway, investigate the models it names; never just repair the hash.

### Step 1: NoCollectScope (allocator)

`runtime/src/allocator/ThreadLocalHeap.hpp`:
- Add a private member `int no_collect_depth_ = 0;` next to `pause_depth_`, with a comment citing
  HEAP_083.
- Add the public methods `void enterNoCollect() { ++no_collect_depth_; }`,
  `void exitNoCollect() { --no_collect_depth_; }` and
  `bool inNoCollect() const { return no_collect_depth_ > 0; }`.

`runtime/src/allocator/ThreadLocalHeap.cpp`, in `PauseEndHook`'s constructor, *before*
`++h.pause_depth_`:
```cpp
if (__builtin_expect(h.no_collect_depth_ != 0, 0)) {
    std::fprintf(stderr, "[gc] FATAL: a collection started inside a host callback (HEAP_083)\n");
    std::fflush(stderr);
    std::abort();
}
```

`runtime/src/allocator/Allocator.hpp`: add an RAII guard next to the other helpers. It is not
copyable, and is a no-op when the thread has no heap:
```cpp
// Forbids a collection on this thread for its lifetime (HEAP_083).
class NoCollectScope {
public:
    NoCollectScope() : h_(Allocator::instance().getCurrentThreadHeap()) { if (h_) h_->enterNoCollect(); }
    ~NoCollectScope() { if (h_) h_->exitNoCollect(); }
    NoCollectScope(const NoCollectScope&) = delete;
    NoCollectScope& operator=(const NoCollectScope&) = delete;
private:
    ThreadLocalHeap* h_;
};
```
Check whether `getCurrentThreadHeap` or `getThreadHeap` is the public one, and use it.

### Step 2: Non-collecting Bytes allocation (allocator)

`ThreadLocalHeap` gets a new public method, with a matching forwarding method on `Allocator`:
```cpp
// Allocates a Bytes value of `length` bytes (1..UINT32_MAX) without collecting, and returns it with a pointer
// to write the bytes through, or {hp = 0, bytes = null} when that is impossible without a collection. The
// form is the one allocByteBuffer(length) makes. Small: nursery bump. Large: a nursery
// LargeByteHeader + an un-zeroed body. The bytes are not written. A pointer into a small object is valid
// until the next collection; one into a large body stays valid while the value is reachable. HEAP_083.
BlankByteBuffer tryAllocByteBufferNoCollect(size_t length);
```
Its body:
1. `total = roundup8(sizeof(ByteBuffer) + length)`.
2. If `total < config_->large_object_threshold`:
   - `void* p = allocateFast(total)`; if `!p`, return the failure value.
   - `initHeaderForTag(getHeader(p), Tag_ByteBuffer, total)`, then set
     `static_cast<ByteBuffer*>(p)->header.size = length`. This is exactly what `allocByteBuffer`
     does through `eco_alloc_with_roots`.
   - Return `{parent_->wrap(p), buf->bytes, length}`.
3. Otherwise (large), copy `allocLargeByteBuffer`'s single attempt, leaving out its `minorGC`,
   `majorGC` and `memset`:
   - `void* hobj = allocateFast(sizeof(LargeByteHeader))`; if null, return the failure value.
   - `initHeaderForTag(getHeader(hobj), Tag_LargeByteHeader, sizeof(LargeByteHeader))`, set
     `header.size = length`, set `body = hpFromBits(0)`.
   - `void* body = old_gen_.allocateLargeBody(roundup8(length), length, Tag_ByteBuffer, nursery_.minor_color_)`.
     If it is null, return the failure value. The header is left behind with a null body, the same
     as `allocLargeByteBuffer`'s retry path does.
   - Set `h->body = parent_->wrap(body)`, call `noteDirectAlloc(roundup8(length))`, and return
     `{header_hp, largeBytesData(h), length}`.
   - Check how `allocLargeByteBuffer` initialises the header (`allocate(header_size, Tag_LargeByteHeader)`)
     and do the same initialisation.

The wrapper is `BlankByteBuffer Allocator::tryAllocByteBufferNoCollect(size_t)`.

`BlankByteBuffer` lives in `HeapHelpers.hpp`. If including that from the allocator headers would
create a cycle, define a small `struct NoCollectBytes { HPointer hp; u8* bytes; }` in
`ThreadLocalHeap.hpp` instead.

### Step 3: PortRuntime internals (`runtime/src/platform/PortRuntime.{hpp,cpp}`)

**3.0 Handles (do this first; every later sub-step uses them).**
- Move `PortInfo` to global scope as `struct eco_port` in `PortRuntime.hpp`, and add
  `using PortInfo = ::eco_port;` in the namespace. Add the fields `std::string name;` (set when the
  entry is created) and `std::atomic<int> kind{ECO_PORT_UNREGISTERED};`. Keep `registered`,
  `incoming` and `bytes` as they are (all under `portsMutex_`), and set `kind` from them with
  `store(release)` wherever they change: in the three `register*` functions, and in the
  heap-reset block of `ensureRuntimeHooks`. `std::atomic` makes the struct non-copyable;
  `ports_[name]` default-constructs in place, so nothing copies it, but check every use.
- `eco_port* PortRuntime::get(const char* name)`: null for null; otherwise
  `lock; auto& p = ports_[name]; if (p.name.empty()) p.name = name; return &p;`.
- `int PortRuntime::kindOf(const eco_port* p)`: `p ? p->kind.load(acquire) : -1`.
- Every existing name-based function (`sendIncoming`, `sendIncomingBytes`, `subscribeOutgoing*`,
  `unsubscribeOutgoing*`) gets a handle overload that does the work; the name overload becomes
  `return handleOverload(get(name), ...)`. The checks that used `it->second.registered && ...`
  read `kind` instead.
- `buildPortManager(eco_port* port, bool incoming, bool bytes)`: capture with
  `closureCapture(clPtr, unboxedInt(static_cast<i64>(reinterpret_cast<intptr_t>(port))), PK_Int)`
  instead of the name string. The evaluators read `reinterpret_cast<eco_port*>(args[0])`. Check how
  an existing kernel evaluator reads an unboxed Int capture from `args[]`, and copy that exactly.
  `elmStringToStd` then has no callers in this file except error paths; delete it if unused.
- `setIncomingSubs(eco_port*, HPointer)`, `deliverOutgoing(eco_port*, const std::string&)` and
  `deliverOutgoingBytes(eco_port*, const uint8_t*, size_t)` replace the name forms. The
  `PlatformRuntime` registration stays by name.
- `PendingSend::name` becomes `eco_port* port`.

**3a. Sinks.**
- Add `struct Sink { enum Kind { Json, Interim, Borrowed } kind; EcoPortCallback json = nullptr;
  EcoPortBytesCallback interim = nullptr; EcoPortBorrowedCallback borrowed = nullptr;
  void* user = nullptr; EcoDestroyFn destroy = nullptr; ~Sink() { if (destroy) destroy(user); } };`
- Change both `PortInfo::sinks` (JSON) and `PortInfo::byteSinks` to
  `std::vector<std::shared_ptr<Sink>>`. JSON sinks gain `destroy` through the new
  `eco_port_subscribe_json`; the old `eco_port_subscribe` passes none.
- `subscribeOutgoingBytes` and `unsubscribeOutgoingBytes` work on `Interim` sinks, matching
  `(interim, user)`.
- The new `subscribeOutgoingBorrowed(port, cb, user, destroy)` and
  `unsubscribeOutgoingBorrowed(port, cb, user)` mirror them on `Borrowed` sinks.
- Copy the flush loop from `subscribeOutgoingBytes`. The flush calls the borrowed `cb` with a
  plain `eco_borrowed_bytes` over the buffered copy, without `t_inHostCallback` and without a
  `NoCollectScope`; any emit it makes takes the off-heap path.
- In both unsubscribes, move the `shared_ptr` out under the lock and let it go after the
  `lock_guard` scope ends:
  `std::shared_ptr<BytesSink> victim; { lock; victim = std::move(*it); sinks.erase(it); } return true;`
  `victim` is destroyed outside the lock.
- Add the type aliases `EcoPortBorrowedCallback` and `EcoDestroyFn` next to `EcoPortBytesCallback`,
  and declare them identical to the C typedefs.

**3b. The borrowed struct.** In `PortRuntime.hpp`, outside the namespace, so that the C name matches
`eco_embed.h`:
```cpp
struct eco_borrowed_bytes { const uint8_t* data; size_t length; };
```
It has no HPointer: nothing collects during the call, so `data` stays valid (HEAP_083). A future
pinning `retain` adds a field here; the struct is opaque to hosts.

**3c. Delivery.** Rewrite `deliverOutgoingBytes(port, data, length)`:
- Copy `byteSinks` (the `shared_ptr` copies) under the lock, as today, including the
  buffer-if-never-subscribed branch.
- Release the lock. Then set `t_inHostCallback = true` (save and restore the previous value with
  a small RAII type), construct one `NoCollectScope`, and build one
  `eco_borrowed_bytes b{data, length}`.
- For each sink, call `interim(data, length, user)` or `borrowed(&b, user)` according to its kind.
- Drop the copy *after* resetting the flag and the scope. A `destroy` that runs as the copy goes
  is ordinary host code with no runtime lock held.

Change `deliverOutgoing` (JSON) the same way: `t_inHostCallback` plus a `NoCollectScope` around its
callback loop. Its `json` is a `std::string`, so nothing else changes.

`portOutgoingBytesOnEffectsEvaluator` is unchanged: its single `view` stays valid, because nothing
collects inside `deliverOutgoingBytes`. Update its comment to cite HEAP_083 instead of "nothing
allocates".

**3d. Thread-locals.** In the anonymous namespace of `PortRuntime.cpp`:
```cpp
thread_local bool t_inHostCallback = false;  // Set only by deliverOutgoing{,Bytes} on the eco thread.
thread_local bool t_inFill = false;          // Set while a fill function runs.
```

**3e. Emit.** Add
`int PortRuntime::emit(eco_port* port, size_t capacity, EcoBytesFill fill, void* user)`
implementing §2.4 and §2.5 exactly:
1. Validate:
   - `port` and `fill` non-null and `capacity <= UINT32_MAX`, else 1;
   - if `t_inFill` is set, return 4;
   - `kindOf(port) == ECO_PORT_IN_BYTES` (lock-free, §2.11), else 1.
2. If `t_inHostCallback && !testForceOffHeap_`, try `Allocator::instance().tryAllocByteBufferNoCollect(capacity)`.
   Skip the allocation when `capacity == 0` and use `out = nullptr`.
3. **On success (direct):**
   - Set `t_inFill = true` with an RAII reset, then `size_t n = fill(blank.bytes, capacity, user)`.
   - Handle cancel (2) and overrun (3), with overrun calling `portCrash` under `ECO_HEAP_VALIDATE`.
   - Compute the result HPointer per §2.5. For the exact copy, use `tryAllocByteBufferNoCollect(n)`
     and `std::memcpy(exact.bytes, blank.bytes, n)`. If that allocation fails, go to step 5 with
     `src = blank.bytes`.
   - For the in-place shrink, `static_cast<LargeByteHeader*>(Allocator::instance().resolve(blank.hp))->header.size = n`.
   - `enqueueHeap(port, result)`, `++emitStats_.direct`, return 0.
4. **On failure, or off the callback (off-heap):**
   - `buf = malloc(max(capacity,1))`, or return 5.
   - Run `fill` under `t_inFill`. On a cancel or overrun, `free` and return 2 or 3.
   - Then step 5 with `src = buf, owned = true`.
5. **Off-heap queueing step:**
   - If `src` isn't an owned malloc buffer, `malloc(n)` and `memcpy`. If that malloc fails, return 5.
   - Call `sendIncomingBytes(port, buf, n, &freeRelease, buf)`. If it returns false, `free(buf)` and
     return 1.
   - Increment `emitStats_.offHeap` or `emitStats_.fallback` (fallback when the direct path was
     tried but its allocation failed). Return 0.

`static void freeRelease(void* p) { std::free(p); }`

**3f. Heap pending sends.**
- Add `enum class Kind : uint8_t { Json, Bytes, Heap } kind = Kind::Json;` to `PendingSend`
  (replacing `bool bytes`, and updating every use), plus `uint64_t value = 0; uint64_t generation = 0;`.
- `enqueueHeap(port, hp)` builds an item with `kind = Heap`, `value = encodeHP(hp)` and
  `generation = Allocator::instance().heapGeneration()`, then calls `enqueueSend`. `enqueueSend`
  takes the hold and notifies; both are safe on the eco thread inside a callback (PORT_006 already
  allows `eco_port_send` there).
- In the drain, for `Kind::Heap`:
  - Check that the port is registered, incoming and bytes, as for Bytes.
  - If `item.generation != heapGeneration()`, continue (the `HoldRelease` releases the hold).
  - `payload = decodeHP(item.value)`, which is already inside the `StackRootGuard` that covers
    `payload`. Assign it before any allocation. Nothing allocates between the pop and this
    assignment, which is the existing structure.

**3g. Scanner.** In `ensureRuntimeHooks`'s scanner lambda, after the `portsMutex_` block:
```cpp
{
    std::lock_guard<std::mutex> lock(pendingMutex_);
    const uint64_t g = Allocator::instance().heapGeneration();
    for (auto& item : pendingSends_)
        if (item.kind == PendingSend::Kind::Heap && item.generation == g) evacuate(item.value);
}
```
Check that `evacuate` accepts a `uint64_t&` the way it does for `info.decoder`.

**3h. Bounded drain.**
- At the top of `drainPendingSends`, read `size_t budget = pendingSends_.size()` under the lock.
- Loop while `budget-- > 0` and the queue is non-empty.
- If items remain afterwards, call `Scheduler::instance().notifyWorkAvailableFromAsync()`, so that
  the loop comes back for them. `hasPendingSends` already reports them.

**3i. Stop hook.**
- In `ensureRuntimeHooks` (inside the `!hooksInstalled_` block), call
  `Scheduler::instance().addStopHook(&PortRuntime::dropPendingAtStop)`.
- Add `static void dropPendingAtStop()`. It swaps `pendingSends_` out under the lock, then for each
  item calls `release(ctx)` if it is set and releases its hold with `HoldRelease`.
- Check the `StopHook` type: if it is a plain function pointer, use a static function.

**3j. Owned bytes.**
- In `PortRuntime.cpp` (C++ inside, C ABI outside):
  `struct eco_owned_bytes { std::atomic<size_t> refs; size_t size; uint8_t bytes[1]; };`
  allocated with `malloc(offsetof(eco_owned_bytes, bytes) + max(size,1))` and placement-newed.
- `retain` sets `refs = 1` and copies.
- `unref` does `if (o->refs.fetch_sub(1, std::memory_order_acq_rel) == 1) { o->~eco_owned_bytes(); free(o); }`.
- `ref` does `fetch_add(1, relaxed)`.
- `data` returns null when `size == 0`.

**3k. Test hooks.** These are public, documented "tests only", and not in the C ABI:
- `void setEmitForceOffHeapForTest(bool)` makes the direct path act as if allocation failed, so
  the fallback is exercised.
- `struct EmitStats { std::atomic<uint64_t> direct, offHeap, fallback; } emitStats_;` with a getter.
- `void setCollectAtNextDrainForTest(bool)`. When set, the next `drainPendingSends`:
  1. records the `value` bits of the first Heap item;
  2. calls `Allocator::instance().minorGC()` and then `majorGC()` (runtime frames only, outside any
     callback, which is legal);
  3. aborts with "port test: queued heap value did not move" if the bits are unchanged.

  It then clears itself. This proves the scanner sees and updates the item.

### Step 4: C ABI (`runtime/include/eco/eco_embed.h`, `runtime/src/embed/eco_embed.cpp`, the weak copies in `PortRuntime.cpp`)

- Move `runtime/src/embed/eco_embed.h` to `runtime/include/eco/eco_embed.h`. Every includer switches
  to `#include <eco/eco_embed.h>`, and every target that compiles one gets `runtime/include` on its
  include path: `EcoEmbedStatic`, `EcoNodeGlue`, `EcoEntryStatic` (`eco_entry.cpp`), the `test`
  binary, and `aot-port-host` if it starts including it.
- Add to `eco_embed.h`, each with a doc comment in the existing style:
  - a "---- Port handles ----" section (§2.11);
  - a "---- Bytes ports: borrowed, owned and emitted ----" section (§2.2–§2.4), with the
    `ECO_PORT_*`, `ECO_EMIT_*` and `ECO_FILL_CANCEL` defines.
- Update the header's top comment: ports carry JSON text or, for a bytes port, raw bytes; the C++
  layer lives in `eco_embed.hpp`; and there is a note for embedders that no collection runs inside
  a callback, with what follows from that.
- Add strong definitions in `eco_embed.cpp` and `ECO_PORT_ABI_WEAK` definitions in
  `PortRuntime.cpp`, mirroring `eco_port_send_bytes`, and declare the prototypes in
  `PortRuntime.hpp`'s `extern "C"` block.
- Add the new functions to `design_docs/kernel-boundary/audit-07-runtime-surface.md`'s ABI list.

### Step 5: Test harnesses

- `test/ElmE2ETestBase.hpp`: in `installPortEchoBounce` (behind its existing `static` once-flag),
  also install the emit harness: `static eco::BytesOutPort out{"emitOut"}; static eco::BytesInPort
  in{"emitIn"}; static eco::Subscription sub = out.subscribe(emitHarness);`. Include
  `<eco/eco_embed.hpp>`, so that the C++ layer itself is tested in-process. The handles are made
  before any program registers its ports, which exercises the placeholder path.
- `test/aot_port_host.cpp`: `dlsym`-bind `eco_port_get`, `eco_port_subscribe_borrowed`,
  `eco_borrowed_data`, `eco_borrowed_size`, `eco_borrowed_retain`, `eco_owned_*` and
  `eco_port_emit`, and implement the same harness in plain C ABI calls, with no path checks
  (see the table below).
- The emit harness protocol (shared by both hosts). An `emitOut` payload is `[op, body...]`, and the
  host emits into `emitIn`:

| op | the host does | expects (JIT only: checked against `emitStats` deltas) |
|---|---|---|
| 0 | emit `reverse(body)`, `capacity = len` | direct +1 |
| 1 | same, `capacity = len + len/2 + 1` (short fill, `2n >= capacity`) | direct +1 |
| 2 | same, `capacity = 4*len + 64` (short fill, exact copy) | direct +1 |
| 3 | an emit whose fill cancels, then emit `[rc]` | rc == 2 |
| 4 | inside a fill, call emit again, write `[rc]` | rc == 4 |
| 5 | a `std::thread` emits `reverse(body)`; the callback joins it | offHeap +1 |
| 6 | `retain()`, hand the `OwnedBytes` to a thread that waits until the callback has returned, then emits `reverse(owned)` and drops it | offHeap +1 |
| 7 | `setEmitForceOffHeapForTest(true)`, op 0, reset | fallback +1 |
| 8 | `setCollectAtNextDrainForTest(true)`, op 0 | direct +1, and the drain hook proves the move |

  Op 6's thread must not outlive the program run. The callback records the thread, and the
  harness joins it before the next op or at stop: keep a `static std::thread` and join it at the
  start of each op.

  If an expectation fails, the JIT host emits `[0xEE]` instead, which the program logs as
  `mismatch`, so the CHECK fails. The AOT host performs ops 0–6 the same way, skips the
  expectations, and treats 7 and 8 as 0.

### Step 6: The C++ header (`runtime/include/eco/eco_embed.hpp`)

The header is header-only C++20, includes only `"eco_embed.h"` and the standard library, and
compiles cleanly with `-Wall -Wextra -Werror` under GCC and Clang. Contents, in order:

1. `enum class EmitResult { Queued, NotAPort, Cancelled, Overrun, Nested, NoMemory }` (values
   0–5, matching `ECO_EMIT_*`), and `enum class SendResult { Queued, NotAPort, Rejected }`.
2. **`OwnedBytes`.** It holds an `eco_owned_bytes*`.
   - The copy constructor calls `eco_owned_ref`; assignment is copy-and-swap; the move
     constructor nulls the source; the destructor calls `eco_owned_unref`.
   - `view()` returns an empty span when it holds nothing.
   - Only `BorrowedBytes::retain` constructs a non-empty one, through a private constructor and a
     `friend`.
3. **`BorrowedBytes`.** It holds a `const eco_borrowed_bytes*`.
   - Copy and move are deleted. A private constructor is reached through
     `struct detail_access { static BorrowedBytes make(const eco_borrowed_bytes*); }`; guaranteed
     copy elision makes a prvalue return legal for a non-movable type.
   - `view()`, `size()` and `retain()`; `retain()` throws `std::bad_alloc` on NULL.
4. **`Subscription`.** It holds `{eco_port* port; int kind /*json or borrowed*/; void* cb; void* user}`.
   - Move-only. `reset()` calls `eco_port_unsubscribe_json` or `eco_port_unsubscribe_borrowed`
     according to `kind`, then clears itself. The destructor calls `reset()`.
   - Only the port classes construct one.
5. **`namespace detail`.**
   - `resolve(const char* name, int want)`: `eco_port_get`, then throw `std::invalid_argument`
     ("eco: port 'x' is not an incoming bytes port") if the kind is neither `want` nor
     `ECO_PORT_UNREGISTERED`.
   - `abortOnException(const char* what)`: print to stderr and `std::abort()`.
   - `template<class Fn> struct SubscriberThunks`, with `static void borrowed(const
     eco_borrowed_bytes*, void*)`, `static void json(const char*, void*)` and `static void
     destroy(void*)`. Each call body is wrapped in `try { … } catch (const std::exception& e) {
     abortOnException(e.what()); } catch (...) { abortOnException(nullptr); }`.
   - Because each `Fn` gets its own function, `(cb, user)` is unique per subscription.
6. **`BytesOutPort`, `BytesInPort`, `JsonOutPort` and `JsonInPort`.** Each holds one `eco_port*`
   and is copyable. Each has an `explicit` constructor from `const char*` that calls
   `detail::resolve` with its kind, plus `handle()` and `name()`.
   - **`subscribe(F)`** (both Out ports): `static_assert` that `F` is invocable with the right
     argument; `new` the decayed functor; call `eco_port_subscribe_*` with
     `SubscriberThunks<Fn>::…` and `destroy`. On failure, `delete` the functor and throw
     `std::invalid_argument`. Return the `Subscription`.
   - **`BytesInPort::emit(capacity, F&&)`:** a local `struct Ctx { std::remove_reference_t<F>* f;
     std::exception_ptr ex; }`.
     - The captureless trampoline builds `std::span<std::byte>(reinterpret_cast<std::byte*>(out),
       cap)`.
     - `if constexpr` on whether `F` returns `std::optional<std::size_t>`: nullopt maps to
       `ECO_FILL_CANCEL`.
     - It catches into `ex` and returns `ECO_FILL_CANCEL`.
     - After `eco_port_emit`, rethrow `ex` if it is set; otherwise return the `EmitResult`.
   - **`BytesInPort::send(Buffer&&)`:** `eco_port_send_buffer` with a release that does
     `delete[] static_cast<std::byte*>(p)`. On success, release the `unique_ptr` and zero the
     buffer; on failure, leave the buffer with the caller and return `NotAPort`.
   - **`JsonInPort::send(const std::string&)`:** map `eco_port_send_json`'s 0, 1 and 2 to
     `SendResult`.
7. **`Buffer`.** It holds `std::unique_ptr<std::byte[]>` (allocating `max(capacity,1)`), a
   capacity and a size. `writable()` returns the span; `setSize(n)` throws `std::length_error` past
   the capacity; `size()`. `BytesInPort` is a friend.

### Step 7: Divergence D5 (done: not observed)

- `test/embed/ValuesService.elm` gains the ports `orderGo`, `orderOut`, `orderIn` and `orderLog`.
  Its model records the order of the two `update` calls ("in" for the send from the subscriber,
  "task" for the Task of the same batch) and reports it on `orderLog`.
- `test/embed/embed_host.js` gains the scenario `order`, which prints the order in the transcript,
  so the parity check requires both modes to agree. Both give `task,in`.
- D5 is listed in `plans/native-bytes-ports.md`'s parity list as predicted and not observed.

### Step 8: Docs

- `design_docs/theory/runtime/scheduler-and-services.md`, "Ports and embedding": add a paragraph on
  borrowed and emitted bytes, the no-collection-in-callback rule and why (stack walk), and D5.
- `design_docs/invariants.csv`: add HEAP_083 and PORT_010, and amend PORT_004, PORT_006 and
  PORT_008 as in §3.
- `docs/options.md`: add rows for the new host functions next to `eco_app_start`.
- Set this plan's front matter to `status: done` and update `updated`.

### Step 9: Ship the headers

1. Add an `install(DIRECTORY ${CMAKE_SOURCE_DIR}/runtime/include/eco/ DESTINATION include/eco
   COMPONENT <comp> FILES_MATCHING PATTERN "*.h" PATTERN "*.hpp")` to each of the three bundle
   blocks in the top-level `CMakeLists.txt` (`Bundle`, `BundleDarwin`, `BundleWindows`). Update the
   "Layout produced" comment to list `<prefix>/include/eco/`.
2. Write `docs/embedding.md` (§2.12) and link it from `docs/options.md`'s `eco_app_start` row and
   from `docs/getting-started.md`.
3. Switch `test/embed/echo_host.c` and `kafka_host.c` to `#include <eco/eco_embed.h>`, and fix
   their "Build:" comments to say `-I <eco>/include` (in-tree: `-I runtime/include`).
4. Write `test/embed/bytes_host.cpp`, a C++ host over a `.so` of `test/embed/BytesEchoService.elm`.
   - Read that fixture's ports first, and use its outgoing and incoming bytes port names.
   - It subscribes with `eco::BytesOutPort`, emits each payload back reversed through
     `eco::BytesInPort::emit`, and prints `HOST got N` lines.
   - Model its lifecycle on `echo_host.c`: start, wait for idle through the idle hook, stop, join.
5. In `docker/static-build.Dockerfile`'s glibc-smoke stage:
   - delete the `COPY runtime/src/embed/eco_embed.h …` line and the comment about it;
   - compile `echo_host.c` with `-I/opt/eco/include`;
   - install `g++` and build `bytes_host.cpp` with `g++ -std=c++20 -Wall -Wextra -Werror
     -I/opt/eco/include … build/bytes.so`, run it, and grep its expected lines;
   - add `test -f /opt/eco/include/eco/eco_embed.h && test -f /opt/eco/include/eco/eco_embed.hpp`.
6. Add a local build check (the docker smoke test is not part of the local gates): two
   object-library targets in `test/CMakeLists.txt`, `embed-header-c` and `embed-header-cxx`. They
   compile one-line TUs (`#include <eco/eco_embed.h>` as C99, and `#include <eco/eco_embed.hpp>` as
   C++20) with `-Wall -Wextra -Werror` and only `runtime/include` on the include path. That proves
   the headers are self-contained. Add both to the `test` target's dependencies.

## 5. Tests

All run under the JIT, and also under AOT where noted. Run them once into a log
(CLAUDE.md "Running Tests").

- **T1. `test/eco-divergence/src/PortBytesEmitTest.elm`** (JIT + AOT). Ports `emitOut : Bytes ->
  Cmd msg` and `emitIn : (Bytes -> msg) -> Sub msg`. The program sends one payload per op from §4
  step 5, one at a time, and logs `(op, width, sum)` or the status byte.
  - Bodies for ops 0–2: length 0, 1, 31, 32, 4,000, 6,000 and 20,000, which covers the empty, flat and
    large forms and both short-fill rules (a 20,000-byte body with op 2 has a capacity of 80,064:
    large, and copied exactly into the large form).
  - Expected CHECK lines are computed from the bodies (reverse keeps the sum and width). Op 1 with a
    6,000-byte body gives capacity 9,001: large, `n=6,000`, so `large(6000)` is false and it goes
    to an exact flat copy. Op 1 with a 20,000-byte body gives an in-place shrink. List those two
    cases explicitly.
- **T2. Fallback (op 7) and scanner (op 8)** are in T1's JIT run.
- **T3. Validate build.** Run T1 in build-validate with `ECO_NURSERY_POISON=1`. A missed scanner
  update then reads poison instead of stale-but-correct bytes.
- **T4. `test/allocator/NoCollectScopeTest.cpp`** (unit, isolated suite).
  - A `ForkedChild::runInChild` scenario enters a `NoCollectScope` and calls
    `Allocator::instance().minorGC()`. Expect `SIGABRT` and the HEAP_083 message on stderr.
  - A second scenario does the same with `majorGC()`.
  - A control scenario calls `minorGC()` after the scope has ended and expects success.
- **T5. `test/allocator/NoCollectBytesTest.cpp`** (unit).
  - `tryAllocByteBufferNoCollect` for lengths 1, 8,000 (flat) and 8,184+ (large; use the boundary
    `large_object_threshold - sizeof(ByteBuffer)` and one above it), with the minor and major
    counts unchanged.
  - With the nursery bump at its limit (use the existing unit-test helper that fills the nursery to
    the threshold, e.g. from `EnsureHeadroomTest`), it returns the failure value and still does not
    collect.
  - A filled buffer survives a following `minorGC()` with its bytes intact (it is rooted in the
    test).
- **T6. `test/platform/OwnedBytesTest.cpp`** (unit). Ref and unref from 8 threads over 100k
  iterations, then a final unref. Run under the existing TSan configuration if one covers
  `test/platform`; otherwise as a plain test.
- **T7. Interim unchanged.** `PortBytesEchoTest` and `PortBytesEchoSizesTest` stay green.
- **T8. Subscription lifetime** (JIT harness unit, or a `test/platform` test with a fake port).
  - Unsubscribe from inside the callback: `destroy` runs after the callback returns, exactly once.
  - Unsubscribe from another thread while the eco thread is inside the callback (synchronised with
    a latch): `destroy` runs only after the callback returns.
- **T9. D5 parity scenario** in `run-node-addon-tests` (§4 step 7). Both modes give `task,in`.
- **T10. Handles** (`test/platform/PortHandleTest.cpp`, unit, over a bare `PortRuntime` with no
  program; registration needs `PlatformRuntime`, so use the registration kernels the way an
  existing platform unit test does, or cover the registered cases in T1 instead).
  - `eco_port_get` on the same name returns the same pointer.
  - Before registration the kind is `ECO_PORT_UNREGISTERED`, and `eco_port_emit` and
    `eco_port_send_json` return 1.
  - `eco_port_get(NULL)` returns NULL.
  - The handle stays valid while another 10,000 names are created, which forces rehashes.
- **T11. Header self-containment**: the `embed-header-c` and `embed-header-cxx` targets build
  (§4 step 9.6).
- **T12. Shipped headers**: the glibc-smoke stage passes with both hosts built against
  `/opt/eco/include`. This runs in the docker release build, not in the local gates.
- **The gates:** `cmake --build build --target full` (JIT E2E), the AOT E2E, `elm-tests`, the
  stress suite, and `run-node-addon-tests`.

## 6. Adversarial review log (2026-11-06)

The first draft was reviewed against the code. Each finding and what was done with it:

| # | sev | finding | disposition |
|---|---|---|---|
| 1 | blocker | A collection inside a callback walks the stack through host frames, and the walk stops silently at an un-unwindable frame | **Redesigned.** No collection ever runs inside a callback (§2.1, HEAP_083, enforced). The direct path uses non-collecting allocation with an off-heap fallback. |
| 2 | major | The Direct mode could reach a flush on a host thread, or nest inside an interim callback | Only `deliverOutgoing*` sets the flag. With no collection there is no staleness, so nesting is harmless. |
| 3 | major | F5's claim of JS parity was false | Corrected (F7). Recorded as D5 with a parity test. When implemented, measurement showed both backends handle the Task first, so D5 is not observed (§2.10). |
| 4 | major | `Subscription` destructor use-after-free | The runtime owns `destroy` through `shared_ptr` sinks (§2.7). |
| 5 | major | The tests did not catch their target bugs | The scanner is proven by the drain hook (forced minor and major, assert moved), plus a poison run. The re-resolve tests were dropped with the rule they tested. |
| 6 | major | Exceptions could unwind through C and Elm frames | The subscriber trampoline aborts; the fill trampoline cancels and rethrows. |
| 7 | minor | The shrink premise was wrong for the large form | In-place logical shrink for the large form; exact copy otherwise (§2.5). Slices dropped (`makeByteBufferSlice` can collect). |
| 8 | minor | P1 wording for large bodies | Cited HEAP_026 and the encoder precedent. |
| 9 | minor | F2 named only allocation as a pause start | Lists safepoint polls and explicit collections. |
| 10 | minor | PORT_004 and PORT_008 text becomes false | Amended ("collects" instead of "allocates"). |
| 11 | minor | An emit from the idle hook deadlocks | Documented, same as `eco_port_send`. |
| 12 | minor | The large path zero-fills twice, and can abort when out of memory | The no-collect allocation skips the memset; failure falls back instead of aborting. |
| 13 | minor | Queued items are never released at stop | Stop hook (§2.6, 3i). |
| 14 | minor | The off-heap path can fail after fill | Result 1 with the buffer freed; documented. |
| 15 | minor | `ECO_FILL_CANCEL` on 32-bit | Eco is 64-bit only; stated. |
| 16 | minor | A ping-pong between ports starves the event loop | Bounded drain (3h). |
| 17 | minor | Missing work (AOT binds, harness once-flag, header comment, audit doc, headers' distribution) | Steps 4, 5 and 8. Distribution: see Later. |
| 18 | minor | Underspecified (thread, ordering, NULL `out`, empty retain) | Specified in §2.2–§2.4. |
| A | major | The draft's `retain` would have needed an HPointer slot | Not needed, since nothing moves during a callback. A future pin adds it. |
| B | (user, Nov 6) | Ports are named by strings, so every call does a hash lookup under a lock; and the headers are not shipped | Folded in: port handles (§2.11, PORT_011) and shipped headers (§2.12, step 9). |

## 7. Done when

- T1–T11 pass, and T12 passes in the next docker release build.
- The gates are green with no new failures against the current baselines.
- The invariants and docs are updated, and this plan's status is `done`.

## 8. Later

- `retain` pins large bodies (at least `large_object_threshold`) through a retained-bodies root
  registry instead of copying. Release must be queued to the eco thread.
- A lock-free sink snapshot per port (`std::atomic<std::shared_ptr<const SinkList>>`), replaced by
  subscribe and unsubscribe, so that a delivery takes no mutex at all.
- A compiler-generated `<program>_ports.hpp` declaring a typed handle for each port, from
  `MonoGraph.ports`, so that a misspelt port name is a C++ compile error.
- An emit that lets the host supply the destination as an existing Bytes value it builds over
  several callbacks. This would need builder-bit objects (HEAP_BUILDER_*).
- The general binary (heap-shaped) port format, which replaces JSON ports and lifts the
  nested-Bytes and Bytes-in-flags compile errors.

## 9. Implementation notes (2026-11-06)

What landed differs from the steps above in these places:

- **D5 is not observed** (§2.10). Measured, both backends handle the Task first, so the `order`
  scenario is a parity test, not a divergence.
- **Program stop** closes the incoming queue. `dropPendingAtStop` sets `stopped_`, and
  `enqueueSend` refuses items after it, so a send racing with stop returns 1 with its buffer still
  the caller's, instead of being queued and never released. The next registration reopens it.
- **The direct path also requires a thread heap** (`getCurrentThreadHeap() != nullptr`). It is a
  backstop for deliveries made on a heap-less thread, which only unit tests do.
- **The emit counters gained `shrunk`**, so that op 1 with a 20,000-byte body proves the in-place
  shrink ran whenever the emit went direct.
- **The harness accepts direct or fallback** for ops 0–4, because a nursery at its limit makes a
  correct emit fall back. Op 7 insists on the fallback, op 8 on direct, and ops 5 and 6 on off-heap.
- **`PortBytesEmitTest` keeps a `Time.every 20` subscription** while requests are outstanding. Its
  timer hold keeps the event loop up between op 6's callback and its thread's emit.
- **The AOT runner** (`aot_e2e_main.cpp`) routes a test that declares `emitOut` and `emitIn`
  through `aot-port-host`, as it does for `echoOut` and `echoIn`.
- **The unit tests live in one file**, `test/platform/PortBytesTest.cpp` (12 cases in the
  PlatformServices isolated suite), not in the separate files of §5.
- **Negative controls run:**
  - With the scanner's Heap-item evacuation removed, op 8 aborts ("queued heap value did not move").
  - With the harness expecting the wrong path for op 0, the test fails on `[0,0,0,-1,0]`.

**Gates (2026-11-06, after the review fixes):**

| gate | result |
|---|---|
| JIT unit + E2E (`check`) | 3,087/3,087 |
| AOT E2E | 1,477/1,477, 6 skipped |
| stress | 114/114 |
| node-addon parity | all passed, including `order` |
| JS E2E (in `full`) | 267/267, 8 skipped |
| PortBytes tests in build-validate with `ECO_NURSERY_POISON=1` | 4/4 E2E, 12/12 unit |
| C++ smoke host against a real `.so` | passes |

`elm-tests` was not run: no compiler source changed. T12 (the docker glibc smoke stage) runs in the
next release build.
