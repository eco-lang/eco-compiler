# Kernels

Elm's built-in functions and Eco's own IO libraries reach native code as kernels: functions the compiler treats as having no Elm body. Elm source refers to one as `Elm.Kernel.<Home>.<name>` or `Eco.Kernel.<Home>.<name>`, and the compiler turns each use into a call to a C function of the same name with underscores, such as `Elm_Kernel_List_cons`, implemented in C++ that reads and builds values on the Eco heap. The compiler alone decides how each kernel is called: the symbol, the type of each argument and result, and which values cross unboxed. The C++ supplies only the behavior, and it obeys three rules the compiler cannot check for it. It touches only Eco heap values and roots them itself, it never lets Elm code observe a mutation, and a kernel that returns a `Task` performs its IO later, when the scheduler runs the task. Three C++ libraries supply the symbols: Elm's own kernels, ported from the JavaScript originals so that unmodified Elm packages run; the compiler's private IO layer, `eco/kernel`; and the public system library for programs, `eco/system`.

## The compiler owns the call

A kernel call joins two type systems that cannot see each other. Elm's type checker stops at the kernel reference, and C++'s starts at the function definition, so nothing checks the join unless one side owns it. Eco gives it to the compiler. A mismatch between what the generated code passes and what the C++ expects is then a compiler bug in one place, and it can be fixed there.

The link from Elm to C++ is the name and nothing else. A module counts as a kernel module when its name starts with `Elm.Kernel.` or `Eco.Kernel.` and it belongs to a package whose author is `elm`, `elm-explorations` or `eco`. The front end records a reference to a kernel as a prefix, a home module and a function name, and code generation joins them into the symbol `<prefix>_Kernel_<home>_<name>`. The C++ has only that symbol to match, so renaming either side breaks the link.

The Elm side of a kernel is thin. An ordinary Elm function wraps the kernel reference and gives it a public type; elm/core's `String.fromNumber`, for example, is defined as `Elm.Kernel.String.fromNumber`. Beside the wrappers sits one JavaScript file per kernel home, whose header lists the Elm modules that kernel imports. The native path ignores the JavaScript body but still reads the header to learn those imports, so the file must exist and parse. On the JavaScript target the same body is the implementation, which lets one Elm wrapper serve both targets.

The compiler writes one declaration into the emitted MLIR for each distinct kernel symbol a program uses, marked as a kernel and carrying explicit argument and result types. Every call to that symbol must match its declaration. The lowering to LLVM reads the declaration and infers nothing from the calls. A back end that rebuilt kernel parameter types by looking at how each kernel is used would hold a second derivation of the calling convention, and the two could drift apart with no error at either end.

On the C++ side each library declares its symbols with C linkage in one export header and implements them in export files, with the real logic in plain C++ beside them. Each kernel module builds as its own static library. The ahead-of-time driver hands every one of them to the linker as an ordinary archive, so a program takes in only the object files whose symbols it references; only the library holding the `Order` singletons is linked in whole, because nothing references it directly. The just-in-time runner builds a symbol table that takes the address of every Elm kernel export, so its own binary contains all of them.

## Numbers cross unboxed

The types in a kernel declaration come from the concrete types at the call site, which monomorphization has already made concrete. Int, Float and Char always cross as machine values: a 64-bit integer, a double and a 16-bit integer. Everything else, Bool included, crosses as a boxed heap value, an opaque 64-bit pointer, which is the ABI form of the representation models in [value-representation.md](../value-representation.md).

C++ code cannot be polymorphic over unboxed values, so a kernel that Elm declares generic over `number` or `comparable` has to commit to one form. Boxing every argument would force a small heap allocation for each number passed to a kernel. Instead, where a generic kernel is hot for one primitive type, the C++ provides a typed variant whose symbol ends in `_Int`, `_Float` or `_Char`, and the compiler selects it from the call site's argument types. Addition in `Basics` and the comparisons in `Utils` work this way. A coarser policy, boxing every argument of a whole kernel module or boxing all numbers, would bring those allocations back; choosing per use keeps numbers unboxed without a rule for each module.

## What a kernel may do with the heap

Kernels read and build Eco heap values directly, through the runtime's helpers for allocating objects, reading fields and registering roots, and they never do arithmetic on heap pointers. The C++ keeps no private model of Elm values, neither a separate tagged-union value type with reference-counted containers nor C++ objects reached through pointers stored in heap objects. A C++ pointer inside a heap object leaks, because the collector frees the heap object without knowing about the memory behind the pointer, and it ties the lifetime of heap objects to C++ lifetimes. JSON shows the choice most clearly: a parsed JSON value is a real Elm custom type built on the heap, never a C++ document kept alongside it.

The collector is precise and moves objects, and it cannot see C++ local variables. A kernel that holds heap values across an allocation, or across a call back into Elm, therefore registers them as roots before the collector can run. A kernel that builds a long list registers its whole buffer with one record, so the cost of rooting stays the same however long the list grows.

A kernel that receives an Elm function calls it through the runtime's generic apply path, which applies any closure from its header ([closures-and-calls.md](../closures-and-calls.md)). The compiler may compile a closure to take all its arguments at once or one at a time, and the kernel cannot know which, so it uses the one entry point that handles both.

A kernel never gives Elm code an observable mutation. Beyond the collector's dependence on published values never changing ([eco.md](../../../THEORY.md)), a kernel handle onto a mutable store would make Elm code correct only when each handle is used in a strict sequence, a rule the compiler cannot check. Eco has no such store for that reason, even off the heap.

Data crosses the boundary in neutral shapes that need no knowledge of the compiler's layouts. A kernel cannot predict how the compiler lays out the fields of an Elm record or the constructors of a package's custom type. In the compiler's IO layer, fallible operations therefore return a plain tuple of an error tag, a path and a message, and the Elm wrapper builds the typed error from it. `eco/system` applies the same idea to everything that crosses its boundary: only Int, Float, Bool, String, Bytes, lists, Maybes and tuples of those, unit, and closures. A resource such as an open file or socket crosses as a handle id, an Int that indexes a table the C++ side keeps, so no C++ object ever lives inside the heap.

Blocking work runs on service threads, and only the eco thread, the one thread that runs Elm code, touches the heap. Blocking the eco thread would stop every Elm task, and the heap has one mutator whose allocations can move any object, so a pointer held on another thread could go stale at any moment. The kernel copies what the thread needs out of Elm values into plain C++ data on the eco thread, and the eco thread turns the plain result back into heap values.

## Facts in place of a body

To the optimizers a kernel has no body to inspect. There is no link-time optimization between compiled Elm and the C++ kernels, so LLVM sees a kernel call as opaque. The compiler keeps one audited table of facts about each kernel in its place: what effect the call has when it is made, what it allocates, whether it calls back into Elm, how it borrows its arguments, and whether two identical calls may be merged. A kernel with no row is treated as conservatively as possible. Every pass that needs to know whether a kernel is pure or allocates asks this table, so a judgment about a kernel is made once and every pass agrees on it.

A kernel reference in source also carries no type. A second table gives selected kernels real types, so the type checker constrains their uses rather than accepting anything. Each type in it is a claim about representation, so it follows what the C++ does, which can differ from the JavaScript type. In JavaScript `List.fromArray` turns an array into a list, with type `Array a -> List a`. In C++ it returns its argument unchanged, and its one use passes it the list that the string split kernel returns, so its row gives it the type `List a -> List a`. Each row cites the C++ that supports it, and the hashes of the cited files are pinned in a manifest that the build checks, so the build fails when a cited file changes until someone reviews the row against it.

Some small kernels whose behavior is fixed by the type at the call site, such as list cons, string length, append, ordering and equality, are replaced by eco-dialect operations, so that the optimizers can fold them with the code around them. A kernel with a large body keeps it and gets a row in the facts table instead. Calls across the boundary take a small share of a program's running time, in which garbage collection dominates, so this replacement buys the optimizer's visibility into the code more than raw speed.

The list higher-order functions such as `map` and `filter` stay in C++. Their C++ versions build each result list once, while the natural Elm versions build whole intermediate lists again and again, and measurement confirmed the difference.

## Tasks describe IO; the scheduler performs it

A kernel that returns a `Task` does no IO when it is called. It allocates a task binding, a heap object holding a callback, and the scheduler runs that callback when the task is actually executed. In the compiler's IO layer nearly every symbol does nothing at call time except allocate a binding; the few exemptions are listed in an audit with their reasons.

IO at call time breaks the meaning of `Task`. Two tasks built together would run one after the other as they were built, before the program decided to run either of them. A read of something that changes, such as the clock, would always return the value from the moment the task was built. And a blocking call would stall the scheduler, which runs all Elm code on one thread. The binding also roots the values it holds, so they survive until the scheduler runs it.

The deferral rule covers Elm's kernels and the compiler's IO layer. `eco/system` defers its work through its own reactor and worker services, under rules of its own that [system-libraries.md](system-libraries.md) describes.

## Three libraries under two prefixes

The kernels split into three C++ libraries because they serve three audiences with different contracts.

| Library | Symbol prefix | Serves |
|---|---|---|
| Elm's kernels (`elm-kernel-cpp/`) | `Elm_Kernel_` | The published Elm packages: core, json, bytes, parser, regex, time, url, http, file, browser and virtual-dom |
| The compiler's IO layer, `eco/kernel` (`eco-kernel-cpp/`) | `Eco_Kernel_` | The compiler itself: files, console, HTTP downloads, environment, processes, shared variables, hashing, package archives, and the call into the native back end |
| The system library, `eco/system` (`system-kernel-cpp/`) | `Eco_Kernel_` | Eco programs: files, processes, streams, sockets, TLS, an HTTP server, WebSockets and the terminal |

Elm's kernels stand apart because their contract is written by someone else: the behavior of the published `elm/*` packages, which Eco must reproduce exactly. The other two invent their APIs. `eco/kernel` is the compiler's own IO and is not meant for applications. `eco/system` is the public API for programs and does not depend on `eco/kernel`, so the compiler's internal needs never constrain the public library. It also has no HTTP client of its own; programs use elm/http, whose kernel lives with Elm's kernels.

The prefix follows the Elm namespace, not the audience. Both Eco libraries are packages authored by `eco` with modules under `Eco.Kernel.`, so both produce `Eco_Kernel_` symbols, and their home module names keep them apart.

The compiler's IO is a kernel package rather than Elm ports because the compiler needs real IO to build itself, and Elm ports cannot carry `Bytes`, which the compiler uses for file contents and for its shared variables. `eco/kernel` exposes the same `Eco.*` modules as an implementation built on browser-style HTTP requests that runs under stock Elm. The same compiler sources therefore build through stock Elm at the start of the bootstrap and natively once Eco can compile itself.

Elm's kernels have one child document, and the two Eco libraries share the other, because they share a design that Elm's kernels do not.

[elm-kernel.md](elm-kernel.md) covers Elm's kernels, the native replacement for the JavaScript files behind the stock Elm packages. Each kernel function is a C-linkage symbol that reads and builds values directly on the Eco heap, so the unmodified packages run on top of it. Every kernel is a contract that Elm's type system cannot see, covering rooting, representation and which closures it may call. The claims the compiler relies on about which closures a kernel may call, and the real types it gives kernels, are audited and pinned by hash.

[system-libraries.md](system-libraries.md) covers `eco/kernel` and `eco/system`. Both are Elm packages over C++ kernels for native code and JavaScript kernels for Node, and both expose only neutral values. `eco/system` is derived from the Node library of Gren, a language close to Elm, and covers files, processes, streams, sockets, TLS, WebSockets and an HTTP server on top of a network reactor and worker services. Because these packages invent their APIs, they carry their own rules for threads, rooting, errors and keeping a program alive while work is pending.

## Where kernel changes belong

A kernel change fits when it adds behavior in C++ and leaves the calling convention, the kernel's facts and its type to the compiler's tables, when it keeps IO inside task bindings, and when it passes only neutral values across the boundary. A change that moves one of those decisions somewhere else breaks the theory.

### Examples of changes that fit the theory
- A kernel function takes an Elm wrapper, the JavaScript body for the Node target, the declaration in the library's export header, the implementation and its export, and an entry in the library's CMake module list. The compiler needs no change unless the function needs a typed variant. The completion of elm/core's kernels and the progress reporting behind `Http.track` both have this shape.
- A typed variant for a hot instantiation takes one C++ function with an `_Int`, `_Float` or `_Char` suffix and one branch in the compiler's symbol selection.
- A task-returning IO kernel builds its binding with the shared helpers and does all its IO inside the binding's body. An exemption from deferral goes into the audit with its reason.
- A whole package of kernels, as `eco/system` is, is an `eco`-authored package with its own kernel homes, its own CMake library and the registration of its effect managers. That extends the design along an axis it already has.
- A row in the facts or types table is added or refined after reading the C++, with the evidence it rests on recorded beside it.
- A small kernel whose behavior the call-site type fixes can become a dialect operation when its body is tiny and the operation folds with its neighbors.

### Examples of changes that would break the theory
- A name check in a compiler pass that decides "this kernel is pure" or "this kernel allocates". A second place deciding a kernel's properties will disagree with the facts table. Add or amend a row instead, so every pass sees one answer.
- Giving a kernel its type from its first use. The first use may not match what the C++ does with the value. Add a row to the types table that follows the C++.
- IO, or a call back into Elm, made when a task-returning kernel is called. Tasks lose their ordering and the scheduler can block. Put the work in the binding's body.
- Letting the back end repair a kernel signature, or accepting two signatures for one symbol. The compiler's declaration is the only source of the convention, so fix it there.
- Passing an Elm record or a package's custom type through a kernel, or reading a field by position. The kernel cannot know the compiler's layout, and the code breaks when the layout changes. Return a neutral tuple and decode it in the Elm wrapper.
- Keeping a C++ pointer or C++-owned state inside a heap object to avoid a conversion. The collector frees the object without releasing what the pointer owns. Use a handle id with a C++ table, or build real heap values.
- Registering one root per element in a kernel that builds a list. The rooting cost then grows with the list. Root the buffer once.
- Giving Elm code observable mutation through a kernel handle. Elm code would then depend on a usage rule the compiler cannot check. Build a fresh value instead.
- Adding a package whose kernel home name matches an existing one. The compiler's kernel tables key a kernel by its home name without the `Elm` or `Eco` prefix, so the two homes would silently share facts and types. `Elm.Kernel.File` and `Eco.Kernel.File` already share one row, which covers both bodies. A guard script run by the full test target rejects an `eco/system` home that collides with any other, but nothing checks a home added to another package. Choose a distinct home name, or separate the tables by prefix first.
- Adding a third kernel prefix of a different length. The compiler splits a symbol into its parts by dropping a fixed number of leading characters, which works only because `Elm_Kernel_` and `Eco_Kernel_` are the same length. Change the splitting to parse the prefix before adding one.
- Adding a native-only function to an `eco/system` wrapper without a matching JavaScript kernel. The wrapper then fails on the JavaScript target. Write both kernels.

## References

Parent: [eco.md](../../../THEORY.md). Children: [elm-kernel.md](elm-kernel.md), [system-libraries.md](system-libraries.md). Related: [runtime.md](../runtime/runtime.md) for the scheduler and the collector.

Code and documents:

- `compiler/src/Compiler/Generate/MLIR/KernelAbi.elm`: symbol naming, typed variant selection (`kernelInstanceSymbol`) and the per-use calling convention (`monoTypeToAbi`).
- `compiler/src/Compiler/GlobalOpt/KernelFacts.elm`: the audited facts table; `splitSymbol` relies on equal prefix lengths.
- `compiler/src/Compiler/Type/KernelIntrinsics.elm`, `compiler/src/Compiler/Type/KernelTypes.elm`: kernel types and home-name keying.
- `test/scripts/check-kernel-license-manifest.sh`: the hash manifest for the evidence behind kernel types, checked in the default build. `test/scripts/check-kernel-homes.sh`: rejects `eco/system` kernel homes that collide with others, run by the `full` target.
- `elm-kernel-cpp/src/KernelExports.h`, `elm-kernel-cpp/src/ExportHelpers.hpp`, `elm-kernel-cpp/src/core/ListExports.cpp`: the Elm kernel pattern, heap helpers and the generic closure call.
- `eco-kernel-cpp/src/eco-kernel/KernelExports.h`, `eco-kernel-cpp/src/eco-kernel/File.cpp`, `eco-kernel-cpp/src/eco-kernel/KernelHelpers.hpp`: the deferred-binding pattern.
- `eco-kernel-cpp/src/Eco/IO/Error.elm`: neutral error tuples decoded in Elm.
- `system-kernel-cpp/src/eco-system/Core/`, `system-kernel-cpp/README.md`: shared services for the public library.
- `runtime/src/platform/TaskBinding.hpp`: task bindings.
- `runtime/src/codegen/EcoNativeDriver.cpp`, `CMakeLists.txt`, `elm-kernel-cpp/CMakeLists.txt`: linking the kernel libraries.
- `compiler/src-xhr/Eco/`: the stock-Elm implementation of the `Eco.*` modules.
- `design_docs/kernel-boundary-reduction.md`, `design_docs/kernel-boundary/audit-06-eco-kernel.md`, `design_docs/elm_kernel_functions.csv`.
- Tests: `test/kernel/`, `test/eco-kernel/`, `test/eco-system/`, `test/elm-core/`.

Invariants (`design_docs/invariants.csv`):

- REP_ABI_001: Int, Float and Char cross unboxed.
- CGEN_038, CGEN_057: one declaration per kernel symbol, and every use agrees with it.
- KERN_006: the compiler alone decides kernel calling conventions.
- KERNEL_FACTS_001: conservative treatment of kernels with no facts row.
- KERNEL_TASK_IO_001, KERNEL_TASK_IO_002: task kernels defer their IO and root what they hold.
- IO_ERR_002: neutral error tuples.
- SYS_001: the values that may cross the `eco/system` boundary. SYS_003, SYS_004: only the eco thread touches the heap.
- HEAP_020, FORBID_HEAP_002, FORBID_HEAP_003: kernel rooting and pointer use.
