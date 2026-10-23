# Native Drivers

A lowered module is run, split, linked or embedded by a small set of drivers that sit on top of the one shared backend routine. The just-in-time (JIT) driver loads the module into the running process, which is how the tests and the developer tools execute programs. The ahead-of-time (AOT) driver, for an optimized build, cuts the module into partitions while it is still in MLIR, compiles each partition on its own thread through the shared routine, and links the objects with the bundled runtime into a binary that needs nothing installed on the host. The output kind follows the file name asked for: an object file, a static executable, or a shared library or Node addon that exposes the program to a C or Node host through a small embedding interface. The drivers choose what kind of code they want and what to do with it afterward; how heap pointers are tracked and how code is optimized is decided once, in the shared routine and the passes before it.

## Thin drivers over one routine

The parent document gives the reason all tools compile through one routine: separate copies of statepoint rewriting, target setup and frame-pointer handling drift apart, and programs then behave differently depending on which tool built them. The drivers are shaped by that rule. Each one fills in a job description, chooses one of three kinds of result (a printed module, an object file, or code handed to the JIT), and then runs, links or wraps the result. The choice of how many partitions to use is part of the shared routine too, so every driver splits the same way.

The split is the one step a driver takes before the shared routine rather than after it. The AOT driver partitions the module in MLIR and then runs the routine once per partition. Each partition must carry every fact that needs the whole program, because the thread compiling it never sees the other partitions.

## The drivers and what each is for

The four drivers differ in who calls them and what they do with the finished code.

- The product compiler calls the AOT driver as a library. The compiler is written in Elm and compiles itself, so for `eco make` to produce a native binary without spawning a second tool, the compiled compiler has to reach the lowering directly. It does so through a small C interface inside the one `eco` process, passing the module as a temporary MLIR bytecode file. Binaries that do not carry the backend get weak stand-ins for that interface that report failure, so every AOT binary links whether or not it contains the driver.
- The bootstrap compiler is a command-line program built on the same library. It can start from Elm source by way of the JavaScript-hosted front end, or start from an object file and only relink.
- The developer tool prints the module after any stage of the lowering, or runs it in the JIT. It can stop after the eco-level or the structured-control-flow layer of the pass list, as [lowering-passes.md](lowering-passes.md) describes.
- The test harness runs MLIR in the JIT inside the test process, so thousands of end-to-end tests pay nothing for starting a process or linking.

For AOT output, the kind of result follows the file extension. An object file stops after emission. A shared library or Node addon links the embedding entry. Any other name links a standalone executable with the entry stub. All of them share everything up to emission and differ only in the entry object and the link, so the build command's choice of output by extension needs no further options.

## Splitting the module before LLVM sees it

The largest module the backend compiles is the self-hosted compiler, and lowering it as one module is dominated by steps that LLVM performs serially over the whole module: translation, whole-program passes and a bitcode round trip. An MLIR context can be shared between threads and an LLVM context cannot. Splitting the final LLVM-dialect module in MLIR therefore lets each worker translate its own partition into a private LLVM context, with no serialized copy of the whole module passed between threads. An optimized executable is split this way, as is an object file whose exported symbols the caller names. A development build with optimization off is not split.

The splitter gives every symbol exactly one role in each partition. A defined function is owned by one partition and emitted there. Elsewhere it appears either as a declaration or, for the small capacity-checking helpers, as a body copied in so that LLVM may inline it but must not emit it. Those roles are what keep the partitions independent:

```text
buildPartitions(module, N):
  g = symgraph::build(module)            # symbol edges: calls, address-of
  cost[f] = op count of each defined function
  owner: functions by cost desc (then name), each to the least-loaded partition (LPT)
  each defined global goes to the owner of its first referrer, else partition 0
  for each partition p, each symbol's role is one of:
    1 owned        cloned with its body
    2 import copy  a `$cap` body owned elsewhere, reached by calls (only at -O>0);
                   cloned as available_externally so it can be inlined
    3 declaration  anything an owned or imported body names; cloned without a body
  exports[p] = owned functions that another partition declares or imports
  module flags are cloned into every partition; other non-symbol ops go to partition 0
  error if any declaration or copy lacks its owner's eco-cap-* facts
```

From `runtime/src/codegen/EcoSplit.cpp` (`buildPartitions`).

Notice that balancing uses only operation counts, that a global follows the first function that refers to it, and that only the capacity helpers are copied across partitions. A missing capacity fact on a copy stops the build; it is never treated as a lost optimization. The symbol graph is the same one the planning passes use, so the splitter and the planners agree on who calls whom.

Each worker thread translates its partition and runs the shared routine in partition-worker mode, which marks the job as already split so the routine never splits it again. Every partition is optimized at full strength. Losing inlining across partition boundaries measures within noise on the compiler's own run time, so the design has no machinery for replicating functions across partitions or for cross-module optimization.

When the requested output is a single object file and the module was split, the partition objects are joined into one by a relocatable link. Windows linkers have no relocatable link, so object output there is not split, while executables are. LLVM's own module splitter, working on the translated module, is used only for configurations the MLIR split cannot serve, such as statepoint rewriting placed after the optimizer or an MLIR context without threads. There LLVM's splitter is used as it comes: refining it with size balancing or call-graph clustering would help only if one partition finished well after the others, and measurements show that none does. Serializing the whole translated module and re-reading it lazily in each worker is not used at all: it costs exactly the serial round trip that splitting in MLIR avoids.

## Whole-program facts travel with each partition

Every fact that needs the whole program is decided before the split and carried into each partition as an attribute or a module flag. The lowering pipeline's last passes decide which functions are reachable, where nursery capacity checks are hoisted into callers, and which functions can never collect; the compiler itself folds constant thunks. Deciding such a fact after the split, on the LLVM side, would need each worker to read the other partitions' bodies, and the partitions would stop being independent.

The facts are checked at both ends of the hand-off. The splitter copies the module flags into every partition and declares each cross-partition symbol with all of its owner's attributes, and stops with an error when a declaration or a copy lacks the owner's capacity stamps. Inside each partition, the shared routine checks every function locally against its stamps, refuses a capacity stamp that arrives without the plan's module flag, refuses to work out a capacity plan of its own on a partition, and strips the flags once it has used them. A copied helper body that reaches statepoint rewriting is also an error. These checks are hard failures because a silently wrong stack map or capacity plan is a garbage collection safety bug, not a slow program.

## The link

The parent document explains why the link uses nothing from the host: users must be able to unpack a bundle and run `eco make` with no toolchain installed. The link step implements that with one link profile per output kind. Every input in the bundle's profiles is an absolute path into the bundle's runtime directory, worked out when the compiler runs, and the linker is the bundled `ld.lld`. Paths recorded when the compiler is configured would point at the machine that built it. Development builds use profiles that link with the host toolchain instead.

On Linux, executables link statically against musl. Shared libraries and Node addons cannot, because a static musl object cannot be loaded into a Node process built on glibc. They link against a second set of position-independent archives, built for the glibc interface and shipped in the same bundle, with a static libc++ whose symbols are hidden so it cannot clash with the libstdc++ that Node loads. So each output kind has one link mode that works: a dynamic executable is the hardest case to make work everywhere and is not the product, and a fully static shared library is a contradiction. There is no option to choose the mode.

The memory copy and fill functions come from LLVM's C library and are placed ahead of musl on the link line, because musl's versions are a measurable cost on small copies. All five are replaced together, because musl's move routine jumps into its own copy routine.

On macOS the link goes through the compiler driver that `xcrun` locates when the link runs. Tool paths recorded at configure time would point into the build server's Xcode and fail on other Macs. The oldest supported macOS version is pinned, so it does not drift with whatever machine built the compiler.

The link must keep the stack map section, since the collector reads it from the running image to find roots. Removing unused sections at link time is therefore opt-in, and it comes with an explicit rule that keeps the stack maps.

## Entry points

Each output kind has its own entry code, chosen by the link, and that entry code is the only part of the program that differs between them.

An executable's entry stub supplies the C `main`. It finds the stack map section in the running image so the collector can locate roots, calls the program's compiled main, and exits. The compiled main returns the value of Elm's `main`, not a status: for a program whose `main` is Unit, that value is the embedded constant for Unit, which is not zero. The stub therefore exits with the code the program set through the runtime, which is zero unless the program asked for another.

A shared library exposes a C interface instead of `main`: start, stop and wait for an application, send a message to a port, subscribe to a port's output, and register a hook that reports when the program goes idle. All Elm code runs on one dedicated thread, the eco thread. Host threads only queue bytes and wake that thread's loop. This keeps the heap with its single mutator, so calling Elm or touching the heap from a host thread is never allowed.

The Node addon wraps that C interface as a native Node module that looks like the JavaScript target's output: the host calls `init` on the program's root module, and messages cross the boundary as JSON strings. Its liveness follows the same rule as the JavaScript target. An idle program must not keep Node's event loop alive, but a program with pending work must, so the addon holds a reference on Node's loop only while the idle hook reports that the scheduler is busy. The scheduler reports busy while the program holds a counted claim, a hold, on something it asked for ([scheduler-and-services.md](../runtime/scheduler-and-services.md)).

## The JIT

The JIT compiles a module in memory, from the same shared routine, and runs it in the calling process. The collector finds roots through stack maps and by unwinding the stack, so JIT code must be visible to both. The JIT pulls the stack map section out of each object it loads. It registers each object's unwind tables as a whole section, because the LLVM unwinder that the collector uses takes a section at a time rather than single frame descriptions. On Apple's ARM machines it also undoes an address shift that LLVM's dynamic loader applies to those descriptions. Without these steps the collector misses roots in JIT frames, and deeply recursive programs corrupt their heap.

AOT binaries get the runtime and the kernels by linking their archives. The JIT has no link, so it registers every runtime symbol by name in a table. A symbol missing from that table shows up only when the JIT tests run.

## Changing the drivers

A change fits when the drivers stay thin, every whole-program fact is settled before the split, and Elm code stays on its one thread.

### Examples of changes that fit the theory
- A whole-program analysis is computed in MLIR or in the compiler, carried as an attribute or module flag, checked by the splitter when it crosses a partition boundary, and checked again locally by each worker. Reachability, the leaf stamps and the capacity plan all work like this.
- An output kind or platform becomes a link profile or a per-platform link function in the link step, plus an extension in the output choice. The macOS and Windows links and the glibc profile for libraries have this shape.
- A host-facing capability, such as a flag, a hook or another kind of port, extends the embedding C interface, keeps Elm on the eco thread, and lets the Node addon wrap it.
- An optimization tier or setting becomes an option on the job description that the shared routine honors, so every driver gets it at once.
- A kernel that must keep the program alive takes a hold through the scheduler's interface rather than adjusting a counter directly, so the idle hook stays truthful for embedded and Node hosts.
- A runtime function the compiled code calls is added to the JIT's symbol table at the same time as to the archives, so the JIT tests can run it.

### Examples of changes that would break the theory
- Re-implementing statepoint rewriting, internalization or the partition count inside one driver. The copies drift; route the change through the shared routine.
- Computing a whole-program fact after the split, or letting one partition read another's bodies. It destroys the independence the split depends on; decide the fact in MLIR and stamp it.
- Downgrading a missing or inconsistent stamp at a partition boundary to a warning. A wrong plan or leaf stamp is a collector safety bug; fix the producer.
- Recording toolchain paths at configure time in a shipped bundle, or adding a dependency on a host library to a bundle profile. The bundle then works only on the build machine; resolve the path when the compiler runs and ship the input.
- Calling Elm or touching the heap from a host thread in the embedding layer. The heap has one mutator and no write barrier; queue bytes and wake the loop.
- Making the executable link dynamic, or adding an option whose only legal value is its default. Each output kind has one correct link mode.
- Treating the value the compiled main returns as an exit status. It is an Elm value; use the exit code the runtime holds.

## References

Parent: [backend.md](backend.md). Siblings: [eco-dialect.md](eco-dialect.md), [lowering-passes.md](lowering-passes.md).

Code:

- `runtime/src/codegen/EcoBackend.h`, `runtime/src/codegen/EcoBackend.cpp`: `runEcoBackend`, `EcoBackendJob`, `BackendKind`, `PartitionWorkerInfo`, `choosePartitionCount`, `rs4gcAfterOpt`. `EcoBackend.cpp.orig` is a stale backup, not part of the design.
- `runtime/src/codegen/EcoNativeDriver.h`, `runtime/src/codegen/EcoNativeDriver.cpp`: the AOT pipeline, output choice by extension, `linkExecutable` and its link profiles, `gcSections`. Header comments that mention a `clang++` link driver and Linux-only output are out of date.
- `runtime/src/codegen/EcoNativeAPI.h`, `runtime/src/codegen/eco_native_stub.cpp`: the C interface the compiler calls, and its weak stand-ins.
- `runtime/src/codegen/EcoSplit.h`, `runtime/src/codegen/EcoSplit.cpp`: `buildPartitions`, `lowerMlirSplit`.
- `runtime/src/codegen/EcoBootConfig.cpp`: bundle path resolution when the compiler runs.
- `runtime/src/codegen/eco-boot.cpp`, `runtime/src/codegen/ecoc.cpp`: the bootstrap compiler and the developer tool.
- `runtime/src/codegen/eco_entry.cpp`: the executable entry stub and `eco_get_exit_code`.
- `runtime/src/embed/eco_embed.h`, `runtime/src/embed/eco_embed.cpp`, `runtime/src/embed/eco_node_addon.cpp`: the embedding C interface and the Node addon.
- `runtime/src/jit/EcoJIT.cpp`, `runtime/src/codegen/EcoRunner.cpp`, `runtime/src/codegen/RuntimeSymbols.cpp`: the JIT, the test harness and the runtime symbol table.
- `runtime/src/codegen/SpikeCensus.cpp`: a diagnostic that runs only when its environment switch is set.

Invariants (`design_docs/invariants.csv`):

- CGEN_074, CGEN_081 to CGEN_083: capacity hoisting, closed-world reachability and the MLIR split.
- HEAP_010: the Unit constant returned by the compiled main.
- PORT_001 to PORT_007: ports and embedding, with PORT_006 for the single eco thread.
- LIVE_001 to LIVE_006: program liveness and the idle hook.

Design documents: `design_docs/mlir-level-partitioning-whole-program-steps.md`, `design_docs/lld-in-eco.md`, `design_docs/distribution.md`.
