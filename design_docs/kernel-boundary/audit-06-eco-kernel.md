# 06 — `eco-kernel-cpp/src/eco/` kernel surface audit

Scope: every symbol declared in `eco-kernel-cpp/src/eco/KernelExports.h` (53
declarations; a 54th, `Eco_Kernel_Order_register_gc_roots`, is declared only in
`RuntimeExports.cpp:41-43`), cross-read against the Elm wrappers in
`eco-kernel-cpp/src/Eco/*.elm` and against `KERNEL_TASK_IO_001/002`
(`design_docs/invariants.csv:590-591`).

## Answer to the core question

The user's hypothesis is **correct and near-total for this tree**. 47 of 53
exported symbols (89%) perform **zero IO at kernel-call time**. They decode
their arguments, allocate a payload aggregate, allocate a 2-slot closure over a
C++ body function pointer, and allocate a `Tag_Task{ctor=Task_Binding}` node
pointing at it. All of that is *pure heap allocation of a fixed shape*. The
syscall lives in the `*Body` function, which the scheduler invokes later via
`Elm::Platform::detail::bindingTrampoline` (`runtime/src/platform/TaskBinding.hpp:99-119`).

Only **6** symbols are effectful at call time, and every one of them is a
named exemption in `KERNEL_TASK_IO_001`: `Console_log` (identity + eager
stderr), `Crash_crash` and `Process_exit` (non-returners), and the three
`register_gc_roots` hooks (runtime-internal registration, not Elm-callable).

**There are zero undocumented TB-EAGER violations of `KERNEL_TASK_IO_001` in
this tree.** The Phase 1–7 deferral migration is complete and consistent.

## Classification table

Legend: **TB** = Task builder (no IO at call time) · **TB-ASYNC** = TB whose
body parks the resume with a worker service · **TB-EAGER** = Task-typed but
eager · **E** = effectful non-Task · **RT** = runtime-internal state ·
**X** = non-returning. `HOF` column = invokes an Elm closure *at kernel-call
time* (never; see note under the table).

| Symbol (`Eco_Kernel_…`) | Elm type (from `Eco/*.elm` wrapper) | Class | Binding body | HOF | Part 2 verdict | Notes |
|---|---|---|---|---|---|---|
| `File_readString` | `String -> Task (Int,String,String) String` | TB | `readStringBody` `File.cpp:82` | no (step) | ctor Feasible / body Hard-Infeasible | zero-copy UTF-8 view path |
| `File_writeString` | `String -> String -> Task e ()` | TB | `writeStringBody` `File.cpp:461` | no | Feasible / Hard-Infeasible | payload `tuple2` alloc |
| `File_readBytes` | `String -> Task e Bytes` | TB | `readBytesBody` `File.cpp:132` | no | Feasible / Hard-Infeasible | |
| `File_writeBytes` | `String -> Bytes -> Task e ()` | TB | `writeBytesBody` `File.cpp:486` | no | Feasible / Hard-Infeasible | payload `tuple2` |
| `File_open` | `String -> Int -> Task e Int` | TB | `openBody` `File.cpp:513` | no | Feasible / Hard-Infeasible | `mode` declared `HPtr`, actually raw i64 (`File.cpp:631-637`) |
| `File_close` | `Int -> Task e ()` | TB | `closeBody` `File.cpp:436` | no | Feasible / Hard-Infeasible | payload `tuple2(int, unit)` — pure padding |
| `File_size` | `Int -> Task e Int` | TB | `sizeBody` `File.cpp:444` | no | Feasible / Hard-Infeasible | **header says "Returns Int (unboxed)"** (`KernelExports.h:79-80`) — it is a Task |
| `File_lock` | `String -> Task e ()` | TB | `lockBody` `File.cpp:431` | no | **Elm-source** | body is a NO-OP STUB — `Task.succeed ()` |
| `File_unlock` | `String -> Task e ()` | TB | `unlockBody` `File.cpp:432` | no | **Elm-source** | NO-OP STUB |
| `File_fileExists` | `String -> Task Never Bool` | TB | `fileExistsBody` `File.cpp:152` | no | Feasible / Hard-Infeasible | header claims raw `Bool` (`:88-89`) |
| `File_dirExists` | `String -> Task Never Bool` | TB | `dirExistsBody` `File.cpp:161` | no | Feasible / Hard-Infeasible | header claims raw `Bool` (`:91-92`) |
| `File_findExecutable` | `String -> Task Never (Maybe String)` | TB | `findExecutableBody` `File.cpp:187` | no | Feasible / Hard-Infeasible | header claims raw `Maybe String` (`:94-95`) |
| `File_list` | `String -> Task e (List String)` | TB | `listBody` `File.cpp:236` | no | Feasible / Hard-Infeasible | header claims raw `List String` (`:97-98`) |
| `File_modificationTime` | `String -> Task e Int` | TB | `modificationTimeBody` `File.cpp:263` | no | Feasible / Hard-Infeasible | declared `uint64_t` (`:101`), returns Task HPointer |
| `File_getCwd` | `Task Never String` | TB | `getCwdBody` `File.cpp:291` | no | Feasible / Hard-Infeasible | header claims raw `String` (`:103-104`); captures `unit()` — no payload alloc |
| `File_setCwd` | `String -> Task e ()` | TB | `setCwdBody` `File.cpp:309` | no | Feasible / Hard-Infeasible | |
| `File_canonicalize` | `String -> Task e String` | TB | `canonicalizeBody` `File.cpp:324` | no | Feasible / Hard-Infeasible | header claims raw `String` (`:109-110`) |
| `File_appDataDir` | `String -> Task Never String` | TB | `appDataDirBody` `File.cpp:343` | no | Feasible / Hard-Infeasible | header claims raw `String` (`:112-113`) |
| `File_createDir` | `Bool -> String -> Task e ()` | TB | `createDirBody` `File.cpp:567` | no | Feasible / Hard-Infeasible | payload `tuple2` |
| `File_removeFile` | `String -> Task e ()` | TB | `removeFileBody` `File.cpp:378` | no | Feasible / Hard-Infeasible | |
| `File_removeDir` | `String -> Task e ()` | TB | `removeDirBody` `File.cpp:391` | no | Feasible / Hard-Infeasible | |
| `File_hWriteString` | `Int -> String -> Task e ()` | TB | `hWriteStringBody` `File.cpp:544` | no | Feasible / Hard-Infeasible | payload `tuple2` |
| `File_touch` | `String -> Task e ()` | TB | `touchBody` `File.cpp:405` | no | Feasible / Hard-Infeasible | |
| `Crash_crash` | `String -> a` (`Eco/Crash.elm:16`) | **X** | — | no | **Already-intrinsic** | duplicates `eco.crash` (`Ops.td:478`) → `eco_crash` + `unreachable`; exemption (b) |
| `Console_write` | `Int -> String -> Task e ()` | TB | `writeBody` `Console.cpp:55` | no | Feasible / Hard-Infeasible | **silently no-ops for handle ∉ {1,2}** (`Console.cpp:73`) |
| `Console_readLine` | `Task e String` | TB | `readLineBody` `Console.cpp:103` | no | Feasible / Hard-Infeasible | body BLOCKS the scheduler thread (TODO StdinService) |
| `Console_readAll` | `Task e String` | TB | `readAllBody` `Console.cpp:112` | no | Feasible / Hard-Infeasible | body BLOCKS the scheduler thread |
| `Console_log` | `String -> a -> a` (`Eco/Console.elm:81`) | **E** | — | no | Hard-Infeasible (stderr write) | exemption (c); identity on arg 2 (`Console.cpp:162`) |
| `Env_lookup` | `String -> Task Never (Maybe String)` | TB | `lookupBody` `Env.cpp:30` | no | Feasible / Hard-Infeasible | header claims raw `Maybe String` (`:159-160`) |
| `Env_rawArgs` | `Task Never (List String)` | TB | `rawArgsBody` `Env.cpp:40` | no | Feasible / Hard-Infeasible | header claims raw `List String` (`:162-163`) |
| `Process_exit` | `Int -> Task Never ()` (`Eco/Process.elm:49`) | **TB-EAGER (exempt)** | — | no | Hard-Infeasible | `::exit()` at call time, `Process.cpp:227-234`; exemption (b). **The only Task-typed symbol that fires its effect at construction.** |
| `Process_spawn` | `String -> List String -> Task e Int` | TB | `spawnBody` `Process.cpp:44` | no | Feasible / Hard-Infeasible | declared `uint64_t` (`:173`); Windows returns ENOSYS |
| `Process_spawnProcess` | `String -> List String -> String -> String -> String -> Task e ( Maybe Int, Int )` | TB | `spawnProcessBody` `Process.cpp:85` | no | Feasible / Hard-Infeasible | **SHAPE BUG — see Key finding 3** |
| `Process_wait` | `Int -> Task Never Int` | **TB-ASYNC** | `waitBody` `Process.cpp:208` (WaitService) | no | Feasible / Hard-Infeasible | `makeAsyncBinding`; `waitEnsureRegistered()` runs at *call* time (`Process.cpp:266`) |
| `MVar_new` | `Task Never Int` | TB | `mvarNewBody` `MVarExports.cpp:17` | no | Feasible / Hard-Infeasible | slot allocated at fulfilment (F1 purity) |
| `MVar_read` | `Int -> Task Never a` | TB | `readBindingEvaluator` `MVar.cpp:158` (hand-rolled) | no | Feasible / Hard-Infeasible | **already the optimal shape**: id captured directly in the closure, no payload tuple |
| `MVar_take` | `Int -> Task Never a` | TB | `takeBindingEvaluator` `MVar.cpp:185` (hand-rolled) | no | Feasible / Hard-Infeasible | same |
| `MVar_put` | `Int -> a -> Task Never ()` | TB | `putBindingEvaluator` `MVar.cpp:217` (hand-rolled) | no | Feasible / Hard-Infeasible | 2 direct captures, no payload tuple |
| `MVar_put_Int` | `Int -> Int -> Task Never ()` | TB (+eager box) | `putBindingEvaluator` | no | box is **Already-intrinsic** (`eco.box`) | `allocInt` at call time (`MVarExports.cpp:49`) — allocation, not IO |
| `MVar_put_Float` | `Int -> Float -> Task Never ()` | TB (+eager box) | `putBindingEvaluator` | no | Already-intrinsic (`eco.box`) | `MVarExports.cpp:54` |
| `MVar_put_Char` | `Int -> Char -> Task Never ()` | TB (+eager box) | `putBindingEvaluator` | no | Already-intrinsic (`eco.box`) | `MVarExports.cpp:59` |
| `MVar_drop` | `Int -> Task Never ()` | TB | `dropBody` `MVar.cpp:309` | no | Feasible / Hard-Infeasible | payload `tuple2(int, unit)` |
| `Runtime_dirname` | `Task Never String` | TB | `dirnameBody` `Runtime.cpp:32` | no | Feasible / Hard-Infeasible | header claims raw `String` (`:218-219`) |
| `Runtime_random` | `Task Never Float` | TB | `randomBody` `Runtime.cpp:40` | no | Feasible / Hard-Infeasible | declared `uint64_t` (`:222`); fresh sample per fulfilment |
| `Runtime_saveState` | `Value -> Task Never ()` | TB | `saveStateBody` `Runtime.cpp:49` | no | **RT-adjacent** / Hard-Infeasible | writes `s_savedState` C++ static |
| `Runtime_loadState` | `Task Never Value` | TB | `loadStateBody` `Runtime.cpp:55` | no | RT-adjacent / Hard-Infeasible | reads `s_savedState`; returns `nothing()` when unset |
| `MVar_register_gc_roots` | not Elm-callable | **RT** | — | no | Hard-Infeasible | `MVar.cpp:343` — installs external root scanner |
| `Runtime_register_gc_roots` | not Elm-callable | **RT** | — | no | Hard-Infeasible | `Runtime.cpp:84` |
| `register_all_gc_roots` | not Elm-callable | **RT** | — | no | Hard-Infeasible | `RuntimeExports.cpp:46-51`; also calls weak `Eco_Kernel_Order_register_gc_roots` |
| `NativeDriver_lowerAndLink` | `String -> String -> String -> Task String ()` | TB | `lowerAndLinkBody` `NativeDriver.cpp:39` | no | Feasible / Hard-Infeasible | payload `tuple3`; body still blocks the scheduler thread |
| `NativeDriver_lowerAndLinkBytes` | `Bytes -> String -> Task String ()` | TB | `lowerAndLinkBytesBody` `NativeDriver.cpp:62` | no | Feasible / Hard-Infeasible | payload `tuple2` |
| `Http_fetch` | `String -> String -> List (String,String) -> Task Never (Result (Int,String) String)` | **TB-ASYNC** | `fetchBody` `Http.cpp:354` (HttpService) | no | Feasible / Hard-Infeasible | `ensureRegistered()` inside the body (`:367`) |
| `Http_getArchive` | `String -> Task Never (Result String (String, List (String,String)))` | **TB-ASYNC** | `getArchiveBody` `Http.cpp:390` (HttpService) | no | Feasible / Hard-Infeasible | libzip+SHA1 post-process runs on the main thread in `ecoHttpDrain` (`:150`) |

**HOF note.** *No* symbol in this tree invokes an Elm closure at kernel-call
time. Every Elm-closure invocation happens later, in one of exactly four
places: the two generic trampolines
(`TaskBinding.hpp:113`, `:135`), the MVar hand-rolled evaluators + `wakeWaiter`
(`MVar.cpp:81,174,204,236`), `waitServiceDrain` (`Process.cpp:188`), and
`ecoHttpDrain` (`Http.cpp:323`). This is the *only* HOF surface, and it is 5
call sites, not 47.

## Part 2 — can the Task-builder half move out of C++?

### What `makeBinding<Body>(payload)` actually allocates

`runtime/src/platform/TaskBinding.hpp:144-162`, three fixed-shape heap objects:

1. **payload aggregate** — `tuple2` / `tuple3` / `record` of the decoded args
   (skipped when arity is 1-boxed or 0; `unit()` is an embedded constant).
2. **closure** — `alloc::allocClosureK(&bindingTrampoline<Body>, max_values=2,
   PK_Boxed)` then one `closureCapture(payload, boxed)`. Slot 1 is left for the
   scheduler's resume closure.
3. **Task node** — `Scheduler::taskBinding(cb)` →
   `allocTask(Task_Binding, nil, cb, nil, nil)` (`Scheduler.cpp`), a fixed
   4-HPointer-field `Tag_Task` (`Heap.hpp`).

Nothing is data-dependent. There is no branching, no size computation, no
type dispatch — it is a literal 3-object constructor.

### Emittability in the `eco` dialect

| Piece | Existing op | Verdict |
|---|---|---|
| payload `tuple2`/`tuple3`/`record` | `eco.construct.tuple2/3`, `eco.construct.record` (`Ops.td:697,727,804`) | **Already-intrinsic** — and *deletable*: if the compiler emits captures directly, the payload object disappears entirely |
| closure over the body fn | `eco.papCreate` (`Ops.td:1169`) — takes `FlatSymbolRefAttr $function`, variadic captures, `arity`, `num_captured`, `unboxed_bitmap`, `_result_kind` | **Feasible** — this is an exact shape match. Blocker: the trampolines are `template<Body>` instantiations with inline linkage and the bodies are anonymous-namespace statics, so there is no stable symbol to name. Fix is mechanical: export one `extern "C" void* Eco_KernelBody_<Module>_<name>(void* args[])` per body. |
| `Tag_Task{ctor=Task_Binding}` node | **none** — the dialect has no Task op at all (`grep -i task Ops.td` = 0 hits); `eco.allocate_ctor` builds `Tag_Custom`, not `Tag_Task` | **Feasible, small addition** — one new `eco.construct.task` op (ctor + 4 fields), or teach `eco.allocate` the `Tag_Task` type symbol |

So the pattern *"inline-allocate a binding node capturing N args + one
genuinely-effectful C++ body"* is implementable behind **one new dialect op and
a naming convention for exported body symbols**.

### Coverage quantification

- **47 of 53** header symbols (89%) are exactly this pattern:
  File 23 + Console 3 + Env 2 + Process 3 (`spawn`, `spawnProcess`, `wait`) +
  MVar 8 + Runtime 4 + NativeDriver 2 + Http 2 = 47.
  (The three `MVar_put_*` variants need one extra `eco.box`, already an
  intrinsic, so they fold in.)
- **6 not covered**: `Console_log` (E), `Crash_crash` + `Process_exit` (X),
  and the 3 `register_gc_roots` (RT).
- **15 payload allocations vanish** if captures go straight into the closure:
  `File_{writeString, writeBytes, open, close, size, hWriteString, createDir}` (7),
  `Console_write` (1), `Process_{spawn, spawnProcess, wait}` (3),
  `MVar_drop` (1), `NativeDriver_{lowerAndLink, lowerAndLinkBytes}` (2),
  `Http_fetch` (1). That is one heap object saved per Task construction on
  those 15, i.e. 3 objects → 2. `MVar_{read,take,put}` already do this
  (`MVar.cpp:264-304` capture the id/value directly) and are the reference
  shape.
- Every kernel `Task` construction also currently costs one **C-call across the
  JIT boundary with a statepoint + GC-root marshalling** (`StackRootGuard` on
  every decoded arg). Inlining removes the call *and* the marshalling; the
  remaining C++ symbol is entered only when the scheduler steps the binding.

### MVar fast paths — reported separately, as requested

**There are no MVar fast paths any more.** `MVar.cpp:256-262` states it
explicitly: since `plans/task-purity-and-caf-guard-removal.md` F1,
`read`/`take`/`put` are **pure binding constructors** — no slot inspection, not
even the not-found check, happens at call time. The synchronous short-circuit
still exists but has moved *inside* the evaluators:
`readBindingEvaluator` `MVar.cpp:169-174` (slot full → `taskSucceed(v)` +
`callClosure1` inline), `takeBindingEvaluator` `:196-205`, `putBindingEvaluator`
`:230-237`. The blocking arms register a pending resume and push onto
`readers`/`takers`/`putters` (`:176-178`, `:207-209`, `:239-241`).
`invariants.csv:590` confirms exemption (d) is **DELETED**.

### GC-root registration — reported separately, as requested

Three `void`-returning, non-Elm-callable hooks, called once per Elm thread
after `Allocator::initThread()`:

- `Eco_Kernel_MVar_register_gc_roots` → `MVar::registerGcRootScanner`
  (`MVar.cpp:343-365`): installs an `addExternalRootScanner` lambda that
  evacuates each full slot's `value` and every parked putter's `pendingValue`.
  Reader/taker waiters hold only a token — their resume closures are rooted by
  the scheduler's `pendingResumes_`.
- `Eco_Kernel_Runtime_register_gc_roots` → `Runtime::registerGcRootScanner`
  (`Runtime.cpp:84-92`): evacuates the single `s_savedState` REPL slot.
- `Eco_Kernel_register_all_gc_roots` (`RuntimeExports.cpp:46-51`): aggregator;
  also calls the *weak* `Eco_Kernel_Order_register_gc_roots` (defined in
  `elm-kernel-cpp/Utils`, `/alternatename` stub on Windows) if linked.

All three are **Hard-Infeasible** to move: they install C++ lambdas into the
runtime `RootSet`, which has no Elm/MLIR-level representation, and they must
run before any Elm code exists.

## Key findings

1. **The hypothesis holds: 47/53 (89%) of this kernel surface performs no IO at
   call time.** Only 6 symbols are call-time effectful, all of them named
   exemptions in `KERNEL_TASK_IO_001`. The Phase 1–7 deferral migration
   (File/Console/Env/Process/MVar/Http/NativeDriver/Runtime) is complete.

2. **Zero undocumented `KERNEL_TASK_IO_001` violations.** The one Task-typed
   symbol that fires eagerly is `Eco_Kernel_Process_exit`
   (`Process.cpp:227-234`), the documented exemption (b). It is nonetheless a
   real semantic hazard: the Elm wrapper types it `ExitCode -> Task Never ()`
   (`Eco/Process.elm:49-51`), so *constructing* the value terminates the
   process. `List.map Eco.Process.exit codes` or storing it in a list would
   exit at build time, not at run time. Nothing in the type says so.

3. **`Eco_Kernel_Process_spawnProcess` returns the wrong heap shape AND the
   wrong field order — likely a live bug.** `Process.cpp:148-161` builds a
   `Tag_Record` with `fields[0] = pid` (unboxed Int, mask `0b01`) and
   `fields[1] = Maybe stdinHandle`. The Elm wrapper destructures a **Tuple2**:
   `\( stdinHandle, processHandle ) ->` (`Eco/Process.elm:84`), so the
   monomorphized kernel result type is `Task e ( Maybe Int, Int )`.
   `Record` is `Header | u64 unboxed | values[]` (`Heap.hpp:522-526`) while
   `Tuple2` is `Header | a | b` (`Heap.hpp:464-468`) — `Tuple2.a` sits at offset
   8, which in the Record is the **`unboxed` bitmap word (value 1)**, read as
   `Maybe Int`. The field order is also swapped relative to both the Elm
   pattern and the JS reference kernel, which returns
   `__Utils_Tuple2(stdinHandle, child.pid)` (`Eco/Kernel/Process.js:60`).
   Reachable via `System.Process.withCreateProcess`
   (`compiler/src/System/Process.elm:92`), used only by `eco test`
   (`Terminal/Test.elm:346`) and `eco repl` (`Terminal/Repl.elm:741`) — which is
   probably why it has not been caught.

4. **`Eco.File.lock` / `unlock` are silent no-op stubs.** `File.cpp:431-432`
   return `succeedUnit()` unconditionally. `Utils.Main.withFileLock
   LockExclusive` (`compiler/src/Utils/Main.elm:865-883`) therefore provides no
   mutual exclusion at all in the native backend — relevant given the known
   concurrent-`~/.eco`-cache corruption class.

5. **`Console.write` silently discards output for any handle other than 1 or 2**
   (`Console.cpp:66-74`). `Eco/Process.elm:64-65` documents that the
   `spawnProcess` stdin handle "can be used with Console.write" — it cannot;
   the data is dropped with a `Task.succeed ()`. (`File.hWriteString` does write
   to an arbitrary fd, so that is the working path.) Second latent bug in the
   `spawnProcess` pipe feature, alongside finding 3.

6. **22 header comments in `KernelExports.h` still describe pre-deferral eager
   semantics.** They claim raw values where the symbol returns a Task:
   `File_{size:79, fileExists:88, dirExists:91, findExecutable:94, list:97,
   modificationTime:100, getCwd:103, canonicalize:109, appDataDir:112}`,
   `Console_{readLine:145, readAll:148}`, `Env_{lookup:159, rawArgs:162}`,
   `Process_{spawn:172, spawnProcess:176, wait:181}`,
   `MVar_{new:188, read:194, take:197}`,
   `Runtime_{dirname:218, random:221, loadState:227}`.
   `MVar_new` self-contradicts within two lines (`:188` "Returns Int (MVar id,
   unboxed)" vs `:189` "Returns a Task that succeeds with…").

7. **5 symbols are declared `uint64_t` but return an encoded HPointer (a Task):**
   `File_size:80`, `File_modificationTime:101`, `Process_spawn:173`,
   `Process_wait:182`, `Runtime_random:222`. ABI-benign (`HPtr` is a
   `struct{u64}`, `Heap.hpp:228-235`, so both are INTEGER-class in one
   register on every supported target) but the declarations are a type-lie that
   would break if `HPtr` ever gained a member. Mirror-image lie in the argument
   position: `File_{close,size}(HPtr handle)`, `File_open(…, HPtr mode)`,
   `File_hWriteString(HPtr handle, …)`, `Console_write(HPtr handle, …)` all
   receive raw i64 (acknowledged in `File.cpp:631-633`). The *actual* ABI is
   derived from the monomorphized Elm type via
   `monoTypeToAbi` (`compiler/src/Compiler/Generate/MLIR/Types.elm:158-175`,
   Task → `!eco.value`), so codegen is correct; only the header is wrong.

8. **`design_docs/theory/kernel-task-deferral.md` is stale on its own exemption
   list.** Lines 97-99 still list "**MVar partial-eager fast paths** —
   `MVar::read/take/put` short-circuit synchronously" as an exemption. That
   exemption was **deleted** (`invariants.csv:590`, `MVar.cpp:256-262`); the
   three are now pure binding constructors. Line 90-91 likewise still lists
   `spawn`/`kill` as exempt pure Task constructors, which `invariants.csv:590`
   explicitly contradicts ("NOT spawn/kill which are bindings since
   2026-07-23"). The doc should be regenerated from the invariant.

9. **The Task-builder half is a fixed-shape 3-object allocation with no data
   dependence** (`TaskBinding.hpp:144-162`): payload aggregate → 2-slot closure
   over the body pointer → `Tag_Task{Task_Binding}`. Nothing about it needs to
   be C++.

10. **`eco.papCreate` (`Ops.td:1169-1221`) is already an exact structural match
    for the closure half** — `FlatSymbolRefAttr $function`, variadic captures,
    `arity`, `num_captured`, `unboxed_bitmap`, `_result_kind`. The only blocker
    is symbol naming: the bodies are anonymous-namespace statics and the
    trampolines are `template<BindingBody Body>` instantiations
    (`TaskBinding.hpp:99`), so no stable name exists to put in the attribute.
    Exporting one `extern "C"` trampoline per body is mechanical.

11. **The one genuinely missing piece is a Task op.** The `eco` dialect has no
    Task construct/project op whatsoever — Tasks are opaque `!eco.value`
    produced by kernel calls. `eco.allocate_ctor` builds `Tag_Custom`, not
    `Tag_Task`. One new `eco.construct.task` op (ctor + 4 HPointer fields,
    mirroring `allocTask`) closes the gap.

12. **Inlining would delete 15 payload aggregate allocations outright** (listed
    in Part 2 above) by capturing args directly in the closure instead of
    packing them into a `tuple2`/`tuple3`/`record` first. `MVar_{read,take,put}`
    (`MVar.cpp:264-304`) already use direct captures and are the template.
    Every kernel Task construction also currently pays a cross-boundary C call
    plus a statepoint and per-arg `StackRootGuard` marshalling that inlining
    removes.

13. **`Eco_Kernel_Crash_crash` duplicates an existing intrinsic.** `eco.crash`
    (`Ops.td:478-494`) already lowers to `eco_crash(msg)` + `unreachable`
    (`EcoToLLVMErrorDebug.cpp:144-162`). The kernel symbol adds only a
    `Backtrace (%d frames)` dump (`Crash.cpp:24-28`). Verdict:
    Already-intrinsic; consider folding the backtrace into `eco_crash` and
    dropping the kernel export.

14. **Async-source registration is placed inconsistently.**
    `Process::wait` calls `waitEnsureRegistered()` at *kernel-call* time
    (`Process.cpp:266`) — a scheduler-state mutation during Task construction —
    whereas `Http` calls `ensureRegistered()` inside the *body*
    (`Http.cpp:367`, `:393`). Both are `std::call_once`-idempotent and neither
    is a syscall, so neither breaks the invariant, but `wait` is the odd one
    out and would need moving into `waitBody` for the compiler-emitted
    binding-allocation scheme to work (there would be no call-time C++ hook
    left to run it in).

15. **Possible reentrancy hazard in `takeBindingEvaluator` (unverified).**
    `MVar.cpp:198-201` resets the slot and then passes `it->second` (a reference
    into `s_mvars`) to `processTakeDeparture`, which calls `wakeWaiter` →
    `callClosure1` → arbitrary Elm code. `std::unordered_map` keeps element
    *references* valid across rehash, so `MVar.new` re-entering is safe; but
    `dropBody` (`MVar.cpp:332`) does `s_mvars.erase(it)`, which would invalidate
    the held reference. Whether a resumed fiber can synchronously reach a `drop`
    fulfilment inside `callClosure1` was not established — flagged for
    follow-up, not asserted as a bug.
