# Elm's Kernels in C++

Elm's kernel functions are implemented in `elm-kernel-cpp/`, a C++ library that takes the place of the JavaScript files behind the published Elm packages: core, json, bytes, parser, regex, time, url, http and virtual-dom, with file and browser present but mostly asserting, because they need a browser to host them. Each kernel function becomes a C-linkage function, such as `Elm_Kernel_List_cons`, that takes the arguments its JavaScript original takes and returns the same shape of result, so the unmodified Elm packages run on it. The library decides only what each kernel means. The runtime decides how strings, lists and bytes are stored, and the compiler decides how each kernel is called. What is left to the C++ is a set of obligations that no type checker sees: keep every heap pointer it holds registered with the collector while anything can allocate, call Elm functions only through the runtime's generic entry, and do a task's IO only when the scheduler runs the task. Where the compiler relies on a claim about which functions a kernel can call, or on a real type given to a kernel, the files that support the claim are pinned by hash, and the build fails when one of them changes until someone checks the claim again.

## The packages stay stock

The contract a kernel keeps is the one its JavaScript original defines: the same arity, the same argument values and a result of the shape the Elm wrapper expects. The same `Json/Decode.elm`, `Http.elm` and `Html.elm` therefore compile to JavaScript and to native code without a line changed. The packages belong to the Elm project, and forking them for native code would mean Eco-specific packages for every program and two copies of each package that drift apart. Holding the C++ to the JavaScript behavior keeps one set of Elm sources for both targets.

The library is written function by function from the JavaScript kernel sources. A table of the JavaScript kernel surface, `design_docs/elm_kernel_functions.csv`, records what exists to port. It lists the JavaScript functions, including packages Eco has no C++ for, and it leaves out the typed variants and helpers the C++ adds, so the list of what is implemented is the export header, not the table.

Matching JavaScript extends to characters. Elm's JavaScript kernels treat a string as UTF-16, so a Char here is a 16-bit code unit everywhere: converting a number to a Char clamps it to 16 bits, and the parser kernels index strings by UTF-16 unit as JavaScript's `charCodeAt` does. A program then gets the same characters and positions on both targets, including for text outside the 16-bit range.

Functions that need a browser are not implemented. File, the Debugger and most of Browser assert when called. Browser's program constructors (`element`, `document`, `application`) are the exception and return their argument. An assertion is preferred to a quiet result because a function that returned something plausible would make a program that cannot work look as if it does.

## How a kernel module is laid out

Most modules are a pair of files. `List.cpp` holds the logic in plain C++, where there is logic to hold, and `ListExports.cpp` holds the C-linkage functions the compiler calls, each of which converts its arguments, calls the logic or does the work itself, and converts the result. One header, `KernelExports.h`, declares every exported symbol, and one helper header, `ExportHelpers.hpp`, holds the conversions every export uses. The conversions are the same few operations for every kernel, so keeping them in one header keeps the exports thin and makes a wrong conversion a bug in one place.

Each module builds as its own static library, and one module list in the back end's build drives both what is compiled and what the native linker is given. Adding a module is then one entry in that list, and each package's kernels stay a separate unit of the build.

Arguments are not always heap pointers. A non-empty string literal in compiled Elm is allocated once, interned, in a permanent space outside the heap's address range, so a kernel can be passed an address that is not in the heap. The literal `""` is the empty constant, not an interned object. Every export reads its heap arguments through one helper, `Export::toPtr`. It returns null for an embedded constant, follows any forwarding for an address inside the heap, and returns every other address unchanged, which is the case that serves the permanent space. Comments beside it that describe that case as literals in read-only data are stale.

Char arguments are read as 64-bit integers and masked to 16 bits, although the calling convention passes a 16-bit value. Calls from compiled Elm go through the garbage-collection statepoints that LLVM wraps around every call that may collect, and the statepoint drops the attribute that promises the caller has zeroed the upper bits of the register. A parameter declared as 16 bits would let the C++ compiler trust whatever is left in those bits. Reading the whole register and masking it is correct whatever the caller left there.

## The runtime owns representation

A kernel never looks inside a string, a list or a bytes value. The runtime stores a string in several forms, among them flat UTF-16, a rope of pieces and a slice of another string, and it stores a list as cells or as chunks ([runtime-data-structures.md](../runtime/data-structures.md)). Kernels reach all of these through the runtime's string, list and bytes operations and its allocation helpers in `runtime/src/allocator/`. The kernel decides what `String.split` means; the runtime decides how the pieces are stored. A change of representation is then made once, in the runtime, and every kernel keeps working.

Empty values are constants, never heap objects. The empty string, the empty bytes value and constructors with no fields, such as the values of `Order` or the empty node of a dictionary's tree, are constants held in the pointer word itself, which points at no heap object. Equality compares the two words directly when either side is a constant, so a heap-allocated empty string would compare unequal to `""`. [value-representation.md](../value-representation.md) gives their encoding and why each must exist only in that form. A zero-length object also falls below the allocator's minimum object size. Every kernel that can produce an empty result returns the constant, and the runtime's helpers, such as string join and building a constructor with no fields, already do so.

## Values that stay on the heap

A kernel keeps no C++ object inside a heap value ([kernels.md](kernels.md)). Three packages in Elm's kernels show what that rule costs and where its one exception lies.

JSON values are ordinary heap custom types. Their constructor numbers are fixed in a table at the top of `JsonExports.cpp`, and a new JSON case takes the next free number there. A long array is split into chunks that each stay below the large-object threshold, so a decoded array never becomes a large object that holds pointers, which the collector would have to place in its young large-object space ([garbage-collector.md](../runtime/garbage-collector.md)). Code that reads a JSON array goes through the two accessors that hide the split, `jsonArrayLength` and `jsonArrayAt`. Parsing goes through the vendored nlohmann/json library, and the parsed C++ document is thrown away as soon as the heap value is built, so nothing outside the heap has to be freed with it.

Regular expressions are the deliberate exception. A compiled regex lives in a C++ side table, and the Elm value holds only a handle id, the integer index into that table. The table never frees an entry. That matches the JavaScript runtime, which never frees a compiled regex either, so a program sees no difference, and the heap still holds nothing but an integer.

Virtual DOM nodes are ordinary heap custom types. `eco/system`'s HTTP server can answer a request with an elm/html view rendered as HTML text, so the node type is declared in Elm in that library, and the C++ builds nodes in exactly that layout. The layout is written once in `virtual-dom/VirtualDomLayout.hpp`, and an Elm test checks that it matches the declaration. A view is then a plain heap value, not a browser DOM, which is why elm/html links natively at all, and the HTML writer streams that value to text without first building it as a String. [system-libraries.md](system-libraries.md) describes the server.

## Holding pointers while the collector moves things

The collector is precise and moves young objects by copying them. For compiled Elm frames it finds the live pointers from the stack maps LLVM builds, but a local variable in C++ kernel code appears in no stack map. A kernel that holds heap pointers across an allocation, or across a call into Elm (which can allocate), registers them as roots first. Otherwise they point at the old copy after the next collection.

A higher-order kernel shows the whole pattern: copy out what the loop needs, register the values that survive each call, and read them back after every call. `String.foldl`, from `elm-kernel-cpp/src/core/StringExports.cpp`:

```cpp
HPtr Elm_Kernel_String_foldl(HPtr closure, HPtr acc, HPtr str) {
    auto chars = snapshotChars(Export::toPtr(str.toBits()));
    if (chars.empty()) return acc;

    HPointer closureHP = Export::decode(closure.toBits());
    HPointer accHP     = Export::decode(acc.toBits());
    Elm::StackRootGuard loopRoots(&closureHP, &accHP);

    for (u16 c : chars) {
        HPtr cl = HPtr::fromBits(Export::encode(closureHP));
        uint64_t newAcc = callFoldClosure(cl, c, Export::encode(accHP));
        accHP = Export::decode(newAcc);
    }
    return HPtr::fromBits(Export::encode(accHP));
}
```

The string's characters are copied into a C++ vector before any call, so the string's form and its place in the heap do not matter to the loop. One guard roots both live values for the whole loop, not one per iteration. The closure is re-encoded from its rooted slot on every pass, because each call into Elm may have moved it. And `callFoldClosure` reaches Elm through the runtime's typed apply entry, never by calling the closure directly.

That last rule holds for every kernel that takes an Elm function, including the list and JSON kernels. A closure may be compiled to take its arguments all at once or in stages, and only the runtime reads the closure header that says which ([closures-and-calls.md](../closures-and-calls.md)). A call that assumed one arity would work for one kind of closure and corrupt the other.

Rooting costs the same however large the input. A kernel that collects heap pointers in a buffer registers the whole buffer with one record (`RootedSlots`, `RootedElems`), or keeps partial results on the heap in builder objects. One record per element, or per batch of 64, overflows the root stack on large lists, so a static check script rejects a root push inside a loop.

The rules at a call are fixed. The caller keeps its own arguments rooted across the call, and a returned value is unrooted until the caller roots it. A heap pointer cached in a C++ static, or in any other structure the collector does not know, is never safe, because the next collection moves the object it names.

## Typed siblings and dialect operations

C++ cannot be generic over unboxed values, but many kernels are generic in Elm. For the generic kernels that are used at number types, the library carries typed siblings whose names end in `_Int`, `_Float` or `_Char`: addition in `Basics`, list cons, comparison in `Utils`, number-to-string and array push. The sibling takes and returns raw `int64_t`, `double` or `uint16_t`. The compiler picks the sibling from the types at the call site and calls the boxed version only where a type is still generic after monomorphization. The boxed version, `Elm_Kernel_Basics_add(HPtr, HPtr)` for example, reads the heap tag of its arguments and forwards to a sibling, then boxes the result, which costs an allocation per call. That tag test is the fallback for generic calls, not a way to add a type.

The compiler also replaces some kernels with eco-dialect operations, which the optimizers can fold with the code around them. Among them are string and list append, string ordering, reading one code unit of a string, and the ordering of Int, Float and Char. Each C++ export stays in the library, both as the function the operation lowers to and as the target for call sites whose type is still generic. Append shows why the typed form matters for correctness as well as for folding: the generic `Utils_append` works out at run time whether it has strings or lists, and returns its first argument for any pair it does not recognize. Where the type is known, the typed operation leaves nothing to guess.

Because the boundary takes a small share of running time ([kernels.md](kernels.md)), removing a kernel call pays in smaller code and in what the optimizers can see, not in speed.

## Decode failures unwind

The primitive decoders of elm/bytes throw a C++ exception on failure, and only the top-level `Bytes.decode` catches it. The JavaScript kernel throws and catches in the same way. A failure marker returned as an ordinary value would flow on into `map` and `andThen`, which take their input apart as a decoded tuple and would misread the marker as one.

## Effects and the eco thread

A kernel that returns a `Task` does its IO inside a task binding, a heap object holding a callback that the scheduler runs when it steps the task ([kernels.md](kernels.md) gives the reasons). Time, Http and Task are also effect managers, written in C++ over the runtime's platform services and registered with the runtime by name.

Only the eco thread, the one thread that runs Elm code and the scheduler, touches the heap. HTTP requests run on one worker thread built on libcurl, which receives plain C++ structs and a token, an integer that matches each result to the request that asked for it. The continuation that will receive the result stays rooted in the scheduler's registry of pending resumes until the result comes back. The timer thread works the same way and sees only pairs of a deadline and a token. Keeping heap work on one thread is what lets every kernel ignore concurrent mutation of the heap.

A program exits when nothing more can happen. An outstanding request or a time subscription takes a hold, a counted claim that tells the runtime a result is still expected, so the program stays alive until it arrives. [scheduler-and-services.md](../runtime/scheduler-and-services.md) describes the services these managers sit on.

## Claims the compiler trusts on audit

The compiler works out which functions can reach each call ([lambda-set-specialization.md](../compiler/lambda-set-specialization.md)). At a kernel it normally assumes the worst: any function passed in may be called from anywhere, so precision is lost at that point. For a set of audited kernels, whose Elm type was checked against the C++ to describe completely what happens to the functions they receive, the compiler skips that assumption and can turn later calls into direct calls. That is a claim about C++ that Elm cannot check. A manifest therefore pins the sha256 of every C++ file an audited row cites, and the build fails when one of them changes.

The failure is a prompt to audit again. Editing a pinned file and refreshing the manifest without re-checking each claim lets the compiler make direct calls that the C++ does not justify, and the program then miscompiles with no error.

## Changing Elm's kernels

A change fits when it keeps the JavaScript contract, leaves representation to the runtime and the calling convention to the compiler, and roots in fixed space. A change that moves one of those decisions into a kernel breaks the theory.

### Examples of changes that fit the theory
- A kernel function for an existing module: a declaration in `KernelExports.h`, the C++ export in the module's exports file, a row in the JavaScript inventory, a row in the compiler's facts table (which treats an unaudited kernel conservatively), and an end-to-end test in the package's test directory. The completion of elm/core and the Parser, Regex and Url kernels have this shape.
- A typed sibling for a kernel that numbers pass through often: one C++ function with the suffix, and one case in the compiler's sibling selection.
- A dialect operation for a small kernel whose type fixes its behavior, with the C++ export kept as its lowering target and generic fallback.
- Another package backed natively: build its values as ordinary custom types, write the layout once in a header shared with the Elm declaration, and add a test that pins the match, as elm/html does.
- Another IO kernel: a task binding built with the shared helpers, its payload and resume function rooted before the body runs, and a hold for any long wait.
- A fix to a representation bug in a kernel, such as a rebuilt list with the wrong kind of slot: the fix, a focused unit or end-to-end test, then a fresh audit of every pinned row whose file changed before the manifest is refreshed.

### Examples of changes that would break the theory
- Caching a heap pointer, or an address derived from one, in a C++ static or other off-heap structure without registering it as a root. The collector moves the object and the cache points at the old copy. Use a registered slot, or a handle id into a side table as regex does.
- A root push per element, or any rooting that grows with the input. It overflows the root stack on large inputs. Root the buffer once, or build on the heap.
- Testing heap tags inside a generic kernel to special-case a type and avoid a compiler change. The tag test runs on every call and hides the type from the optimizers. Add a typed sibling or a dialect operation.
- IO done when a task-returning kernel is called. The task loses its ordering, and a blocking call stalls the scheduler. Do the work in the binding's body.
- Calling an Elm function by a fixed arity, or by reading its code pointer. A closure of the other shape is corrupted. Go through the runtime's apply entries.
- Allocating a zero-length string, bytes value or constructor. It compares unequal to the constant and breaks the allocator's minimum size. Return the constant.
- Reading a string's or a list's storage directly. The kernel then works for one representation and breaks when the runtime adds another. Use the runtime's operations.
- Editing a pinned file and refreshing the manifest without re-auditing its rows. The compiler keeps trusting claims the code does not meet. Re-check each claim, then refresh.
- Making a browser-only function return a quiet default. A program that cannot work would appear to. Leave the assertion, or provide a host.

## References

Parent: [kernels.md](kernels.md). Related: [garbage-collector.md](../runtime/garbage-collector.md), [scheduler-and-services.md](../runtime/scheduler-and-services.md), [lambda-set-specialization.md](../compiler/lambda-set-specialization.md), [system-libraries.md](system-libraries.md).

Code:

- `elm-kernel-cpp/src/KernelExports.h`: every exported symbol and its calling convention. Its Bytes and Regex sections are labeled stubs but are full implementations.
- `elm-kernel-cpp/src/ExportHelpers.hpp`: argument conversions, `Export::toPtr` and boxed Bool.
- `elm-kernel-cpp/CMakeLists.txt`, `runtime/src/codegen/CMakeLists.txt` (`ECO_ELM_KERNEL_MODS`): per-module libraries and the module list.
- `elm-kernel-cpp/src/core/StringExports.cpp`, `ListExports.cpp`, `Utils.cpp`, `UtilsExports.cpp`, `JsArrayExports.cpp`: the core data kernels, closure calls and rooting patterns.
- `elm-kernel-cpp/src/core/BasicsExports.cpp`: typed siblings and the boxed fallback.
- `elm-kernel-cpp/src/core/CharExports.cpp`: Char masking and the reason for it.
- `elm-kernel-cpp/src/json/JsonExports.cpp`: heap-resident JSON values, decoders and encoders.
- `elm-kernel-cpp/src/regex/RegexExports.cpp`: the regex side table.
- `elm-kernel-cpp/src/bytes/BytesExports.cpp`: the decode interpreter and failure unwinding.
- `elm-kernel-cpp/src/http/HttpExports.cpp`, `HttpEffectManager.cpp`, `elm-kernel-cpp/src/time/TimeExports.cpp`, `TimeEffectManager.cpp`, `elm-kernel-cpp/src/core/ProcessExports.cpp`: effect shape, threads and holds. `time/Time.cpp` holds unused asserting stubs, and `core/Process.cpp` is empty on purpose.
- `elm-kernel-cpp/src/virtual-dom/`: node layout, constructors, attribute filters and the HTML writer.
- `elm-kernel-cpp/vendor/`: nlohmann/json and SRELL. HTTP uses libcurl with OpenSSL. `elm-kernel-cpp/LIBRARY_DEPENDENCIES.md` is the catalog written before implementation and names other libraries.
- `runtime/src/allocator/`: string, list and bytes operations, allocation and roots.
- `runtime/src/platform/TaskBinding.hpp`, `runtime/src/platform/Liveness.hpp`, `EffectManagerRegistry.cpp`: task bindings, holds and effect manager registration.
- `compiler/src/Compiler/Generate/MLIR/KernelAbi.elm` (`deriveKernelInstanceAbi`), `compiler/src/Compiler/GlobalOpt/KernelFacts.elm`, `compiler/src/Compiler/MonoSolver/KernelSetFacts.elm`: the compiler's half of the contract.
- `compiler/src/Compiler/MonoSolver/kernel-license-manifest.txt`, `test/scripts/check-kernel-license-manifest.sh`: the hash manifest.
- `test/scripts/check-kernel-homes.sh`: keeps `eco/system` kernel homes from colliding with Elm's.
- Tests: `test/kernel/` (C++ unit); `test/elm-core`, `test/elm-json`, `test/elm-bytes`, `test/elm-parser`, `test/elm-regex`, `test/elm-time`, `test/elm-url`, `test/elm-http`, `test/elm-html` (end to end, one per package).

Documents:

- `design_docs/elm_kernel_functions.csv`: the JavaScript kernel inventory.
- `design_docs/kernel-boundary-reduction.md`: the measurement of boundary cost; a snapshot whose figures and line numbers are out of date.

Invariants (`design_docs/invariants.csv`):

- REP_ABI_001, CGEN_038, CGEN_057, KERN_006: the calling convention.
- HEAP_005, HEAP_044, HEAP_071, FORBID_HEAP_003 and the HEAP_BUILDER rows: the heap, empty constants and rooting.
- KERNEL_TASK_IO_001, KERNEL_TASK_IO_002: deferred IO.
- LSS_022: audited kernels.
- VDOM_001 to VDOM_005: virtual DOM layout.
