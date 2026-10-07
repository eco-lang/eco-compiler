# Plan: `eco/system` — the public system library for Eco

Status: **v3, implementation-ready** (2026-10-07). Amended for D8 (no HTTP client) and D9
(`Http.Stream`), with the readiness review R3 applied. v1 was drafted, reviewed adversarially by two
independent reviewers (runtime/compiler; Elm/API/streams), cross-checked against the GC patterns of
`eco-kernel-cpp/` and `elm-kernel-cpp/`, and rewritten. The review findings and their resolutions are in
§9.

Already in tree (scaffold): `system-kernel-cpp/` (package `eco/system`, placeholder `System.noop`, CMake
target `EcoSystem_System`), `ECO_SYSTEM_MODS` in `runtime/src/codegen/CMakeLists.txt`,
`ecoSystemLibs()`/`glibcEcoSystemLibs()` in the generated `EcoBootConfig.h`, the AOT link lines in
`EcoNativeDriver.cpp`, and bundle install rules in `/work/CMakeLists.txt`.

How to read this plan:
- §0–§2: decisions, scope, and the facts the design rests on.
- §3: architecture. **§3.3 (GC safety and kernel code patterns) is mandatory reading before writing any
  C++ in this package.**
- §4: the phases, each with numbered steps, the files they touch, tests, and exit criteria.
- Appendices: A public API (normative), B kernel function catalogue (normative), C effect-manager
  constructor layouts (normative), D LICENSE text, E behaviour notes ported from gren.

---

## 0. Resolved decisions (from the user)

| # | Decision |
|---|---|
| D1 | `eco/system` is the **public** system API for Eco programs. `eco/kernel` stays the compiler's internal IO layer. eco/system does not depend on eco/kernel. |
| D2 | The API is a port of **gren-node 6.2.0** (`/work/gren-node`, the author has given permission) **minus Sqlite**. gren's `Node` module is renamed `System`. |
| D3 | **No `Permission` types**: no `Init` module, no `initialize` functions, no permission arguments. As a consequence `startProgram`, `endSimpleProgramWithCmd` are dropped (they only existed to wrap `Init.Task`). |
| D4 | **`Stream`** and **`Stream.Log`** come from **gren-lang/core 7.5.0** (`/work/gren-core`) into eco/system. Every other gren-core facility is replaced by elm/core, elm/bytes, elm/json, elm/time or elm/url. |
| D5 | Module names: `System`, `System.File`, `System.File.Path`, `System.File.FileHandle`, `System.Process`, `System.Terminal`, `Http.Server`, `Http.Server.Response`, `Http.Stream`, `Stream`, `Stream.Log`. |
| D6 | **Phase 0** writes every module with full annotations, doc comments and `Debug.todo "Implement System API"` bodies, plus a README, and a pnpm setup so `pnpm run docs` previews the docs with elm-doc-preview. |
| D7 | LICENSE: the gren BSD-3-Clause text with an added line `Modified work Copyright 2026-present Rupert Smith` (Appendix D, verbatim). |
| D8 | **No HTTP client in eco/system.** gren-node's `HttpClient` is dropped; eco programs use **elm/http**, which already runs natively (`elm-kernel-cpp/src/http/`, `plans/complete-elm-http-kernel.md`). |
| D9 | **`Http.Stream`** extends elm/http with the stream-based operations of gren's `HttpClient` (`withStreamBody`, `expectStream`) and **nothing else**. It owns its own `Body`, `Expect` and `Resolver` types and `request`/`task` functions shaped like elm/http's, and reuses elm/http's public `Header`, `Error`, `Metadata` and `Response`. Responses are always delivered as streams. eco/system therefore depends on elm/http. (See §9, design note DN1, for why it does not extend `Http.Body`/`Http.Expect` directly.) |
| D10 | `Environment.args` is the **full C argv**: `args[0]` is the program as invoked. This differs from gren-node, whose `process.argv` starts with the node binary and the script path (§3.7). |
| D11 | Effect managers stay keyed by **bare module name** in `PlatformRuntime` (`"System"`, `"System.File"`, …), not by package. Only kernel-author packages can declare effect modules, so a collision would itself signal that a module should be redesigned rather than namespaced. The compiler still uses the package (`eco/system`) to decide which registration calls to emit. |

Other deliberate API changes relative to gren (all reflected in Appendix A):
- `SimpleProgram msg = Program () msg`.
- `Terminal.initialize` becomes `getConfiguration`, and `Configuration` loses its `permission` field.
- FileHandle's phantom types are named `ReadAccess`/`WriteAccess`.
- `FileHandle.metadata` returns `Metadata`; gren's type was wrong.
- `Stream.fromArray` becomes `fromList`.
- `Array` becomes `List` and `{}` becomes `()` throughout.

## 1. Scope

**In scope:**
- Every function in Appendix A, implemented natively (MLIR → LLVM, C++ kernels) on **Linux and macOS**.
- Build, compiler, bundle and test integration.
- Documentation.

**Out of scope, as follow-ups** (§8 lists the risks):
- **The JS target.** Phase 1 ships JS kernel stubs that throw, because the compiler needs a `.js` file
  per kernel home (F14). Porting gren-node's JS kernels properly is Phase 10 and optional.
- **Windows.** The libraries must compile there (CI builds Windows). The kernels that are portable work:
  platform, arch, environment, args, cwd/home/tmp/devNull and in-memory streams. Every fallible task
  fails with error code `"ENOTSUP"`. Every infallible operation (`Task Never`, `Cmd`, `Sub`) crashes
  with `eco/system: <function> is not supported on Windows yet`.
- **ecoc.** It links only ElmKernel, so eco/system programs do not run under `ecoc`; this is the same
  limitation eco/kernel has today.

## 2. Verified facts the design rests on

All were checked on 2026-10-07. "inv" means `design_docs/invariants.csv`, and line numbers are into that
file. Reviewer corrections have been applied.

| # | Fact | Where |
|---|---|---|
| F1 | Only the main scheduler thread may touch the heap. Workers exchange plain data (POD) and a `uint64_t` token, nothing else. | HEAP_007 (inv:391), PORT_006 (inv:609); `plans/complete-elm-http-kernel.md` §0 |
| F2 | Every Task-returning kernel does its IO inside a binding (`makeBinding`/`makeAsyncBinding`). Only `exit`/`crash`/`log` may run eagerly. Task nodes are immutable. | KERNEL_TASK_IO_001/002 (inv:597-598); `runtime/src/platform/TaskBinding.hpp` |
| F3 | The async template:<br>1. register the resume closure;<br>2. `incrementPendingAsync`;<br>3. submit POD to a service;<br>4. the worker pushes `(token, POD)` and calls `notifyWorkAvailableFromAsync`;<br>5. a main-thread drain (registered with `registerAsyncSource`) builds the heap values, calls `takePendingResume`, resumes, and calls `decrementPendingAsync`.<br>The smallest complete example is `eco-kernel-cpp/src/eco-kernel/Process.cpp:170-273` with `runtime/src/platform/WaitService.*`. | `Scheduler.hpp:100-109`, `Scheduler.cpp:91-107,549-658` |
| F4 | Kernels must not build Elm **records**: their layout comes from `computeRecordLayout`, with unboxed fields first and then boxed fields, each group sorted by name. Kernels must not build error records or package ADTs either. Errors cross as neutral tuples that Elm decodes. | IO_ERR_002, FORBID_IO_001 (inv:590-591); `Generate/MLIR/Types.elm:463-494` |
| F5 | Value helpers live in `runtime/src/allocator/HeapHelpers.hpp`: `allocStringFromUTF8`, `allocByteBuffer[Blank]`, `listFromPointers`, `tuple2/3(…, mask)`, `custom`, `just`, `ok/err`, and the constants `unit()`/`elmTrue()`/`elmFalse()`/`emptyBytes()`. Tuple and custom masks use 2 bits per slot (0 boxed, 1 Int, 2 Float, 3 Char); the `tuple2` doxygen at :1380 is stale. | HH:197-233, 527, 645-1361, 1384-1559, 1606-1715 |
| F6 | Any allocation may move objects (HEAP_011).<br>- Short-lived roots: `StackRootGuard`/`pushStackRootRange`/`RootedSlots`, O(1) root-stack per call.<br>- Long-lived roots: a registry of encoded words scanned by `RootSet::addExternalRootScanner`.<br>See §3.3. | HH:125-170; `RootedSlots.hpp`; `RootSet.hpp:306-312` |
| F7 | The kernel ABI comes from the Elm type: Int→`int64_t`, Float→`double`, Char→`uint16_t`, everything else (Bool included) → `uint64_t` encoded HPointer. Polymorphic positions are boxed. The symbol is `Eco_Kernel_<Home>_<name>`. | REP_ABI_001, KERN_006; `Generate/MLIR/KernelAbi.elm:65-190` |
| F8 | Kernel **homes** are keyed without their `Elm`/`Eco` prefix in kernel typing, `KernelFacts`, `KernelSetFacts`, the JS globals `_Home_name` and the JS graph key. If two packages share a home, they silently share facts or drop a node. | `Type/KernelTypes.elm:20-23`; `GlobalOpt/KernelFacts.elm:418,486`; `MonoSolver/KernelSetFacts.elm:1766-1794`; `Generate/JavaScript.elm:592`; `Builder/GraphAssembly.elm:41-46` |
| F9 | `KernelFacts` is the only source of kernel facts, and a missing row means the conservative answer. New kernels need **no** row; rows are an optional later optimisation with evidence anchors. | KERNEL_FACTS_001 (inv:661); `KernelFacts.elm:26-31` |
| F10 | **Elm-written effect managers do not run natively.**<br>- MLIR emits only the leaves (`Elm_Kernel_Platform_leaf(home, v)`).<br>- The runtime managers are C++: Task, Time, Http (`EffectManagerRegistry.cpp:13-22`).<br>- A leaf whose home has no manager is **silently dropped** (`PlatformRuntime.cpp:435-437`).<br>- The key is the full module name. | `Generate/MLIR/Functions.elm:2090-2156`; `MonoSolver/Monomorphize.elm:4513-4516` |
| F11 | C++ managers decode the Elm `MySub`/`MyCmd` constructors themselves. External events reach Elm through `registerAsyncSource` drains that call `sendToApp`/`sendToSelf` and then `Scheduler::drain()` **once per message**. | `TimeEffectManager.cpp:96-399`; `HttpExports.cpp:369-382` |
| F12 | The event loop exits when the run queue is empty and `pendingAsync_ == 0`. This check runs under `mutex_` (`Scheduler.cpp:564-566`). There is no before-exit hook and no `setExitCode`; a normal exit returns 0. | `Scheduler.cpp:549-595`; `eco_entry.cpp:143,376` |
| F13 | `Process.kill` resolves the snapshot that `spawn` returned, not the latest process, so a binding's kill handle usually never runs. Process ids are 16-bit. | `Scheduler.cpp:466-512,870-880,429` |
| F14 | A kernel `.js` file is crawled only for packages by the kernel authors (elm, elm-explorations, eco). It must start with `/*`, contain Elm imports with explicit `exposing` and no `as`, then `*/`. Some malformed headers **crash** the compiler. On the native path the JS body is irrelevant. | `Builder/Elm/Details.elm:1597-1688`; `Compiler/Elm/Kernel.elm:173-480` |
| F15 | `--local-package` takes one mapping, and a repeated flag is rejected. Any explicit mapping turns off the bundled probe, which knows only eco/kernel. A local package is copied into `~/.eco/<ver>/packages` **once**. Its artifacts and `docs.json` are validated only against dependency versions. | `Terminal/Make.elm:98-895`; `Chomp.elm:477,605`; `Builder/Stuff.elm:226-324`; `Details.elm:441-461,922-1063,1881` |
| F16 | Every application must list `elm/json`, because every Program has a flags decoder. | `Builder/Elm/Outline.elm:303-308` |
| F17 | There is no fd readiness reactor, no IO thread pool, and no signal handling visible to Elm. `SIGPIPE` is ignored only under `ENABLE_GC_STATS`. | `eco_entry.cpp:162-301` |
| F18 | Existing services:<br>- `TimerService` has no cancel.<br>- `WaitService` has one shared result queue; a child that exits before `submit` is reaped and dropped; signal deaths are reported as code 1.<br>- `HttpService` uses a `bool eco_lane`, does not restrict protocols, does not reset headers on redirect, and never fills `statusText`. | `runtime/src/platform/{TimerService,WaitService,HttpService}.*` |
| F19 | E2E tests live in `test/<pkg>/`, with `-- CHECK:` patterns matched against **`result.output`, which only captures eco-thread `output_text` writes**. Raw fd 1/2 output goes to the fork pipe as `ctx.capturedOutput` and is not checked. The child inherits the runner's stdin, and exit codes are not checked. | `test/ElmE2ETestBase.hpp:757,828,892-967`; `aot_e2e_main.cpp:483` |
| F20 | elm-doc-preview 6.0.1 tries `npx --no-install elm`, then `elm` on `PATH`, running `elm --version` (stdout only) and `elm make --docs=<tmp>.json --report=json` in the package directory. Stock elm rejects `effect module` and kernel imports outside `@elm`. | `lib/elm-doc-server.js:97-100,243` |
| F21 | `ECO_KERNEL_GUARD` only protects **binding construction**. Binding bodies run later inside `stepProcess`, and nothing catches exceptions there. | `KernelExports.h:44-54`; `TaskBinding.hpp:106-118` |
| F22 | The ports/flags preamble (`@__eco_register_ports`) is emitted only when there are ports or a flags decoder. Every `Platform.Program` has a flags decoder. It runs inside `eco_main`, before `initWorker` reads `managers_`, in AOT (`eco_entry.cpp:121→127`), JIT (`EcoRunner.cpp:254→277`) and embed (`eco_embed.cpp:195→222`). | `Functions.elm:58-285`; `EntryPrep.elm:131-160`; `PlatformRuntime.cpp:166-171,876` |
| F23 | Elm has no re-exports and no "friend" modules: a constructor can only be used inside its own module. An exposed `type alias X = M.Internal.X` gives users the type without the constructor; stock elm accepts this and docs.json shows the alias. | review R2.1 (stock elm 0.19.1 test) |
| F24 | Heap-reset test harnesses destroy RootSets while thread-locals survive, so scanner registration must be keyed on `Allocator::heapGeneration()`. | `runtime/src/allocator/RuntimeExports.cpp:4584-4609` |

---

## 3. Architecture

### 3.1 Module map

Kernel homes are unique across elm/core, elm/*, eco/kernel and the compiler's fact tables (F8). Phase 1
step 1 checks this mechanically.

| Elm module | Exposed? | Effect module (manager key) | Kernel home | C++ library |
|---|---|---|---|---|
| `System` | yes | yes — `"System"` | `System` | `EcoSystem_System` |
| `Stream` | yes | no | `Stream` | `EcoSystem_Stream` |
| `Stream.Log` | yes | no | — | — |
| `Stream.Internal` | **no** | no | — | — |
| `System.File` | yes | yes — `"System.File"` | `FileSystem` | `EcoSystem_FileSystem` |
| `System.File.Internal` | **no** | no | — | — |
| `System.File.Path` | yes | no | none (pure Elm) | — |
| `System.File.FileHandle` | yes | no | `FileSystem` | `EcoSystem_FileSystem` |
| `System.Process` | yes | yes — `"System.Process"` | `ChildProcess` | `EcoSystem_ChildProcess` |
| `System.Terminal` | yes | yes — `"System.Terminal"` | `Terminal` | `EcoSystem_Terminal` |
| `Http.Server` | yes | yes — `"Http.Server"` | `HttpServer` | `EcoSystem_HttpServer` |
| `Http.Server.Internal` | **no** | no | — | — |
| `Http.Server.Response` | yes | no (`send` uses `System.endSimpleProgram`) | `HttpServer` | `EcoSystem_HttpServer` |
| `Http.Stream` | yes | no (`request` = `Task.perform`) | `HttpStream` | `EcoSystem_HttpStream` |
| shared C++ services | — | — | — | `EcoSystem_Core` |

`ECO_SYSTEM_MODS = Core System Stream FileSystem ChildProcess Terminal HttpServer HttpStream`.

**Internal modules (F23).** Opaque types that more than one module must construct live in an unexposed
`Internal` module. The public module exposes a type alias:

| Type (public alias) | Defined in | Constructed by |
|---|---|---|
| `Stream.Readable a`, `Stream.Writable a`, `Stream.Transformation r w` | `Stream.Internal` (`Readable Int`, `Writable Int`, `Transformation Int`) | `Stream`, `System` (stdio), `System.File`, `System.Process`, `Http.Stream` |
| `System.File.Error` | `System.File.Internal` (`Error { path : Path, code : String, message : String }`) | `System.File`, `System.File.FileHandle` |
| `Http.Server.Response.Response` | `Http.Server.Internal` (`Response { key : Int, status : Int, headers : List ( String, List String ), body : Body }`) | `Http.Server` (tagger), `Http.Server.Response` |

Types whose constructors users need (`EntityType(..)`, `Method(..)`, …) stay in the public module.
When an `Internal` module needs one of them, it takes the constructor as a function argument instead
of importing the public module, which would create an import cycle. For example,
`decodeMetadata : (Int -> entity) -> List Int -> MetadataOf entity`, where
`type alias MetadataOf e = { entityType : e, deviceID : Int, … }` is defined in `System.File.Internal`
and `System.File` exposes `type alias Metadata = MetadataOf EntityType`.

### 3.2 Elm/kernel boundary rules

- **B1 Types allowed across the boundary.** Kernels accept and return only `Int`, `Float`, `Bool`, `String`, `Bytes`, `List` of
  these, `Maybe`, tuples (at most 3 slots; nest them for more), `()`, Elm closures, `Int` handle ids, and
  polymorphic payloads (`a`, always boxed), and `Process.Id` (only in effect-manager tagger arguments, C.3).
  **No records and no package ADTs** (F4). Elm wrappers take
  config records apart into scalars and build the result records and ADTs.
- **B1a The one foreign ADT read by a kernel.** The `HttpStream` kernel reads elm/http's
  `Header` values, read-only. `type Header = Header String String` is constructor 0 with two boxed
  Strings (`elm/http 2.0.0 Http.elm:198`), and the native elm/http kernel reads it the same way
  (`elm-kernel-cpp/src/http/HttpExports.cpp:505-516`). Building a list of name/value pairs in Elm is
  impossible because `Header` is opaque, so this is the minimal coupling. A test pins it (Phase 8).
- **B2 Errors.** Errors cross as tuples:

  | Shape | Tuple | Used by |
  |---|---|---|
  | `FErr` | `( String code, String message )`, where `code` is the errno name, e.g. `"ENOENT"` | FileSystem kernels, `HttpServer.createServer` |
  | `SErr` | `( Int kind, String reason )`, mask 0x1 | Stream kernels |
  | `RunErr` | `( Int kind, String errnoName, ( Int exitCode, Bytes stdout, Bytes stderr ) )`, masks 0x1 / 0x1 | `ChildProcess.run` (B.4) |
  | `Never` | — | `HttpStream.send` encodes every outcome in its result (B.7) |

  Elm decoders build the public error types. A decoder lives in the module that owns the error type's
  constructors, or in its `Internal` module when the type is aliased (§3.1).
- **B3 Handles.** Handles are `Int` ids issued by C++ tables. They are wrapped in Elm by the
  `Internal` constructors (§3.1).
- **B4 Dicts and headers.** A `Dict String String` crosses as `List ( String, String )`. Header maps
  (`Dict String (List String)`) cross as `List ( String, List String )`, which keeps duplicate header
  names. Elm builds the Dicts.
- **B5 Bindings.** Every kernel that performs IO or touches a kernel table returns a Task built with
  `makeBinding` or `makeAsyncBinding` (F2). The only pure kernels allowed are side-effect-free
  conversions: `Stream.utf8ToString : Bytes -> Maybe String` and `Stream.stringToUtf8 : String -> Bytes`.
- **B6 Exceptions.** Every export is wrapped in `ECO_KERNEL_GUARD`, **and every binding body in
  `ECO_SYSTEM_BODY_GUARD`** (F21, §3.3 G2).
- **B7 Effect-manager types.** Effect-manager `MySub`/`MyCmd` constructors carry only B1 field types
  and **single-argument taggers whose argument is one boxed tuple or String**, so the C++ managers can
  compose taggers the way `TimeEffectManager` does. The layouts are in Appendix C; each C++ manager
  header repeats its layout with a pointer to the Elm declaration.
- **B8 Paths.** Paths cross as POSIX strings (`Path.toPosixString`) and come back as strings, which
  Elm parses with `Path.fromPosixString`.

### 3.3 GC safety and kernel code patterns (mandatory)

These rules distil the rooting discipline of `eco-kernel-cpp/` and `elm-kernel-cpp/`, which has already
been through several rounds of GC bug fixing. Every C++ file in `system-kernel-cpp/src/eco-system/`
starts with a header comment that names the templates it uses. Every pull request ticks the checklist in
§3.3.4.

#### 3.3.1 Rules

| # | Rule | Source / precedent |
|---|---|---|
| G1 | Only the main thread touches the heap. Worker, channel, signal and accept threads see only POD and tokens, and never call Elm, allocate, or call `Debug.log` (stdout capture is thread-local). | F1; lessons in `time-every-via-scheduler-timerservice.md:9`, `timer-effect-test-runtime-support.md:64` |
| G2 | **IO only inside bindings.** An export only decodes and roots its arguments, packs them into one `captured` payload, and returns `makeBinding`/`makeAsyncBinding`. Packing uses `tuple2/3` with the F5 masks; **four or more arguments go in nested tuples**. Bodies are wrapped in `ECO_SYSTEM_BODY_GUARD(Shape, ...)` (sync) or `ECO_SYSTEM_ASYNC_GUARD(Shape, resume, token, counted, ...)` (async). Both are defined in §3.3.2; they produce the kernel's own error shape and always complete async tasks. Use the `std::error_code` overloads of `std::filesystem` in bodies. | KERNEL_TASK_IO_001/002; F21; `File.cpp:279,363` are bodies that throw |
| G3 | **Read → syscall → allocate.** In a body, first copy every input out of the heap (`toString`, `listToStringVector`, Bytes into `std::string`), then do the syscall, then allocate the result. Capture `errno` right after the failing call. | HH Pattern 3 (:44-47); `File.cpp:97,489-497`; `Process.cpp:60-61` |
| G4 | **Root before the next allocation.** Root every live `HPointer` local with `Elm::StackRootGuard` before the next allocation, and read guarded locals again after each call. Helpers (`custom`, `record`, `tuple*`, `cons`, `just`, `ok`, `allocTask`) root their own arguments, so a fresh result passed *directly* into one is safe. | HEAP_011; `KernelHelpers.hpp:105-111`; HH:24-33 |
| G5 | **No raw pointers across allocations or Elm calls.** `void*`, `Custom*`, `Tuple2*`, `byteBufferData` and `ListCursor` die at the next allocation or Elm call. Resolve, copy, and close the scope. Loops that allocate or call Elm use `RootedListCursor`. | HH:754-768,827-836; `HttpExports.cpp:431-466`; lesson "cached `Cons*`" `TaskEffectManager.cpp:101-105` |
| G6 | **Bounded root stack.** Per call, use O(1) root-stack records. Root N results with one `pushStackRootRange` over a pre-sized vector filled with `listNil()`, or with `RootedSlots`/`RootedElems`. Build lists with `listFromPointers`. Never hand-roll `cons` loops and never push one guard per element. | `KernelHelpers.hpp:160-172`; `Http.cpp:254-267`; `kernel-root-stack-bounded-rooting.md`; `test/scripts/check-root-bounded.py` |
| G7 | **Representation.**<br>- Bytes: `allocByteBufferBlank(n)` then fill without allocating; `n == 0` gives `emptyBytes()` and no zero-length objects (HEAP_071).<br>- Strings: `allocStringFromUTF8`; read them with `StringOps::toStdString`.<br>- Nullary constructors only via `custom()` with no fields (HEAP_044).<br>- Int/Float/Char stored **unboxed with the right kind mask** in anything handed to Elm (HEAP_046).<br>- Never resolve constants (Empty/True/False/Unit/Nothing); test them with `isConstant`/`isNil`. | `File.cpp:157-176,571-574`; HH:1626-1647 |
| G8 | **No writes after survival.** Fill closure captures and buffers right after allocating, with no allocation in between. Never write into an object that may have survived a GC (HEAP_SNAPSHOT_001). | `TaskBinding.hpp:145-161`; `BytesExports.cpp:393-409` |
| G9 | **Long-lived references:**<br>- Store them as encoded `uint64_t` in a main-thread-only registry, evacuated in place by an external scanner with a static name.<br>- Register the scanner **keyed on `heapGeneration()`** (F24); register lazily from the first kernel use.<br>- A registry touched only on the main thread needs no mutex. If a mutex is unavoidable, never allocate while holding it (PORT_004): snapshot the words under the lock and decode after unlocking.<br>- When copying a value out, root it straight away. | `MVar.cpp:39-51,343-365`; `RuntimeExports.cpp:4584-4609`; `TimeEffectManager.cpp:53-56,141-171` |
| G10 | **Async protocol:**<br>- Register the resume (or a bundle Custom) → `incrementPendingAsync()` **before** publishing the POD → submit.<br>- The drain loops until its queue is empty. For each item: `takePendingResume`; an orphaned token still decrements; root; build; resume; then decrement **exactly once on every path** (RAII `AsyncRelease`).<br>- **Every path resumes or fails the task**; never return without one (`HttpExports.cpp:594-597` is a known hang). | `Process.cpp:170-223`; `Http.cpp:288-350`; `PortRuntime.cpp:391-393,462-471` |
| G11 | **Calling Elm:**<br>- Root the closure, its arguments and the result. Use the PAP-aware `eco_apply_closure*` / `Scheduler::callClosure1..4`; for unboxed arguments use `eco_apply_closure_typed` with `makeEvalParamLayout`.<br>- After **any** Elm call, treat every raw pointer, registry iterator and cached snapshot as invalid; the call can re-enter onEffects, drain, or this kernel. | `TimeExports.cpp:198-215`; `StringExports.cpp:341-348`; `PlatformRuntime.cpp:297,375-381,625-637`; `Scheduler.cpp:905` |
| G12 | **Messages from drains:** root `router` and `msg`, call `PlatformRuntime::sendToApp(router, msg)` (or `sendToSelf`), then call `Scheduler::drain()` **once per message**. | F11; lessons "double delivery" (`elm-http-track-progress.md` Q-G) |
| G13 | **Processes** are immutable snapshots. Store the process **id** and look it up with `Scheduler::latestProcessById` when you need it later. The one exception is handing a fresh `rawSpawn` result to Elm (C.3 `onInit`): keep that snapshot rooted from `rawSpawn` until it is delivered. | `PlatformRuntime.cpp:189-200,246-253`; `Scheduler.cpp:426` |
| G14 | **Manager registration** roots every closure while allocating the next one. Copy the **`PortRuntime.cpp:198-207`** form, *not* Time/Http/Task, whose registrations happen to be unrooted. | lesson R-GC (`elm-kernel-cpp` scan) |
| G15 | Never sort a rooted `HPointer` buffer; sort indices instead. | `ListExports.cpp:851-866` |

#### 3.3.2 Templates

These are the skeletons to copy. Names in `<>` are placeholders. Every file lives in namespace
`Eco::System` and starts with `#include "eco-system/Core/Core.hpp"`. **Every helper used below is
declared in that header** (Phase 2 step 8 creates it):

```cpp
// system-kernel-cpp/src/eco-system/Core/Core.hpp (abridged; the authoritative list)
namespace Eco::System {
using namespace ::Elm;                                   // HPointer, Unboxable, Tuple2, Custom, PK_*
namespace alloc  = ::Elm::alloc;                         // HeapHelpers.hpp
namespace Export = ::Eco::Kernel::Export;                // eco-kernel ExportHelpers.hpp
using ::Elm::Platform::Scheduler; using ::Elm::Platform::PlatformRuntime;
using ::Elm::Platform::makeBinding; using ::Elm::Platform::makeAsyncBinding;   // runtime TaskBinding.hpp
inline uint64_t enc(HPointer h);                         // = Export::encode
inline HPointer dec(uint64_t w);  inline HPointer dec(void* w);
inline Tuple2* asTuple2(HPointer h);  inline Tuple3* asTuple3(HPointer h);   // resolve; no allocation
std::string toStdString(HPointer s);                     // empty-string safe (KernelHelpers toString)
std::string toStdBytes(HPointer b);                      // T4 copy-out
HPointer succeed(HPointer v); HPointer succeedUnit(); HPointer succeedInt(int64_t);
HPointer succeedString(const std::string&); HPointer succeedBytes(const std::string&);
HPointer failFErr(const std::string& code, const std::string& msg);   // ( String, String )
HPointer failErrno(int err);                                          // failFErr(errnoName(err), strerror(err))
HPointer failSErr(int kind, const std::string& reason);               // ( Int, String ) mask 0x1
HPointer failRun(int kind, const std::string& code, int exitCode,
                 const std::string& out, const std::string& err);     // B.4 triple
HPointer makeKillHandle(uint64_t token, CancelFn cancel);             // T7
}
```
Use `Scheduler::callClosure1..4` (`Scheduler.hpp:83-92`) for 1–4 arguments, and `eco_apply_closure` /
`eco_apply_closure_typed` for anything else.

**Body guards (G2).** Both are variadic, so `BODY` may contain commas.
- `ECO_SYSTEM_BODY_GUARD(Shape, ...)` wraps a `makeBinding` body. On an exception it `return`s the
  failure for the kernel's error shape: `FErr` → `failFErr("EIO", what)`, `SErr` → `failSErr(1, what)`,
  `RunErr` → `failRun(0, "EIO", -1, "", "")`, `Never` → `reportFatal(what)`.
- `ECO_SYSTEM_ASYNC_GUARD(Shape, resume, token, counted, ...)` wraps a `makeAsyncBinding` body.
  `token` is a `uint64_t` local, initialised to 0, that the body sets when it registers; `counted` is a
  `bool` local that the body sets when it calls `incrementPendingAsync()`. On an exception:
  1. if `token != 0`: `takePendingResume(token)`, plus `decrementPendingAsync()` if `counted`;
  2. `Scheduler::callClosure1(resume, <failure per Shape>)`;
  3. `return alloc::unit()`.

  The async task therefore always completes (G10).

**T1 — synchronous binding (S mode).**
```cpp
// Export: decode → root → pack → binding. No IO here (G2).
extern "C" uint64_t Eco_Kernel_<Home>_<fn>(uint64_t a, int64_t n) {
    ECO_KERNEL_GUARD(
        HPointer aHP = dec(a);
        Elm::StackRootGuard g(&aHP);
        HPointer payload = alloc::tuple2(alloc::boxed(aHP), alloc::unboxedInt(n), 0x4);
        return enc(makeBinding<fnBody>(payload));
    )
}
// Body: read → syscall → allocate (G3).
static HPointer fnBody(HPointer captured) {
    ECO_SYSTEM_BODY_GUARD(FErr,
        std::string s; int64_t n;
        { Tuple2* t = asTuple2(captured); s = toStdString(t->a.p); n = t->b.i; }   // no allocation in scope
        int rc = ::<syscall>(s.c_str(), n);
        if (rc < 0) { int e = errno; return failErrno(e); }
        return succeedUnit();
    )
}
```
A `tuple3` holds at most three slots, so **four or more arguments are packed as nested tuples**, e.g.
`tuple2(boxed(tuple2(...)), boxed(tuple2(...)), 0)`.

**T2 — pool-async binding (P mode).**
```cpp
struct <Fn>Req { std::string path; };                       // POD only (G1)
struct <Fn>Res { int err = 0; std::string data; };          // POD only

static HPointer fnAsyncBody(HPointer captured, HPointer resume) {   // makeAsyncBinding body
    uint64_t token = 0; bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(FErr, resume, token, counted,
        <Fn>Req req{ toStdString(captured) };                       // G3: read first
        auto& s = Scheduler::instance();
        token = s.registerPendingResume(resume);                    // G10
        s.incrementPendingAsync(); counted = true;
        SysWorkPool::instance().submit(token,
            [req = std::move(req)]() -> PoolResult {                // worker thread: POD only
                <Fn>Res r; /* blocking syscalls; errno into r.err */
                return PoolResult::of(std::move(r));
            },
            &fnComplete);                                           // runs on the main thread
        return alloc::unit();                                       // kill handle: unit, or T7 if cancellable
    )
}
// Main thread, called by the pool drain with the resume already taken and rooted.
static HPointer fnComplete(PoolResult& pr) {
    auto& r = pr.as<<Fn>Res>();
    if (r.err) return failErrno(r.err);
    return succeedBytes(r.data);                                    // allocates; the drain roots the result
}
```
The pool drain is written once in `Core` (Phase 2 step 8). For each result:
1. pop it;
2. `takePendingResume(token)`; if nil (the task was killed), decrement and continue;
3. root the resume;
4. `task = complete(pr)`, then root the task;
5. `Scheduler::callClosure1(resume, task)`;
6. `decrementPendingAsync` through `AsyncRelease`;
7. after the loop, `Scheduler::instance().drain()`.

**T3 — returning N composite values (G6).**
```cpp
std::vector<HPointer> ptrs(items.size(), alloc::listNil());
auto& rs = Allocator::instance().getRootSet();
size_t saved = rs.stackRangePoint();
rs.pushStackRootRange(ptrs.data(), ptrs.size(), ~0ULL);
for (size_t i = 0; i < items.size(); ++i) {
    HPointer name = alloc::allocStringFromUTF8(items[i].name);
    ptrs[i] = alloc::tuple2(alloc::boxed(name), alloc::unboxedInt(items[i].kind), 0x4);  // fresh → helper roots it
}
HPointer list = alloc::listFromPointers(ptrs);
rs.restoreStackRangePoint(saved);
return succeed(list);
```

**T4 — Bytes in and out (G5, G7).**
```cpp
std::string copy;
{ void* p = alloc::resolveBytesOrNull(bytesHP);       // nullptr for emptyBytes()
  if (p) { auto v = alloc::byteBufferView(p); copy.assign((const char*)v.data, v.length); } }
// ... later, the result:
if (n == 0) return succeed(alloc::emptyBytes());
alloc::BlankByteBuffer bb = alloc::allocByteBufferBlank(n);
std::memcpy(bb.bytes, src, n);                        // no allocation in between (G8)
return succeed(bb.hp);
```
(`byteBufferView` returns `{data, length}`, `HeapHelpers.hpp:2344-2349`.)

**T5 — registry plus scanner (G9).**
```cpp
struct Registry { std::unordered_map<int64_t, Entry> m; uint64_t gen = 0; bool reg = false; };
static Registry& registry() {
    static Registry r;                                       // main-thread only: no mutex
    uint64_t g = Allocator::instance().heapGeneration();
    if (!r.reg || r.gen != g) {
        r.reg = true; r.gen = g; r.m.clear();                // entries of a dead heap are meaningless
        Allocator::instance().getRootSet().addExternalRootScanner(
            [rp = &r](RootSet::EvacuateFn evac) {
                for (auto& [id, e] : rp->m)
                    for (uint64_t* w : e.words()) if (*w) evac(*w);  // evacuate in place
            }, "eco-system-<name>");
    }
    return r;
}
```

**T6 — C++ effect manager.** The full skeleton is in Appendix C.0. In outline:
- `extern "C" uint64_t Eco_System_registerManager_<Key>()` returns `enc(alloc::unit())`, matching the
  `!eco.value` result that `Ctx.registerKernelCall` declares (precedent:
  `Elm_Kernel_Platform_registerOutgoingPort`, `KernelExports.h:329`).
  - It is called from the compiler-emitted preamble (Phase 1 step 6).
  - It allocates the five closures in the rooted PortRuntime form (G14) and calls
    `PlatformRuntime::instance().registerManager("<Key>", info)`.
- `onEffects(router, cmds, subs, state)`:
  - walks the lists with `RootedListCursor`;
  - decodes each constructor per Appendix C;
  - updates the T5 registry (encoded router and taggers);
  - starts or stops services;
  - returns `taskSucceed(unit())`.
- `subMap(f, sub)` / `cmdMap(f, cmd)` rebuild the constructor with a composed tagger, copying
  `TimeEffectManager.cpp:320-399`: root the fields, then `allocClosure`, then `closureCapture` with no
  allocation in between.
- `onSelfMsg` returns `taskSucceed(state)`.
- Event delivery: an async-source drain snapshots the registry entry, roots the router and tagger,
  builds the tagger argument, calls the tagger (G11), then calls `sendToApp` and `drain()` (G12).

**T7 — a kill handle.** `Process.kill` calls this closure with `()` (`Scheduler.cpp:492-508`). The handle
captures the **resume token**. Exactly one side removes the job and decrements `pendingAsync`.
```cpp
static void* killEval(void* args[]) {                  // args[0] = token, args[1] = cancel fn (raw bits), args[2] = ()
    uint64_t token = reinterpret_cast<uint64_t>(args[0]);
    auto cancel = reinterpret_cast<CancelFn>(reinterpret_cast<uint64_t>(args[1]));
    auto& s = Scheduler::instance();
    (void)s.takePendingResume(token);                  // discard: the killed task must never resume
    if (cancel(token)) s.decrementPendingAsync();      // we removed the job: we decrement
    return reinterpret_cast<void*>(enc(alloc::unit()));
}
HPointer makeKillHandle(uint64_t token, CancelFn cancel) {      // CancelFn = bool(*)(uint64_t)
    HPointer cl = alloc::allocClosureK(&killEval, /*max_values=*/3, PK_Boxed);
    void* p = Allocator::instance().resolve(cl);       // no allocation until both captures are done (G8)
    alloc::closureCapture(p, alloc::unboxedInt((int64_t)token), PK_Int);
    alloc::closureCapture(p, alloc::unboxedInt((int64_t)reinterpret_cast<uint64_t>(cancel)), PK_Int);
    return cl;
}
```
**Rule.** `cancel(token)` returns `true` only if it removed a job that had not yet produced a result;
in that case the kill handle decrements. Otherwise the result is already queued. The drain then finds
`takePendingResume(token)` nil, decrements, and skips the resume (G10). So exactly one side decrements.
Typed captures arrive as raw bits (`MVar.cpp:151-161,295-301`).

**T8 — calling a tagger from a drain (G11, G12).**
```cpp
HPointer router = dec(e.routerEnc), tagger = dec(e.taggerEnc),
         arg = alloc::listNil(), msg = alloc::listNil();
Elm::StackRootGuard g({&router, &tagger, &arg, &msg});
HPointer s = alloc::allocStringFromUTF8(path);
arg = alloc::tuple2(alloc::unboxedInt(kind), alloc::boxed(alloc::just(alloc::boxed(s), true)), 0x1);
msg = Scheduler::callClosure1(tagger, arg);
PlatformRuntime::instance().sendToApp(router, msg);
Scheduler::instance().drain();
```
`alloc::just(...)` allocates while `s` is fresh. That is safe because the helper roots its own argument
(G4). Do not reorder it.

**T9 — an operation that may complete immediately or park (Q mode: Stream read/write/close/pipeTo).**
```cpp
static HPointer readBody(HPointer captured, HPointer resume) {          // makeAsyncBinding body
    uint64_t token = 0; bool counted = false;
    ECO_SYSTEM_ASYNC_GUARD(SErr, resume, token, counted,
        int64_t id = /* unboxed Int from captured */;
        StreamPair* p = StreamTable::get(id);                           // re-fetch after any Elm call
        if (auto ready = p->tryReadNow()) {                             // immediate path
            HPointer task = ready->ok ? succeed(dec(ready->valueEnc)) : failSErr(ready->kind, ready->reason);
            Elm::StackRootGuard g(&task);
            Scheduler::callClosure1(resume, task);
            return alloc::unit();
        }
        token = Scheduler::instance().registerPendingResume(resume);    // park path
        if (p->kind == Kind::ChannelSource) {                           // external IO: keep alive
            Scheduler::instance().incrementPendingAsync(); counted = true;
            p->channel->requestRead(token, 64 * 1024);
        }                                                               // in-memory: no pendingAsync
        p->parkRead(token, counted);
        return alloc::unit();
    )
}
// Completion, from pump() or a channel drain:
static void completeParked(uint64_t token, bool counted, HPointer task /* rooted by the caller */) {
    auto& s = Scheduler::instance();
    HPointer resume = s.takePendingResume(token);
    if (!alloc::isNil(resume)) { Elm::StackRootGuard g(&resume); Scheduler::callClosure1(resume, task); }
    if (counted) s.decrementPendingAsync();
}
```
After completing parked tokens from inside an async drain, call `Scheduler::instance().drain()` once.
Completions that happen inside a binding body (one stream op completing another) do not call `drain()`:
the scheduler is already stepping.

#### 3.3.3 GC verification gates

Every phase from Phase 3 onwards must pass all of these before it is done:
1. **Normal suite:** `cmake --build build --target full 2>&1 | tee /tmp/test_output.txt`, run **once**
   (CLAUDE.md).
2. **Validate tree:**
   - Configure once with `cmake -DECO_HEAP_VALIDATE=ON --preset build -B build-validate`
     (`guides/test-fails.md:4`). The first build takes about 30 minutes, later ones about 5.
   - Run `ECO_NURSERY_POISON=1 ECO_HEAP_CONFIG=$PWD/benchmarks/heap-config-gc-pressure.json
     build-validate/test/test --filter eco-system 2>&1 | tee /tmp/test_output_validate.txt`.
   - This is the gate that catches a forgotten root (`guides/kernel-opt-loop.md:293-317`).
3. **Stress:**
   - Add every phase's long-running scenarios to `test/stress-elm/src/` as `EcoSystem*.elm` files,
     using `StressHarness.elm`.
   - Phase 1 step 8i makes `stress-elm` able to import eco/system.
   - Run `ECO_NURSERY_POISON=1 build-validate/test/stress-test --timeout 5m --filter EcoSystem`.
4. **Root-bound check:** `python3 test/scripts/check-root-bounded.py`, with no arguments. Phase 1 step 8j
   adds `"system-kernel-cpp/src"` to the script's hard-coded `DIRS` (`check-root-bounded.py:22-23`).
   Passing the directory as an argument would scan nothing: the script takes the repo root as `argv[1]`.

#### 3.3.4 Review checklist

Copy this into every PR description that adds or changes C++:
- [ ] No heap access, Elm call or `Debug.log` off the main thread (G1).
- [ ] Exports only pack and bind; bodies are inside `ECO_SYSTEM_BODY_GUARD` and use `error_code` APIs (G2).
- [ ] Inputs are copied out before syscalls; errno is captured immediately (G3).
- [ ] Every `HPointer` local is rooted before the next allocation; nothing raw is held across one (G4, G5).
- [ ] No per-element guards and no hand-rolled cons loops (G6).
- [ ] Unboxed kinds are right in every tuple/custom handed to Elm; there are no zero-length objects (G7).
- [ ] Captures and buffers are filled right after allocation (G8).
- [ ] Registries hold encoded words, have a scanner keyed on `heapGeneration`, and never allocate under a mutex (G9).
- [ ] Every async token is decremented exactly once, and every path resumes or fails (G10).
- [ ] After each Elm call, nothing stale is reused (G11). `drain()` is called after every `sendToApp`/`sendToSelf` (G12).
- [ ] The three gates in §3.3.3 are green, with their output files attached.

### 3.4 Threads and services (`EcoSystem_Core`)

All services are **leaky singletons** (`static T* p = new T;`) with **detached** threads, like
`WaitService.cpp:10-23`. That way `std::exit` (from `exitWithCode`) never runs destructors that race
with live threads (`eco_embed.cpp:158-166`). Every fd the package creates is opened with `O_CLOEXEC`.
On macOS, `pipe()` is followed by `fcntl(FD_CLOEXEC)`; this is race-free because pipes are created on
the main thread and children are spawned only from the main thread.

**`SysWorkPool`** runs short blocking syscalls on `min(4, hardware_concurrency)` threads.
- `submit(token, std::function<PoolResult()> work, CompleteFn complete)`, where `CompleteFn =
  HPointer(*)(PoolResult&)`.
- One result queue, drained by the T2 drain.
- `PoolResult` is a type-erased POD holder with a small-buffer `std::any`-like interface that holds no
  `HPointer`.

**`FdChannel`**, one per fd-backed stream (stdio, child pipes, file streams, sockets).
- It owns a thread that runs `poll({fd, wakePipe[0]})`.
- `requestRead(token, maxBytes)` and `requestWrite(token, std::string bytes)` queue POD requests;
  `shutdown()` writes to the wake pipe.
- Reads return `(token, bytes | EOF | errno)` and writes return `(token, written | errno)`; results go
  to a channel-results queue that a Core drain dispatches back to the `StreamTable`.
- **Only the channel thread closes its fd**, and only after it has finished; this avoids reading a
  reused fd number. **fds 0, 1 and 2 are never closed.** Closing a stdio stream marks it closed and
  stops polling.
- Retry on `EINTR`. Signal handlers are installed with `SA_RESTART`.

**`SignalService`** handles SIGINT, SIGTERM and SIGWINCH.
- It uses a self-pipe written by `sigaction` handlers, and one thread posts `(signo)` events.
- It installs a handler for a signal **only while some Elm subscription to it exists**, and restores
  the previous handler when the last subscription goes away.
- It is disabled in embed mode (§3.7).

**`HttpStreamService`** (in `EcoSystem_HttpStream`, Phase 8) runs one detached thread per streaming
transfer, each with its own curl easy handle. Streaming transfers cannot use the shared `HttpService`
worker: that runs requests one at a time with `curl_easy_perform`, so a transfer waiting on Elm to
produce or consume chunks would block every other elm/http request.
- The request body is pulled from an upload `ByteChannel` by `CURLOPT_READFUNCTION`.
- The response body is pushed into a download `ByteChannel` by `CURLOPT_WRITEFUNCTION`. Each channel is
  bounded at 4 chunks of 64 KiB, and the curl callbacks block on a full or empty channel.
- When the headers end, the thread posts a POD `HeadersReady` event.

**Existing runtime services, extended in Phase 2:**
- `WaitService` gets per-client **lanes** and an `unclaimed_` map, and reports the raw wait status.
- `TimerService` gets `cancel(token)`.

**Keep-alive rule:** a kernel holds one `pendingAsync` count while there is external IO that should
keep the program alive.

| Holds a count | Does not hold a count |
|---|---|
| a parked fd read/write | in-memory stream parking |
| a pool job | signal subscriptions |
| a running non-detached child | resize subscriptions |
| a `runDuration` timer (until it fires or is cancelled) | |
| a listening server | |
| an active file watch | |

This matches Node: a program waiting only on an in-memory stream exits.

### 3.5 Stream kernel (`EcoSystem_Stream`)

There is one main-thread-only `StreamTable`, a T5 registry, mapping `int64_t id → StreamPair`. A
`Readable`, `Writable` or `Transformation` handle is the pair id. Which side is meant follows from the
Elm type and the kernel function called.

```
enum class WState { Open, Closing, Closed, Errored };
enum class RState { Open, Closed, Errored };
struct PendingWrite { uint64_t token; uint64_t valueEnc; bool completeOnTransform; };
struct StreamPair {
  Kind kind;                                // Identity | Custom | Codec | ChannelSource | ChannelSink
  std::deque<PendingWrite> writeQ;          // accepted, not yet transformed
  std::deque<uint64_t>     readQ;           // encoded values ready to read
  size_t writeCap, readCap;                 // identity: both ≥1; custom/codec: write ≥1, read ≥0
  WState w = Open; RState r = Open; std::string wReason, rReason;
  bool readLock = false;                    // a read is parked, or this readable is piped
  bool writeLock = false;                   // a write waits for writeQ room, or this writable is piped
  uint64_t parkedReadToken = 0;
  std::deque<PendingWrite> waitingForRoom;  // at most one unless piped (lock)
  uint64_t closeToken = 0;
  uint64_t customFnEnc = 0, customStateEnc = 0;
  CodecState codec;                         // zlib z_stream / utf8 carry bytes
  ByteChannel* channel = nullptr;           // ChannelSource / ChannelSink
};
```

**Byte channels.** `ChannelSource`/`ChannelSink` work over an abstract `ByteChannel` with the
operations `requestRead(token, maxBytes)`, `requestWrite(token, bytes)`, `close()` and `shutdown()`.
Results come back as POD through the Core channel drain. `FdChannel` (§3.4) is one implementation and
`HttpTransferChannel` (Phase 8) another. In the rest of the plan, *FdSource*/*FdSink* means a
ChannelSource/ChannelSink over an `FdChannel`.

All encoded words, including `valueEnc`, custom fn/state and parked values, are evacuated by the
StreamTable scanner. A pair is erased once both sides are terminal and no token is parked. Unreachable
open pairs leak, because the runtime has no finalizers (R3).

#### Semantics (gren-core 7.5.0, checked against WHATWG behaviour by reviewer R2)

| Op | Behaviour |
|---|---|
| `read rd` | If `readLock` → fail `Locked`. If `readQ` is non-empty → pop, run `pump()`, succeed. If `r == Closed` → `Closed`. If `r == Errored` → `Cancelled rReason`. Otherwise park: set `readLock` and `parkedReadToken`, then `pump()` (a parked reader opens the gate when `readCap == 0`). FdSource with an empty queue: also `channel->requestRead` (keep-alive). |
| `write v wr` | If `writeLock` → `Locked`. If `w` is Closing or Closed → fail `Cancelled "WritableStream is closed"`. If `w == Errored` → `Cancelled wReason`. If `writeQ.size() < writeCap` → push `{token, v, completeOnTransform=true}` and `pump()`. Otherwise set `writeLock` and add to `waitingForRoom`; when room appears, move it in and **release the lock**. The task completes when the value leaves `writeQ` through the transform (FdSink: when the bytes are written). Several writes can be in flight; only waiting for room holds the lock. |
| `enqueue v wr` | Same checks, but completes **as soon as the value is accepted** into `writeQ`. Deviation from gren: enqueue after close **fails** `Cancelled "WritableStream is closed"`; gren would produce an unhandled rejection. |
| `closeWritable wr` | If `writeLock` → `Locked`. Closed/Closing → `Cancelled "WritableStream is closed"`. Errored → `Cancelled wReason`. Otherwise set `w = Closing` and queue behind in-flight writes. When `writeQ` is empty: flush (Codec), set `r = Closed`, `w = Closed`, succeed. Readers get `Closed` once `readQ` drains. FdSink: succeed after the channel has written everything and closed the fd (never 0–2). |
| `cancelReadable reason rd` | If `readLock` → `Locked`. Set `r = Closed` (**later reads give `Closed`**), clear `readQ`, set `w = Errored reason`, and fail every parked or in-flight write with `Cancelled reason`. FdSource: `channel->shutdown()`. |
| `cancelWritable reason wr` | If `writeLock` → `Locked`. Set `w = Errored reason`, `r = Errored reason` (reads give `Cancelled reason`), clear both queues, fail parked writes. FdSink: `shutdown()`. |
| `pump()` (transform step) | While `writeQ` is non-empty and `r == Open` and (`readQ.size() < readCap` or a reader is parked):<br>1. pop `pw`;<br>2. **Identity**: push `pw.value`;<br>3. **Custom**: call the Elm action function (G11) with `(state, value)`. It returns `( Int ctor, state, ( List out, String reason ) )`:<br>&nbsp;&nbsp;- 0 UpdateState: replace the state;<br>&nbsp;&nbsp;- 1 Send: replace the state and push all outputs (**may overfill**);<br>&nbsp;&nbsp;- 2 Close: push the outputs, set `r = Closed` after drain, set `w = Errored "TransformStream has been terminated"`;<br>&nbsp;&nbsp;- 3 Cancel: set `w = Errored reason` and `r = Errored reason`;<br>4. **Codec**: run zlib or utf8 and push the non-empty outputs;<br>5. complete `pw`'s task (succeed, or fail with the pair's error);<br>6. after the loop: if a reader is parked and `readQ` is non-empty, hand the value over directly (`readCap == 0` is a rendezvous); move `waitingForRoom` into `writeQ` while there is room; continue any pipes touching this pair. |
| `pipeThrough t src` | If `src.readLock` or `t.writeLock` → `Locked`. Set both locks permanently and register a pipe `src → t`. Succeed with `Readable t`. |
| `pipeTo dst src` | Same locking. The task completes when `src` closes and `dst` has then been closed. Propagation (WHATWG defaults): `src` closed → close `dst`; `src` errored → abort `dst` with the same reason; `dst` errored or closed → cancel `src`. If either side errors, the task fails with `Cancelled reason`. |
| `fromList xs` (Elm) | `identity (max 1 (length xs)) 1`, enqueue each value, close. |
| Capacities | `identityTransformationWithOptions` clamps both to ≥1 (as gren). `customTransformationWithOptions` clamps write to **≥1** (deviation: gren deadlocks at 0) and read to ≥0. |

Pumps never block and never spawn Elm processes. Resuming parked tasks happens on the main thread,
followed by `Scheduler::drain()` (G12 applies to resumes issued from drains). In-memory parks do **not**
hold `pendingAsync`.

**UTF-8.** `readBytesAsString` and `Http.Server.bodyAsString` use the strict kernel
`Stream.utf8ToString` (B5), because eco's legacy `Bytes.Decode.string` path does not validate.
`textDecoder` is lenient, like WHATWG `TextDecoder`: it outputs U+FFFD, strips a leading BOM, carries
incomplete sequences across chunks, and emits nothing for empty output. `textEncoder` emits nothing for
`""` and carries a high surrogate split across chunks.

### 3.6 Effect managers

These are C++ managers (F10), one per effect module, keyed by module name (§3.1). The layouts are in
Appendix C. Each Elm effect module still declares `effect module … where { … }` with **total, trivial**
Elm `init`/`onEffects`/`onSelfMsg`/`cmdMap`/`subMap`; the JS backend would use them, and the native
backend ignores them.

**Registration (Phase 1 step 6).**
- In the `MonoManagerLeaf` branch of `Generate/MLIR/Functions.elm:515`, look up the leaf's package with
  `Registry.lookupSpecKey specId`, which yields `Mono.Global (ModuleName.Canonical pkg _)`.
- If `pkg == eco/system`, record `(pkg, home)` in the codegen context, deduplicated.
- `generateMainEntry`/`generateRegisterPorts` emit `call @Eco_System_registerManager_<Home with . → _>()`
  for each recorded home, **first inside `__eco_register_ports`**.
- The callee is declared with `Ctx.registerKernelCall` (`Functions.elm:146-176`) with result `!eco.value`;
  the C function returns `uint64_t` (T6).
- The preamble guard (`Functions.elm:62-63,130`) also becomes true when this list is non-empty.
- All three `generateMainEntry` call sites (`Backend.elm:107,242,440`) receive the list.
- The calls are strong references, so only managers a program uses are linked, and they run before
  `initWorker` (F22).

**State.** Each manager keeps C++ state in a main-thread T5 registry. Elm state is `()`.

**Taggers.** Single boxed argument (B7). `subMap`/`cmdMap` compose with a C++ closure, following the
`TimeEffectManager.cpp:320-399` composition pattern.

### 3.7 Program lifecycle

- `defineProgram config` = `Platform.worker`:
  - `init` performs `kEnvironment` (B.1), mapped to `InitDone`.
  - `update` handles `InitDone` and `MsgReceived` exactly as gren `Node.gren:269-343`, with tuples.
  - `subscriptions` gives `Sub.none` until the program is initialised.
- `defineSimpleProgram f` = `defineProgram { init = \env -> ( (), f env ), update = \_ m -> ( m, Cmd.none ), subscriptions = \_ -> Sub.none }`.
- `endSimpleProgram task` = `System` manager `Execute (Task.map (\_ -> ()) task)`. The C++ manager
  `rawSpawn`s each Execute task and ignores its result.
- `exitWithCode n` = `endSimpleProgram (kExitWithCode n)`; `exit = exitWithCode 0`.
  - **Standalone:** `fflush(nullptr)` then `std::exit(n)`. As in gren, pending IO is not waited for.
  - **Embed:** `eco_set_exit_code(n)` then `Scheduler::requestStop()`; `eco_app_join` returns the code.
- `setExitCode n`: `eco_set_exit_code(n)`. `eco_entry` returns it on normal exit; embed returns it from
  `eco_app_join`.
- **`args`** = the full C `argv`, so `args[0]` is the program as invoked. **This differs from gren-node**,
  whose `process.argv` starts with the node binary and the script path: gren programs that drop 2
  entries must drop 1 (D10).
- **`applicationPath`** = the executable's real path: `/proc/self/exe` on Linux, `_NSGetExecutablePath`
  plus `realpath` on macOS.
- **`onEmptyEventLoop`** (Node `beforeExit` semantics):
  1. In `runEventLoop`, when quiescent (empty queue, `pendingAsync == 0`, no stop requested), if there
     are listeners and the hook is **armed**: disarm, **unlock `mutex_`**, call the listeners (which
     `sendToApp` the subscribed msgs and `drain()`), re-lock, and `continue`.
  2. The hook re-arms only when `incrementPendingAsync()` has been called since it last fired.
  3. If the program is quiescent again and the hook is not armed, the loop exits.
  4. Never fires in embed mode.

### 3.8 Platform notes

| Feature | Linux | macOS |
|---|---|---|
| `getCpuArchitecture` | compile-time macros (`__x86_64__`→`"x64"`, `__aarch64__`→`"arm64"`, `__i386__`→`"ia32"`, `__arm__`→`"arm"`, `__powerpc64__`→`"ppc64"`, `__s390x__`→`"s390x"`, `__mips__`→`"mips"`), matching Node's compile-time `process.arch` | same |
| `watch` / `watchRecursive` | inotify (recursive: add a watch per subdirectory; rescan on `IN_CREATE` of a directory) | 1 s polling watcher (stat diff) |
| `setProcessTitle` | `pthread_setname_np(mainThread, first 15 bytes)`. This changes only `comm`, not the full `ps` argv. `eco_entry` records the main thread handle. | no-op, succeeds |
| `Metadata.created` | `statx(STATX_BTIME)`; falls back to ctime | `st_birthtimespec` |
| errno names | `strerrorname_np` (glibc ≥ 2.32), otherwise a table | table (`Core/ErrnoNames.cpp`) |
| `fdatasync` | `fdatasync` | `fcntl(F_FULLFSYNC)`, falling back to `fsync` |

---

## 4. Phases

**Rules for every phase:**
- Run the E2E suite **once** per CLAUDE.md:
  `cmake --build build --target full 2>&1 | tee /tmp/test_output.txt`; read failures from the file.
- From Phase 3 onwards, also pass the §3.3.3 gates.
- `pnpm run docs:check` in `system-kernel-cpp/` must stay green.
- Each phase ends with a short status note appended to §10 (Progress log) of this plan.

### Phase 0 — API stubs and documentation

Goal: every module exists with exact annotations, documentation and `Debug.todo` bodies, and the docs
build. Stock elm can build it because Phase 0 contains no kernel imports and no effect modules (F20).

0.1. **Remove the placeholder.**
- Replace `system-kernel-cpp/src/System.elm`; `noop` goes.
- Leave `src/Eco/Kernel/System.js` and `src/eco-system/System.cpp` alone. Phase 1 replaces them, and
  nothing imports them now.

0.2. **Create the 14 modules** under `system-kernel-cpp/src/`:
- the eleven public ones: `System.elm`, `Stream.elm`, `Stream/Log.elm`, `System/File.elm`,
  `System/File/Path.elm`, `System/File/FileHandle.elm`, `System/Process.elm`, `System/Terminal.elm`,
  `Http/Server.elm`, `Http/Server/Response.elm`, `Http/Stream.elm`;
- the three internal ones: `Stream/Internal.elm`, `System/File/Internal.elm`, `Http/Server/Internal.elm`.

All are plain `module` declarations. Phases 3, 4, 5 and 7 turn `System`, `System.File`,
`System.Process`, `System.Terminal` and `Http.Server` into `effect module`s without changing their
exposing lists.

0.3. **Write each public module:**
- **Exposing list:** `module X exposing (…)` with exactly the names in Appendix A. Use `(..)` only for
  types that Appendix A shows with constructors.
- **Module doc comment:** sections and `@docs` lines that together cover every exposed name, so
  `elm make --docs` passes. Adapt the prose from the gren-node / gren-core doc comments of the same
  function (paths in Appendix E):
  - remove permission and `Init` text;
  - Array→List, `{}`→`()`, `Node.`→`System.`, `FileSystem.`→`System.File.`,
    `ChildProcess.`→`System.Process.`, `HttpServer.`→`Http.Server.`;
  - document the deliberate deviations (§0, §3.5, §3.7).
- **Each exposed value:** a `{-| … -}` comment, the Appendix A annotation, and the body
  `Debug.todo "Implement System API"`.
  - Functions take one named parameter per **top-level** arrow: `customTransformation fn init = …`
    has 2, `readFromOffset fh opts = …` has 2. That way the crash happens at the call, not when the
    module is loaded.
  - Non-function values (`exit`, `defaultTimeout`, `identityTransformation`, `empty`, …) are bare
    `Debug.todo`.
- **Opaque types** owned by the module get a private placeholder constructor holding an `Int`
  (`type Server = Server Int`, `type FileHandle r w = FileHandle Int`, `type Body = …` and so on, as in
  gren). The aliased types point at the Internal modules (§3.1).
- **`System`** also defines its private `Model`/`Msg` (`type Model model = Uninitialized | Initialized
  model`, `type Msg model msg = InitDone ( model, Cmd msg ) | MsgReceived msg`), used by the exposed
  `Program` alias.

0.4. **Internal modules:**
- Each has a one-line module doc comment `{-| Internal; not exposed. -}` and exposes its type with
  constructors.
- Phase 0 content: only the types in §3.1.
- `Http.Server.Internal` also defines `type Body = StringBody String | BytesBody Bytes`.

0.5. **`elm.json`:**
- `exposed-modules`: a **flat list** of the 11 public modules, the usual Elm convention. The grouped
  object form is also valid Elm 0.19, but it is rare and was copied from gren-node's `gren.json`; the
  user asked for the flat list.
- `dependencies`:
  - `"elm/core": "1.0.0 <= v < 2.0.0"`
  - `"elm/bytes": "1.0.0 <= v < 2.0.0"`
  - `"elm/json": "1.1.3 <= v < 2.0.0"`
  - `"elm/time": "1.0.0 <= v < 2.0.0"`
  - `"elm/url": "1.0.0 <= v < 2.0.0"`
  - `"elm/http": "2.0.0 <= v < 3.0.0"` (for `Http.Stream`, D9)
- `summary`: **fewer than 80 bytes**, e.g. `"POSIX-style system programming for Eco programs"`.
- `license`: `"BSD-3-Clause"`.
- `version`: `"1.0.0"`.

0.6. **`README.md`** (elm-doc-preview shows it on the package page):
- a one-paragraph purpose statement (D1);
- the module table from §3.1, public modules only;
- a hello-world example:
  ```elm
  main : System.SimpleProgram msg
  main = System.defineSimpleProgram (\env -> System.endSimpleProgram (Stream.Log.line env.stdout "Hello"))
  ```
- the status line "API preview — every function is a stub until the implementation phases land";
- an attribution paragraph naming gren-node and gren-core and the BSD-3 licence.

0.7. **`LICENSE`**: Appendix D verbatim.

0.8. **pnpm.** `system-kernel-cpp/package.json`:
```json
{
  "name": "eco-system",
  "private": true,
  "license": "BSD-3-Clause",
  "scripts": {
    "docs": "PATH=$PWD/../build/toolchain/bin:$PATH elm-doc-preview",
    "docs:check": "PATH=$PWD/../build/toolchain/bin:$PATH elm-doc-preview --output docs.json"
  },
  "devDependencies": { "elm-doc-preview": "^6.0.1" },
  "packageManager": "pnpm@11.1.3"
}
```
- Copy `compiler/.npmrc` (`ignore-scripts=true`, `strict-peer-dependencies=true`,
  `auto-install-peers=false`).
- Add `node_modules/` to `system-kernel-cpp/.gitignore`. `docs.json` is already ignored there and is
  regenerated.
- Run `pnpm install` and commit `pnpm-lock.yaml` (as `compiler/` does).
- Prerequisite: `build/toolchain/bin/elm` exists after `cmake --preset build` (F20).

0.9. **Bundle hygiene.** In the three eco/system `install(DIRECTORY …system-kernel-cpp/ …)` blocks in
`/work/CMakeLists.txt` (≈ lines 611, 775, 856), add:
```cmake
REGEX "/node_modules(/|$)" EXCLUDE
REGEX "/scripts(/|$)" EXCLUDE
```
Without this, `node_modules/**/*.js` matches `PATTERN "*.js"` and ships in the bundle.

0.10. **Verify:**
- `cd system-kernel-cpp && pnpm install && pnpm run docs:check`. Expect exit 0 and a `docs.json`
  listing exactly the 11 public modules and none of the Internal ones.
- Spot-check that `Stream.Readable` appears as an alias.
- `pnpm run docs` serves `http://127.0.0.1:8000`; check the README and the module pages by hand.
- `cmake --build build --target full` is unaffected, since nothing imports eco/system yet. It may be
  skipped for this phase if only Elm, Markdown and JSON files changed.

**Exit criteria:** docs build clean, all modules and functions are present, README and LICENSE are in
place, and nothing else changed.

### Phase 1 — Build, compiler and test plumbing

1.1. **Kernel home uniqueness check.** Add `scripts/check-kernel-homes.sh`. It scans the **repo only**
and builds:
- `A` = `ECO_ELM_KERNEL_MODS` ∪ `ECO_KERNEL_MODS` ∪ homes appearing in
  `compiler/src/Compiler/GlobalOpt/KernelFacts.elm` and
  `compiler/src/Compiler/MonoSolver/KernelSetFacts.elm` ∪ `Elm_Kernel_<X>_`/`Eco_Kernel_<X>_` prefixes in
  `elm-kernel-cpp/src` and `eco-kernel-cpp/src`;
- `B` = basenames of `system-kernel-cpp/src/Eco/Kernel/*.js`.

It fails if `A ∩ B` is non-empty. Add a `check-kernel-homes` custom target and make `full` depend on it.

1.2. **CMake.**
- `ECO_SYSTEM_MODS = Core System Stream FileSystem ChildProcess Terminal HttpServer HttpStream`.
- `system-kernel-cpp/CMakeLists.txt` gets one `add_library(EcoSystem_<Mod> STATIC src/eco-system/<Mod>/*.cpp)` per
  module. Each has PUBLIC include dirs `src` and `../runtime/src` and `../eco-kernel-cpp/src` (header
  reuse only; no link to EcoKernel), and `cxx_std_20`.
- Every module links `EcoSystem_Core`. `EcoSystem_Stream` links ZLIB (`find_package(ZLIB)`, or the vendored
  `zlibstatic` under `ECO_STATIC`/Windows).
- Windows: each module compiles `src/eco-system/<Mod>/Win32Stubs.cpp` instead of its POSIX sources.
- Add `-lz` to the dynamic Linux AOT link (`EcoNativeDriver.cpp`, next to `-lzip`). Today libz only
  reaches the link transitively.
- Delete the scaffold `src/eco-system/System.cpp` and `noop`.

1.3. **JS stubs.** Create `src/Eco/Kernel/<Home>.js` for every home in §3.1. Each has the header `/*\n\n*/`
and one line per Appendix B function:
`var _<Home>_<fn> = function() { throw new Error("eco/system: the JS target is not supported yet"); };`
Multi-argument functions use `F2`…`F9` wrappers so the generated JS still links. Run
`check-kernel-homes`.

1.4. **Compiler: multiple local packages and the bundled eco/system.**

Every reference below is under `compiler/src/`.

a. **`Terminal/Terminal/Chomp.elm`:** add `chompRepeatableFlag : String -> Parser -> (String ->
   Maybe a) -> …` that collects every occurrence into a `List a`. Make `checkForUnknownFlags` accept
   repeats of that flag.

b. **`Terminal/Main.elm:219,258,268`:** use the new chomper for `local-package`. `Make.Flags.localPackage`
   becomes a `List ( Pkg.Name, FilePath )`.

c. **`Terminal/Make.elm`:**
   - change `FlagsData`/`BuildContext` (:98, :179) and the threading at :196-227, :349, :360, :429 and
     :441 to the list type;
   - `parseLocalPackage` (:885-895) splits on the **first** `=` only, so paths may contain `=`.

d. **`Builder/Stuff.elm`:**
   - `PackageCache String (List ( Pkg.Name, FilePath ))`;
   - `getPackageCache`, `isLocalPackage`, `localPackageSource` and the encoder/decoder (:377-391) all
     take the list;
   - replace `resolveBundledKernel` with `resolveBundledPackages : List ( Pkg.Name, FilePath ) -> Task
     Never (List ( Pkg.Name, FilePath ))`. For each of `( Pkg.ecoKernel, "../share/eco/kernel/eco-kernel-cpp" )`
     and `( Pkg.ecoSystem, "../share/eco/system/system-kernel-cpp" )` that is **not already mapped**, it
     probes the directory and appends it if present.

e. **`Compiler/Elm/Package.elm`:** add `ecoSystem = toName eco "system"` next to `ecoKernel` (:216).

f. **`Builder/Deps/Solver.elm`:** update `initEnv`/`forkHttpManagerAndInitCache` (:727-735) and the Env
   encoder/decoder (:910-930).

g. **`Builder/Elm/Details.elm`:**
   - update the signatures `loadTypedObjects`, `load`, `loadWithTime`, `handleCachedDetails`, `generate`
     and `initEnv` (:298, :440-557);
   - `bundledKernelUnresolvable` (:688-697) checks every bundled package that is a dependency and is
     unresolved.

h. **`Builder/Reporting/Exit.elm`:** change `DetailsBundledKernelMissing` (:1475, report :1528-1557) to
   carry the `Pkg.Name` and its expected path.

i. **`Builder/Generate.elm`:** update the signatures at :483, :665, :2045 and :2078.

j. **Callers that pass `Nothing`** now pass `[]` through `resolveBundledPackages`, so `eco install
   eco/system` and `eco init` find the bundle:
   - `Outline.elm:495`
   - `Terminal/Helpers.elm:186,204`
   - `Diff.elm:125,289`
   - `Bump.elm:98,262`
   - `Install.elm:114`
   - `Uninstall.elm:101`
   - `API/Make.elm:82`
   - `API/Install.elm:54`
   - `API/Uninstall.elm:54`
   - `Init.elm:165`

k. **`compiler/CMakeLists.txt:215-216`:** add a build-tree symlink
   `${BUILD_KERNEL_DIR}/share/eco/system/system-kernel-cpp` → `system-kernel-cpp`.

l. **Tests:** update `compiler/tests` for any changed signatures (`grep -rn localPackage
   compiler/tests`). Add parser tests: repeated flags, and a path containing `=`.

m. **Bootstrap:** the AOT E2E harness uses the self-compiled compiler (`aot_e2e_main.cpp:396-405`), so
   the new flag reaches it only after the bootstrap rebuild that `full` performs.

1.5. **Compiler: refreshing local packages** (F15).

In `Details.elm` `seedLocalPackage` (:922-963):
- **Fingerprint:** compute the fingerprint of the seed: the sorted list of `(relative path, size,
  mtime)` for `elm.json` and every file under `src/`, walked with `Utils.dirListDirectory`, hashed.
  `dirGetModificationTime` crashes on error, so check existence first.
- **Compare:** read it against `<cache>/eco-local-fingerprint`.
- **On mismatch**, inside `Stuff.withRegistryLock`:
  1. copy the package into `<cache>.tmp`;
  2. delete `<cache>` (add `Utils.dirRemoveDirectoryRecursive` if it does not exist; check
     `compiler/src/Utils/Main.elm`);
  3. rename `<cache>.tmp` → `<cache>` (this deletes stale `src/` files, `artifacts.dat`,
     `typed-artifacts.dat` and `docs.json`);
  4. write the fingerprint.
- **Project cache:** fold the fingerprints of all local packages into the project `d.dat` key
  (:441-461), so dependent projects rebuild.

1.6. **Compiler: registering effect managers** (§3.6).

In `Generate/MLIR/Functions.elm`:
- In the `MonoManagerLeaf` branch (:515), get `pkg` from `Registry.lookupSpecKey`. If `pkg ==
  Pkg.ecoSystem`, add `home` to a new `Ctx` field `ecoSystemManagers : EverySet String`.
- `generateMainEntry` and `generateRegisterPorts` take the set. The calls are emitted **first inside
  `__eco_register_ports`**, one `func.call @Eco_System_registerManager_<Home_with_underscores>()` per
  element.
- Declare each callee with `Ctx.registerKernelCall` (:146-176), result `!eco.value`. The C function
  returns `uint64_t` = `encode(unit())` (T6).
- The preamble guard (:62-63, :130) becomes `hasPorts || hasFlags || not (EverySet.isEmpty
  managers)`.
- Pass the set from all three call sites (`Generate/MLIR/Backend.elm:107,242,440`).
- Add a compiler unit test: a module graph with an eco/system manager leaf emits exactly one
  registration call.

1.7. **Docs shim.**
- Add `system-kernel-cpp/scripts/elm` (POSIX sh, executable):
  ```sh
  #!/bin/sh
  here=$(cd "$(dirname "$0")" && pwd)
  if [ "$1" = "--version" ]; then echo 0.19.1; exit 0; fi
  exec node "$here/../../compiler/bin/index.js" "$@"
  ```
- Switch the `docs` and `docs:check` scripts to `PATH=$PWD/scripts:$PATH`.
- Verify that `node compiler/bin/index.js make --docs=/tmp/x.json --report=json`, run in
  `system-kernel-cpp/`, works for a package with kernel imports and effect modules (create a throwaway
  effect module to test). If `--docs` or `--report=json` is unsupported or fails for that case, fix the
  compiler (`Terminal/Make.elm` docs path) before continuing.

1.8. **Test harness.**

a. **Files:**
   - `test/eco-system/elm.json`: an application whose direct dependencies are `eco/system 1.0.0`, `elm/core`,
     `elm/json`, `elm/http`, `elm/bytes` and `elm/time` (tests import `Bytes` and `Time`), with
     `elm/url` and `elm/file` as indirect. The stated set must equal the
     solved closure (`Details.elm:618-630`).
   - `test/eco-system/EcoSystemTest.hpp`, modelled on `test/eco-kernel/EcoKernelTest.hpp`:
     `buildTestSuite("eco-system", "Eco System E2E", "eco-system/", " --local-package eco/system=" REPO_ROOT "/system-kernel-cpp")`.

b. **Output and exit checking.** For suites constructed with a new `checkProcessOutput = true`
   option (only EcoSystemTest), `ElmE2ETestBase.hpp` changes as follows.
   - **Today:** CHECK patterns are verified inside the forked child (`verifyPatterns(result.output, …)`,
     `:762-763`). The child exits with `_exit(passed ? 0 : 1)` (`:910-925`). The fork-pipe text
     `ctx.capturedOutput` exists only in the parent after `waitpid` (`:955-977`).
   - **Child, for these suites:**
     - it does **not** verify patterns;
     - before running the program, it registers an `atexit` hook and an end-of-run path; both copy the
       eco-thread output into the shared-memory block (`shared->output`) and set
       `shared->programExited = true` and `shared->programExitCode`;
     - a normal end of the program sets the code from `eco_get_exit_code()` (Phase 2 step 2);
     - `exitWithCode` → `std::exit(n)` goes through the `atexit` hook.
   - **Parent:** after `waitpid`:
     1. extract the CHECK, CHECK-NOT and EXIT directives from the `.elm` file;
     2. verify the patterns against `shared->output + ctx.capturedOutput`;
     3. pass iff `shared->programExited`, the patterns pass, and `WEXITSTATUS == EXIT` (default 0).
   - **Other suites:** unchanged.

c. **New directives:**
   - `-- EXIT: <n>`:
     - in the JIT harness, enforced only for `checkProcessOutput` suites (as above);
     - in `aot_e2e_main.cpp`, enforced **only when the directive is present**, so the existing policy at
       `:479-485` is preserved.
   - `-- STDIN: <text>`: the text is written to a pipe that becomes the child's stdin. `\n` escapes are
     allowed, and repeated lines are concatenated.
   - The default stdin for every child of a `checkProcessOutput` suite, and every AOT child, becomes
     `/dev/null` (`dup2` after `fork` at :892-905).

d. **Registration:** `test/main.cpp` (include ≈:72, build ≈:1190, add ≈:1232); `ELM_TEST_PACKAGES` in
   `test/CMakeLists.txt:15-27`.

e. **JIT linking:** whole-archive every `EcoSystem_${mod}` in the three branches of
   `test/CMakeLists.txt:166-230` (loop over `ECO_SYSTEM_MODS`), and in the stress-test list (:248-268).

f. **AOT:** add `"eco-system"` to `aot_test_packages` (`aot_e2e_main.cpp:190-195`) with its own
   `--local-package` flag in `compile_to_mlir`.

g. **SIGPIPE** (review R1.15): `signal(SIGPIPE, SIG_IGN)` in `EcoRunner` and in the forked test child.

h. **Stress tests can import eco/system:**
   - add `eco/system` (and its closure: `elm/url`, `elm/http`, `elm/file`, `elm/time`) to
     `test/stress-elm/elm.json`;
   - make `StressElmTest.hpp` pass both `--local-package eco/kernel=…` and
     `--local-package eco/system=…` (needs Phase 1 step 4);
   - stress programs for this package are named `EcoSystem*.elm`.

i. **Root-bound check:** add `"system-kernel-cpp/src"` to `DIRS` in `test/scripts/check-root-bounded.py`.

j. **First test:** `test/eco-system/src/PackageLinksTest.elm`. It imports every public module, uses
   `Debug.log "links" 1` in `init`, and checks `-- CHECK: links: 1`. This proves that the package
   compiles natively with stubs and links. Phase 1 does not yet turn modules into effect modules.

**Exit criteria:** `full` is green, including the new suite; `check-kernel-homes` passes; the compiler
tests are green; the docs shim works.

### Phase 2 — Runtime prerequisites and Core services

2.1. **SIGPIPE.** `eco_entry.cpp`: move `signal(SIGPIPE, SIG_IGN)` out of `#if ENABLE_GC_STATS` (F17).
Embed mode leaves it to the host.

2.2. **Exit code.**
- Add `extern "C" void eco_set_exit_code(int)` and `int eco_get_exit_code()` to
  `runtime/src/allocator/RuntimeExports.{h,cpp}` (a process-wide `std::atomic<int>`).
- `eco_entry.cpp:143,376` return `eco_get_exit_code()` instead of 0.
- `eco_embed.cpp` (≈:225) stores it into `s.exitCode`, so `eco_app_join` returns it.
- The JIT (`EcoRunner.cpp`) returns it as the process status, which the `-- EXIT:` directive checks.

2.3. **Quiescence hook.**
- Add `Scheduler::addQuiescenceListener(void (*fn)(void*), void* ctx)`, flags `quiescenceArmed_ = true`
  and `embedMode_`, and set `quiescenceArmed_ = true` inside `incrementPendingAsync()`.
- In `runEventLoop` (`Scheduler.cpp:549-595`), at the exit check (:566): if the exit condition holds,
  `!embedMode_`, listeners exist and `quiescenceArmed_`:
  1. `quiescenceArmed_ = false`;
  2. `lock.unlock()`;
  3. call each listener;
  4. `lock.lock()`;
  5. `continue`.

  Otherwise exit as today.
- Add `void Scheduler::setEmbedMode(bool)` and `bool Scheduler::embedMode() const`. `eco_embed.cpp` calls
  `setEmbedMode(true)`.
- eco/system's SignalService and `exitWithCode` read `Scheduler::instance().embedMode()`; there is no
  separate embed flag in eco/system.

2.4. **`Process.kill`** (F13). In `killBindingBody` (`Scheduler.cpp:492-508`), resolve the target as
`latestProcessById(proc->id)` (or the equivalent field) before reading `root->kill`. Leave the
best-effort semantics unchanged. The test comes in Phase 5 (`ProcessKillTest`).

2.5. **WaitService** (F18).
- Add `enum class WaitLane { EcoKernel, EcoSystem }`.
- `submit(pid_t, uint64_t token, WaitLane)`.
- Per-lane ready queues, with `hasReady(lane)` and `tryPopReady(lane, Ready&)`.
- `Ready{token, exitCode, rawStatus}`; signal deaths set `exitCode = 128 + sig`.
- An `unclaimed_` map (pid → raw status) for children reaped before `submit`, checked inside `submit`.
- Update `eco-kernel-cpp/src/eco-kernel/Process.cpp` to `WaitLane::EcoKernel`.

2.6. **TimerService.** Add `bool cancel(uint64_t token)`, which removes a scheduled entry. When it
returns `true`, the caller calls `decrementPendingAsync()`.

2.7. **Record the main thread.** `eco_entry.cpp` records `pthread_self()` of the process main thread.
Expose it as `extern "C" pthread_t eco_process_main_thread()`, declared in `RuntimeExports.h`, for
`setProcessTitle`. Do not use the name `eco_main_thread`: `eco_entry.cpp:99` already has a static
function of that name, for the thread that runs Elm.

2.8. **`EcoSystem_Core`** (`system-kernel-cpp/src/eco-system/Core/`):
- `Core.hpp` + `Core.cpp`: **exactly** the declarations listed at the top of §3.3.2 (namespace
  aliases, `enc`/`dec`, `asTuple2`/`asTuple3`, `toStdString`/`toStdBytes`, the `succeed*` and `fail*`
  helpers, `makeKillHandle`), plus the macros `ECO_SYSTEM_BODY_GUARD(Shape, ...)` and
  `ECO_SYSTEM_ASYNC_GUARD(Shape, resume, token, counted, ...)`. Implement them on top of the eco-kernel
  helpers (`eco-kernel-cpp/src/eco-kernel/KernelHelpers.hpp`, `ExportHelpers.hpp`). Include those headers;
  do not link `EcoKernel_*`.
- `ErrnoNames.cpp`: `const char* errnoName(int)`, a table covering every POSIX errno, with `"UNKNOWN"` as
  the fallback.
- `SysWorkPool.{hpp,cpp}`, `PoolResult`, and the T2 pool drain with `std::call_once` registration of the
  async source.
- `FdChannel.{hpp,cpp}`: §3.4 (poll + wake pipe, the channel thread owns close, never closes 0–2).
- `SignalService.{hpp,cpp}`: self-pipe; `subscribe(signo)` / `unsubscribe(signo)` reference counts; a no-op
  when `Scheduler::instance().embedMode()`.
- `KillHandle.cpp` (T7), `Registry.hpp` (the T5 helper template), `AsyncRelease.hpp` (RAII decrement),
  `ChannelDrain.cpp` (the drain that dispatches `ByteChannel` results to the StreamTable through a
  registered callback, so Core does not depend on Stream).
- **Unit tests** `test/kernel/EcoSystemCoreTest.cpp`, which need no Elm and no heap:
  - the pool runs 1000 jobs;
  - FdChannel reads and writes a pipe and wakes from `shutdown()`;
  - SignalService delivers a raised SIGUSR1 (use SIGUSR1 in the test);
  - the errno table includes ENOENT and EACCES.

**Exit criteria:** `full` is green, the Core unit tests pass, and the eco-kernel Process tests still
pass (WaitService lanes).

### Phase 3 — Stream core, stdio, `System`

3.1. **Elm `Stream.Internal`:** the handle types (§3.1) and nothing else. The `SErr` decoder
`decodeError : ( Int, String ) -> Error` (0 Closed, 1 Cancelled, 2 Locked) is a **private** function in
`Stream`, because `Error`'s constructors live there. No other module needs to decode stream errors.

3.2. **Elm `Stream`:**
- Replace the stubs of the Phase 3 functions with wrappers over the B.2 kernels, e.g.
  `read (Readable id) = kRead id |> Task.mapError decodeError`.
- **Keep `Debug.todo`** for `customTransformation`, `customTransformationWithOptions`,
  `nullTransformation`, `pipeThrough`, `awaitAndPipeThrough`, `pipeTo` and the codec constructors until
  Phase 6. Their kernels do not exist yet, and referencing them would fail at link time.
- Port `readBytesAsString`, `readUntilClosed`, `writeStringAsBytes` and `writeLineAsBytes` from
  gren-core `Stream.gren` (Appendix E), using the private kernel wrappers `kUtf8ToString` /
  `kStringToUtf8`.
- `fromList`: §3.5.
- `Stream.Log`: port the three functions (`Stream/Log.gren`), mapping errors to `()`.

3.3. **C++ `EcoSystem_Stream`:**
- `StreamTable` (T5).
- Kernels `identity`, `read`, `write`, `enqueue`, `closeWritable`, `cancelReadable`, `cancelWritable`,
  `utf8ToString`, `stringToUtf8`.
- The `pump()` state machine for Identity, FdSource and FdSink (Custom, Codec and pipes come in Phase 6).
- C++ API `createFdSource(int fd, bool owns)` / `createFdSink(int fd, bool owns)`, built on the general
  `createChannelSource(ByteChannel*)` / `createChannelSink(ByteChannel*)`.
- Resuming a parked token:
  1. `takePendingResume`;
  2. build the Task (`taskSucceed(value)` or `taskFail(errTuple)`);
  3. `callClosure1`;
  4. if inside an async drain, `drain()` afterwards.

3.4. **Elm `System`:**
- Convert it to `effect module System where { command = MyCmd, subscription = MySub }` (Appendix C.1).
- Write the program machinery (§3.7) and `platformFromString`/`archFromString` (gren `Node.gren:113-216`).
- `getEnvironmentVariables` = `kGetEnvironmentVariables |> Task.map Dict.fromList`.
- `endSimpleProgram`, `exit`, `exitWithCode`, `setExitCode`.
- `onEmptyEventLoop`, `onSignalInterrupt`, `onSignalTerminate`.
- Trivial Elm manager functions.

3.5. **C++ `EcoSystem_System`:**
- The B.1 kernels.
- `Eco_System_registerManager_System` (T6, C.1): Execute → `rawSpawn`; subscriptions → a
  quiescence listener (registered once) and SignalService subscriptions; on events, deliver the stored
  msg (it is a value, not a tagger: `sendToApp(router, msg)` + `drain()`).
- Stdio streams: `environment` creates FdSource(0, owns=false), FdSink(1, false), FdSink(2, false)
  lazily, once per process.
- `exitWithCode`/`setExitCode` per §3.7.

3.6. **Tests** (`test/eco-system/src/`, each with `-- CHECK:` lines; add `GcPressure` stress variants for
the starred ones):

| Test | Checks |
|---|---|
| `HelloStdoutTest` | `-- CHECK: Hello` through `Stream.Log.line env.stdout` |
| `StderrTest` | |
| `StdinEchoTest` | `-- STDIN: abc\n`; reads to close |
| `ExitWithCodeTest` | `-- EXIT: 3` |
| `SetExitCodeTest` | `-- EXIT: 4`, and the program still finishes its writes |
| `EnvVarsTest` | finds `PATH` |
| `PlatformArchTest` | |
| `ArgsTest` | length ≥ 1 |
| `SimpleProgramFreeMsgTest` | `main : System.SimpleProgram msg` |
| `OnEmptyEventLoopTest` | fires exactly once, then exits |
| `StreamIdentityRoundTripTest`* | |
| `StreamBackpressureTest`* | identity(1,1): w1 ok, w2 pending until a read, w3 waits, w4 `Locked` |
| `StreamCloseThenReadTest` | |
| `StreamCancelReadableTest` | reader gets `Closed`, writer gets `Cancelled` |
| `StreamCancelWritableTest` | reader gets `Cancelled` |
| `StreamWriteAfterCloseTest` | |
| `StreamFromListTest` | includes the empty list |
| `StreamReadUntilClosedTest`* | 10 000 chunks |
| `Utf8StrictTest` | invalid bytes → `Cancelled` from `readBytesAsString` |

Signal tests come in Phase 5, where the program can signal itself through `System.Process.run "kill"`.

**Exit criteria:** the §3.3.3 gates are green, and the hello-world from the README runs AOT and JIT.

### Phase 4 — Files

4.1. **`System.File.Path`**, pure Elm. Port `FilePath.js` semantics (node `path.normalize` then
`path.parse`) for POSIX and Win32 separately, plus the rules in Appendix E.2.
- Generate golden tables with node: add a script `system-kernel-cpp/scripts/gen-path-golden.js` that runs
  `node:path.posix` and `node:path.win32` over about 200 inputs (including `""`, `"."`, `"a/../b"`,
  `"//a//b/"`, `"C:foo\\bar.txt"`, `"\\\\server\\share\\x"`, trailing separators, dotfiles,
  `"file.tar.gz"`) and writes `tests/PathGolden.elm`.
- Unit tests run with elm-test-rs in a new project `system-kernel-cpp/tests/` (its `elm.json` source-dirs
  point at `../src`, test-dependencies `elm-explorations/test`). Add a CMake target
  `eco-system-elm-tests` and make `elm-tests` depend on it. `System.File.Path` must not import any
  kernel module, so stock elm can test it.

4.2. **`System.File.Internal`:**
- the `Error` type;
- `decodeError : Path -> ( String, String ) -> Error`;
- `type alias MetadataOf e = { entityType : e, deviceID : Int, userID : Int, groupID : Int, byteSize : Int,
  blockSize : Int, blocks : Int, lastAccessed : Time.Posix, lastModified : Time.Posix, lastChanged :
  Time.Posix, created : Time.Posix }`;
- `decodeMetadata : (Int -> e) -> List Int -> MetadataOf e` (§3.1).

`entityFromInt : Int -> EntityType` (0 File … 5 Pipe) is a **private** function in `System.File`,
duplicated privately in `System.File.FileHandle`. The Internal module cannot name `EntityType`'s
constructors.

4.3. **`System.File`:**
- Effect module (`subscription = MySub`, C.2).
- Wrappers over B.3 with the argument orders in Appendix E.3.
- `accessPermissionsToInt` as in gren (octal digit composition, `FileSystem.gren:347-365`).
- `errorIs*` compare codes exactly as gren (`FileSystem.gren:140-258`).
- The directory helpers (`homeDirectory` …) parse strings into `Path`.

4.4. **`System.File.FileHandle`:** wrappers over B.3; the `open` flag strings as in gren
`FileHandle.gren:130-175`; `read fh = readFromOffset fh { offset = 0, length = -1 }`; `write fh bytes =
writeFromOffset fh 0 bytes` (gren always writes at offset 0, Appendix E.3).

4.5. **C++ `EcoSystem_FileSystem`:**
- B.3 kernels, all P mode except the four directory getters (S).
- File streams create FdSource/FdSink pairs on fds opened in the pool (`O_CLOEXEC`). `Between` uses an
  inclusive end.
- The `System.File` manager (C.2) with a watcher thread:
  - Linux: inotify, with a wake pipe in the poll set.
  - macOS: a 1 s polling thread.
  - Events are POD `(watchId, kind, relativePath | none)`.
  - The drain maps them to the registered taggers (T8).
  - An active watch holds `pendingAsync`.

4.6. **Tests:** one or more per kernel function, following Appendix E.3:
- create, read, write, append, copy, move, remove (non-recursive on a directory gives
  `ERR_FS_EISDIR`), recursive mkdir, readdir sorted, links, realpath, chmod/access, utimes (whole
  seconds), temp dir prefix, `errorIsNoSuchFileOrDirectory`;
- FileHandle open modes (`wx` on existing → EEXIST), read and write offsets, truncate, sync;
- read and write streams, including `Between`;
- watch: create a file and receive `Changed`;
- a stress variant that reads and writes 10 000 small files.

### Phase 5 — Processes and terminal

5.1. **Elm `System.Process`:**
- Effect module (`command = MyCmd`, C.3).
- `run` wrapper: destructure the options into the B.4 arguments and decode the failure into `FailedRun`.
- `spawn` builds `Spawn` with a spec tuple and two taggers. The `onInit` tagger receives
  `( Process.Id, Maybe ( Int, Int, Int ) )` and the Elm wrapper builds `StreamIO` with
  `Stream.Internal` constructors when the connection is `External`.
- `defaultRunOptions`/`defaultSpawnOptions` as in gren (`ChildProcess.gren:92-330`;
  `maximumBytesWrittenToStreams = 1024 * 1024`).

5.2. **C++ `EcoSystem_ChildProcess`:**
- **Spawning:** use `posix_spawn` only, never `fork` (HEAP_075). Use `posix_spawn_file_actions_adddup2` for
  the child's stdio and `POSIX_SPAWN_CLOEXEC_DEFAULT` on macOS. The pipes come from `pipe2(O_CLOEXEC)`
  on Linux. Before spawning, `posix_spawn_file_actions_addchdir_np` (glibc ≥ 2.29, macOS ≥ 10.15) sets
  the working directory; if unavailable, run through `/bin/sh -c 'cd "$1" && exec "$0" "$@"'`.
- **Shell:** `DefaultShell` = `/bin/sh -c "<program> <args joined by spaces>"`, as gren
  `ChildProcess.js` joins them; `CustomShell s` = `s -c …`.
- **Environment:** Merge = `environ` overlaid with the pairs; Replace = the pairs only.
- **`run`:** two FdChannels collect stdout and stderr up to `maximumBytesWrittenToStreams` each (gren
  kills the child when it exceeds this; match that behaviour per Appendix E.4). WaitService
  `WaitLane::EcoSystem` reports the exit. `runDuration` uses TimerService. On expiry: `kill(SIGTERM)`,
  and the failure is `ProgramError { exitCode = -1, … }` (E.4). When the child exits first,
  `TimerService::cancel` the timer and decrement per the T7 rule.
  Success requires exit code 0, otherwise `ProgramError`. A spawn failure is `InitError` with the
  errno name.
- **`spawn` manager (C.3).** For each `Spawn`:
  1. spawn the child per its connection (Integrated: inherit 0–2; External: three pipes →
     FdSink(stdin) and FdSource(stdout, stderr); Ignored: `/dev/null`; Detached: `/dev/null` plus
     `POSIX_SPAWN_SETSID`, and it does **not** hold `pendingAsync`);
  2. create an Elm process with `Scheduler::instance().rawSpawn(makeAsyncBinding<childBody>(pid))`. Its
     kill handle sends `SIGTERM` to the pid; build it with a `CancelFn` that calls `kill` and returns
     `false`, so the drain still decrements when the exit arrives. It resumes when the child exits.
     **Root the `rawSpawn` result from here until step 5** (G13);
  3. `Scheduler::instance().drain()`, so the binding steps and installs its kill handle (review R1.20);
  4. call `onInit` with `(processId, streams)`;
  5. `sendToApp`;
  6. on exit, call `onExit` with `( exitCode, signal )`, then `sendToApp`.

5.3. **`System.Terminal` + C++ `EcoSystem_Terminal`:**
- `getConfiguration`: `isatty(1)` → `ioctl(TIOCGWINSZ)`; colour depth from the §B.5 heuristics.
- `setStdInRawMode`: termios. Save the original on first use and restore it in an `atexit` handler. While
  raw mode is on, the Terminal kernel holds an **internal** SignalService subscription to SIGINT and
  SIGTERM; its handler restores termios before chaining. SignalService otherwise installs handlers only
  for Elm subscriptions.
- `setProcessTitle`: §3.8.
- `onResize` manager (C.4) through SignalService SIGWINCH, delivering the new size.

5.4. **Tests:**
- run `echo hi` (checks stdout bytes);
- run a failing `sh -c 'exit 3'` (ProgramError 3);
- run a nonexistent program (InitError ENOENT);
- environment merge and replace;
- working directory;
- `runDuration` kills `sleep 10` within 1 s, and the program then exits promptly (timer cancelled);
- spawn External: write to `cat`'s stdin, read it back, close, `onExit 0`;
- spawn Integrated;
- `ProcessKillTest`: spawn `sleep 30`, `Process.kill`, `onExit` reports SIGTERM;
- `SignalInterruptTest`: `run "sh" [ "-c", "kill -INT $PPID" ] { defaultRunOptions | shell = NoShell }`
  (sh's parent is the test program) → the `onSignalInterrupt` msg arrives, and the program exits 0;
- `getConfiguration` gives `Nothing` under the test harness (not a TTY);
- concurrent `run`s (20 in parallel) all report the right codes, a WaitService lanes regression check.

### Phase 6 — Stream transformations

6.1. **Elm:**
- `customTransformationWithOptions` wraps the user function into the tuple-returning action (§3.5) and
  clamps the capacities.
- `nullTransformation`, `pipeThrough`, `awaitAndPipeThrough`, `pipeTo`, `readable`, `writable`, the codec
  constructors.

6.2. **C++:**
- The Custom kind calls Elm in `pump()` (G11): root `fn`, `state`, `value` and the result tuple; decode
  the result with a non-allocating resolve scope; re-resolve the pair after the call, because the call
  can re-enter the table.
- The Codec kind: zlib `deflateInit2`/`inflateInit2` with windowBits 31 (gzip), 15 (deflate) or -15
  (raw); 64 KiB output chunks; `Z_FINISH` on close.
- UTF-8 encoder and decoder with carry (§3.5).
- Pipes: a registry of `src → dst` pumps, triggered from every state change of either pair.

6.3. **Tests:**
- custom upper-casing transform;
- custom `Close` early: later writes fail "terminated";
- custom `Cancel`;
- `readCap 0` rendezvous;
- `Send` overfill;
- pipeThrough chains (identity → custom → identity);
- pipeTo completes and propagates close;
- an error in the source aborts the destination;
- gzip round trip of 1 MiB, compared with a known gzip of the same data written by a test fixture;
- textDecoder handles a split multibyte sequence and a BOM;
- textEncoder handles `""`;
- a stress variant: 1 MiB through 3 chained transforms.

### Phase 7 — HTTP server

7.1. **llhttp:**
- Vendor it with `FetchContent` (pin the release tarball `llhttp-release-v9.2.1`, which contains generated
  C) as an `OBJECT` library.
- **Merge its objects into the archive:**
  `target_sources(EcoSystem_HttpServer PRIVATE $<TARGET_OBJECTS:llhttp_objects>)`.
  - Static archives do not carry their link dependencies.
  - The AOT driver links only the archives listed in `EcoBootConfig.h` (`EcoNativeDriver.cpp:593-595,1059-1066`).
  - So llhttp must be **inside** `libEcoSystem_HttpServer.a`.
  - This needs no driver change and no extra bundle entry.

7.2. **C++:**
- `createServer` (P mode): `socket`, `SO_REUSEADDR`, `bind`, `listen`. It fails with
  `( code, message )`, which Elm turns into `ServerError { code, message }`.
- An accept thread per server; a connection thread per client with a poll + wake pipe; llhttp parses the
  request.
- A complete request becomes a POD posted to the drain; the drain calls the registered taggers (C.5).
- `respond(key, status, headers, body)` (C mode) writes `HTTP/1.1` with `Content-Length` and
  `Connection: close`, then closes the connection (no keep-alive in v1).
- A listening server holds `pendingAsync` forever (Node semantics).

7.3. **Elm:**
- `Http.Server`: effect module (C.5), `Request` from the tuple, URL parsing (Appendix E.5),
  `methodToString`/`toMethod` as gren, `bodyAsString` via `utf8ToString`, `bodyFromJson`,
  `requestInfo`.
- `Http.Server.Response`: builders over the Internal record; `send` = `System.endSimpleProgram
  (kRespond key status headers body)`.

7.4. **Tests:**
- **Port choice.** Test applications cannot import the unexposed `Internal` modules, so the port comes
  from the harness:
  - the EcoSystemTest harness picks a free port per test (bind port 0, read it back, close) and sets
    `ECO_TEST_PORT=<port>` in the forked child's environment, in `ElmE2ETestBase.hpp` and in the AOT
    runner;
  - the test reads it with `System.getEnvironmentVariables`;
  - add this harness change in Phase 7 together with a harness self-test.
- A program serves one request and calls itself with **elm/http** (`Http.request` with `expectString`;
  the test application lists `elm/http` as a dependency): status, headers, body, `bodyFromJson`, 404 for
  an unknown path, and two sequential requests.

### Phase 8 — `Http.Stream` (streaming extension of elm/http)

Goal: the API in Appendix A (`Http.Stream`) and B.7, with the semantics in Appendix E.6. Everything
that is not about streams stays elm/http's (D9).

8.1. **Elm `Http.Stream`** (private types, no Internal module needed):
```elm
type Body = EmptyBody | BytesBody String Bytes | StreamBody String Int     -- Int = Readable id
type Expect msg = Expect Bool (Http.Response (Stream.Readable Bytes) -> msg)  -- Bool = discard non-2xx bodies
type Resolver x a = Resolver (Http.Response (Stream.Readable Bytes) -> Result x a)
```
- **Body constructors:**
  - `emptyBody`;
  - `bytesBody mime b`;
  - `stringBody mime s = BytesBody mime (Eco.Kernel.Stream.stringToUtf8 s)`. Kernel imports are
    allowed in any eco/system module; give it a private annotated wrapper (`kStringToUtf8 : String ->
    Bytes`);
  - `jsonBody v = stringBody "application/json" (Json.Encode.encode 0 v)`;
  - `streamBody mime (Readable id) = StreamBody mime id`.
- **Expects and resolver:**
  - `expectStream toMsg = Expect True (toMsg << toStreamResult)`. `toStreamResult` maps
    `GoodStatus_ meta r` → `Ok ( meta, r )`, `BadStatus_ meta _` → `Err (Http.BadStatus
    meta.statusCode)`, `BadUrl_ u` → `Err (Http.BadUrl u)`, `Timeout_` → `Err Http.Timeout`,
    `NetworkError_` → `Err Http.NetworkError`.
  - `expectStreamResponse toMsg f = Expect False (toMsg << f)`.
  - `streamResolver f = Resolver f`.
- **`sendRaw`** (private) `: { method, headers, url, body, timeout } -> Bool -> Task Never (Http.Response
  (Stream.Readable Bytes))`. It calls `kSend` (B.7) and builds the `Http.Response` in Elm:
  - `Metadata.headers` is `Dict.fromList` over the pairs, after joining duplicate names with `", "` in
    arrival order, as elm/http's `_Http_parseHeaders` does (`Elm/Kernel/Http.js:94-113`). The kernel
    lower-cases header names.
  - The body is `Readable id`.
- **Commands and tasks:**
  - `request r = Task.perform (\resp -> toMsg resp) (sendRaw r discard)`, with `toMsg`/`discard` taken
    out of `r.expect`. This is a plain `Task.perform`, so no effect manager is needed.
  - `task r = sendRaw r False |> Task.andThen (\resp -> case resolve resp of Ok a -> Task.succeed a ;
    Err x -> Task.fail x)`.
- **Timeout:** `Maybe Float` milliseconds becomes `round`, with `Nothing` mapped to 0 (no timeout).

8.2. **C++ `EcoSystem_HttpStream`:**
- **`send` binding (async, T2 shape, but on `HttpStreamService`):**
  1. Read the arguments (G3). Headers come from the `Http.Header` customs per B1a.
  2. Body kind 2: look up the Readable in the StreamTable and attach an upload pump. The pump reads the
     stream on the main thread (an internal read, not an Elm Task) and moves chunks into the upload
     `ByteChannel`. On `Closed` it sends EOF. On error it aborts the transfer with a NetworkError.
  3. Register the resume, `incrementPendingAsync`, and start the transfer thread.
  4. The kill handle (T7) aborts the transfer: the curl progress callback returns non-zero.
- **Transfer thread** (`HttpTransfer.cpp`):
  - `CURLOPT_PROTOCOLS_STR "http,https"`, `CURLOPT_REDIR_PROTOCOLS_STR "http,https"`,
    `CURLOPT_FOLLOWLOCATION 1`.
  - The header callback resets the header list on each `HTTP/` status line, parses `statusText`, and
    lower-cases names.
  - When the headers end, post `HeadersReady{token, status, statusText, effectiveUrl, headers}`.
  - Write callback:
    - if `discardNon2xx` is set and the status is outside 200–299, drop the bytes;
    - otherwise push them into the download channel, blocking while it is full.
  - On completion, post `Done{token, curlCode}`.
  - Timeout: `CURLOPT_CONNECTTIMEOUT_MS` plus a header deadline. Elm's timeout covers the time **until
    the response headers arrive**; there is no timeout afterwards (documented deviation, E.6).
- **Drain:**
  - **`HeadersReady`:**
    1. Create the response stream: a `ChannelSource` over the transfer's download channel, or an empty
       closed stream when the body is discarded.
    2. Build the result tuple (B.7; masks per G7) and resume with `taskSucceed`.
    3. `decrementPendingAsync`. After this point, only parked reads of the body stream keep the
       program alive (§3.4 keep-alive rule).
  - **`Done` before `HeadersReady`:** resume with kind 0, 1 or 2 (BadUrl_/Timeout_/NetworkError_),
    chosen from the curl code.
  - **`Done` after the headers:** close the body stream. A curl error instead sets the stream to
    `Errored "network error: <curl message>"`, so readers get `Cancelled`.
- **Linking:**
  - Compile against curl's headers, using the same per-platform target selection as `EcoKernel_Http` in
    `eco-kernel-cpp/CMakeLists.txt`.
  - The AOT link already adds libcurl for every profile (`EcoNativeDriver.cpp`: `-lcurl`,
    `libcurlStaticA`, Darwin `curl`, `windowsLibcurlA`), so the driver needs no change.
  - `EcoSystem_HttpStream` reaches the bundle through `ECO_SYSTEM_MODS`.

8.3. **Tests** (against `test/TestHttpServer.hpp`). Reuse the existing `TestServerConfig.elm` generator,
which already exists in two places: `test/eco-kernel/EcoKernelTest.hpp:36-50` and
`test/elm-http/ElmHttpTest.hpp:33-63`. Factor it into one helper that `EcoSystemTest` also calls.

| Test | Endpoint | Checks |
|---|---|---|
| `HttpStreamDownloadTest`* | `/bytes/1048576` | read chunk by chunk and count to 1 MiB |
| `HttpStreamDripTest` | `/drip-chunked` | the first chunk arrives before the response completes (log the order) |
| `HttpStreamUploadTest` | `/anything` | `streamBody` from `Stream.fromList` of 3 chunks; the echoed body equals their concatenation |
| `HttpStreamTaskTest` | | `Http.Stream.task` with `streamResolver` |
| `HttpStream404Test` | `/status/404` | `expectStream` gives `Err (BadStatus 404)` and the program exits promptly (no stalled transfer) |
| `HttpStream404BodyTest` | | `expectStreamResponse` exposes the error body stream |
| `HttpStreamHeadersTest` | `/echo-headers` | `Http.header` values are sent (pins B1a); a duplicate response header is joined with `", "` |
| `HttpStreamTimeoutTest` | `/slow` | `Timeout` before the headers |
| `HttpStreamTruncatedTest` | `/truncate` (**add**: sends `Content-Length: 1000`, writes 10 bytes, closes) | the reader gets `Cancelled` |
| `HttpStreamKillTest` | | `Process.spawn` the task, kill it mid-download; the stream is cancelled and the program exits |
| `HttpStreamRedirectTest` | `/redirect` | `Metadata.url` is the final URL and the headers are only the final hop's |

Starred tests also run as stress variants (§3.3.3).

### Phase 9 — Distribution and documentation

9.1. The bundle ships `docs.json`: generate it in the build (`pnpm run docs:check`, or the eco compiler
directly) before `install`.

9.2. Update `docs/getting-started.md` with a "System programs" section using the README example, and
update the README status line.

9.3. Add examples under `examples/system/` (cat, ls, an http echo server). They are compiled in CI,
not run.

9.4. Update `design_docs/invariants.csv`:
- add `SYS_001`, eco/system kernels obey §3.2 B1–B8;
- add `SYS_002`, C++ managers mirror Appendix C;
- add `SYS_003`, all eco/system services are leaky singletons with detached threads;
- add a `KernelFacts` evidence row only where profiling shows a benefit (F9).

### Phase 10 (optional) — JS target

Port the gren-node and gren-core JS kernels into `src/Eco/Kernel/*.js`. This means rewriting Array to
List, using Elm record/constructor conventions (`__$field`, `__Module_Ctor` imports), writing real Elm
effect-manager bodies (gren's `onEffects` code works after Array→List), and adding a JS E2E run.

---

## 5. Test strategy summary

- Every Appendix B function has at least one E2E test.
- Pure Elm (`System.File.Path`, the error decoders, `accessPermissionsToInt`, `methodToString`) is
  covered by elm-test-rs unit tests.
- The GC gates of §3.3.3 must pass for every phase from 3 to 8, and every starred test has a stress
  variant.
- Harness changes (Phase 1 step 8) are covered by the tests that use them. Add one self-test per
  directive: an `-- EXIT: 0` program, `-- STDIN:` echo, and a `CHECK` on fd output.

## 6. Ordering and dependencies

Phase 0 → 1 → 2 → 3, then Phases 4, 5 and 6 can proceed in parallel. Phase 5's External spawn needs
Phase 3 streams. Phase 7 (HTTP server) needs Phase 3; its tests use elm/http as the client. Phase 8
(`Http.Stream`) needs Phase 3 and can run in parallel with 4–7. Phase 9 follows the rest, and Phase 10
is optional.

## 7. Open questions for the user

None. Q1 (LICENSE wording) is resolved by D7 and Q3 (`args`) by D10. Q2 (`Http.Client` naming) and Q4
(where `Method` lives) are moot since D8: `Method` stays in `Http.Server`.

## 8. Risks

- **R1:** C++ managers hard-code constructor layouts. Mitigated by Appendix C, B7, header comments
  and `SYS_002`.
- **R2:** One thread per connection and per channel does not scale to thousands of connections. This
  is acceptable for v1; a reactor is a follow-up.
- **R3:** Unclosed streams, handles and servers leak, because the runtime has no finalizers.
- **R4:** 16-bit process ids (F13) limit long-running programs that spawn more than 65,536 children.
- **R5:** A gren program ported unchanged may differ in `args` (§3.7), enqueue-after-close (§3.5),
  and custom write capacity 0. All are documented in the module docs.

## 9. Adversarial review log

Two reviewers attacked v1. Every finding was accepted unless a reason is given.

**Runtime/compiler reviewer (R1):**

| # | Sev | Finding | Resolution |
|---|---|---|---|
| R1.1 | BLOCKER | Appendix C (constructor layouts) was missing | Appendix C added; HEAP_046 cited in G7 |
| R1.2 | MAJOR | `CHECK` sees only eco-thread output; exit codes are unchecked; stdin is inherited | Phase 1 step 8 (`checkProcessOutput`, `EXIT`, `STDIN`, `/dev/null`) |
| R1.3 | MAJOR | The before-exit hook ran under `mutex_` (deadlock), looped forever, and was wrong in embed | §3.7 semantics, Phase 2 step 3 |
| R1.4 | MAJOR | Registration premises: the preamble is guarded; the package is available via the Registry; there are 3 `generateMainEntry` sites | §3.6, Phase 1 step 6 |
| R1.5 | MAJOR | WaitService has a shared queue, a reap-before-submit race, and lost signals | Phase 2 step 5 |
| R1.6 | MAJOR | Closing an fd does not wake a blocked read; stdio fd reuse; destructors racing threads | §3.4 FdChannel and leaky singletons |
| R1.7 | MAJOR | TimerService has no cancel, so `runDuration` kept the program alive | Phase 2 step 6 |
| R1.8 | MAJOR | `O_CLOEXEC`, `posix_spawn` only, termios restore | §3.4, Phase 5 steps 2–3 |
| R1.9 | MAJOR | Refreshing the source copy alone leaves stale artifacts | Phase 1 step 5 (fingerprint, temp+rename, `d.dat` key) |
| R1.10 | MAJOR | `node_modules` would ship in the bundle | Phase 0 step 9 |
| R1.11 | MAJOR | Embed: signals and `std::exit` would affect the host | §3.4 SignalService, §3.7 exit |
| R1.12 | MINOR | Phase 1 compiler list incomplete (Env codec, existing Exit, install/init, `=` paths, AOT bootstrap) | Phase 1 step 4 |
| R1.13 | MINOR | F14, F15 and F8 overstated or mis-pathed | F-table corrected |
| R1.14 | MINOR | Multi-argument taggers vs `subMap` composition | B7: single tuple argument |
| R1.15 | MINOR | SIGPIPE in EcoRunner and test children | Phase 1 step 8g, Phase 2 step 1 |
| R1.16 | MINOR | HttpService lane is a bool | Moot: HTTP client dropped (D8) |
| R1.17 | MINOR | `prctl` renames the calling thread | §3.8 |
| R1.18 | MINOR | Docs shim relative path | Phase 1 step 7 (`dirname "$0"`) |
| R1.19 | MINOR | `~/.eco` scan is machine-dependent; seeded-cache deletion is unsafe across runs | Phase 1 step 1 scans the repo only; deletion dropped in favour of step 5 |
| R1.20 | MINOR | Process.Id snapshot: kill handle not installed before the id is delivered | Phase 5 step 2 (`drain()` after `rawSpawn`) |
| R1.21 | MINOR | ecoc does not link eco/system | §1 scope note |

**Elm/API/streams reviewer (R2):**

| # | Sev | Finding | Resolution |
|---|---|---|---|
| R2.1 | BLOCKER | Modules cannot build each other's opaque types | §3.1 Internal modules + aliases, done in Phase 0 |
| R2.2 | MAJOR | Write-lock semantics | §3.5 `write` |
| R2.3 | MAJOR | `cancelReadable` gives `Closed` to readers; lock checks on cancel and close | §3.5 |
| R2.4 | MAJOR | Transform gating, rendezvous at `readCap 0`, custom write ≥1, `fromList []`, write-after-close, custom Close | §3.5 |
| R2.5 | MAJOR | Unsafe fd close (stdio reuse) | §3.4 |
| R2.6 | MAJOR | `onEmptyEventLoop` loops forever | §3.7 |
| R2.7 | MAJOR | `args`/`applicationPath` unspecified | §3.7, D10 |
| R2.8 | MAJOR | "Every Windows kernel fails" is impossible for `Task Never`/`Cmd`/`Sub` | §1 Windows rule |
| R2.9 | MAJOR | Path parsing rules unstated | Phase 4 step 1, Appendix E.2 |
| R2.10 | MAJOR | HttpService gaps (protocols, header injection, redirect headers, statusText, timeout 0, cancel) | Moot for eco/system (D8). They affect elm/http's native kernel; recorded as a follow-up for `plans/complete-elm-http-kernel.md` |
| R2.11 | MAJOR | `node_modules` in the bundle; `.npmrc` | Phase 0 steps 8–9 |
| R2.12 | MINOR | Duplicate header keys | B4 |
| R2.13 | MINOR | UTF-8 strictness, decoder and encoder edge cases | §3.5 UTF-8, B5 |
| R2.14 | MINOR | File behaviour details | Appendix E.3 |
| R2.15 | MINOR | Undeclared drops (`startProgram`, …) | D3 |
| R2.16 | MINOR | Summary must be under 80 bytes | Phase 0 step 5 |
| R2.17 | MINOR | Stub wording (top-level arrows) | Phase 0 step 3 |
| R2.18 | MINOR | Arch is compile-time; title is `comm` only | §3.8 |
| R2.19 | MINOR | Pipe propagation unstated | §3.5 |

**Readiness reviewer (R3)**, run on v2 before D8/D9 were added. Every finding was accepted; findings
about the dropped HTTP client are moot.

| # | Sev | Finding | Resolution |
|---|---|---|---|
| R3.1 | BLOCKER | CHECK runs inside the child; `std::exit` skips it; exit status is ambiguous | Phase 1 step 8b/c (parent verifies, atexit hook, EXIT only where stated) |
| R3.2 | BLOCKER | The body guard returned the wrong error shape; async bodies leaked tokens | §3.3.2 guards with a `Shape` parameter; `ECO_SYSTEM_ASYNC_GUARD` |
| R3.3 | MAJOR | Templates used helpers that do not exist | `Core.hpp` declaration list in §3.3.2; Phase 2 step 8 |
| R3.4 | MAJOR | No template for operations that park | T9 |
| R3.5 | MAJOR | Kill handles: resume not discarded; double decrement | T7 token + `CancelFn` rule |
| R3.6 | MAJOR | The root-bound gate scanned nothing | §3.3.3 gate 4; Phase 1 step 8i |
| R3.7 | MAJOR | `stress-elm` cannot import eco/system | Phase 1 step 8h |
| R3.8 | MAJOR | llhttp would not reach the AOT link | Phase 7 step 1 (`TARGET_OBJECTS`) |
| R3.9 | MAJOR | `eco_main_thread` name clash; embed detection | Phase 2 steps 3 and 7 (`Scheduler::embedMode()`, `eco_process_main_thread`) |
| R3.10 | MINOR | Error shapes inconsistent | B2 table |
| R3.11 | MINOR | `runDuration` exit code | Phase 5 step 2 (−1, E.4) |
| R3.12 | MINOR | `Process.Id` rooting and B1 | G13, B1 |
| R3.13 | MINOR | Registration ABI and placement | T6, Phase 1 step 6 |
| R3.14 | MINOR | Internal-module details | §3.1, Phase 3 step 1, Phase 4 step 2 |
| R3.15 | MINOR | Tuple nesting for 4 or more arguments | G2, T1 |
| R3.16 | MINOR | `move`/`copyFile` argument order | E.3 |
| R3.17 | MINOR | Test `elm.json` direct dependencies | Phase 1 step 8a |
| R3.18 | MINOR | Phase 3 must keep Phase 6 stubs | Phase 3 step 2 |
| R3.19 | MINOR | Raw mode not restored on SIGTERM | Phase 5 step 3 |
| R3.20 | MINOR | Reuse the `TestServerConfig` generator | Phase 8 step 3 |

**GC pattern cross-check** (requested by the user): the three scans of eco-kernel-cpp, elm-kernel-cpp
and the GC invariants/tooling produced §3.3 (rules G1–G15, templates T1–T8, gates, checklist). The two
new facts F21 (bodies not guarded) and F24 (scanners keyed on `heapGeneration`) were found by them.

**Design note DN1 (user request, 2026-10-07): `Http.Stream` owns its types.** Extending
`Http.Body`/`Http.Expect` in place was considered and rejected.
- It would need a new Body constructor and Expect type inside elm/http's native kernel, plus a bridge
  into eco/system.
- It would make eco/system build and read elm/http's internal kernel values, which breaks B1.
- It would leave the elm/http JS kernel unaware of these values.

Owning `Body`/`Expect`/`Resolver` costs four one-line body constructors. It needs no change to
elm-kernel-cpp, and every elm/http value (`Response`, `Metadata`, `Error`) is built in Elm from neutral
tuples. The one cost is no `tracker`/`Http.cancel` support; cancel a `task` with `Process.kill` instead.

## 10. Progress log

(append one line per completed phase: date, phase, test output file, notes)

- 2026-10-07 — **Phase 0 done.**
  - 14 modules: 11 public, plus `Stream.Internal`, `System.File.Internal` and `Http.Server.Internal`.
  - Also added: README, LICENSE (D7), `package.json` + `.npmrc` + `pnpm-lock.yaml`, and the bundle
    exclusions (`node_modules`, `scripts`).
  - `pnpm run docs:check` passes with stock elm: `docs.json` has the 11 public modules and no Internal
    ones. `pnpm run docs` serves on :8000.
  - Notes:
    - `/work/gren-node` and `/work/gren-core` were removed from the container after the plan was
      written. Phase 0 prose was adapted from gren-node 6.2.0 fetched from GitHub and from
      `/tmp/gren-core`. Later phases need fresh copies of these sources (tag `6.2.0` / core `7.5.0`).
    - `FileHandle` docs keep gren's note that `errorPath` is the empty path for handle errors.
      Phase 4 must either make the C++ match it or drop the sentence.
- 2026-10-07 — Phase 1 deviations so far:
  - The kernel-home check lives at `test/scripts/check-kernel-homes.sh`, next to the other check
    scripts, and `full` runs it.
  - Linking `EcoSystem_Stream` against zlib is deferred to Phase 6, when the codecs first use zlib.
    `-lz` was added to the dynamic Linux AOT link now.
  - **Step 1.5:** none of the three IO backends has a directory rename, so the refresh does not copy
    to a temp directory and rename. It deletes the cache, copies the seed, and writes the fingerprint
    **last**. An interrupted refresh leaves no fingerprint and is redone on the next build. A concurrent
    reader in another process can still see a half-copied directory, and `withRegistryLock` is a no-op
    on every backend. The `d.dat` record gained a `localFingerprint` field, so the first build after
    this change regenerates the details cache once.
  - **Step 1.6:** the registration set is accumulated in the `Ctx` field `ecoSystemManagers`, as a core
    `Set String`, rather than found by a pre-scan; `generateMainEntry` runs after the bodies on all three
    paths.
- 2026-10-07 — Phase 2 step 2.8 deviations, all accepted:
  - **One async source for the whole package.** All of eco/system's drains share one async source
    (`Core/AsyncSources.cpp`, registered with `std::call_once`) and are dispatched by index. The
    Scheduler walked its source list with a range-for, which is undefined behaviour if a drain causes a
    new source to be registered; `processReadyAsync` was changed to iterate by index as well.
  - **Helpers beyond the §3.3.2 list:** `Core.hpp` also declares `errnoName`, `CancelFn`, `ErrShape` and
    `detail::failureFor`/`asyncFailure`.
  - **Guard rooting:** `ECO_SYSTEM_ASYNC_GUARD` also roots the body's `resume` parameter.
  - **API changes:**
    - `ByteChannel::close(token)` takes a token.
    - `Registry<Entry>` needs `Entry::forEachWord(f)`.
    - `SysWorkPool::submit` takes an optional `ErrShape`.
  - **Core unit tests:** they live in `test/eco-system-core/EcoSystemCoreTest.cpp` as target
    `eco-system-core-test`, and `full` runs them.
- 2026-10-07 — Governance updates triggered by Phase 2:
  - **Kernel licence manifest (LSS_022).** The WaitService lanes edited `eco-kernel-cpp/.../Process.cpp`.
    The rows for `Process.exit`, `spawn`, `spawnProcess` and `wait` were re-audited: the bodies are
    unchanged apart from the lane argument, and B1–B3 still hold. Their evidence line numbers were
    updated and the audit date moved to 2026-10-07 in `KernelSetFacts.elm`, then the manifest was
    regenerated.
  - **TLA+ canary (GC_MODEL_001).** The exit-code and main-thread atomics in `RuntimeExports.cpp`
    moved M1's census pin. An M1 `AUDIT.md` entry records the verdict "no model change needed"
    (prefix `e6ce850a9a95`), and the manifest was updated.
- 2026-10-07 — **Phases 1 and 2 done.**
  - Results:
    - `full`: 2161/2161 (`/tmp/test_output.txt`). It includes `check-kernel-homes`, the Core unit
      tests (127 checks), `platform-services` PS1–PS9, and eco-system `PackageLinksTest` and
      `HarnessExitZeroTest`.
    - `elm-tests`: 14,118 passed.
    - `run-aot-e2e` with `TEST_FILTER=eco-`: 16/16, covering the eco-kernel and eco-system suites.
    - stress-test: compiles and runs with both `--local-package` flags.
    - The docs shim builds the docs for a throwaway effect module with a kernel import, and reports
      compile errors correctly.
  - Fixes found on the way:
    - eco/kernel's JS `Runtime.dirname` used Node's double-underscore dirname global. The kernel-JS
      parser reads it as a kernel tag, and `--optimize` mangled it into an undefined name, so the
      call threw a ReferenceError. It was latent until the bundled-package probe started running in
      the JS bootstrap (Phase 1 step 1.4). It now uses `require('path').dirname(module.filename)`.
    - The docs shim drops the eco compiler bundle's "Compiled in DEV mode" stderr warning, because
      elm-doc-preview parses stderr as JSON.
  - Deferred to Phase 3, because they need eco/system's stdio APIs: harness self-tests for a
    non-zero `EXIT`, `STDIN` echo, and `CHECK` on raw fd output.

---

## Appendix A — Public API (normative)

Elm type references are qualified in this appendix only to show their origin. Types shown as
`type alias X = <M>.Internal.X` are opaque to users: the `Internal` modules are not exposed (§3.1,
review finding R2.1), so users can name the type but never see its constructor.
`Bytes` is elm/bytes, `Dict` is elm/core, `Json.*` is elm/json, `Time.Posix` is elm/time,
`Url` is elm/url, `Process.Id` is elm/core, and `Http.*` is elm/http.

```elm
module System exposing (..)

type alias Environment =
    { platform : Platform, cpuArchitecture : CpuArchitecture, applicationPath : Path
    , args : List String
    , stdout : Stream.Writable Bytes, stderr : Stream.Writable Bytes, stdin : Stream.Readable Bytes
    }
type Platform = Win32 | Darwin | Linux | FreeBSD | OpenBSD | SunOS | Aix | UnknownPlatform String
type CpuArchitecture = Arm | Arm64 | IA32 | Mips | Mipsel | PPC | PPC64 | S390 | S390x | X64 | UnknownArchitecture String
getPlatform : Task x Platform
getCpuArchitecture : Task x CpuArchitecture
getEnvironmentVariables : Task x (Dict String String)

type alias Program model msg = Platform.Program () (Model model) (Msg model msg)
type alias ProgramConfiguration model msg =
    { init : Environment -> ( model, Cmd msg )
    , update : msg -> model -> ( model, Cmd msg )
    , subscriptions : model -> Sub msg
    }
defineProgram : ProgramConfiguration model msg -> Program model msg

type alias SimpleProgram msg = Program () msg
defineSimpleProgram : (Environment -> Cmd msg) -> SimpleProgram msg
endSimpleProgram : Task Never a -> Cmd msg

exit : Cmd msg
exitWithCode : Int -> Cmd msg
setExitCode : Int -> Task x ()

onEmptyEventLoop : msg -> Sub msg
onSignalInterrupt : msg -> Sub msg
onSignalTerminate : msg -> Sub msg
```

```elm
module Stream exposing (..)

type alias Readable value = Stream.Internal.Readable value
type alias Writable value = Stream.Internal.Writable value
type Error = Closed | Cancelled String | Locked
errorToString : Error -> String

fromList : List a -> Task Error (Readable a)
read : Readable value -> Task Error value
readBytesAsString : Readable Bytes -> Task Error String
readUntilClosed : (a -> b -> Result String b) -> b -> Readable a -> Task Error b
cancelReadable : String -> Readable value -> Task Error ()

write : value -> Writable value -> Task Error (Writable value)
writeStringAsBytes : String -> Writable Bytes -> Task Error (Writable Bytes)
writeLineAsBytes : String -> Writable Bytes -> Task Error (Writable Bytes)
enqueue : value -> Writable value -> Task Error (Writable value)
closeWritable : Writable value -> Task Error ()
cancelWritable : String -> Writable value -> Task Error ()

type alias Transformation read write = Stream.Internal.Transformation read write
identityTransformation : Task x (Transformation data data)
identityTransformationWithOptions : { readCapacity : Int, writeCapacity : Int } -> Task x (Transformation data data)
nullTransformation : data -> Task x (Transformation data data)
type CustomTransformationAction state value
    = UpdateState state
    | Send { state : state, send : List value }
    | Close (List value)
    | Cancel String
customTransformation : (state -> input -> CustomTransformationAction state output) -> state -> Task x (Transformation input output)
customTransformationWithOptions :
    (state -> input -> CustomTransformationAction state output)
    -> { initialState : state, readCapacity : Int, writeCapacity : Int }
    -> Task x (Transformation input output)
readable : Transformation read write -> Readable read
writable : Transformation read write -> Writable write
pipeThrough : Transformation input output -> Readable input -> Task Error (Readable output)
awaitAndPipeThrough : Task Error (Transformation input output) -> Readable input -> Task Error (Readable output)
pipeTo : Writable data -> Readable data -> Task Error ()

textEncoder : Task x (Transformation String Bytes)
textDecoder : Task x (Transformation Bytes String)
gzipCompression : Task x (Transformation Bytes Bytes)
deflateCompression : Task x (Transformation Bytes Bytes)
deflateRawCompression : Task x (Transformation Bytes Bytes)
gzipDecompression : Task x (Transformation Bytes Bytes)
deflateDecompression : Task x (Transformation Bytes Bytes)
deflateRawDecompression : Task x (Transformation Bytes Bytes)
```

```elm
module Stream.Log exposing (..)

bytes : Stream.Writable Bytes -> Bytes -> Task x ()
string : Stream.Writable Bytes -> String -> Task x ()
line : Stream.Writable Bytes -> String -> Task x ()
```

```elm
module System.File exposing (..)

type alias Error = System.File.Internal.Error
errorPath : Error -> Path
errorCode : Error -> String
errorToString : Error -> String
errorIsPermissionDenied : Error -> Bool
errorIsFileExists : Error -> Bool
errorIsDirectoryFound : Error -> Bool
errorIsTooManyOpenFiles : Error -> Bool
errorIsNoSuchFileOrDirectory : Error -> Bool
errorIsNotADirectory : Error -> Bool
errorIsDirectoryNotEmpty : Error -> Bool
errorIsNotPermitted : Error -> Bool
errorIsLinkLoop : Error -> Bool
errorIsPathTooLong : Error -> Bool
errorIsInvalidInput : Error -> Bool
errorIsIO : Error -> Bool

type alias Metadata =
    { entityType : EntityType, deviceID : Int, userID : Int, groupID : Int
    , byteSize : Int, blockSize : Int, blocks : Int
    , lastAccessed : Time.Posix, lastModified : Time.Posix, lastChanged : Time.Posix, created : Time.Posix
    }
type EntityType = File | Directory | Socket | Symlink | Device | Pipe
type AccessPermission = Read | Write | Execute
metadata : { resolveLink : Bool } -> Path -> Task Error Metadata
checkAccess : List AccessPermission -> Path -> Task Error Path
changeAccess : { owner : List AccessPermission, group : List AccessPermission, others : List AccessPermission } -> Path -> Task Error Path
accessPermissionsToInt : List AccessPermission -> Int
changeOwner : { userID : Int, groupID : Int, resolveLink : Bool } -> Path -> Task Error Path
changeTimes : { lastAccessed : Time.Posix, lastModified : Time.Posix, resolveLink : Bool } -> Path -> Task Error Path
move : Path -> Path -> Task Error Path
realPath : Path -> Task Error Path

copyFile : Path -> Path -> Task Error Path
appendToFile : Bytes -> Path -> Task Error Path
readFile : Path -> Task Error Bytes
type ReadFileStreamMode = Beginning | From Int | Between { start : Int, end : Int }
readFileStream : ReadFileStreamMode -> Path -> Task Error (Stream.Readable Bytes)
writeFile : Bytes -> Path -> Task Error Path
type WriteFileStreamMode = Replace | ReplaceFrom Int | Append
writeFileStream : WriteFileStreamMode -> Path -> Task Error (Stream.Writable Bytes)
truncateFile : Int -> Path -> Task Error Path
remove : { recursive : Bool } -> Path -> Task Error Path

listDirectory : Path -> Task Error (List { path : Path, entityType : EntityType })
makeDirectory : { recursive : Bool } -> Path -> Task Error Path
makeTempDirectory : String -> Task Error Path

hardLink : Path -> Path -> Task Error Path
softLink : Path -> Path -> Task Error Path
readLink : Path -> Task Error Path
unlink : Path -> Task Error Path

type WatchEvent = Changed (Maybe Path) | Moved (Maybe Path)
watch : (WatchEvent -> msg) -> Path -> Sub msg
watchRecursive : (WatchEvent -> msg) -> Path -> Sub msg

homeDirectory : Task x Path
currentWorkingDirectory : Task x Path
tmpDirectory : Task x Path
devNull : Task x Path
```

```elm
module System.File.Path exposing (..)

type alias Path = { root : String, directory : List String, filename : String, extension : String }
empty : Path
fromPosixString : String -> Path
toPosixString : Path -> String
fromWin32String : String -> Path
toWin32String : Path -> String
filenameWithExtension : Path -> String
parentPath : Path -> Maybe Path
append : Path -> Path -> Path
appendPosixString : String -> Path -> Path
appendWin32String : String -> Path -> Path
prepend : Path -> Path -> Path
prependPosixString : String -> Path -> Path
prependWin32String : String -> Path -> Path
join : List Path -> Path
```

```elm
module System.File.FileHandle exposing (..)

type FileHandle readAccess writeAccess
type ReadAccess
type WriteAccess
type alias ReadableFileHandle a = FileHandle ReadAccess a
type alias WriteableFileHandle a = FileHandle a WriteAccess
type alias ReadWriteableFileHandle = FileHandle ReadAccess WriteAccess
makeReadOnly : ReadWriteableFileHandle -> FileHandle ReadAccess Never
makeWriteOnly : ReadWriteableFileHandle -> FileHandle Never WriteAccess

type OpenForWriteBehaviour = EnsureEmpty | ExpectExisting | ExpectNotExisting
openForRead : Path -> Task File.Error (FileHandle ReadAccess Never)
openForWrite : OpenForWriteBehaviour -> Path -> Task File.Error (FileHandle Never WriteAccess)
openForReadAndWrite : OpenForWriteBehaviour -> Path -> Task File.Error ReadWriteableFileHandle
close : FileHandle a b -> Task File.Error ()

metadata : ReadableFileHandle a -> Task File.Error File.Metadata
changeAccess :
    { owner : List File.AccessPermission, group : List File.AccessPermission, others : List File.AccessPermission }
    -> WriteableFileHandle a -> Task File.Error (WriteableFileHandle a)
changeOwner : { userID : Int, groupID : Int } -> WriteableFileHandle a -> Task File.Error (WriteableFileHandle a)
changeTimes : { lastAccessed : Time.Posix, lastModified : Time.Posix } -> WriteableFileHandle a -> Task File.Error (WriteableFileHandle a)

read : ReadableFileHandle a -> Task File.Error Bytes
readFromOffset : ReadableFileHandle a -> { offset : Int, length : Int } -> Task File.Error Bytes
write : WriteableFileHandle a -> Bytes -> Task File.Error (WriteableFileHandle a)
writeFromOffset : WriteableFileHandle a -> Int -> Bytes -> Task File.Error (WriteableFileHandle a)
truncate : Int -> WriteableFileHandle a -> Task File.Error (WriteableFileHandle a)
sync : WriteableFileHandle a -> Task File.Error (WriteableFileHandle a)
syncData : WriteableFileHandle a -> Task File.Error (WriteableFileHandle a)
```

```elm
module System.Process exposing (..)

type alias RunOptions =
    { shell : Shell, workingDirectory : WorkingDirectory, environmentVariables : EnvironmentVariables
    , maximumBytesWrittenToStreams : Int, runDuration : RunDuration
    }
defaultRunOptions : RunOptions
type Shell = NoShell | DefaultShell | CustomShell String
type WorkingDirectory = InheritWorkingDirectory | SetWorkingDirectory String
type EnvironmentVariables
    = InheritEnvironmentVariables
    | MergeWithEnvironmentVariables (Dict String String)
    | ReplaceEnvironmentVariables (Dict String String)
type RunDuration = NoLimit | Milliseconds Int

type alias SuccessfulRun = { stdout : Bytes, stderr : Bytes }
type FailedRun
    = InitError { program : String, arguments : List String, errorCode : String }
    | ProgramError { exitCode : Int, stdout : Bytes, stderr : Bytes }
run : String -> List String -> RunOptions -> Task FailedRun SuccessfulRun

type alias SpawnOptions msg =
    { shell : Shell, workingDirectory : WorkingDirectory, environmentVariables : EnvironmentVariables
    , runDuration : RunDuration, connection : Connection msg, onExit : Int -> msg
    }
type alias StreamIO = { input : Stream.Writable Bytes, output : Stream.Readable Bytes, error : Stream.Readable Bytes }
type Connection msg
    = Integrated (Process.Id -> msg)
    | External ({ processId : Process.Id, streams : StreamIO } -> msg)
    | Ignored (Process.Id -> msg)
    | Detached (Process.Id -> msg)
defaultSpawnOptions : Connection msg -> (Int -> msg) -> SpawnOptions msg
spawn : String -> List String -> SpawnOptions msg -> Cmd msg
```

```elm
module System.Terminal exposing (..)

type alias Configuration = { colorDepth : Int, columns : Int, rows : Int }
type alias Size = { columns : Int, rows : Int }
getConfiguration : Task x (Maybe Configuration)
setStdInRawMode : Bool -> Task x ()
setProcessTitle : String -> Task x ()
onResize : (Size -> msg) -> Sub msg
```

```elm
module Http.Server exposing (..)

type Server
type ServerError = ServerError { code : String, message : String }
createServer : { host : String, port_ : Int } -> Task ServerError Server

type alias Request = { headers : Dict String String, method : Method, body : Bytes, url : Url }
type Method = GET | HEAD | POST | PUT | DELETE | CONNECT | TRACE | PATCH | UNKNOWN String
methodToString : Method -> String
bodyAsString : Request -> Maybe String
bodyFromJson : Json.Decode.Decoder a -> Request -> Result Json.Decode.Error a
requestInfo : Request -> String
onRequest : Server -> (Request -> Http.Server.Response.Response -> msg) -> Sub msg
```

```elm
module Http.Server.Response exposing (..)

type alias Response = Http.Server.Internal.Response
send : Response -> Cmd msg
setStatus : Int -> Response -> Response
setHeader : String -> String -> Response -> Response
appendHeader : String -> String -> Response -> Response
setBody : String -> Response -> Response
setBodyAsString : String -> Response -> Response
setBodyAsBytes : Bytes -> Response -> Response
```

```elm
module Http.Stream exposing (..)

type Body
emptyBody : Body
bytesBody : String -> Bytes -> Body
stringBody : String -> String -> Body
jsonBody : Json.Encode.Value -> Body
streamBody : String -> Stream.Readable Bytes -> Body

type Expect msg
expectStream : (Result Http.Error ( Http.Metadata, Stream.Readable Bytes ) -> msg) -> Expect msg
expectStreamResponse : (Result x a -> msg) -> (Http.Response (Stream.Readable Bytes) -> Result x a) -> Expect msg

type Resolver x a
streamResolver : (Http.Response (Stream.Readable Bytes) -> Result x a) -> Resolver x a

request :
    { method : String, headers : List Http.Header, url : String
    , body : Body, expect : Expect msg, timeout : Maybe Float }
    -> Cmd msg
task :
    { method : String, headers : List Http.Header, url : String
    , body : Body, resolver : Resolver x a, timeout : Maybe Float }
    -> Task x a
```

## Appendix B — Kernel function catalogue (normative)

**Conventions**
- **Elm column.** It is the annotation of the private wrapper in the calling module, for example
  `kRead : Int -> Task SErr a` / `kRead = Eco.Kernel.Stream.read`. The annotation fixes the C ABI (F7).
- **Error tuples.** `FErr = ( String, String )` holds an errno name such as `"ENOENT"` and a message.
  `SErr = ( Int, String )` holds 0 Closed / 1 Cancelled / 2 Locked and a reason.
- **Modes.**
  - **S**: `makeBinding`, trivially fast, no blocking.
  - **P**: `SysWorkPool` via `makeAsyncBinding` (T2).
  - **Q**: parks on the StreamTable, with no `pendingAsync`.
  - **C**: FdChannel.
  - **W**: WaitService.
  - **M**: handled inside a C++ effect manager; there is no kernel function.
  - **pure**: a non-Task conversion (B5).
- **C symbols.** The symbol is `Eco_Kernel_<Home>_<name>`. Every non-Int/Float/Char argument or
  result is `uint64_t`.
- **Locations.** Kernel `<Home>` lives in `src/eco-system/<Home>/`, split into `<Home>.cpp` (bodies) and
  `<Home>Exports.cpp` (exports), as eco-kernel does.

### B.1 `Eco.Kernel.System`

| Kernel fn | Elm type | Mode | Notes |
|---|---|---|---|
| `environment` | `Task Never ( ( String, String, String ), List String, ( Int, Int, Int ) )` | S | Returns `((platform, arch, applicationPath), argv, (stdin, stdout, stderr) pair ids)`. platform is Node's spelling: `"linux"`, `"darwin"`, `"win32"`, `"freebsd"`, `"openbsd"`, `"sunos"`, `"aix"`. arch: §3.8. argv: full (§3.7). Stdio pairs are created once per process and cached. The id tuple is all Int, so its mask is `0b010101`. |
| `getPlatform` | `Task Never String` | S | |
| `getCpuArchitecture` | `Task Never String` | S | |
| `getEnvironmentVariables` | `Task Never (List ( String, String ))` | S | Iterates `environ` and splits each entry at the first `=`. |
| `exitWithCode` | `Int -> Task Never ()` | S | §3.7: standalone `fflush` + `std::exit`; embed sets the code and calls `requestStop`. |
| `setExitCode` | `Int -> Task Never ()` | S | `eco_set_exit_code` |
| `System` manager | — | M | C.1 |

### B.2 `Eco.Kernel.Stream`

| Kernel fn | Elm type | Mode | Notes |
|---|---|---|---|
| `identity` | `Int -> Int -> Task Never Int` | S | `(readCap, writeCap)`, already clamped. Returns the pair id. |
| `custom` | `(s -> a -> ( Int, s, ( List b, String ) )) -> s -> Int -> Int -> Task Never Int` | S | `(action, initialState, readCap, writeCap)`. Stores the encoded fn and state in the pair. |
| `read` | `Int -> Task SErr a` | Q/C | |
| `write` | `a -> Int -> Task SErr ()` | Q/C | |
| `enqueue` | `a -> Int -> Task SErr ()` | Q/C | |
| `closeWritable` | `Int -> Task SErr ()` | Q/C | |
| `cancelReadable` | `String -> Int -> Task SErr ()` | S | |
| `cancelWritable` | `String -> Int -> Task SErr ()` | S | |
| `pipeThrough` | `Int -> Int -> Task SErr ()` | S | `(transformation, readable)`. Elm returns `Readable transformation`. |
| `pipeTo` | `Int -> Int -> Task SErr ()` | Q | `(writable, readable)` |
| `textEncoder`, `textDecoder` | `Task Never Int` | S | |
| `compressor`, `decompressor` | `Int -> Task Never Int` | S | 0 gzip, 1 deflate, 2 deflate-raw |
| `utf8ToString` | `Bytes -> Maybe String` | pure | strict |
| `stringToUtf8` | `String -> Bytes` | pure | |
| C++ API | `int64_t createChannelSource(ByteChannel*)`, `createChannelSink(ByteChannel*)`, plus the fd conveniences `createFdSource(int fd, bool owns)` and `createFdSink(int fd, bool owns)` | — | Used by the other modules. |

### B.3 `Eco.Kernel.FileSystem`

Every path argument is a POSIX string. The behaviours follow Appendix E.3.

| Kernel fn | Elm type | Mode | Notes |
|---|---|---|---|
| `stat` | `Bool -> String -> Task FErr (List Int)` | P | resolveLink: `stat`/`lstat`. Returns `[entityType, dev, uid, gid, size, blksize, blocks, atimeMs, mtimeMs, ctimeMs, birthtimeMs]`. entityType: 0 File, 1 Directory, 2 Socket, 3 Symlink, 4 Device, 5 Pipe. |
| `access` | `Int -> String -> Task FErr ()` | P | mode bits R=4, W=2, X=1; 0 means `F_OK` |
| `chmod` | `Int -> String -> Task FErr ()` | P | The mode is already numeric (Elm parses octal digits, E.3). |
| `chown` | `Bool -> Int -> Int -> String -> Task FErr ()` | P | `(resolveLink, uid, gid, path)` |
| `utimes` | `Bool -> Int -> Int -> String -> Task FErr ()` | P | `(resolveLink, atimeSec, mtimeSec, path)`, whole seconds (E.3) |
| `rename` | `String -> String -> Task FErr ()` | P | `(from, to)` |
| `realpath` | `String -> Task FErr String` | P | |
| `copyFile` | `String -> String -> Task FErr ()` | P | `(src, dest)`, overwrites; errors report dest (E.3) |
| `appendFile` | `Bytes -> String -> Task FErr ()` | P | creates the file |
| `readFile` | `String -> Task FErr Bytes` | P | |
| `writeFile` | `Bytes -> String -> Task FErr ()` | P | |
| `truncate` | `Int -> String -> Task FErr ()` | P | |
| `remove` | `Bool -> String -> Task FErr ()` | P | `(recursive, path)`. Non-recursive on a directory fails with code `"ERR_FS_EISDIR"`. |
| `listDirectory` | `String -> Task FErr (List ( String, Int ))` | P | `(name, entityType)`, sorted by `strcmp`; `lstat` fallback on `DT_UNKNOWN` |
| `makeDirectory` | `Bool -> String -> Task FErr ()` | P | |
| `makeTempDirectory` | `String -> Task FErr String` | P | E.3 |
| `link`, `symlink` | `String -> String -> Task FErr ()` | P | `(src, dest)`, where src is the existing target. gren's Elm API takes `dest src` (E.3). |
| `readLink` | `String -> Task FErr String` | P | |
| `unlink` | `String -> Task FErr ()` | P | |
| `homeDirectory`, `currentWorkingDirectory`, `tmpDirectory`, `devNull` | `Task Never String` | S | E.3 |
| `open` | `String -> String -> Task FErr Int` | P | `(nodeFlags, path)` → fd. Flags: `"r"`, `"w"`, `"r+"`, `"wx"`, `"w+"`, `"wx+"`. Mode 0666 with `O_CLOEXEC`. |
| `close` | `Int -> Task FErr ()` | P | |
| `fstat` | `Int -> Task FErr (List Int)` | P | |
| `fchmod` | `Int -> Int -> Task FErr ()` | P | `(fd, mode)` |
| `fchown` | `Int -> Int -> Int -> Task FErr ()` | P | `(fd, uid, gid)` |
| `futimes` | `Int -> Int -> Int -> Task FErr ()` | P | `(fd, atimeSec, mtimeSec)` |
| `readFromOffset` | `Int -> Int -> Int -> Task FErr Bytes` | P | `(fd, offset, length)`; offset < 0 becomes 0; length < 0 means to EOF |
| `writeFromOffset` | `Int -> Int -> Bytes -> Task FErr ()` | P | `pwrite` loop |
| `ftruncate` | `Int -> Int -> Task FErr ()` | P | |
| `fsync`, `fdatasync` | `Int -> Task FErr ()` | P | §3.8 |
| `readFileStream` | `Int -> Int -> String -> Task FErr Int` | P | `(start, endInclusive or -1, path)` → FdSource id (owns fd) |
| `writeFileStream` | `Int -> Int -> String -> Task FErr Int` | P | `(mode, position, path)` → FdSink id. Modes: 0 Replace (`w`), 1 ReplaceFrom (`r+`, truncate to `position` + bytes written on close), 2 Append (`a`). |
| `System.File` manager | — | M | C.2 |

### B.4 `Eco.Kernel.ChildProcess`

| Kernel fn | Elm type | Mode | Notes |
|---|---|---|---|
| `run` | `String -> List String -> ( Int, String ) -> ( Bool, String ) -> ( Int, List ( String, String ) ) -> ( Int, Int ) -> Task ( Int, String, ( Int, Bytes, Bytes ) ) ( Bytes, Bytes )` | W + C | The arguments, in order:<ul><li>program</li><li>args</li><li>`(shellKind 0 None / 1 Default / 2 Custom, customShell)`</li><li>`(inheritCwd, cwd)`</li><li>`(envMode 0 Inherit / 1 Merge / 2 Replace, pairs)`</li><li>`(maxBytes, runDurationMs)`, where 0 means no limit</li></ul>The failure is `(0 InitError \| 1 ProgramError, errnoName, (exitCode, stdout, stderr))`. Elm fills in `InitError.program`/`arguments` from its own arguments. E.4 |
| `System.Process` manager | — | M | C.3 |

### B.5 `Eco.Kernel.Terminal`

| Kernel fn | Elm type | Mode | Notes |
|---|---|---|---|
| `getConfiguration` | `Task Never (Maybe ( Int, Int, Int ))` | S | `Nothing` unless `isatty(1)`. Returns `(colorDepth, columns, rows)`. colorDepth: `NO_COLOR` or `TERM=dumb` → 1; `FORCE_COLOR=0/1/2/3` → 1/4/8/24; `COLORTERM` truecolor or 24bit → 24; `TERM` ending in `256color` → 8; otherwise 4. |
| `setStdInRawMode` | `Bool -> Task Never ()` | S | termios; a no-op if stdin is not a TTY; restored at exit |
| `setProcessTitle` | `String -> Task Never ()` | S | §3.8 |
| `System.Terminal` manager | — | M | C.4 |

### B.6 `Eco.Kernel.HttpServer`

| Kernel fn | Elm type | Mode | Notes |
|---|---|---|---|
| `createServer` | `String -> Int -> Task ( String, String ) Int` | P | `(host, port)` → server id. Holds `pendingAsync` while listening. |
| `respond` | `Int -> Int -> List ( String, List String ) -> Bytes -> Task Never ()` | C | `(responseKey, status, headers, body)` |
| `Http.Server` manager | — | M | C.5. The request URL handed to Elm is absolute (E.5). |

### B.7 `Eco.Kernel.HttpStream`

| Kernel fn | Elm type | Mode | Notes |
|---|---|---|---|
| `send` | `( String, String, Int ) -> List Http.Header -> ( Int, String, ( Bytes, Int ) ) -> Bool -> Task Never ( Int, String, ( ( Int, String, String ), List ( String, String ), Int ) )` | HttpStreamService | **Arguments:** `((method, url, timeoutMs; 0 = none), headers (B1a), (bodyKind 0 empty / 1 bytes / 2 stream, contentType, (bytes, streamId; -1 if none)), discardNon2xx)`.<br>**Result:** `(kind 0 BadUrl_ / 1 Timeout_ / 2 NetworkError_ / 3 BadStatus_ / 4 GoodStatus_, badUrlMessage, ((statusCode, statusText, finalUrl), headers, bodyStreamId))`. The task never fails.<br>**Masks:** `(Int, String, String)` 0x1; `((…), List, Int)` 0x10; `(Int, String, (…))` 0x1; argument `(Bytes, Int)` 0x4.<br>The kill handle aborts the transfer. |

## Appendix C — Effect-manager constructor layouts (normative)

**Rules**
- Constructor tags are the zero-based **declaration index** (`Compiler/Data/CtorTag.elm`).
- Fields are in declaration order. Int/Float/Char fields are unboxed, with kind masks of 2 bits per
  field (`Generate/MLIR/Types.elm:561-578`).
- Bool and everything else is boxed.
- Nullary constructors are embedded constants (HEAP_044).
- The Elm declaration below is copied verbatim into the module. The C++ header
  `src/eco-system/<Home>/<Home>Manager.hpp` declares the matching `constexpr` tags and field indices,
  with a comment pointing back at the Elm line.
- A tagger takes **one boxed argument** (B7).

### C.0 Manager skeleton (T6 in full)

```cpp
// src/eco-system/<Home>/<Home>Manager.cpp — mirrors Appendix C.<n>.
#include "eco-system/Core/Core.hpp"
namespace Eco::System {
namespace {
constexpr uint16_t CTOR_<A> = 0;  // Elm: type MySub msg = <A> ... | <B> ...

void* initEval(void*[]) {                                   // arity 0, forced by setupEffects
    return enc(Scheduler::instance().taskSucceed(alloc::unit()));
}

void* onEffectsEval(void* args[]) {                         // router, cmds, subs, state
    HPointer router = dec(args[0]), cmds = dec(args[1]), subs = dec(args[2]);
    Elm::StackRootGuard g(&router, &cmds, &subs);
    std::vector<SubSpec> wanted;                            // POD + encoded words only
    for (alloc::RootedListCursor c(subs); /*read*/; c.advance()) {
        // resolve the Custom, read ctor + fields into `wanted` in a scope with NO allocation (G5)
    }
    auto& reg = registry();                                 // T5, main-thread only
    reg.routerEnc = enc(router);
    reconcile(reg, wanted);                                 // start/stop services: POD calls only
    // cmds: for each Execute/Spawn: decode, act (may allocate: re-root as G4)
    return enc(Scheduler::instance().taskSucceed(alloc::unit()));
}

void* onSelfMsgEval(void* args[]) {                         // unused: return state
    return enc(Scheduler::instance().taskSucceed(dec(args[2])));
}

void* subMapEval(void* args[]) {                            // f, sub
    // Copy TimeEffectManager.cpp:320-399: root f and sub, copy fields into rooted locals,
    // allocClosure(composedTaggerEval, 3), closureCapture(f), closureCapture(oldTagger) with
    // no allocation in between (G8), then custom(sameTag, fields with new tagger, sameMask).
}
}  // namespace
}  // namespace Eco::System
using namespace Eco::System;

extern "C" uint64_t Eco_System_registerManager_<Key>() {   // called from __eco_register_ports (§3.6)
    HPointer initCl = alloc::listNil(), effCl = alloc::listNil(), selfCl = alloc::listNil(),
             cmdMapCl = alloc::listNil(), subMapCl = alloc::listNil();
    Elm::StackRootGuard g({&initCl, &effCl, &selfCl, &cmdMapCl, &subMapCl});   // G14
    initCl   = alloc::allocClosure(initEval, 0);
    effCl    = alloc::allocClosure(onEffectsEval, 4);
    selfCl   = alloc::allocClosure(onSelfMsgEval, 3);
    cmdMapCl = HAS_CMDS ? alloc::allocClosure(cmdMapEval, 2) : alloc::listNil();
    subMapCl = HAS_SUBS ? alloc::allocClosure(subMapEval, 2) : alloc::listNil();
    PlatformRuntime::ManagerInfo info{ enc(initCl), enc(effCl), enc(selfCl), enc(cmdMapCl), enc(subMapCl) };
    PlatformRuntime::instance().registerManager("<Key>", info);              // no allocation after encode
    return enc(alloc::unit());                                                // !eco.value result (T6)
}
```

Event delivery from a service drain follows T8.

### C.1 `System` (key `"System"`)

```elm
type MyCmd msg = Execute (Task Never ())                                   -- tag 0: [task boxed]
type MySub msg
    = OnEmptyEventLoop msg                                                 -- tag 0: [msg boxed]
    | OnSignalInterrupt msg                                                -- tag 1: [msg boxed]
    | OnSignalTerminate msg                                                -- tag 2: [msg boxed]
```
- **`cmdMap _ (Execute t) = Execute t`.** In C++, return the command unchanged.
- **`subMap f s`.** Apply `f` to the stored msg now (`callClosure1`) and rebuild with the same tag, as
  gren does. No composition is needed.
- **onEffects.**
  - Every `Execute t` is passed to `Scheduler::rawSpawn(t)`, followed by `drain()` once after the loop.
  - Subs: the registry keeps three lists of encoded msgs. SignalService is subscribed to SIGINT/SIGTERM
    while the matching list is non-empty. The quiescence listener (registered once) delivers the
    `OnEmptyEventLoop` msgs.
- **Delivery.** `sendToApp(router, msg)` + `drain()` for every stored msg of the event type.

### C.2 `System.File` (key `"System.File"`)

```elm
type MySub msg = Watch String Bool (( Int, Maybe String ) -> msg)          -- tag 0: [path boxed, recursive boxed, tagger boxed]
```
- **Tagger argument.** `(kind, relativePath)`, where kind is 0 Changed or 1 Moved. The Elm wrapper is
  `watch toMsg path = subscription (Watch (Path.toPosixString path) False (\( k, p ) -> toMsg (decodeWatchEvent k p)))`.
- **subMap.** Compose the tagger (TimeEffectManager pattern).
- **Registry key.** `(path, recursive)`, holding the list of encoded taggers. One watcher exists per
  key.

### C.3 `System.Process` (key `"System.Process"`)

```elm
type MyCmd msg
    = Spawn
        ( ( String, List String ), ( ( Int, String ), ( Bool, String ) ), ( ( Int, List ( String, String ) ), Int, Int ) )
        (( Process.Id, Maybe ( Int, Int, Int ) ) -> msg)
        (( Int, Int ) -> msg)
    -- tag 0: [spec boxed, onInit boxed, onExit boxed]
```
- **spec.** `((program, args), ((shellKind, customShell), (inheritCwd, cwd)), ((envMode, pairs),
  runDurationMs, connectionKind))`. connectionKind: 0 Integrated, 1 External, 2 Ignored, 3 Detached.
  The inner tuples' Int slots are unboxed: mask `0x1` for `(Int, String)`, `0x14` for the
  `(boxed, Int, Int)` triple.
- **onInit argument.** `(processId, Just (stdinId, stdoutId, stderrId))` for External, otherwise
  `Nothing`.
- **onExit argument.** `(exitCode, signal)`. For a signal death, exitCode is `128 + signal`; otherwise
  signal is 0.
- **cmdMap.** Compose both taggers.

### C.4 `System.Terminal` (key `"System.Terminal"`)

```elm
type MySub msg = OnResize (( Int, Int ) -> msg)                            -- tag 0: [tagger boxed]; arg = (columns, rows)
```

### C.5 `Http.Server` (key `"Http.Server"`)

```elm
type MySub msg = OnRequest Int (( ( String, String ), ( List ( String, List String ), Bytes ), Int ) -> msg)
    -- tag 0: [serverId unboxed Int (mask 0b01), tagger boxed]
```
- **Tagger argument.** `((method, absoluteUrl), (headers, body), responseKey)`. It is a `tuple3`
  whose slot 2 is an unboxed Int: mask `1 << 4 = 0x10` (HEAP_046).
- **Elm side.** The wrapper builds `Request` and `Response` (via `Http.Server.Internal`) and calls the
  user's handler.

## Appendix D — LICENSE (verbatim, Phase 0 step 7)

```
Original work Copyright 2014-2022 Evan Czaplicki
Modified work Copyright 2022-present The Gren CONTRIBUTORS
Modified work Copyright 2026-present Rupert Smith

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Appendix E — Behaviour notes ported from gren (normative where cited by a phase)

### E.1 Source map

Where each module's implementation and doc comments come from:

| eco module | gren source |
|---|---|
| `System` | `/work/gren-node/src/Node.gren`, `Gren/Kernel/Node.js` |
| `Stream`, `Stream.Log` | `/work/gren-core/src/Stream.gren`, `Stream/Log.gren`, `Gren/Kernel/Stream.js` (7.5.0) |
| `System.File` | `FileSystem.gren`, `Gren/Kernel/FileSystem.js` |
| `System.File.Path` | `FileSystem/Path.gren`, `Gren/Kernel/FilePath.js` |
| `System.File.FileHandle` | `FileSystem/FileHandle.gren` |
| `System.Process` | `ChildProcess.gren`, `Gren/Kernel/ChildProcess.js` |
| `System.Terminal` | `Terminal.gren`, `Gren/Kernel/Terminal.js` |
| `Http.Server`, `Http.Server.Response` | `HttpServer.gren`, `HttpServer/Response.gren`, `Gren/Kernel/HttpServer.js` |

### E.2 Paths (`System.File.Path`)

**Parsing.** `fromPosixString`/`fromWin32String` = node `path.normalize` followed by `path.parse` (in the
posix or win32 flavour), mapped to `{ root, directory = dir split on the separator, minus the root, empty
segments dropped, filename = name, extension = ext without the leading dot }`. Examples:
- `"a/../b"` → filename `b`;
- `"//a//b/"` → root `/`, directory `[a]`, filename `b`;
- `C:foo\bar.txt` → root `C:`;
- `""` and `"."` → `empty`.

**Printing.**
- `toPosixString`: `empty` prints as `"."`, and a non-`/` root is rewritten to `/`.
- `toWin32String` uses `\`.
- `FilePath.js` has a quirk where a `./` prefix is added depending on the native separator; replicate it
  for the posix flavour only.

**Combining.**
- `append`: `left` joined with `right`.
- `prepend left right` = `left.directory ++ [ filenameWithExtension left ] ++ right.directory`.
  gren's `Array.append` has reversed arguments (`Array.gren:566-569`), so the gren source reads
  backwards.
- `join` folds `append` from `empty`.
- `parentPath`: `Nothing` for `empty` and for a root-only path.

**Golden tests.** The golden tables generated in Phase 4 step 1 are authoritative where this text and
node disagree.

### E.3 Files

- `errorCode` is node's `err.code`: an errno name, or `ERR_FS_EISDIR` for a non-recursive `remove` of a
  directory. So `errorIsDirectoryFound` is False in that case, as in gren.
- `copyFile` overwrites. `copyFile`, `move` and the link errors report the **destination** path in
  `errorPath`.
- `hardLink dest src` / `softLink dest src` call `link(src, dest)` / `symlink(src, dest)`
  (`FileSystem.gren:572-586`).
- Argument orders follow gren: `move newPath oldPath` → `rename(old, new)`, and
  `copyFile destPath srcPath` → copy `src` to `dest` (`FileSystem.gren:401-430`).
- `makeTempDirectory prefix`:
  - `mkdtemp(join(tmpDirectory, prefix) ++ "XXXXXX")`;
  - `tmpDirectory` honours `TMPDIR`, then `TMP`, then `TEMP`, and otherwise uses `/tmp`, with a
    trailing `/` stripped;
  - `homeDirectory` is `$HOME`, otherwise `getpwuid(getuid())->pw_dir`;
  - `devNull` is `/dev/null`.
- `changeAccess` takes octal digits per class (gren builds `"644"` from the lists with
  `accessPermissionsToInt`). The kernel receives the numeric mode.
- `changeTimes` has whole-second precision: Elm passes `Time.posixToMillis t // 1000`.
- `FileHandle.write` always writes at offset 0. `readFromOffset` with a negative length reads to EOF.
- `readFileStream`:
  - `Between { start, end }` has an **inclusive** end; `From n` starts at `n`.
  - Errors opening the file are reported by the `readFileStream` task itself. **Deviation:** gren
    reports them at the first `read`.
- `writeFileStream`:
  - `Replace` = `w`; `Append` = `a`. Both create the file.
  - `ReplaceFrom n` = `r+`, which does **not** create the file; on close it truncates to `n` + bytes
    written. `ReplaceFrom 0` behaves like `Replace`.
- `appendToFile` creates the file. `listDirectory` is sorted by `strcmp`. `Metadata` times are
  milliseconds turned into `Time.Posix` in Elm.
- Every successful mutating function returns the `Path` it was given (as in gren), and `copyFile`
  returns the destination.

### E.4 Processes (node `execFile` semantics)

- **Success:** exit code 0 gives `SuccessfulRun { stdout, stderr }`.
- **Non-zero exit:** `ProgramError { exitCode, stdout, stderr }`.
- **Output exceeds `maximumBytesWrittenToStreams`** (either stream): kill with `SIGTERM`, then
  `ProgramError { exitCode = -1, … }` with the output collected so far, truncated at the limit.
- **`runDuration` expires:** kill with `SIGTERM`, then `ProgramError { exitCode = -1, … }`.
- **Spawn fails:** `InitError { program, arguments, errorCode = errnoName }`.
- The `Spawn` connection semantics are as in `ChildProcess.gren:286-312`. With `Detached` the child gets
  its own session and does not keep the program alive.

### E.5 HTTP server

- The request URL is absolute: `http://` + (the `Host` header, otherwise `host:port`) + the request
  target. Elm parses it with `Url.fromString` and falls back to the gren default record
  (`HttpServer.gren:164-190`).
- `headers` (a `Dict String String`) keeps the **last** value of each header, as gren's `dictFromPairs`
  does.
- `toMethod` maps unknown methods to `UNKNOWN m`.

### E.6 `Http.Stream`

- **Headers:** response header names are lower-cased. Duplicates are joined with `", "` in arrival
  order, as in elm/http. Only the final redirect hop's headers are kept.
- **`Metadata.url`** is the final URL after redirects.
- **`expectStream`:**
  - non-2xx → `Err (BadStatus code)`; the body is discarded by the transfer thread, so nothing stalls;
  - before the headers: `BadUrl`, `Timeout` or `NetworkError`;
  - an error after the headers reaches the body stream as `Cancelled "network error: …"`.
- **`expectStreamResponse`/`streamResolver`** see every status with its real body stream.
- **Timeout** covers only the wait for the response headers. This differs from elm/http, whose timeout
  covers the whole request; streams can be arbitrarily long.
- **`streamBody`:**
  - the readable is consumed by the transfer and locked while it runs;
  - if the stream is cancelled, the request fails with `NetworkError_`;
  - `Content-Length` is not sent, so curl uses chunked transfer encoding.
- **Not supported:** trackers, progress and `Http.cancel`. Use `task` with `Process.spawn`/`Process.kill`.
