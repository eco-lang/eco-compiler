# Kernel audit 05 — the effect-oriented half of `elm-kernel-cpp/`

Scope: Scheduler / Platform / Process / Debug / EffectManagerRegistry / time / http /
file / virtual-dom / browser. Authoritative symbol list = the corresponding sections
of `elm-kernel-cpp/src/KernelExports.h` (lines 289–397, 439–446, 456–517, 551–571).

Background read first: `design_docs/theory/kernel-task-deferral.md`,
`design_docs/theory/platform_scheduler_theory.md`,
`runtime/src/platform/TaskBinding.hpp`, `KERNEL_TASK_IO_001/002`
(`design_docs/invariants.csv:590–591`).

Class tags: **TB** task builder (pure allocating ctor at call time; IO deferred into a
`Task_Binding` body) · **TB-EAGER** returns a Task but does its effect at call time ·
**PA/PH/P** pure allocating / heap-reading / neither · **RT** mutates runtime-internal
state, no external IO · **E** genuinely effectful at call time · **X** non-returning ·
**STUB** unimplemented. **HOF** = invokes an Elm closure at call time.

---

## Symbol table

### Scheduler — `src/core/SchedulerExports.cpp` (+ bodies in `runtime/src/platform/Scheduler.cpp`)

| Symbol | Signature | Class | Binding body (if TB) | HOF | Part 2 verdict | Notes |
|---|---|---|---|---|---|---|
| `Elm_Kernel_Scheduler_succeed` | `a -> Task x a` | **PA** | — | no | **Elm-source** | `SchedulerExports.cpp:16` → `Scheduler::taskSucceed` `Scheduler.cpp:123`: one `allocTask(Task_Succeed, value, nil,nil,nil)`. Nothing else. Exempt ctor per `KERNEL_TASK_IO_001`. |
| `Elm_Kernel_Scheduler_fail` | `x -> Task x a` | **PA** | — | no | **Elm-source** | `:23` → `Scheduler.cpp:139`. `allocTask(Task_Fail, …)`. |
| `Elm_Kernel_Scheduler_andThen` | `(a -> Task x b) -> Task x a -> Task x b` | **PA** | — | no (stores the closure) | **Elm-source** | `:30` → `Scheduler.cpp:149`. 2-field node (callback, task). |
| `Elm_Kernel_Scheduler_onError` | `(x -> Task y a) -> Task x a -> Task y a` | **PA** | — | no | **Elm-source** | `:39` → `Scheduler.cpp:154`. |
| `Elm_Kernel_Scheduler_spawn` | `Task x a -> Task y ProcessId` | **TB** | `spawnBindingBody` `Scheduler.cpp:466` (`rawSpawn` → alloc Process + `enqueue`) | no | **Hard-Infeasible** (needs run queue) | `:48`. Became a binding 2026-07-23; no longer on the exemption list (invariants.csv:590 supersedes the stale theory doc). |
| `Elm_Kernel_Scheduler_kill` | `ProcessId -> Task x ()` | **TB** | `killBindingBody` `Scheduler.cpp:492` (calls target `Task_Binding.kill`) | **HOF (in body)** | **Hard-Infeasible** (needs Process/kill handle) | `:55`. |

`Scheduler::taskBinding` / `taskReceive` / `rawSpawn` exist in the runtime API but are
**not** exported from `elm-kernel-cpp` — `taskReceive` has no `Elm_Kernel_*` symbol
despite being named in the exemption list.

### Platform — `src/core/PlatformExports.cpp` (+ `runtime/src/platform/PlatformRuntime.cpp`)

| Symbol | Signature | Class | Binding body | HOF | Part 2 verdict | Notes |
|---|---|---|---|---|---|---|
| `Elm_Kernel_Platform_batch` | `List (Cmd msg) -> Cmd msg` | **PA** | — | no | **Elm-source** | `:21–29`. One `Custom(Fx_Node, [list], bitmap 0)`. |
| `Elm_Kernel_Platform_map` | `(a -> b) -> Cmd a -> Cmd b` | **PA** | — | no (stores tagger) | **Elm-source** | `:31–42`. `Custom(Fx_Map, [tagger, bag])`. |
| `Elm_Kernel_Platform_sendToApp` | `Router msg a -> msg -> Task x ()` | **TB-EAGER** ⚠ | *(none — should have one)* | **HOF** | **Hard-Infeasible** (router/scheduler) | `PlatformExports.cpp:44–50` → `PlatformRuntime.cpp:540–550`: calls the app closure **at call time**. Also declared `void` in `KernelExports.h:303` while the Elm type is `Task x ()` → return-ABI mismatch. Stock JS wraps it in `_Scheduler_binding` (`Elm/Kernel/Platform.js:153–160`). |
| `Elm_Kernel_Platform_sendToSelf` | `Router a msg -> msg -> Task x ()` | **TB-EAGER** ⚠ | *(none — should have one)* | no | **Hard-Infeasible** (scheduler mailbox) | `PlatformExports.cpp:52–59` → `PlatformRuntime.cpp:558–578`: `sched.rawSend(...)` at **line 574** (mailbox push + enqueue), then `taskSucceed(unit())` at **line 577**. Stock JS routes through `_Scheduler_send`, which **is** a binding (`Elm/Kernel/Scheduler.js`). |
| `Elm_Kernel_Platform_worker` | `{init,update,subscriptions} -> Program` | **E + HOF** | — | **HOF** | **Hard-Infeasible** | `:61–66` → `PlatformRuntime::initWorker`: decodes flags, runs `init`, registers GC roots, spawns manager self-processes, drains the scheduler. |
| `Elm_Kernel_Platform_leaf` | `String -> value -> Cmd/Sub msg` | **PA** | — | no | **Elm-source** | `:68–79`. `Custom(Fx_Leaf, [home, value])`. |
| `Elm_Kernel_Platform_registerIncomingPort` | `String -> Decoder -> ()` | **RT** | — | no | **Hard-Infeasible** (port registry) | `:85–98` → `PortRuntime::registerIncoming`. |
| `Elm_Kernel_Platform_registerOutgoingPort` | `String -> ()` | **RT** | — | no | **Hard-Infeasible** | `:110–119`. |
| `Elm_Kernel_Platform_registerFlagsDecoder` | `Decoder -> ()` | **RT** | — | no | **Hard-Infeasible** | `:104–108` → `PlatformRuntime::setFlagsDecoder`. |

### Process — `src/core/ProcessExports.cpp`

| Symbol | Signature | Class | Binding body | HOF | Part 2 verdict | Notes |
|---|---|---|---|---|---|---|
| `Elm_Kernel_Process_sleep` | `Float -> Task x ()` | **TB** (async-park) | `sleepBindingBody` `ProcessExports.cpp:27–39` (`registerPendingResume` + `incrementPendingAsync` + `TimerService::schedule`) | no | **Hard-Infeasible** (TimerService) | `:43–52`. Call time = one `allocFloat` + `makeAsyncBinding`. Textbook shape. |

### Debug — `src/core/{Debug.hpp,Debug.cpp,DebugExports.cpp}`

| Symbol | Signature | Class | Binding body | HOF | Part 2 verdict | Notes |
|---|---|---|---|---|---|---|
| `Elm_Kernel_Debug_log` | `String -> a -> a` | **E** | — | no | **Hard-Infeasible** (stdio) | `DebugExports.cpp:26–42`: `eco_output_text` ×3 + `eco_print_elm_value`. Non-Task identity/logging helper — exempt (`KERNEL_TASK_IO_001` clause c). **Direct calls never reach it**: `Debug.log` is intrinsic-lowered to `eco.dbg` (`compiler/src/Compiler/Generate/MLIR/Expr.elm:3921–3969`); the symbol survives only for indirect/PAP uses. |
| `Elm_Kernel_Debug_todo` | `String -> a` | **X** | — | no | n/a | `DebugExports.cpp:44–54`: prints then `exit(1)` at **line 51**. |
| `Elm_Kernel_Debug_toString` | `a -> Int -> String` | **PA + PH** | — | no | **Hard-Infeasible** (needs the type table) | `DebugExports.cpp:56–60` → `eco_value_to_string_typed` `runtime/src/allocator/RuntimeExports.cpp:3945–3968`: walks `g_type_graph` by `type_id`, renders into a thread-local `ostringstream`, allocates an Elm String. `type_id` is a compile-time constant the backend materialises (`Expr.elm:4030–4048`). No IO — the "print" is captured. |
| `Elm::Kernel::Debug::{log,toString,todo}` | (C++-internal) | **STUB / dead** | — | — | delete | `Debug.cpp:49` prints via `std::cout`; `Debug.cpp:101` returns `"<internals>"`; `Debug.cpp:132` throws. Nothing calls any of them — `DebugExports.cpp` bypasses the whole TU. |

### Time — `src/time/`

| Symbol | Signature | Class | Binding body | HOF | Part 2 verdict | Notes |
|---|---|---|---|---|---|---|
| `Elm_Kernel_Time_now` | `(Int -> Posix) -> Task x Posix` | **TB** (hand-rolled sync binding) | `timeNowBindingEvaluator` `TimeExports.cpp:182–220` (`system_clock::now`, applies `millisToPosix`, `taskSucceed`, `callClosure1(resume,…)`) | **HOF (in body)** | **Hard-Infeasible** (clock) | `:248–277`. Call time = alloc closure + capture + `taskBinding`. Uses `allocClosureK` directly rather than `makeBinding` because it needs a 1-capture closure; follows `KERNEL_TASK_IO_002` manually (guard at `:264`, `:199`). |
| `Elm_Kernel_Time_here` | `Task x Zone` | **TB** | `timeHereBody` `TimeExports.cpp:226–230` (`localtime_r` via `getLocalTimezoneOffset`) | no | **Hard-Infeasible** | `:279–284`. `makeBinding<timeHereBody>(unit())`. |
| `Elm_Kernel_Time_getZoneName` | `Task x ZoneName` | **TB** | `timeGetZoneNameBody` `TimeExports.cpp:232–242` (`getenv("TZ")`, `readlink("/etc/localtime")`, `fopen("/etc/timezone")`) | no | **Hard-Infeasible** | `:286–293`. |
| `Elm_Kernel_Time_setInterval` | `Float -> (Posix -> msg) -> Sub msg` | **PA** | — | no | **Elm-source** | `:295–310`. Despite the name it starts **no** timer — it allocates `Custom(CTOR_TIME_EVERY, [interval(f64 unboxed), tagger], 0b01)`. The timer is started by `timeOnEffectsEvaluator`. |
| `eco_register_time_effect_manager` | `void()` | **RT + PA** | — | no | **Hard-Infeasible** | `TimeEffectManager.cpp:419–441`. Allocates 4 evaluator closures + `registerManager("Time", …)`. |
| `Elm::Kernel::Time::{now,here,getZoneName,setInterval}` | (C++-internal) | **STUB / dead** | — | — | delete | `Time.cpp:14–34`, all four `assert(false && "not implemented")`. Nothing calls them. |

Manager internals (not exported): `timerTickEvaluator` `TimeEffectManager.cpp:124–199`
is **E + HOF** — reads `system_clock`, applies the tagger, `sendToApp`, re-arms.
`timeOnEffectsEvaluator` `:217–316` is **RT** (mutates `g_intervals`) + schedules ticks.

### Http — `src/http/`

| Symbol | Signature | Class | Binding body | HOF | Part 2 verdict | Notes |
|---|---|---|---|---|---|---|
| `Elm_Kernel_Http_emptyBody` | `Body` | **PA** | — | no | **Elm-source** | `HttpExports.cpp:656–659`. `Custom(BODY_EMPTY, [], 0)`. |
| `Elm_Kernel_Http_pair` | `a -> b -> Body` | **PA** | — | no | **Elm-source** | `:662–670`. `Custom(BODY_PAIR, [a,b])`. |
| `Elm_Kernel_Http_toTask` | `Router -> (a -> Task x b) -> Request -> Task x b` | **TB** (async-park, hand-rolled) | `httpBindingEval` `HttpExports.cpp:585–628` (extract request → bundle → `registerPendingResume` `:613` → `incrementPendingAsync` `:614` → `HttpService::submit` `:623`) | no | **Hard-Infeasible** (libcurl) | `:673–693`. Call time: `allocClosureK` + 3 captures + `taskBinding`. **Caveat**: `httpEnsureRegistered()` at **`:674`** mutates scheduler state (async-source + GC scanner registration, `:469–480`) at *call* time — idempotent `std::call_once`, no IO, but strictly it makes the "pure constructor" claim not quite true. |
| `Elm_Kernel_Http_expect` | `String -> (Body -> a) -> (Response a -> b) -> Expect b` | **PA** | — | no | **Elm-source** | `:714–724`. |
| `Elm_Kernel_Http_mapExpect` | `(a -> b) -> Expect a -> Expect b` | **PA** | — | no (allocates the composing closure, doesn't run it) | **Feasible** (needs a closure-composition primitive) | `:727–749`. |
| `Elm_Kernel_Http_bytesToBlob` | `Bytes -> String -> body` | **PA** | — | no | **Elm-source** | `:752–760`. |
| `Elm_Kernel_Http_toDataView` | `Bytes -> body` | **P** | — | no | **Already-intrinsic** (identity) | `:764–766`. Literally `return bytes;`. |
| `Elm_Kernel_Http_toFormData` | `List Part -> body` | **PA** | — | no | **Elm-source** | `:769–775`. |
| `Eco_Http_cancelTracker` | `uint64_t -> void` (not in `KernelExports.h`) | **RT** | — | no | **Hard-Infeasible** | `:698–711`. Marks a tracked request cancelled. Called from `HttpEffectManager.cpp:162`. |
| `eco_register_http_effect_manager` | `void()` | **RT + PA** | — | no | **Hard-Infeasible** | `HttpEffectManager.cpp:292`. |
| `initCurl` / `cleanupCurl` | ELF ctor/dtor | **E** | — | no | **Hard-Infeasible** | `HttpExports.cpp:778–781`: `curl_global_init` runs at process load, unconditionally, even for programs that never touch Http. |

### File — `src/file/` (header says "STUBS"; confirmed)

| Symbol | Signature | Class | Binding body | HOF | Part 2 verdict | Notes |
|---|---|---|---|---|---|---|
| `Elm_Kernel_File_decoder` | `Decoder File` | **STUB** | — | — | — | `FileExports.cpp:19–23` `assert(false)`, returns `HPtr::fromBits(0)`. |
| `Elm_Kernel_File_name` | `File -> String` | **STUB** | — | — | Trivial to un-stub | `:25–29`. Real impl already exists and is unused: `File.cpp:44–52`. |
| `Elm_Kernel_File_mime` | `File -> String` | **STUB** | — | — | Trivial to un-stub | `:31–35`; real impl `File.cpp:54–62`. |
| `Elm_Kernel_File_size` | `File -> Int` | **STUB** | — | — | Trivial to un-stub | `:37–41`; real impl `File.cpp:64–76`. |
| `Elm_Kernel_File_lastModified` | `File -> Int` | **STUB** | — | — | Trivial to un-stub | `:43–47`; real impl `File.cpp:78–90`. |
| `Elm_Kernel_File_toString` | `File -> Task x String` | **STUB** | — | — | — | `:49–53`. Would be TB. |
| `Elm_Kernel_File_toBytes` | `File -> Task x Bytes` | **STUB** | — | — | — | `:55–59`. |
| `Elm_Kernel_File_toUrl` | `File -> Task x String` | **STUB** | — | — | — | `:61–65`. |
| `Elm_Kernel_File_download` | `String -> String -> String -> Cmd msg` | **STUB** | — | — | — | `:67–73`. |
| `Elm_Kernel_File_downloadUrl` | `String -> String -> Cmd msg` | **STUB** | — | — | — | `:75–80`. |
| `Elm_Kernel_File_uploadOne` | `List String -> Task x File` | **STUB** | — | — | — | `:82–86`. |
| `Elm_Kernel_File_uploadOneOrMore` | `List String -> Task x (File, List File)` | **STUB** | — | — | — | `:88–92`. |
| `Elm_Kernel_File_makeBytesSafeForInternetExplorer` | `Bytes -> Bytes` | **P** | — | no | **Already-intrinsic** (identity) | `:94–98`. The one real symbol in the module. |

### VirtualDom — `src/virtual-dom/`

| Symbol | Signature | Class | Binding body | HOF | Part 2 verdict | Notes |
|---|---|---|---|---|---|---|
| `Elm_Kernel_VirtualDom_text` | `String -> Node msg` | **STUB + RT** | — | no | see notes | `VirtualDomExports.cpp:27–30` → `VirtualDom.cpp:52–58` + `wrapVNode` `:392–401`, which pushes into the never-trimmed global `vnodeRegistry` (`:390`) and returns an *index*. Not a heap value. |
| `Elm_Kernel_VirtualDom_node` | `String -> List Attr -> List Node -> Node msg` | **STUB + RT** | — | no | **Elm-source** once redesigned | `VirtualDom.cpp:64–80` **discards `factList` and `kidList`** (`(void)factList; (void)kidList;` lines 71–72). Produces a childless, attribute-less node. |
| `Elm_Kernel_VirtualDom_nodeNS` | `+ns` | **STUB + RT** | — | no | as above | same body, `VirtualDom.cpp:64`. |
| `Elm_Kernel_VirtualDom_keyedNode` | `String -> List Attr -> List (String,Node) -> Node` | **STUB + RT** | — | no | as above | `VirtualDom.cpp:86–102`, kids discarded (`:93–94`). |
| `Elm_Kernel_VirtualDom_keyedNodeNS` | `+ns` | **STUB + RT** | — | no | as above | same. |
| `Elm_Kernel_VirtualDom_attribute` | `String -> String -> Attribute msg` | **STUB** | — | no | — | `VirtualDomExports.cpp:70–75`: builds a `Fact`, throws it away, returns `Nothing`. |
| `Elm_Kernel_VirtualDom_attributeNS` | `…` | **STUB** | — | no | — | `:77–80`, same shape. |
| `Elm_Kernel_VirtualDom_property` | `String -> Value -> Attribute msg` | **STUB** | — | no | — | `:82–85`, same shape. |
| `Elm_Kernel_VirtualDom_style` | `String -> String -> Attribute msg` | **STUB** | — | no | — | `:87–90`, same shape. |
| `Elm_Kernel_VirtualDom_on` | `String -> Handler msg -> Attribute msg` | **STUB** | — | — | — | `:92–97` `assert(false)`. |
| `Elm_Kernel_VirtualDom_map` | `(a -> b) -> Node a -> Node b` | **STUB** | — | — | — | `:99–104` `assert(false)`. |
| `Elm_Kernel_VirtualDom_mapAttribute` | `(a -> b) -> Attribute a -> Attribute b` | **STUB** | — | — | — | `:106–111` `assert(false)`. |
| `Elm_Kernel_VirtualDom_lazy` … `lazy8` (8 symbols) | `(a…->Node msg) -> a… -> Node msg` | **STUB** ×8 | — | — | **Hard-Infeasible** if implemented (needs referential-equality memo + VDOM) | `:117–164`, every one `assert(false)`. The `VirtualDom.cpp:190–288` bodies exist but are unreachable. |
| `Elm_Kernel_VirtualDom_noScript` | `String -> String` | **PA + PH** | — | no | **Elm-source** | `:170–180`. Real: string compare + maybe alloc `"p"`. |
| `Elm_Kernel_VirtualDom_noOnOrFormAction` | `String -> Maybe String` | **PA + PH** | — | no | **Elm-source** | `:182–194`. Real. |
| `Elm_Kernel_VirtualDom_noInnerHtmlOrFormAction` | `String -> Maybe String` | **PA + PH** | — | no | **Elm-source** | `:196–205`. Real. |
| `Elm_Kernel_VirtualDom_noJavaScriptOrHtmlUri` | `String -> Maybe String` | **PA + PH** | — | no | **Elm-source** | `:207–219`. Real. |
| `Elm_Kernel_VirtualDom_noJavaScriptOrHtmlJson` | `Value -> Maybe Value` | **PA / STUB semantics** ⚠ | — | no | **Elm-source** | `:221–224`. Unconditionally returns `Just value` — the XSS filter filters nothing. |

### Browser / Debugger — `src/browser/`

| Symbol | Signature | Class | Binding body | HOF | Part 2 verdict | Notes |
|---|---|---|---|---|---|---|
| `Elm_Kernel_Browser_element` | `impl -> Program` | **P** (identity) | — | no | **Elm-source** (trivially) | `BrowserExports.cpp:16–18`: `return impl;`. Does *not* start a program. |
| `Elm_Kernel_Browser_document` | `impl -> Program` | **P** (identity) | — | no | **Elm-source** | `:20–22`. |
| `Elm_Kernel_Browser_application` | `impl -> Program` | **P** (identity) | — | no | **Elm-source** | `:24–26`. |
| `Elm_Kernel_Browser_load` `reload` `pushUrl` `replaceUrl` `go` `getViewport` `getViewportOf` `setViewport` `setViewportOf` `getElement` `on` `decodeEvent` `doc` `window` `withWindow` `rAF` `now` `visibilityInfo` `call` (19 symbols) | various, many `Task x a` | **STUB** ×19 | — | — | **Hard-Infeasible** (needs a DOM) | `BrowserExports.cpp:28–143`, every one `assert(false && "… requires platform")`. |
| `Elm_Kernel_Debugger_{init,isOpen,open,scroll,messageToString,download,upload,unsafeCoerce}` (8 symbols) | various | **STUB** ×8 | — | — | **Hard-Infeasible** (needs a browser) | `BrowserExports.cpp:149–195`. `unsafeCoerce` (`:191`) would be a pure identity but asserts instead. |

### Effect-manager registry — `src/EffectManagerRegistry.cpp`, `src/core/TaskEffectManager.cpp`

| Symbol | Signature | Class | Binding body | HOF | Part 2 verdict | Notes |
|---|---|---|---|---|---|---|
| `eco_register_all_effect_managers` | `void()` | **RT** | — | no | **Hard-Infeasible** | `EffectManagerRegistry.cpp:13–22`: Time, Http, Task. |
| `eco_register_task_effect_manager` | `void()` | **RT + PA** | — | no | **Hard-Infeasible** | `TaskEffectManager.cpp:216–238`. |

Manager internals (not exported): `taskOnEffectsEvaluator` `TaskEffectManager.cpp:69–139`
is **RT + PA** (`taskAndThen` + `rawSpawn` per cmd); `taskSendToAppEvaluator` `:51–65`
and `httpSuccessHandler` `HttpEffectManager.cpp:67–80` are **E + HOF** via `sendToApp`;
`taskCmdMapEvaluator` `:167–206` and `timeSubMapEvaluator`
`TimeEffectManager.cpp:358–409` are **PA** (closure composition, no call).

---

## Key findings

1. **⚠ `Platform_sendToSelf` is a KERNEL_TASK_IO_001 violation (TB-EAGER).** Its Elm type
   is `Router a msg -> msg -> Task x ()` (`elm/core/1.0.5/src/Platform.elm:118`), yet
   `PlatformRuntime.cpp:574` performs the mailbox push + `enqueue` at **kernel-call
   time** and only then returns `taskSucceed(unit())` (`:577`). It is not on the
   exemption list (`invariants.csv:590`). Stock elm/core routes it through
   `_Scheduler_send`, which *is* a binding.
2. **The sendToSelf bug is exactly the spawn/kill bug that was already fixed.** Per the
   Task-immutability corollary, a `sendToSelf` Task that is aliased or cached in a
   memoized CAF slot sends **once at construction**, not once per fulfilment; and a Task
   that is built but never stepped sends anyway. That is the precise failure mode
   `plans/task-purity-and-caf-guard-removal.md` fixed for `spawn`/`kill` on 2026-07-23
   (`Scheduler.cpp:460–474`, `486–512`). Fix is mechanical: `makeBinding<sendToSelfBody>(tuple2(router,msg))`.
3. **⚠ `Platform_sendToApp` is both eager and ABI-wrong.** `KernelExports.h:303` declares
   `void`, but the Elm type is `Task x ()`, so the backend's inferred return is
   `!eco.value` — a caller reads a garbage RAX. And it calls the app closure eagerly at
   `PlatformRuntime.cpp:549`. Stock JS wraps it in `_Scheduler_binding`
   (`Elm/Kernel/Platform.js:153–160`). Currently latent only because every effect
   manager in this tree is C++ and calls `PlatformRuntime::sendToApp` directly.
4. **TB-vs-E split among Task-returning kernels in scope: 8 TB, 2 TB-EAGER, 0 legitimately
   eager E.** TB = `Scheduler_spawn`, `Scheduler_kill`, `Process_sleep`, `Time_now`,
   `Time_here`, `Time_getZoneName`, `Http_toTask` (7 implemented) + counting
   `Http_toTask`'s async-park shape once. TB-EAGER = `Platform_sendToApp`,
   `Platform_sendToSelf`. Every real syscall (clock, `localtime_r`, `/etc/localtime`,
   libcurl, timerfd) is behind a binding body. The deferral discipline is genuinely
   holding for `time/`, `http/`, and `Process.sleep`.
5. **The `Http_toTask` construction path has one non-pure step**: `httpEnsureRegistered()`
   at `HttpExports.cpp:674` registers the async source and the GC scanner at call time
   rather than in the binding body. `std::call_once`, no IO, so it is not a
   `KERNEL_TASK_IO_001` breach — but it means "`toTask` allocates and nothing else" is
   not literally true. Moving it into `httpBindingEval` would make the claim exact.
6. **`design_docs/theory/kernel-task-deferral.md` is stale relative to
   `invariants.csv:590`.** The theory doc still lists `spawn`/`kill`/`taskReceive` as
   exempt pure constructors (lines 90–91) and still carries exemption (d) for MVar
   partial-eager fast paths (lines 97–99), both of which the invariant explicitly
   deletes/supersedes. `platform_scheduler_theory.md:148–153` repeats the same stale
   list. Two docs, one invariant — the invariant is right.
7. **Stub inventory is large and concentrated: 62 of the ~118 symbols in scope are
   unimplemented.** `browser/` 27 of 30 (19 Browser + 8 Debugger), `virtual-dom/` 20 of
   25, `file/` 12 of 13, `Debug.cpp` 3 dead internals, `Time.cpp` 4 dead internals.
8. **⚠ In a shipped binary the stubs do not crash — they return a null HPointer.** The
   `release` preset compiles with `-DNDEBUG` (`CMakePresets.json:112–113`), which erases
   every `assert(false)` in the stub bodies; each then falls through to
   `return HPtr::fromBits(0)`, which downstream code dereferences. Loud failure in
   `build`/`dev`, silent heap corruption in `release`. Replace with `eco_fatal`/`abort`.
9. **⚠ `VirtualDom_node`/`nodeNS`/`keyedNode`/`keyedNodeNS` silently drop their children
   and attributes** (`VirtualDom.cpp:71–72`, `:93–94`) rather than asserting, so they
   look implemented while producing an empty tree.
10. **⚠ `VirtualDom_noJavaScriptOrHtmlJson` is a security filter that filters nothing** —
    `VirtualDomExports.cpp:221–224` unconditionally returns `Just value`. Its four
    siblings (`noScript`, `noOnOrFormAction`, `noInnerHtmlOrFormAction`,
    `noJavaScriptOrHtmlUri`) are real.
11. **`wrapVNode` leaks and is GC-unsafe.** `VirtualDom.cpp:390–401` appends every VNode
    to a process-global `std::vector<VNodePtr>` that is never trimmed and returns an
    index; the `HPointer`s held in `Fact::jsonValue` and `VNode::refs`
    (`VirtualDom.hpp:60`, `:87`) are not registered with any root scanner, so they
    dangle after the first collection. Any VDOM revival must start here.
12. **Four `File` accessors are stubbed at the export while a working implementation sits
    unused one file over.** `FileExports.cpp:25/31/37/43` assert; `File.cpp:44/54/64/78`
    implement `name`/`mime`/`size`/`lastModified` correctly against the Record layout.
    Cheapest de-stubbing in the whole audit.
13. **`Elm_Kernel_Debug_log` is effectively dead on the direct path.** `Debug.log` is
    intrinsic-lowered to `eco.dbg` (`Expr.elm:3921–3969`); only PAP/indirect uses reach
    the C symbol. `Debug.toString`, by contrast, is a real call with a
    compiler-materialised `type_id` (`Expr.elm:4030–4048`).
14. **`curl_global_init` runs unconditionally at process load** via an ELF constructor
    (`HttpExports.cpp:778–781`), paying TLS/CA-bundle init for every Eco binary that
    links the kernel, including compiler stages that never make a request.
15. **Only two symbols in scope invoke an Elm closure at call time**: `Platform_sendToApp`
    and `Platform_worker`. Every other HOF-ness is inside a binding body
    (`timeNowBindingEvaluator`, `killBindingBody`) or inside an effect-manager evaluator,
    which is the correct place for it.

---

## Task builders that are really pure constructors

**(a) Fully pure — no binding, no IO anywhere, just an `allocTask`/`custom` call.** These
are the strongest Elm-source candidates in the audit.

| Symbol | What it actually allocates | Site |
|---|---|---|
| `Elm_Kernel_Scheduler_succeed` | `Task{ctor=Succeed, value}` | `Scheduler.cpp:123` |
| `Elm_Kernel_Scheduler_fail` | `Task{ctor=Fail, value}` | `Scheduler.cpp:139` |
| `Elm_Kernel_Scheduler_andThen` | `Task{ctor=AndThen, callback, task}` | `Scheduler.cpp:149` |
| `Elm_Kernel_Scheduler_onError` | `Task{ctor=OnError, callback, task}` | `Scheduler.cpp:154` |
| `Elm_Kernel_Platform_batch` | `Custom{Fx_Node, [list]}` | `PlatformExports.cpp:27` |
| `Elm_Kernel_Platform_map` | `Custom{Fx_Map, [tagger, bag]}` | `PlatformExports.cpp:40` |
| `Elm_Kernel_Platform_leaf` | `Custom{Fx_Leaf, [home, value]}` | `PlatformExports.cpp:77` |
| `Elm_Kernel_Time_setInterval` | `Custom{Time_Every, [f64, tagger]}` | `TimeExports.cpp:308` |
| `Elm_Kernel_Http_{emptyBody,pair,expect,bytesToBlob,toFormData}` | 0–3-field `Custom` | `HttpExports.cpp:658/669/723/759/774` |
| `Elm_Kernel_Http_{toDataView}`, `Elm_Kernel_File_makeBytesSafeForInternetExplorer` | nothing (identity) | `HttpExports.cpp:765`, `FileExports.cpp:97` |
| `Elm_Kernel_Browser_{element,document,application}` | nothing (identity) | `BrowserExports.cpp:17/21/25` |

**(b) Pure at call time, IO deferred into a named body.** The kernel call itself is still
just an allocating constructor; the C++ is unavoidable only because of what the *body*
touches.

| Symbol | Body that performs the effect | What the body touches |
|---|---|---|
| `Elm_Kernel_Process_sleep` | `sleepBindingBody` `ProcessExports.cpp:27` | TimerService worker |
| `Elm_Kernel_Time_now` | `timeNowBindingEvaluator` `TimeExports.cpp:182` | `system_clock` |
| `Elm_Kernel_Time_here` | `timeHereBody` `TimeExports.cpp:226` | `localtime_r` |
| `Elm_Kernel_Time_getZoneName` | `timeGetZoneNameBody` `TimeExports.cpp:232` | `getenv`/`readlink`/`fopen` |
| `Elm_Kernel_Http_toTask` | `httpBindingEval` `HttpExports.cpp:585` | libcurl worker pool |
| `Elm_Kernel_Scheduler_spawn` | `spawnBindingBody` `Scheduler.cpp:466` | run queue (no external IO) |
| `Elm_Kernel_Scheduler_kill` | `killBindingBody` `Scheduler.cpp:492` | target's kill handle closure |

---

## Part 2 — could the pure ones move out of C++?

**1. `Scheduler_succeed`/`fail`/`andThen`/`onError` → Elm-source, with one blocker.**
They are nothing more than 1–2-field node allocations (`Scheduler.cpp:123–157`); no
scheduler state, no IO, no closure calls. `type Task x a = Succeed a | Fail x | Binding …
| AndThen (a -> Task x b) (Task x a) | OnError … | Receive …` in Elm would generate
identical `Custom` allocations and let the existing constructor codegen handle them.
**Blocker:** the scheduler reads the node through the fixed `Task` struct layout
(`Heap.hpp` — `ctor:CTOR_BITS`, then `value`, `callback`, `kill`, `task` at fixed
offsets; `stepProcess` in `Scheduler.cpp` and `killBindingBody:498–500` depend on it),
and the ctor indices are pinned by `Task_Succeed=0 … Task_Receive=5`. An Elm
`type Task` compiles to a generic `Tag_Custom` with compiler-assigned ctor ids and a
packed field layout — so the move requires either (a) pinning that Elm type's ctor
order + field order and teaching the runtime to read `Custom` instead of `Task`, or
(b) keeping `Task` as a reserved layout the way `Dict`'s `CTOR_DICT_RBNODE` is
(`HttpExports.cpp:76–77`). `Binding` must stay kernel-built (it holds a C++ trampoline
closure). Verdict: **Elm-source, medium effort, gated on Task-layout unification.**

**2. `Platform_batch`/`map`/`leaf` → Elm-source, cleanly.** All three are single
`alloc::custom` calls with fixed `Fx_*` ctors and no runtime-state contact
(`PlatformExports.cpp:21–79`). `PlatformRuntime::gatherEffects` matches on
`Fx_Leaf/Fx_Node/Fx_Map`, so the same ctor-order pinning caveat as (1) applies, but the
bag tree is *only* read by `gatherEffects` — a much smaller surface than `Task`. **This
is the best cost/benefit removal in the audit.** `Platform_worker` must stay C++
(`initWorker` drives GC-root registration, manager spawn, and the drain loop).
`VirtualDom` node constructors *would* be Elm-source candidates — they are tagged-value
constructors in principle — but the current C++ is a `shared_ptr` side-table, not heap
values, so this is a rewrite rather than a port; `lazy1..8` are **Hard-Infeasible** in
Elm because they need referential-equality memoisation over the previous render.
`noScript`/`noOnOrFormAction`/`noInnerHtmlOrFormAction`/`noJavaScriptOrHtmlUri` are pure
`String.startsWith`/`==` predicates — **Elm-source, trivial, and they would gain the
missing `noJavaScriptOrHtmlJson` filter for free.**

**3. `Debug_log` → Hard-Infeasible** (writes to the runtime's capture stream; and it is
already bypassed by the `eco.dbg` intrinsic). **`Debug_toString` → Hard-Infeasible**:
it needs the runtime type graph (`g_type_graph`, indexed by the compiler-materialised
`type_id` — `pass_type_table_theory.md`, `RuntimeExports.cpp:3952–3958`). Elm has no way
to reach the type table; the only alternative would be compiler-generated per-type
`toString` functions, which is a different feature, not a port.

**4. Must stay C++.** Scheduler-dependent: `Scheduler_spawn`/`kill`, `Platform_worker`,
`Platform_sendToApp`/`sendToSelf`, `Platform_register*Port`/`registerFlagsDecoder`, all
three `eco_register_*_effect_manager`. libcurl: `Http_toTask` (+ `Eco_Http_cancelTracker`,
`initCurl`). Timers: `Process_sleep`, `Time_now`/`here`/`getZoneName`, and the
`Time.every` manager. DOM: every `Browser_*` and `Debugger_*` symbol, plus
`VirtualDom_on`/`map`/`mapAttribute`/`lazy*`.
