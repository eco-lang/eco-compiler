# Native Ports + Host Embedding (C and Node.js) Implementation Plan

## Status: IMPLEMENTED (2026-06-11) — all phases landed (0–5)

Phase 5 (flags) implementation notes:

- The flags decoder is synthesized in `Monomorphize.insertFlagsDecoderNode`
  (pre-AssignMVarIds) from the entry's dealiased `Program flags model msg`
  annotation using the same `Port.toFlagsDecoder` the JS pipeline uses,
  inserted as a synthetic `Define` under `Global home "main$flagsDecoder"`,
  enqueued alongside main, carried in `MonoGraph.flagsDecoder`, rooted by
  Prune, and registered at startup from the generated preamble via the new
  kernel `Elm_Kernel_Platform_registerFlagsDecoder`.
  `Elm_Kernel_Platform_worker` keeps its one-argument signature (Q12).
- `initWorker` decodes uniformly: host JSON (or `null` when absent) through
  the registered decoder; decode failure crashes with a clear message.
  Bare `null` with no registered decoder (a pre-flags artifact driven by a
  `flags: null` host) is tolerated as Unit; real flags against such an
  artifact crash with a "recompile" message.
- StressFlags is fully retired from PlatformRuntime: the struct lives in
  the test harness (ElmE2EBase::StressFlags + toJson()), and stress
  programs decode the harness JSON through their compiler-generated
  decoders. A `-- FLAGS: {...}` line-start directive in a test's Elm
  source feeds per-test flags JSON (see test/elm/src/FlagsRecordTest.elm).
- Validation: 1478/1478 JIT E2E (incl. new FlagsRecordTest), 100/100
  stress over the JSON path, C and Node flags round-trips, wrong-shape
  crash message, kafka worker unchanged-host run.

Implementation deltas vs the original design:

- **Compiler lowering happens in Specialize, not the MLIR backend.**
  `Specialize.specializePortNode` builds the leaf-wrapper as a proper
  zero-capture `MonoClosure` at the Mono level, so every GlobalOpt
  arity/staging invariant holds with no port special-casing downstream.
  The incoming decoder is enqueued as a *second specialization of the same
  Global* at its `Decoder payload` type (compiled as a plain `MonoDefine`
  value node) — no AST surgery, no `$decoder` name mangling; the spec id
  is carried in `MonoGraph.ports` and rooted by Prune (PORT_003).
- **gatherEffects routes through cmdMap/subMap only for NON-EMPTY tagger
  chains**; empty chains pass the leaf value through untouched. This keeps
  unmapped effects byte-identical to pre-ports behaviour (the dormant
  native cmdMap evaluators turned out to have real bugs —
  `taskCmdMapEvaluator` treated the mapper result as a Task; fixed).
- **No Make.elm changes were needed**: `.o`/`.so`/`.node` targets already
  fell through to the native driver, which now dispatches on the output
  extension (object-only / `-shared` + embed entry / + N-API glue +
  `elm.js` shim).
- **Teardown discipline**: hosts calling `exit()`/`process.exit()` without
  `eco_app_stop` are handled by an atexit hook registered on the eco
  thread plus leaking the Scheduler/PlatformRuntime/PortRuntime singletons
  (the runtime's existing TimerService/HttpService pattern).
- `CMAKE_POSITION_INDEPENDENT_CODE ON` globally (archives must be PIC for
  `.so` links); generated code was already `Reloc::PIC_`.

Validation: 1477/1477 JIT E2E tests (baseline 1476 + new PortEchoTest with
a harness echoOut→echoIn bounce); the elm-actor-kafka worker runs as a
standalone binary, embedded in a C host (test/embed/kafka_host.c), and as
a `.node` addon under its **unmodified** index.ts host logic.

Accepted divergences from the JS reference (post-review decisions):

- **Within-batch effect order is SOURCE order natively** (`Cmd.batch [a, b]`
  reaches the manager as a-then-b). JS delivers reverse source order — an
  artifact of `_Platform_insert` prepending. Elm documents batch order as
  unspecified; native source order is deterministic and was already the
  pre-ports native behaviour encoded in the test suite.
- **`eco_port_send` / `app.ports.x.send` are asynchronous**: the decode +
  update cycle run on the eco thread after the call returns (JS is
  synchronous, depth-first). Consequence: a decode failure crashes the app
  later rather than throwing synchronously at the send call site.
- **Outgoing callbacks racing a concurrent `eco_port_unsubscribe` on
  another thread may fire once after unsubscribe returns** (the sink list
  is snapshotted outside the lock). Hosts must not free callback user data
  until deliveries have quiesced.

---

## Context

Ports have never been designed into the native compiler. What exists today is
accidental and broken in two distinct ways, plus the runtime has one dormant
dispatch bug that ports cannot live without fixing:

1. **Outgoing ports lower to a bare encoder.** `port logPort : String -> Cmd msg`
   compiles to `@Main_logPort(s) = Json_Encode_string(s)` — it returns a wrapped
   Json value where a `Cmd` (an `Fx_Leaf` bag) is expected. No leaf is ever
   built, so the effect silently never reaches any manager.

2. **Incoming ports corrupt the heap.** `Compiler/GlobalOpt/MonoGlobalOptimize.elm`
   `wrapNodeCallables` (line ~1007) passes the port's *decoder* expression
   through `ensureCallableForNode` against the port's function type
   `(payload -> msg) -> Sub msg`. The decoder is a `Decoder payload` **value**
   (a `Tag_Custom`), not a closure, so `makeGeneralClosureGO` wraps it as
   `\tagger -> decoder(tagger)`. At runtime this emits
   `eco.papExtend(decoder, tagger)` which reads the decoder's custom fields as
   a Closure header. Observed crash (elm-actor-kafka worker example):

   ```
   eco_pap_extend: new_n_values (14) exceeds max_values (0)
   Assertion failed: val.bits != 0 && "eco_get_tag: null HPointer"
   ```

   (The "closure" was a `Tag_Custom` with size=2; `n_values=13`/`max_values=0`
   were decoder field bytes; `evaluator` was `0x60000cce`, not a code pointer.)

3. **`cmdMap`/`subMap` are registered but never invoked.** Native
   `PlatformRuntime::gatherEffects` (`runtime/src/platform/PlatformRuntime.cpp:354`)
   applies the accumulated `Fx_Map` taggers **directly to the leaf value**
   (`applyTaggers(taggers, value)` at line ~379). The JS kernel instead hands
   the tagger chain to the manager's map function:
   `effect = A2(map, applyTaggers, value)` (`Platform.js _Platform_toEffect`).
   Today the Time manager's `subMap` and Task manager's `cmdMap`
   (`elm-kernel-cpp/src/time/TimeEffectManager.cpp`,
   `elm-kernel-cpp/src/core/TaskEffectManager.cpp:196`) are dead code, and
   `Cmd.map f (Task.perform …)` natively applies `f` to the `Perform` custom
   itself — a latent correctness bug. For ports this indirection is
   *load-bearing*: an incoming-port sub value is a function (the tagger), and
   `Sub.map` over it must be **composition**, while an outgoing-port cmd value
   must **ignore** taggers entirely.

### Current state (verified by codebase exploration)

**Already in place — reusable as-is:**

- Effect-manager framework: `PlatformRuntime` manager registry
  (`ManagerInfo{init, onEffects, onSelfMsg, cmdMap, subMap}` as GC-scanned
  encoded HPointers, `PlatformRuntime.hpp:36`), per-manager self-process +
  Router custom (`setupEffects`, `PlatformRuntime.cpp:117`), effect queue +
  dispatch (`enqueueEffects`/`dispatchEffects`, lines 241–352), `sendToApp` /
  `sendToSelf`.
- Bag representation: `Fx_Leaf{home, value}` / `Fx_Node{list}` /
  `Fx_Map{tagger, bag}` customs built by `Elm_Kernel_Platform_leaf/batch/map`
  (`elm-kernel-cpp/src/core/PlatformExports.cpp`). Identical shapes to JS.
- Manager registration pattern from C++: `eco_register_time_effect_manager`
  builds evaluator closures with `allocClosure` and calls
  `PlatformRuntime::registerManager` (`TimeEffectManager.cpp`,
  `EffectManagerRegistry.cpp`).
- Scheduler with event loop, `pendingAsync` refcount, and the **async-source
  pattern** for cross-thread completion (worker thread enqueues plain data +
  `notifyWorkAvailableFromAsync()`; main thread drains via
  `registerAsyncSource(drain, ready)` — `Scheduler.hpp:79`,
  `Scheduler.cpp:521` `runEventLoop`). TimerService and HttpService already
  use it.
- Complete native Json kernel: `Elm_Kernel_Json_runOnString` (parse+decode),
  `Elm_Kernel_Json_encode` (stringify), `wrap/unwrap`
  (`elm-kernel-cpp/src/json/JsonExports.cpp:1505,1515,1541`).
- Compiler port converters: `Compiler/LocalOpt/Typed/Port.elm` already builds
  `toEncoder payload` (a `\payload -> Json.Value` lambda) and
  `toDecoder payload` (a `Decoder payload` value) per port;
  `Typed/Module.elm:299 addPort` stores them as `PortOutgoing` /
  `PortIncoming` graph nodes. (`toFlagsDecoder` also exists, unused natively.)
- Entry/link model: generated MLIR `@main` is renamed `eco_main`; the real C
  `main` lives in `runtime/src/codegen/eco_entry.cpp:269` → spawns
  `eco_main_thread` (big-stack pthread) → allocator init, stackmap parse,
  `__eco_init_globals`, `eco_register_all_effect_managers()`, `eco_main()`.
  `EcoNativeDriver.cpp:301 linkExecutable` emits one `.o` from MLIR and links
  it with the runtime/kernel static archives via a direct `ld` invocation.
  `eco-boot-native` already supports `--emit=obj`.

**Must be built:**

- Port registry + per-port pseudo effect managers (runtime).
- `gatherEffects` map-routing fix (runtime).
- Dedicated MLIR lowering for port nodes + registration preamble (compiler).
- Host embedding C API + library output modes (`.o`, `.so`) (runtime + driver).
- Node.js N-API addon glue + `.node` output + drop-in JS shim.

**Explicitly dropped:** a stdio/NDJSON port bridge for standalone binaries.
Hosts are C programs or Node.js; a standalone binary with ports and no host
has no delivery target and registration alone is harmless.

---

## How JS does it (reference semantics)

From `elm/core` `Elm/Kernel/Platform.js`:

- Ports are pseudo effect managers keyed by **bare port name** (global
  uniqueness enforced by `_Platform_checkPortName`, crash on collision).
- `_Platform_outgoingPort(name, converter)` registers
  `{cmdMap: \_ v -> v, converter, portSetup}` and returns
  `_Platform_leaf(name)`, so `logPort s` ⇒ `Leaf{home, value=s}` (raw payload;
  encoder runs in the manager's `onEffects`).
- `_Platform_incomingPort(name, converter)` registers
  `{subMap: \f g -> \v -> f (g v), converter, portSetup}`; `onP2PSend tagger`
  ⇒ `Leaf{home, value=tagger}` — **the leaf value is the tagger function**.
- `_Platform_setupEffects` (app init) calls each `portSetup` to build the
  public `app.ports[name]` object: `{subscribe, unsubscribe}` for outgoing
  (callbacks invoked from `onEffects` after running the encoder),
  `{send}` for incoming (`send(v)` = run decoder, `Debug.crash 4` on failure,
  else `sendToApp(tagger(decoded))` for each currently-subscribed tagger; the
  manager's `onEffects` just snapshots the sub list).
- Outgoing manager `init = Process.sleep 0` — delivery is deferred one tick,
  which is why JS hosts that `subscribe` immediately after `init()` still see
  messages produced by the program's `init` command.

---

## Resolved design decisions

### Q1: Leaf value shapes — JS parity, with eager outgoing encode

- Outgoing: `name payload` ⇒ `Fx_Leaf{home=name, value = encoder(payload)}`.
  Divergence from JS (which encodes in `onEffects`): we encode **at the call
  site**. Encoders are pure and total so this is unobservable, and it means
  the registry never needs to hold outgoing converters — the leaf always
  carries a wrapped Json value, and `onEffects` only stringifies + delivers.
- Incoming: `name tagger` ⇒ `Fx_Leaf{home=name, value = tagger}` (closure).
- Port manager maps (kernel-built closures):
  `outgoingPortMap = \_ v -> v`;
  `incomingPortMap = \f g -> (\v -> f (g v))` (allocates a composed-tagger
  closure, same pattern as `composedTaggerEvaluator` in TimeEffectManager).

### Q2: `gatherEffects` must route through `cmdMap`/`subMap`

Replace the direct `applyTaggers(taggers, value)` at the leaf with JS
semantics:

```cpp
// at Fx_Leaf, with `taggers` = accumulated Elm list of mapper closures:
HPointer applyFn = (isNil(taggers))
    ? identityClosure()                       // cached static, no alloc
    : allocApplyTaggersClosure(taggers);      // 1-arg closure capturing list
HPointer map = decodeHP(isCmd ? info.cmdMap : info.subMap);
HPointer effect = isNil(map)
    ? applyTaggers(taggers, value)            // legacy fallback (no map fn)
    : Scheduler::callClosure2(map, applyFn, value);
```

`allocApplyTaggersClosure` is a kernel evaluator that captures the tagger
list and applies it innermost-first (exactly `PlatformRuntime::applyTaggers`,
packaged as an Elm-callable closure). This activates the dormant Time
`subMap` / Task `cmdMap` and fixes `Cmd.map`/`Sub.map` over those managers as
a side effect. The legacy fallback keeps any map-less manager working.

### Q3: Registration timing — generated preamble before `Platform.worker`

JS registers ports at module-load time. Native equivalent: the MLIR backend
emits a synthetic `@__eco_register_ports()` containing one kernel call per
port node in the mono graph, and `@main` calls it before `@Main_main_$_0`
(i.e. before `Elm_Kernel_Platform_worker` runs). Ports therefore exist before
any effect dispatch and before the host's ready handshake completes.

Port nodes must also be **pruning roots**: in JS, every declared port of a
compiled module appears in `app.ports` even if no Elm code references it
(incoming-only ports are *typically* unreferenced by Elm except in
`subscriptions`, but a port used only by the host must still register).
Adjust the reachability pass (`Compiler/Monomorphize/Prune.elm`, MONO_022) to
seed `MonoPortIncoming`/`MonoPortOutgoing` nodes of the root module set as
reachable.

### Q4: Outgoing delivery — buffer until first subscriber

JS relies on `Process.sleep 0` scheduling so a host that subscribes
immediately after `init()` still receives init-time messages. Native hosts
attach either before start (C) or after the ready handshake (Node), so we
make the stronger guarantee explicit: **messages delivered while a port has
zero subscribers are buffered (FIFO, unbounded) and flushed on the first
`subscribe`; once a subscriber exists, delivery is immediate and nothing is
buffered.** This is a deliberate, documented superset of JS behaviour; init
bursts are small, so unboundedness is acceptable (revisit with a cap only if
real programs prove otherwise).

### Q5: Incoming decode failure — hard crash (JS parity)

`eco_port_send` with JSON that fails the port's decoder aborts with a message
naming the port and the decode error — the native analogue of
`Debug.crash 4`. A future, separate extension can add a host-installable
error hook; not in this plan.

### Q6: Threading model — eco thread owns all Elm execution

All Elm code, GC interaction, and HPointer handling stay on the eco thread
(the pthread spawned by the entry shim — allocator `initThread`, stackmaps,
GC roots all assume this).

- `eco_port_send(name, json)` is callable from **any thread**: it copies
  `{name, json}` (plain `std::string`s, zero GC interaction) into a
  mutex-guarded queue and calls `notifyWorkAvailableFromAsync()`. A
  `registerAsyncSource` drain runs on the eco thread: allocate Elm string →
  `Json_runOnString(decoder, …)` → on Ok, for each tagger in the port's
  current sub list: `msg = callClosure1(tagger, payload)`;
  `callClosure1(sendToAppClosure, msg)` (normal update cycle).
- Outgoing subscriber callbacks are invoked **on the eco thread**, with the
  payload already serialized to a UTF-8 JSON C string. Contract: callbacks
  must be quick, must not touch Elm values, and may only re-enter the runtime
  via `eco_port_send` (which queues — no re-entrancy hazard). The Node glue
  obeys this automatically via threadsafe functions.

### Q7: Lifetime — explicit app-hold refcount

`runEventLoop` currently exits when the run queue is empty and
`pendingAsync == 0` (`Scheduler.cpp:532`) — a port-driven app would exit
immediately. The embedding layer holds one `pendingAsync` reference for the
lifetime of the app (`eco_app_start` acquires, `eco_app_stop` releases and
sets a stop flag). Add `Scheduler::requestStop()`: sets an atomic flag +
notifies; `runEventLoop` breaks after the current drain when the flag is set.
An Elm-side "exit port" then works naturally: the host's outgoing-port
callback calls `eco_app_stop()`.

### Q8: Packaging — `.o`, `.so`, `.node` outputs; no stdio bridge

`eco make` output mode is selected by extension (it already switches on
`.mlir` vs default ELF):

| `--output=` | Produces | Use case |
|---|---|---|
| `app` (default) | PIE executable (today's behaviour, `eco_entry.o` main) | standalone programs without ports |
| `app.o` | single relocatable object of the compiled program | C hosts that want full link control; pair with `eco ldflags` |
| `libapp.so` | self-contained shared library: program `.o` + all runtime/kernel archives, exporting the `eco/embed.h` C ABI | C hosts; `dlopen`-able |
| `app.node` | `.so` + N-API glue archive, loadable by Node `require()` | Node.js hosts |

Supporting pieces:

- `eco ldflags` (new small subcommand): prints the archive list + flags that
  `linkExecutable` already computes (`EcoNativeDriver.cpp:301`), so a C host
  can link an `.o` itself: `cc main.c app.o $(eco ldflags) -o app`.
- Library outputs exclude `eco_entry.o` (its C `main`, signal handlers, and
  atexit GC-stats printer belong to the standalone profile only) and include
  `eco_embed.o` instead.
- PIC: the generated module's TargetMachine must use `Reloc::PIC_` for
  library outputs, and the runtime/kernel archives must be built with
  `-fPIC` (`CMAKE_POSITION_INDEPENDENT_CODE ON`). Verify; this is a build
  task, not a design risk.
- `.a` bundling is deferred (the `.o` + `eco ldflags` path covers static
  linking without inventing archive-merge machinery).

### Q9: Node embedding — N-API addon, JSON strings across the boundary

Goal: an existing Node program written against the JS target's API runs
against native code with only its `require` path unchanged:

```js
const { Elm } = require("./build/elm.js");   // shim → loads elm.node
const app = Elm.Main.init({ flags: null });
app.ports.logPort.subscribe(msg => console.log(msg));
app.ports.onP2PSend.send(data);
```

Architecture:

- `eco make src/Main.elm --output=build/elm.node` links the program `.so`
  with `libEcoNodeGlue.a` (new, N-API C++ glue) and emits a sibling
  `elm.js` shim (`module.exports = require('./elm.node');`) so existing
  `require("./build/elm.js")` calls keep working. (Bundlers need the usual
  `.node` externals config — documented, out of scope.)
- The glue registers `{ Elm: { <RootModule>: { init } } }` via
  `napi_register_module_v1` (module name from the compiled root module).
- `init(opts)`:
  1. Starts the app via the same embed core as C hosts (`eco_app_start`),
     which spawns the eco thread and blocks until the ready handshake
     (Q10). Single instance per process (Q11).
  2. Queries the port registry (`eco_port_count/name/is_incoming`) and
     builds `ports`:
     - outgoing `subscribe(fn)`: wraps `fn` in a
       `napi_threadsafe_function` (TSFN) and registers a C callback via
       `eco_port_subscribe`; the callback (eco thread) posts the JSON
       string to the TSFN; the JS-side trampoline does `JSON.parse` and
       calls `fn`. `unsubscribe(fn)` releases the TSFN.
     - incoming `send(value)`: `JSON.stringify(value)` on the JS thread,
       then `eco_port_send` (thread-safe queue + wake).
  3. Returns `{ ports }`.
- Liveness matches Node norms automatically: referenced TSFNs keep the Node
  event loop alive while subscriptions exist (`napi_ref_threadsafe_function`);
  an explicit `app.stop()` extension calls `eco_app_stop` + releases TSFNs.
- N-API is ABI-stable; target NAPI version 8 (Node ≥ 16). `napi_*` symbols
  resolve from the node binary at load time (undefined-at-link is the normal
  addon model on Linux).

### Q10: Ready handshake

`Elm_Kernel_Platform_worker` → `initWorker` runs: init → `setupEffects` →
initial `enqueueEffects` (synchronous dispatch) → `runEventLoop` (blocks).
`eco_app_start` must return *after* ports are registered and the init
effects have dispatched — i.e. `PlatformRuntime::initWorker` signals a
semaphore between Phase 6 (initial `enqueueEffects`) and Phase 7
(`runEventLoop`); `eco_app_start` waits on it. Combined with Q4 buffering,
hosts that subscribe right after start never lose init-time messages.

### Q11: One app instance per process

`PlatformRuntime`, `Scheduler`, `Allocator` are singletons. The embed API
enforces a single `eco_app_start` per process (second call fails). Node glue
caches the `init` result. Multi-instance is future work and out of scope.

### Q12: Flags — separate final phase

Native `Elm_Kernel_Platform_worker(impl)` takes no flags (JS takes
`(impl, flagDecoder, debugMetadata, args)`); `initWorker` passes Unit (or the
StressFlags test hack). Phase 5 wires the real path: the typed pipeline's
`Port.toFlagsDecoder` is compiled like a port decoder, `eco_app_start`
gains a `flags_json` parameter (Node glue passes
`JSON.stringify(opts.flags)`), and `initWorker` decodes via
`Json_runOnString`, crashing on failure (JS parity, `Debug.crash 2`).
Until Phase 5, programs must declare `Program () model msg` and hosts must
pass `flags: null`/omit flags — enforced with a clear error.

**Constraint: `Elm_Kernel_Platform_worker` MUST keep its one-argument
signature.** `Platform.worker` is called from elm/core Elm code, so its
kernel arity is outside our control — extending it would fork the kernel
interface for every existing program. The flags decoder instead reaches
the runtime through the same startup-registration mechanism ports use:
the generated `@__eco_register_ports` preamble (or a sibling call emitted
alongside it) passes the compiled decoder to a new kernel,
`Elm_Kernel_Platform_registerFlagsDecoder(decoder)`, and `initWorker`
looks it up when building the `flags` argument. This is purely additive —
no elm/core-facing signature changes anywhere.

---

## Detailed design

### D1: Runtime — `PortRuntime` (new: `runtime/src/platform/PortRuntime.{hpp,cpp}`)

```cpp
namespace Elm::Platform {

using EcoPortCallback = void (*)(const char* json_utf8, void* user);

class PortRuntime {
public:
    static PortRuntime& instance();

    // ---- eco-thread API (called from kernel exports / port managers) ----
    // Registers the port and its pseudo effect manager. Crashes on
    // duplicate name (JS parity with _Platform_checkPortName).
    void registerIncoming(const std::string& name, HPointer decoder);
    void registerOutgoing(const std::string& name);
    // incoming manager onEffects: snapshot the composed-tagger sub list.
    void setIncomingSubs(const std::string& name, HPointer subsList);
    // outgoing manager onEffects: stringify + deliver (or buffer, Q4).
    void deliverOutgoing(const std::string& name, HPointer jsonValue);
    // asyncSource hooks (drain on eco thread; ready from any thread).
    void drainPendingSends();
    bool hasPendingSends() const;

    // ---- host API backing (any thread) ----
    bool sendIncoming(const char* name, const char* json);   // queue + wake
    bool subscribeOutgoing(const char* name, EcoPortCallback cb, void* user);
    bool unsubscribeOutgoing(const char* name, EcoPortCallback cb, void* user);

    // ---- introspection (host threads, after registration completes) ----
    size_t portCount() const;
    const char* portName(size_t i) const;
    bool isIncoming(const char* name) const;

private:
    struct PortInfo {
        bool incoming = false;
        uint64_t decoder = 0;   // encoded HPointer (incoming only) — GC-scanned
        uint64_t subs = 0;      // encoded HPointer: Elm list of taggers — GC-scanned
        std::vector<std::pair<EcoPortCallback, void*>> sinks;  // outgoing
        std::vector<std::string> buffered;  // outgoing, pre-first-subscribe (Q4)
    };
    std::unordered_map<std::string, PortInfo> ports_;
    mutable std::mutex sinksMutex_;   // sinks/buffered touched cross-thread

    std::mutex pendingMutex_;
    std::deque<std::pair<std::string, std::string>> pendingSends_;
};

} // namespace Elm::Platform
```

GC: the constructor registers an external root scanner (same pattern as
`PlatformRuntime`'s) that evacuates every `decoder` and `subs` handle.
`pendingSends_`/`buffered`/`sinks` hold plain bytes and function pointers —
no GC interaction, safe to touch off-thread under their mutexes.

`registerIncoming/Outgoing` also build the pseudo manager and call
`PlatformRuntime::registerManager(name, info)`:

- shared `init`: 0-arg thunk returning `Task.succeed Nil` (existing pattern).
- outgoing `onEffects(router, cmdList, _subList, state)` evaluator: walk
  `cmdList` (each element is a wrapped Json value, already encoded at the
  call site per Q1); for each: `Elm_Kernel_Json_encode(0, v)` → Elm string →
  `StringOps::toStdString` → `deliverOutgoing(name, …)`; return
  `succeed(state)`. The port name is recovered from a per-port closure
  capture (capture the name as an Elm string in the onEffects closure —
  one closure pair per port, built at registration).
- incoming `onEffects(router, _cmdList, subList, state)` evaluator:
  `setIncomingSubs(name, subList)`; return `succeed(state)`.
- `cmdMap` (outgoing) = `\_ v -> v` evaluator; `subMap` (incoming) =
  compose evaluator returning a 1-arg closure `\v -> f (g v)`.

Note `PlatformRuntime::dispatchEffects` always calls `onEffects` with 4 args
(`callClosure4(fn, router, cmdList, subList, state)`) — port managers accept
both lists and use one; no dispatch changes needed beyond Q2.

`drainPendingSends` (registered once via
`Scheduler::registerAsyncSource(drain, ready)` at first registration):

```
pop {name, json} under pendingMutex_
  look up PortInfo; missing or outgoing → crash "unknown incoming port"
  elmJson = allocate Elm string from json bytes      (rooted)
  result  = Elm_Kernel_Json_runOnString(decoder, elmJson)
  Err e   → crash "Port <name>: invalid incoming value: <error>"   (Q5)
  Ok v    → for each tagger in subs list (rooted walk, snapshot tails):
              msg = callClosure1(tagger, v)
              PlatformRuntime::deliverToApp(msg)   // new accessor wrapping
                                                   // callClosure1(sendToAppClosure_, msg)
```

`PlatformRuntime` gains `deliverToApp(HPointer msg)` (the private
`sendToAppClosure_` stays private).

### D2: Runtime — `gatherEffects` map routing (Q2)

`PlatformRuntime.cpp:354–413`. At the `Fx_Leaf` case, replace the direct
tagger application with the Q2 snippet. New kernel evaluators:

- `identityClosure()` — cached 1-arg identity (allocate once, GC-rooted).
- `applyTaggersEvaluator` — captures the tagger list; body = existing
  `applyTaggers` loop.

The manager's map closure and the produced effect must be rooted across calls
(follow the existing `StackRootGuard` discipline in that file). The
`effectsScratch_` rooting already covers the results.

Acceptance for this change alone: a native E2E test where
`Sub.map`/`Cmd.map` wrap Time/Task effects and the mapped tagger is observed
(this is broken today; the elm-actor-kafka worker exercises both).

### D3: Kernel exports (new, in `elm-kernel-cpp/src/core/PlatformExports.cpp`)

```cpp
// Called from the generated @__eco_register_ports preamble (eco thread).
HPtr Elm_Kernel_Platform_registerIncomingPort(HPtr name, HPtr decoder);
HPtr Elm_Kernel_Platform_registerOutgoingPort(HPtr name);
// Both return Unit. Names arrive as Elm strings; converted via StringOps.
```

Register the symbols in `RuntimeSymbols.cpp` alongside the existing
`Elm_Kernel_Platform_*` entries.

### D4: Compiler — MLIR lowering for port nodes

`Compiler/Generate/MLIR/Functions.elm:174` currently does
`generateDefine` for both node kinds. New lowering:

**Outgoing** (`MonoPortOutgoing encoderExpr nodeType`), for port `foo`:

```mlir
func.func private @Main_foo$encoder(%p: !eco.value) -> !eco.value { …existing encoder body… }
func.func private @Main_foo(%p: !eco.value) -> !eco.value {
  %j = eco.call @Main_foo$encoder(%p)
  %n = eco.string_literal "foo"
  %b = eco.call @Elm_Kernel_Platform_leaf(%n, %j)
  eco.return %b
}
```

(If the encoder body is a `MonoClosure` with one param, inline its body into
the wrapper instead of emitting two functions — implementation detail; the
two-function form is always correct.)

**Incoming** (`MonoPortIncoming decoderExpr nodeType`), for port `bar`:

```mlir
func.func private @Main_bar$decoder() -> !eco.value { …existing decoder body, natural Decoder type… }
func.func private @Main_bar(%tagger: !eco.value) -> !eco.value {
  %n = eco.string_literal "bar"
  %b = eco.call @Elm_Kernel_Platform_leaf(%n, %tagger)
  eco.return %b
}
```

**Registration preamble** — emitted iff the graph contains port nodes:

```mlir
func.func private @__eco_register_ports() -> !eco.value {
  %n1 = eco.string_literal "bar"
  %d1 = eco.call @Main_bar$decoder()
  eco.call @Elm_Kernel_Platform_registerIncomingPort(%n1, %d1)
  %n2 = eco.string_literal "foo"
  eco.call @Elm_Kernel_Platform_registerOutgoingPort(%n2)
  %u = eco.constant Unit : !eco.value
  eco.return %u
}
```

and `@main` becomes:

```mlir
func.func private @main() -> !eco.value {
  eco.call @__eco_register_ports() : () -> !eco.value   // only if ports exist
  %0 = eco.call @Main_main_$_0()
  eco.return %0
}
```

The port name is the `Name` component of the node's `Mono.Global home name`
(bare name, matching the JS registry key; `registerIncoming/Outgoing` crash
on duplicates).

**Pipeline changes:**

- `GlobalOpt/MonoGlobalOptimize.elm wrapNodeCallables` (line ~998): leave
  `MonoPortIncoming`/`MonoPortOutgoing` expressions **untouched** — no
  `ensureCallableForNode`. This removes the heap-corrupting wrapper. (The
  decoder keeps its natural `Decoder payload` MonoType; the new MLIR lowering
  owns making the node callable.)
- `Monomorphize/Prune.elm`: seed root-module port nodes as reachable (Q3).
- Type-level: ports are monomorphic in `payload`; `msg` is universally
  quantified but erased (the tagger crosses as `!eco.value` and is only
  applied generically by the runtime). No new MVar/CNumber hazards; the
  `$decoder` function returns `!eco.value` per CGEN_012.

### D5: Embedding C API (new: `runtime/include/eco/embed.h`, `runtime/src/embed/eco_embed.cpp`)

```c
#ifdef __cplusplus
extern "C" {
#endif

typedef void (*eco_port_callback)(const char* json_utf8, void* user);

/* Lifecycle. start spawns the eco thread (allocator init, stackmaps,
 * __eco_init_globals, effect managers, eco_main) and blocks until the
 * ready handshake (Q10). Returns 0 on success; nonzero if already started
 * or init failed. flags_json may be NULL (Phase 5 wires it; until then
 * non-NULL is an error for flagless programs). */
int  eco_app_start(int argc, char** argv, const char* flags_json);
void eco_app_stop(void);     /* request loop exit; idempotent */
int  eco_app_join(void);     /* wait for eco thread; returns exit code */

/* Ports. subscribe/unsubscribe may be called before start (queued) or any
 * time after; send is valid only after start (else returns nonzero).
 * Callbacks run ON THE ECO THREAD: be quick, don't block, don't touch Elm
 * state; re-entry only via eco_port_send. */
int  eco_port_send(const char* port, const char* json_utf8);
int  eco_port_subscribe(const char* port, eco_port_callback cb, void* user);
int  eco_port_unsubscribe(const char* port, eco_port_callback cb, void* user);

/* Introspection (valid after start). */
int         eco_port_count(void);
const char* eco_port_name(int i);
int         eco_port_is_incoming(const char* port);

#ifdef __cplusplus
}
#endif
```

`eco_embed.cpp` reuses the body of `eco_main_thread`
(`eco_entry.cpp:144`) minus the signal handlers/atexit stats printer, runs it
on a `pthread` with `ECO_DEFAULT_STACK_SIZE`, holds the Q7 lifetime ref, and
implements the Q10 handshake (a semaphore posted by `initWorker` between its
Phase 6 and Phase 7 — add a `PlatformRuntime::setReadyHook(std::function)` or
a plain semaphore the embed layer passes in). Pre-start `subscribe` calls
are recorded and applied during start, after registration.

`eco_entry.cpp`'s standalone `main` is refactored to call the same core
(start + join), so there is exactly one init path.

**C host usage:**

```c
#include <eco/embed.h>

static void on_log(const char* json, void* user) { printf("log: %s\n", json); }

int main(int argc, char** argv) {
    eco_port_subscribe("logPort", on_log, NULL);
    if (eco_app_start(argc, argv, NULL) != 0) return 1;
    eco_port_send("onP2PSend", "{\"subjectId\":1,\"messageId\":2}");
    /* … host work … */
    eco_app_stop();
    return eco_app_join();
}
```

Build: `cc main.c app.o $(eco ldflags) -o app` or
`cc main.c -L. -l:libapp.so -o app` (or `dlopen`).

### D6: Driver — output modes (`runtime/src/codegen/EcoNativeDriver.cpp`, `Terminal/Make.elm`)

- Extension dispatch in `eco make`: `.o` → emit object only (reuse the
  existing emit-to-temp-object step of `lowerAndLink`, copy out, skip link);
  `.so`/`.node` → link with `-shared` (PIC module; runtime archives built
  `-fPIC`), exclude `eco_entry.o`, include `eco_embed.o` (+ node glue for
  `.node`), version-script/`--export-dynamic-symbol` limiting exports to
  `eco_*` + `napi_register_module_v1`.
- `eco ldflags` subcommand printing the archive/flags list `linkExecutable`
  computes.

### D7: Node glue (new: `runtime/src/embed/eco_node_addon.cpp` → `libEcoNodeGlue.a`)

Plain N-API (no node-addon-api dependency; the runtime already builds C++20):

- `napi_register_module_v1`: builds
  `exports.Elm.<RootModule> = { init }`. Root module name is baked in at
  link time via a tiny generated object (the driver emits a
  `const char* __eco_root_module = "Main";` global into the program `.o`).
- `init(opts)`:
  - `flags` handling per Q12 (reject non-null until Phase 5).
  - `eco_app_start(0, NULL, flagsJsonOrNull)`.
  - For each registered port, build the JS port object:
    - outgoing: `subscribe(fn)` creates
      `napi_threadsafe_function(fn, …, call_js: (env, fn, data) => fn(JSON.parse(data)))`
      with `napi_ref_threadsafe_function` (keeps the Node loop alive —
      Node-native liveness semantics), then
      `eco_port_subscribe(name, tsfnTrampoline, tsfnHandle)`. The eco-thread
      trampoline copies the JSON string and
      `napi_call_threadsafe_function(napi_tsfn_nonblocking)`.
      `unsubscribe(fn)` looks up the TSFN by fn identity, calls
      `eco_port_unsubscribe`, releases the TSFN.
    - incoming: `send(value)` does `JSON.stringify(value)` (call back into
      JS `JSON.stringify` via napi, or require the value already be
      JSON-serializable — use napi's built-in `napi_get_global` →
      `JSON.stringify` for exact JS semantics including `undefined`
      handling), then `eco_port_send`.
  - Returns `{ ports }`; also exposes `app.stop()` (releases TSFNs,
    `eco_app_stop`, `eco_app_join` on a detached watcher).
- The emitted `elm.js` shim:
  `module.exports = require('./<basename>.node');`

**Acceptance:** the elm-actor-kafka worker example's `index.ts` runs
unaltered (its `require("./build/elm.js")` resolves to the shim), driving
`logPort`, `notifyP2PSend` → `onP2PSend` port-bounce, and `exitPort` against
the native binary.

---

## Implementation phases

### Phase 0 — Dispatch correctness groundwork (no new features)

1. **`gatherEffects` map routing (D2).**
   Files: `runtime/src/platform/PlatformRuntime.cpp` (+ small helpers file
   for the identity/applyTaggers evaluators).
   Tests: native runtime unit test feeding hand-built `Fx_Map(Fx_Leaf)` bags
   through `enqueueEffects` for a fake manager asserting `cmdMap`/`subMap`
   receive `(applyFn, value)`; E2E Elm test with `Cmd.map` over
   `Task.perform` and `Sub.map` over `Time.every` asserting mapped messages
   arrive (both broken today).
2. **Remove the incoming-port mis-wrap.**
   File: `Compiler/GlobalOpt/MonoGlobalOptimize.elm` (`wrapNodeCallables`):
   skip `ensureCallableForNode` for both port node kinds. Until Phase 2
   lands, make the MLIR backend emit `eco.crash "ports are not yet supported
   natively"` for port nodes instead of silently-corrupting code — a clean,
   diagnosable failure.
   Tests: compile the kafka worker; assert clean crash message, not
   `eco_pap_extend` corruption.

### Phase 1 — Runtime port core (independent of compiler changes)

- `PortRuntime` (D1) + kernel exports (D3) + symbol registration.
- Port manager evaluator closures (onEffects ×2, cmdMap, subMap, init).
- `PlatformRuntime::deliverToApp`, `Scheduler::requestStop`.
- C API surface compiled into the runtime (D5 functions minus
  start/stop/join, which arrive in Phase 3 — `eco_port_*` only).
- Tests: C++ unit tests registering ports by hand (no compiler needed):
  build leaf bags with `Elm_Kernel_Platform_leaf`, push through
  `enqueueEffects`, assert outgoing callback receives stringified JSON,
  buffering semantics (Q4), incoming `sendIncoming` → decoder → tagger →
  `deliverToApp` (fake sendToApp closure), duplicate-name crash, GC stress
  across the drain path (decoder/subs survive forced GC).

### Phase 2 — Compiler emission

- MLIR lowering for port nodes + `$decoder`/`$encoder` siblings +
  `@__eco_register_ports` + `@main` preamble call (D4).
  Files: `Compiler/Generate/MLIR/Functions.elm`, `…/Context.elm`
  (function-name plumbing), `Compiler/Monomorphize/Prune.elm` (port roots).
- Tests: codegen golden tests (MLIR shape for an outgoing + incoming port);
  E2E echo program: `port emit : String -> Cmd msg`,
  `port poke : (Int -> msg) -> Sub msg`, update echoes pokes out through
  `emit` — driven by a C++ test host via `eco_port_send`/`subscribe`;
  E2E with `Sub.map` over the incoming port (exercises subMap composition).

### Phase 3 — C embedding + library outputs

- `eco_embed.cpp` (start/stop/join, handshake, pre-start subscribes),
  `eco_entry.cpp` refactor onto the shared core, `eco/embed.h` public header.
- Driver output modes `.o`/`.so` + `eco ldflags`; PIC build flags for
  runtime archives; export filtering for `.so`.
  Files: `runtime/src/codegen/EcoNativeDriver.cpp`, `Terminal/Make.elm`
  (extension dispatch + new subcommand), runtime CMake.
- Tests: E2E — C host program (committed under `runtime/test/embed/` or the
  e2e suite) linking the echo program as `.so` and as `.o + ldflags`,
  asserting port round-trip and clean stop/join; ready-handshake test
  (subscribe after start still sees init-time messages via Q4 buffering).

### Phase 4 — Node.js addon

- `eco_node_addon.cpp` + `libEcoNodeGlue.a`; `.node` output mode + `elm.js`
  shim + `__eco_root_module` baking.
- Tests: Node-driven E2E (requires node in the test toolchain — already
  present for `eco-boot`): echo program via `require('./echo.node')`;
  **acceptance: the elm-actor-kafka worker example runs with its existing
  `index.ts` unchanged** (logPort output, port-bounce delivery, exitPort →
  `app.stop`), compiled natively.

### Phase 5 — Flags (optional, separable)

- Compile `Port.toFlagsDecoder` output as a flags-decoder thunk and
  register it at startup from the generated preamble via a new kernel,
  `Elm_Kernel_Platform_registerFlagsDecoder(decoder)` — the same
  mechanism ports use. Do **NOT** extend `Elm_Kernel_Platform_worker`
  with an extra argument: it is called from elm/core Elm code, so its
  arity is outside our control (see Q12).
- Register a flags decoder for EVERY worker program (JS parity:
  `_Platform_initialize` always runs the flags decoder; the `()`-program
  decoder simply accepts null/undefined). `initWorker` then becomes
  uniform — `flags = runDecoder(registeredDecoder, hostJsonOrNull)`,
  crash on decode failure (JS `Debug.crash 2` parity) — with no branches
  and no test hooks.
- `eco_app_start` flags_json plumbed through to a single generic
  `PlatformRuntime::setPendingFlagsJson(std::string)` stash; Node glue
  stringifies `opts.flags` on the JS thread.
- **Retire the StressFlags special case.** `PlatformRuntime` must end up
  with no knowledge of stress tests: delete the `StressFlags` struct,
  `setPendingFlags`/`clearPendingFlags`, and `buildStressFlagsRecord`
  (whose hand-mirrored record layout is a silent-corruption trap if
  layout rules change). The test harness and stress binary instead format
  their config as JSON and stash it via `setPendingFlagsJson`, flowing
  through the same compiler-generated decoder as all host flags — which
  also exercises the flags-decoding path in CI on every stress run.
- Tests: flags record round-trip from both C and Node hosts; wrong-shape
  flags crash message; full stress suite (`--target stress`) over the
  JSON path.

---

## Invariants to add (`design_docs/invariants.csv`)

- **PORT_001** — Port names are globally unique per program; both the
  compiler registry emission and `PortRuntime::register*` enforce this
  (crash on duplicate), matching JS `_Platform_checkPortName`.
- **PORT_002** — An outgoing-port Cmd leaf's value is the already-encoded
  Json value (encoder runs at the call site); an incoming-port Sub leaf's
  value is the tagger closure. No other shapes reach port managers.
- **PORT_003** — `@__eco_register_ports` runs before `Platform.worker`;
  every reachable-or-declared root-module port is registered before any
  effect dispatch.
- **PORT_004** — Incoming-port decoders and sub lists held by `PortRuntime`
  are encoded HPointers scanned by an external GC root scanner; strings
  crossing the host ABI are plain bytes with no GC interaction off the eco
  thread.
- **PORT_005** — `gatherEffects` applies `Fx_Map` taggers only through the
  owning manager's `cmdMap`/`subMap` (JS `_Platform_toEffect` semantics);
  direct application is permitted only for managers with no map function.
- **PORT_006** — All Elm execution (closure calls, decoding, GC) happens on
  the eco thread; host threads interact only via the queued
  `eco_port_send` path and the registration/introspection API.

---

## Risks / open questions

- **PIC for runtime archives**: if any archive is currently built non-PIC,
  `.so` linking fails — flush this out first in Phase 3 (build-system task).
- **TLS in `.so`**: runtime uses `thread_local`; general-dynamic TLS in a
  dlopen'd library is standard but worth a smoke test under `dlopen`.
- **Callback discipline**: outgoing callbacks run on the eco thread; a
  misbehaving C host can stall the app. Documented contract; Node glue is
  immune (TSFN is fire-and-forget).
- **Unbounded buffers**: Q4 pre-subscribe buffer and the incoming send queue
  are unbounded. Acceptable for v1; add caps/backpressure only with evidence.
- **Single instance** (Q11): acceptable for v1; multi-instance would require
  de-singletonizing Allocator/Scheduler/PlatformRuntime — far out of scope.
- **`emptyRecord` ports return**: `initWorker`'s Elm-side return value stays
  as today; hosts use the C/N-API surface. If an Elm-visible `app.ports`
  record is ever wanted natively it can be derived from the registry later.
- **Phase 0.2 interim behaviour**: between Phase 0 and Phase 2, programs
  with ports fail with a clean crash instead of compiling — strictly better
  than today's heap corruption, but worth flagging in release notes if a
  release ships in between.
