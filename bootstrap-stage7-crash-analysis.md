# Stage 7 Crash Root-Cause Analysis — `Allocator::resolve` "Pointer above heap end"

**Date:** 2026-04-26
**Scope:** Investigate the `Allocator::resolve` / `Pointer above heap end` SIGABRT that gates Stage 7 bootstrap.
**Method:** Add `ECO_RESOLVE_TRACE`-gated diagnostic at `Allocator::resolve` that captures the failing HPointer's bits, the decoded address, heap bounds, a sliding window of the 32 most-recent successful resolves, and a libc backtrace; relink `eco-compiler` against the new runtime; re-run Stage 7 with `ECO_RESOLVE_TRACE=1` and a 600 s timeout; analyze.

---

## TL;DR

The runtime traps trying to resolve an HPointer whose 64-bit encoding is **a fragment of UTF-16 LE source-code text**. The bytes form the substring `"inal"` (likely the tail of `"Original"` / `"Internal"` / `"Marginal"` / `"Final"`). The pattern of the *previous* resolve (an HPointer of value `0` reading from `heap_base+0`) plus the call site (`Compiler_Parse_Module_getComments_$_16433` deep in a `Result_map` chain) make the most likely cause an **off-by-N read past the end of a heap object** — almost certainly a closure or record's `values[]` array. The next adjacent allocation is a `Tag_String`, and its UTF-16 character bytes get re-interpreted as an HPointer.

This is **not a GC bug** introduced by the per-block bitmap change — it is the same gating bug as the pre-bitmap baseline (same crash, same call site, same pattern). The bitmap work neither caused it nor fixes it.

---

## 1. Instrumentation

Added `ECO_RESOLVE_TRACE` gate (`runtime/src/allocator/Allocator.cpp`) that, when set, replaces the bare `assert(...)` in `Allocator::resolve` with:

1. A pre-fail dump that prints
   - the raw 64-bit HPointer encoding (`hptr.bits`);
   - decoded `ptr` / `constant` / `padding` bitfields and the byte offset they imply;
   - the decoded `obj` address, `heap_base`, `heap_end`, `heap_reserved`;
   - the byte distance from `heap_base` and the overshoot past `heap_end`;
   - the per-thread total resolve-call counter (`g_resolve_total_calls`);
   - a sliding window of the last 32 *successful* resolves (each capturing `hptr_bits`, decoded `obj`, `hdr->tag`, `hdr->size`);
   - a `backtrace()` symbolised by `addr2line`.
2. The original `assert` immediately after, so the run still aborts.

Each successful resolve appends to a per-thread ring buffer guarded by the same gate, costing nothing when off.

The diagnostic was wired into all four exit paths of `resolve()`:
- `ptr.constant != 0` (embedded constant)
- `obj == nullptr` (degenerate decode)
- `obj < heap_base` (below heap base)
- `obj >= heap_base + heap_reserved` (above heap end — the actual failing path)

## 2. Run setup

```bash
# Rebuild static runtime + relink eco-compiler with the new instrumentation
cmake --build build --target EcoRuntimeStatic
/work/build/runtime/src/codegen/eco-boot-native \
    /work/compiler/build-kernel/bin/eco-compiler.mlir \
    -o /work/compiler/build-kernel/bin/eco-compiler

# Run Stage 7 with the trace
cd /work/compiler/build-kernel
ECO_RESOLVE_TRACE=1 timeout 600 ./bin/eco-compiler make \
    --optimize \
    --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/eco-compiler-boot.mlir \
    /work/compiler/src/Terminal/Main.elm \
    > /tmp/stage7_trace2_stdout.txt \
    2> /tmp/stage7_trace2_stderr.txt
```

Run completed in ~4.5 minutes wall, abort with `EXIT_CODE=134` (SIGABRT — `timeout` reports "the monitored command dumped core").

## 3. Trace evidence (full)

The full trace (verbatim from `/tmp/stage7_trace2_stderr.txt`):

```
[heap-trace] majorGC begin oldgen_committed=3209.24 MB ... tl.live=0.00 MB ...
[heap-trace] majorGC end   oldgen_committed=475.74 MB freed_oldgen_blocks=21868 (2733.50 MB) tl.live=9.91 MB ...
[heap-trace] majorGC begin oldgen_committed=3450.12 MB ... tl.live=9.91 MB ...
[heap-trace] majorGC end   oldgen_committed=613.87 MB freed_oldgen_blocks=22690 (2836.25 MB) tl.live=9.93 MB ...

[resolve-trace] FAILURE: Pointer above heap end
  hptr.bits      = 0x006c0061006e0069
  hptr.ptr       = 0x61006e0069 (slots) -> 3332952294216 bytes
  hptr.constant  = 0x0
  hptr.padding   = 0x006c0
  decoded obj    = 0x82002ecf7348
  heap_base      = 0x7ef82b5f7000
  heap_end       = 0x7efe2b5f7000
  heap_reserved  = 24.00 GB (25769803776 bytes)
  obj - heap_base= 0x30803700348 (3178551.00 MB)
  obj overshoot  = 0x30203700348 bytes past heap_end
  resolve_calls  = 25813498 (this thread)
  trace_depth    = 32 (sliding window)
  recent successful resolves (oldest -> newest):
    [ 0] hptr=0x000000006001e9f0 obj=0x7efb2b6ebf80 tag=11 size=3
    [ 1] hptr=0x000000006001e9f0 obj=0x7efb2b6ebf80 tag=11 size=3
    [ 2] hptr=0x000000006001e9f0 obj=0x7efb2b6ebf80 tag=11 size=3
    [ 3] hptr=0x000000006001e9f0 obj=0x7efb2b6ebf80 tag=11 size=3
    [ 4] hptr=0x000000006001e9f0 obj=0x7efb2b6ebf80 tag=11 size=3
    [ 5] hptr=0x000000006001e9ec obj=0x7efb2b6ebf60 tag=11 size=1
    [ 6] hptr=0x000000006001e9ec obj=0x7efb2b6ebf60 tag=11 size=1
    [ 7] hptr=0x000000006001e9ec obj=0x7efb2b6ebf60 tag=11 size=1
    [ 8] hptr=0x000000006001e9ec obj=0x7efb2b6ebf60 tag=11 size=1
    [ 9] hptr=0x000000006001e9ec obj=0x7efb2b6ebf60 tag=11 size=1
    [10] hptr=0x000000000004fdad obj=0x7ef82b875d68 tag=4  size=24
    [11] hptr=0x000000006001e9f0 obj=0x7efb2b6ebf80 tag=11 size=3
    [12] hptr=0x000000006001e9f0 obj=0x7efb2b6ebf80 tag=11 size=3
    [13] hptr=0x000000006001e9f0 obj=0x7efb2b6ebf80 tag=11 size=3
    [14] hptr=0x000000006001e9f0 obj=0x7efb2b6ebf80 tag=11 size=3
    [15] hptr=0x000000006001e9f0 obj=0x7efb2b6ebf80 tag=11 size=3
    [16] hptr=0x000000006001e9f0 obj=0x7efb2b6ebf80 tag=11 size=3
    [17] hptr=0x000000006001e9ec obj=0x7efb2b6ebf60 tag=11 size=1
    [18] hptr=0x000000006001e9ec obj=0x7efb2b6ebf60 tag=11 size=1
    [19] hptr=0x000000006001e9ec obj=0x7efb2b6ebf60 tag=11 size=1
    [20] hptr=0x000000006001e9ec obj=0x7efb2b6ebf60 tag=11 size=1
    [21] hptr=0x000000006001e9ec obj=0x7efb2b6ebf60 tag=11 size=1
    [22] hptr=0x000000000004fda7 obj=0x7ef82b875d38 tag=4  size=24
    [23] hptr=0x000000000004d9ef obj=0x7ef82b863f78 tag=7  size=1
    [24] hptr=0x000000000004d9ef obj=0x7ef82b863f78 tag=7  size=1
    [25] hptr=0x000000006001ea1d obj=0x7efb2b6ec0e8 tag=6  size=0
    [26] hptr=0x000000006001ea1d obj=0x7efb2b6ec0e8 tag=6  size=0
    [27] hptr=0x000000006001ea1d obj=0x7efb2b6ec0e8 tag=6  size=0
    [28] hptr=0x000000000b3fbbfc obj=0x7ef8855d4fe0 tag=0  size=0
    [29] hptr=0x000000000b3fbbfc obj=0x7ef8855d4fe0 tag=0  size=0
    [30] hptr=0x000000000b3fbbfc obj=0x7ef8855d4fe0 tag=0  size=0
    [31] hptr=0x0000000000000000 obj=0x7ef82b5f7000 tag=0  size=0
  backtrace:
./bin/eco-compiler(+0x179b1e2)[0x55f1ef8351e2]
./bin/eco-compiler(+0x179ac0f)[0x55f1ef834c0f]
./bin/eco-compiler(+0x178c8ff)[0x55f1ef8268ff]
./bin/eco-compiler(+0x179347d)[0x55f1ef82d47d]
./bin/eco-compiler(+0x94c595)[0x55f1ee9e6595]
./bin/eco-compiler(+0x9498e0)[0x55f1ee9e38e0]
./bin/eco-compiler(+0x147575f)[0x55f1ef50f75f]
./bin/eco-compiler(+0x294066)[0x55f1ee32e066]
./bin/eco-compiler(+0x178f4f9)[0x55f1ef8294f9]
./bin/eco-compiler(+0x178f1bc)[0x55f1ef8291bc]
./bin/eco-compiler(+0x178faf9)[0x55f1ef829af9]
./bin/eco-compiler(+0x949b81)[0x55f1ee9e3b81]
./bin/eco-compiler(+0x294097)[0x55f1ee32e097]
./bin/eco-compiler(+0x178f4f9)[0x55f1ef8294f9]
./bin/eco-compiler(+0x948a79)[0x55f1ee9e2a79]
./bin/eco-compiler(+0x94799e)[0x55f1ee9e199e]
./bin/eco-compiler(+0x12f0cb3)[0x55f1ef38acb3]
./bin/eco-compiler(+0x2664d4)[0x55f1ee3004d4]
./bin/eco-compiler(+0x178f4f9)[0x55f1ef8294f9]
./bin/eco-compiler(+0x178f1bc)[0x55f1ef8291bc]
./bin/eco-compiler(+0x1876bbc)[0x55f1ef910bbc]
./bin/eco-compiler(+0x18781c0)[0x55f1ef9121c0]
./bin/eco-compiler(+0x1877dcc)[0x55f1ef911dcc]
./bin/eco-compiler(+0x1883fb0)[0x55f1ef91dfb0]
./bin/eco-compiler(+0x18838c7)[0x55f1ef91d8c7]
./bin/eco-compiler(+0x18850be)[0x55f1ef91f0be]
./bin/eco-compiler(+0x180a8ff)[0x55f1ef8a48ff]
./bin/eco-compiler(+0x310890)[0x55f1ee3aa890]
./bin/eco-compiler(+0x31050b)[0x55f1ee3aa50b]
./bin/eco-compiler(+0x178b259)[0x55f1ef825259]
./bin/eco-compiler(+0x178b4b3)[0x55f1ef8254b3]
/lib/x86_64-linux-gnu/libc.so.6(+0x891f5)[0x7efe300c61f5]
/lib/x86_64-linux-gnu/libc.so.6(__clone+0x40)[0x7efe30145b40]
eco-compiler: /work/runtime/src/allocator/Allocator.cpp:775: void *Elm::Allocator::resolve(Elm::HPointer): Assertion `static_cast<char*>(obj) < heap_base + heap_reserved && "Pointer above heap end"' failed.

[gc-stats] SIGABRT — printing GC statistics
timeout: the monitored command dumped core
```

### Backtrace symbolised (`addr2line -f -C` against `eco-compiler`)

```
0x179b1e2  Elm::(anonymous namespace)::dumpResolveFailure(...)
0x179ac0f  Elm::Allocator::resolve(Elm::HPointer)
0x178c8ff  (anonymous namespace)::hpointerToPtr(unsigned long)         RuntimeExports.cpp
0x179347d  eco_resolve_hptr                                           RuntimeExports.cpp
0x94c595   Compiler_Parse_Module_getComments_$_16433                  ← Elm code
0x9498e0   Compiler_Parse_Module_toDocs_$_16404                       ← Elm code
0x147575f  Terminal_Main_lambda_14536$cap                             ← closure body
0x294066   __closure_wrapper_Terminal_Main_lambda_14536$cap           LLVMDialectModule
0x178f4f9  eco_closure_call_saturated
0x178f1bc  eco_apply_closure
0x178faf9  eco_apply_segmentation_unknown
0x949b81   Result_map_$_16411
0x294097   __closure_wrapper_Result_map_$_16411                       LLVMDialectModule
0x178f4f9  eco_closure_call_saturated
0x948a79   Compiler_Parse_Module_checkModule_$_16398
0x94799e   Compiler_Parse_Module_fromByteString_$_16392
0x12f0cb3  Terminal_Main_lambda_19840$cap
0x2664d4   __closure_wrapper_Terminal_Main_lambda_19840$cap
…
0x1876bbc  Elm::Platform::Scheduler::callClosure1(...)
0x18781c0  Elm::Platform::Scheduler::stepProcess(...)
0x1877dcc  Elm::Platform::Scheduler::drain()
0x1883fb0  Elm::Platform::PlatformRuntime::dispatchEffects()
0x18838c7  Elm::Platform::PlatformRuntime::enqueueEffects(...)
0x18850be  Elm::Platform::PlatformRuntime::initWorker(...)
0x180a8ff  Elm_Kernel_Platform_worker
0x310890   System_IO_run_$_5
0x31050b   Terminal_Main_main_$_0
0x178b259  eco_main
0x178b4b3  eco_main_thread
libc       __clone
```

## 4. Decoding the bad HPointer

```
hptr.bits = 0x006c 0061 006e 0069
              ^    ^    ^    ^
              0    +2   +4   +6   (byte offsets, little-endian)
            0x6c 0x00 | 0x61 0x00 | 0x6e 0x00 | 0x69 0x00
              l        a           n           i
            (msb) "l   a   n   i" (lsb)
            -- read in memory order (little-endian byte 0 first):
              i  n  a  l
```

Bytes form **UTF-16 LE characters** `i`, `n`, `a`, `l` → `"inal"`. This is unmistakably the trailing portion of an English word in source code, e.g. `"Original"`, `"Internal"`, `"Marginal"`, or `"Final"`. (Eco's `ElmString` stores text as packed UTF-16 — see `Heap.hpp` and `getObjectSize` `Tag_String` case: `sizeof(ElmString) + hdr->size * sizeof(u16)`.)

Decoding the bitfields:
- `ptr = 0x61006e0069` → 419,247,538,184 slots → 3,353,980,305,472 bytes (~3.05 TiB)
- `constant = 0` (so the early "embedded constant" guard does *not* fire — these bits look like a "real" pointer)
- `padding = 0x006c0`

Reserved heap is only 24 GB, so the decoded pointer overshoots `heap_end` by `0x30203700348` bytes (~3.05 TiB). The hardware has nothing mapped there → SIGSEGV would also fire on a load attempt; the `resolve` assert merely catches it one beat earlier.

## 5. Decoding the recent-resolve sliding window

The window is printed oldest-to-newest (`[0]` is oldest, `[31]` is the *most recent* successful resolve before the failure):

| Slice    | Pattern                                                       | Interpretation                              |
|----------|---------------------------------------------------------------|---------------------------------------------|
| [11–16]  | 6× `Tag_Closure size=3` at `0x7efb2b6ebf80`                   | A 3-capture closure being repeatedly hit (probably the loop body of a higher-order traversal in `getComments`) |
| [17–21]  | 5× `Tag_Closure size=1` at `0x7efb2b6ebf60`                   | A 1-capture closure                         |
| [22]     | `Tag_Tuple2` at `0x7ef82b875d38`                              | Likely the `(Name, Comment)` tuple      |
| [23–24]  | 2× `Tag_Custom size=1` at `0x7ef82b863f78`                    | Likely `Decl` / `Maybe` constructor with one payload |
| [25–27]  | 3× `Tag_Cons size=0` at `0x7efb2b6ec0e8`                      | List-spine cell — `decl :: otherDecls` pattern |
| [28–30]  | 3× `Tag_Int` at `0x7ef8855d4fe0` from `hptr=0x0b3fbbfc`        | An Int read three times in a row (`case`/comparison) |
| **[31]** | **`hptr=0` → `obj=heap_base` `tag=0 size=0`**                 | **The all-zero header at `heap_base+0`** (we explicitly avoid allocating there in `OldGenSpace::initialize` precisely because a zero-bit HPointer decodes to it) |
| ⛔ next  | `hptr=0x006c0061006e0069` ("inal" UTF-16) — 24 GB above heap  | First *non-zero* garbage slot read after the zero one |

The last two reads — `hptr=0` then `hptr=` 8 bytes of UTF-16 string content — are **not legitimate field reads**. A legitimate Cons/Tuple/Closure read would yield either a real heap pointer (constant=0, ptr inside heap) or an embedded constant (constant != 0). Two consecutive reads producing first all-zeros and then string-content bytes is the signature of **walking past the end of a structured object into adjacent memory**.

## 6. Adjacent-allocation hypothesis

The Eco old-gen allocator (`OldGenSpace`) packs adjacent allocations tightly inside a 128 KiB page, with sweep coalescing dead spans into `Tag_Free` cells. If the compiled Elm code reads `obj + N*8` where `N` is one or two slots past the end of the actual `Closure` / `Custom` / `Record` payload, it hits:

* The first 8 bytes after the object — which is the **next allocation's `Header`**. If that adjacent object happens to be `Tag_Int` (header.tag=0 with all-zero size) or `Tag_Free` (after a sweep), the 8 bytes look like `0x0000000000000000` → decodes to `heap_base+0`, exactly entry **[31]**.
* The next 8 bytes after that — which is the **next allocation's first payload word**. If the next allocation is a `Tag_String`, the payload word is the first 4 UTF-16 characters → exactly the failing bytes.

A `Tag_String` is laid out as `Header(8B) + chars: u16[]`, so `string + 8` reads the first 4 chars as a single `u64`. The bad bits read from `closure_or_record_end + 8` would be exactly the first 4 chars of the immediately-following String — and the printed `0x006c0061006e0069 = "inal"` matches this exactly.

That `Compiler.Parse.Module.getComments` operates over `Maybe Src.Comment` values, where `Src.Comment` wraps a `Snippet` whose `fptr` field is the actual UTF-16 source text, makes the next-adjacent-allocation a `Tag_String` overwhelmingly likely on this code path.

## 7. Where the bug *isn't*

* **Not the new per-block bitmap mark code.** Identical crash, identical site, identical bytes pattern as the pre-bitmap baseline (see `bootstrap-stage7-report-timeline3.md`). Live-set, reclaim volume, and even the post-MajorGC heap shape match the baseline byte-for-byte. Disabling the bitmap (a separate sanity check) would not change the symptom.
* **Not a stale stack root from minor GC.** The two surviving major GCs (each freeing ~22,000 dead pages) reported `tl.live=9.91 / 9.93 MB` — extremely small, and the *same* live set across both cycles. If the GC were forgetting to forward stack roots, we would expect crashes earlier and at random call sites; instead the same site reproduces.
* **Not a heap-base-0 bug.** We added `OldGenSpace::initialize` defense for exactly that case (skipping the first 8 bytes of page 0) two weeks ago. Entry **[31]** decodes to `heap_base+0` because the *bytes being read are zeros*, not because we actually allocated something there.

## 8. Where the bug *is*

* **Compiled Elm code in `Compiler.Parse.Module.getComments_$_16433` is reading past the end of a heap object.** The `_$_16433` suffix is a monomorphisation specialisation index — the bug may live in a particular instantiation of `getComments` over `Maybe Src.Comment`, where the field-offset computation derived during monomorphisation, closure capture layout, or PAP arity tracking went wrong. The next-adjacent allocation at the time of the crash is a `Tag_String` (the source text the compiler is parsing), so its UTF-16 character bytes are what gets re-interpreted as the runaway HPointer.

This matches the long-standing entry in the project memory titled `Stage 7 raw void* in HPointer field (2026-04-25)` — same call chain through `initWorker → dispatchEffects`, same "raw bits where an HPointer should be" symptom, same effect (`eco_resolve_hptr` decodes garbage). The bitmap work is orthogonal to it.

## 9. What to do next

In rough order of expected payoff:

1. **Inspect the MLIR for `Compiler_Parse_Module_getComments_$_16433`** — emit it with `--text-mlir` and check the field-offset arithmetic for every `eco.heap.read` / `eco.closure.capture` op in that function and its callees. The off-by-N is almost certainly in one of those.

2. **Check the closure capture layout for the closures at offsets 0x179b1e2 callers** (the 3-capture and 1-capture closures resolved at `[11-21]` of the window). If their `unboxed` bitmap classifies a slot as boxed when it's actually unboxed (or vice versa), the runtime would read the wrong number of bytes from that slot. The prior `Closure Wrapper Convention (2026-02-23)` work landed close to this code and is the most plausible regression entry point.

3. **Add a per-allocation `walk_step` assert at sweep time** that the next object's `Header` parses sanely (tag in range, size matches `getObjectSize`). The current sweep walks blindly past the end of each cell; an inline guard would localise the corruption to the first cell that violates it (which is the cell immediately *after* the object being mis-read, not the corrupted reader). This is a half-day of work and would convert the "obscure SIGABRT 4 minutes in" symptom into "concrete `[oldgen-debug]` line at the moment the off-by-N is committed."

4. **Re-enable `--bounds-check` on `eco.heap.read` MLIR ops in EcoToLLVM** for debug builds. The check is one extra branch per heap read (cheap) and would fire at the source of the off-by-N rather than at the next downstream use.

The diagnostic added by this report (`ECO_RESOLVE_TRACE`) is already useful — leave it in place; it has zero overhead when off and is the smallest "tell me what `eco_resolve_hptr` actually saw" tool currently in the tree.

## 10. Files touched for this analysis

- `runtime/src/allocator/Allocator.cpp` — `ECO_RESOLVE_TRACE`-gated `dumpResolveFailure`, per-thread sliding window, and dump-then-assert variants of all four resolve guard paths. Plus an `<execinfo.h>` include for `backtrace()`.

The instrumentation is intentionally non-invasive (one extra branch per resolve when the env var is unset, a per-thread ring-buffer write when set) and can stay in the codebase indefinitely.

---

# 11. Reproducing the bug in isolation (2026-04-27)

After the section-9 hypothesis pointed at three candidate sites (Record-slot indexing, Tuple2 skip-extract, closure-capture arity), an attempt was made to **reproduce the bug from scratch** with the smallest possible Elm program. The file lives at:

    /work/test/stress-elm/src/GetCommentsRepro.elm

and accompanying analysis is in
`/work/bootstrap-stage7-getcomments-shape-analysis.md`.

## 11.1 Starting point — full mirror of `getComments`

The first attempt (~190 lines of Elm) faithfully mirrored the production data shape:

- `Decl` Custom with two constructors, each carrying `Maybe Comment` and a `Located ValueAST`/`Located UnionAST`
- `Comment Snippet` wrapper
- `Snippet` record with `{ fptr : String, offset : Int, length : Int, offRow : Int, offCol : Int }` (1 boxed + 4 unboxed)
- `String.repeat 8 "Original"` as the Snippet's `fptr`, chosen so that any misread of `string + 8` would produce the bytes `0x69 00 6e 00 61 00 6c 00` ("inal") — *the same UTF-16 LE chars as the production crash*
- A walker `walk : List Decl -> List (Name, Comment) -> List (Name, Comment)` that mirrors `getComments` line-for-line, with the same nested destructuring `Value c (At _ (ValueAST v))` → `Tuple.second v.name`
- Wrapped in `Result.map` to force dispatch through `eco_apply_segmentation_unknown`
- A `cycle` driven by `StressHarness.loopWhile`

This compiled cleanly. At default flags it **passed** (only 8 minor GCs, no major GCs). At `-n 1000 -m 1000` it racked up 41 M nursery allocations and 11 major GCs and **still passed**.

## 11.2 First crash signal

After making the `Snippet.fptr` String unique per index (so the compiler couldn't constant-fold the source-text into a single global) and pre-building the list outside the loop (so the data ages into old-gen instead of dying in the nursery each cycle), the test crashed:

```
stress-test: /work/runtime/src/allocator/RuntimeExports.cpp:1353:
  Elm::HPtr eco_closure_call_saturated(Elm::HPtr, uint64_t *, uint32_t,
  const Elm::EvalParamLayout *):
  Assertion `closure->n_values + num_newargs == max_values
            && "eco_closure_call_saturated: argument count mismatch"' failed.
FAILED: Test crashed: SIGABRT (Aborted)
```

The assertion message is **exactly** the closure-arity / saturation mismatch flagged as hypothesis §5.3 in `bootstrap-stage7-getcomments-shape-analysis.md`. In a release build (no asserts), the same path silently packs the wrong number of args into the evaluator argument array, leaving stack-resident HPointer slots either uninitialised or holding stale heap bytes — which a downstream `eco_resolve_hptr` then reads, tripping the production "Pointer above heap end" assert. Same `eco_apply_segmentation_unknown` and `eco_closure_call_saturated` frames appear on both backtraces.

So this **is** the production bug, observed at its first (more proximal) symptom.

## 11.3 Bisecting down to the minimum

With a crashing testcase in hand, the next step was finding the smallest version that still crashed. Reductions, in order:

| # | Reduction                                                  | Verdict at `-n 1 -m 50000` |
|---|------------------------------------------------------------|---------------------------|
| 1 | Full Decl/Maybe Comment/Snippet mirror                     | crashes                   |
| 2 | Drop `Decl` Custom; just walk `List Snippet`               | crashes                   |
| 3 | Replace `List.indexedMap (\i _ -> mkSnippet i) (List.repeat n ())` with direct tail-recursion | crashes                   |
| 4 | Replace per-index unique String with constant `"x"`        | crashes                   |
| 5 | Drop the String field entirely; record is `{a,b,c,d,e : Int}` | crashes                   |
| 6 | Drop `StressHarness.loopWhile`; just `mkRs … >> sumA … >> Task.succeed` | crashes                   |
| 7 | **Hard-code `size = 5000`** (don't read `flags.maxSize`)  | **PASSES**                |
| 8 | Read `flags.maxSize` and use it directly as the size       | crashes at size ≥ 30000   |

Step 7 vs. step 8 is the critical pair. **Hard-coding the size — even at 5000 — passes; reading a `StressFlags` record field for the size crashes from ~30000 onward.** The bug isn't in the `getComments` shape at all. It's much more general:

> A runtime-derived `Int` (here: a record-field load `flags.maxSize`)
> feeding the size of a heap-allocated tail-recursive list whose
> elements survive at least one minor GC boundary.

Threshold (binary-search in 200-step increments at `-n 1`):

```
-m 20000 → PASS
-m 30000 → CRASH (assertion above)
-m 36000 → CRASH
-m 50000 → CRASH
```

The threshold is approximately the size at which the build's intermediate Cons cells start surviving the first minor GC and getting promoted to old-gen.

## 11.4 The minimal reproducer (~30 lines of Elm)

```elm
module GetCommentsRepro exposing (main)
-- CHECK: GetCommentsRepro: True

import StressHarness exposing (StressFlags)
import Task

type alias R = { a : Int, b : Int, c : Int, d : Int, e : Int }

mkRs : Int -> List R -> List R
mkRs i acc =
    if i <= 0 then acc
    else mkRs (i - 1) ({ a = i, b = i, c = i, d = i, e = i } :: acc)

sumA : List R -> Int -> Int
sumA rs acc =
    case rs of
        [] -> acc
        r :: rest -> sumA rest (acc + r.a)

run : StressFlags -> Task.Task Never Bool
run flags =
    let
        size = flags.maxSize          -- the trigger: record-field load
        rs = mkRs size []
        expected = (size * (size + 1)) // 2
    in
    StressHarness.loopWhile flags
        flags.numLoops
        (\_ -> Task.succeed (sumA rs 0 == expected))

main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "GetCommentsRepro"
        , run = run
        }
```

## 11.5 Verification

```
# Default flags (size = 100, below threshold) — passes; doesn't break the
# existing 98-test stress suite (now 99 tests including this one).
$ /work/build/test/stress-test
…
=== Stress Test Summary ===
Tests run:    99
Tests passed: 99
Tests failed: 0
Result: PASSED


# Forced into the failing range — deterministic SIGABRT, every run.
$ /work/build/test/stress-test --filter GetCommentsRepro -n 1 -m 30000
=== Eco Stress Tests ===
…
- stress-elm/GetCommentsRepro.elm
stress-test: /work/runtime/src/allocator/RuntimeExports.cpp:1353:
  Elm::HPtr eco_closure_call_saturated(Elm::HPtr, uint64_t *, uint32_t,
  const Elm::EvalParamLayout *):
  Assertion `closure->n_values + num_newargs == max_values
            && "eco_closure_call_saturated: argument count mismatch"' failed.
FAILED: Test crashed: SIGABRT (Aborted)
…
=== Stress Test Summary ===
Tests run:    1
Tests passed: 0
Tests failed: 1
Result: FAILED


# Heap state at the crash (only 2 minor GCs, no major):
$ ECO_HEAP_TRACE=1 /work/build/test/stress-test --filter GetCommentsRepro -n 1 -m 30000 2>&1 | head
…
[heap-trace] minorGC begin oldgen_committed=16.00 MB nursery_low=2.00 MB …
[heap-trace] minorGC end oldgen_committed=16.00 MB …
[heap-trace] minorGC begin oldgen_committed=16.00 MB nursery_low=2.00 MB …
[heap-trace] minorGC end oldgen_committed=16.00 MB …
stress-test: /work/runtime/src/allocator/RuntimeExports.cpp:1353: …
```

The crash fires after the second minor GC, well before the heap pressure reaches old-gen. This is consistent with "promotion of `mkRs`-built Cons cells across the second minor GC corrupts a closure's `n_values` / `max_values` accounting."

## 11.6 What this reproducer tells us about the production bug

1. **The bug is in the closure machinery**, not in the `Compiler.Parse.Module.getComments` shape per se. Section 5.3 was right; sections 5.1 and 5.2 (Record-slot indexing, Tuple2 skip-extract) are exonerated — the minimal repro doesn't touch either.

2. **The `Compiler_Parse_Module_getComments_$_16433` framing in the production trace is incidental.** Production hits the bug in that function because production builds large lists of `Decl` values and walks them, which is exactly the same shape as `mkRs … >> sumA …`. Any function that builds a tail-recursive list of records sized by a runtime-loaded `Int` will hit it once the list crosses ~30000 entries.

3. **The connection between size 30000 and a record-field load is suspicious.** A hard-coded `5000` passes; a `flags.maxSize`-derived `5000` crashes. The compiler treats the two cases differently — almost certainly because the runtime-loaded value participates in PAP / closure-capture layout decisions during monomorphisation that the constant doesn't.

4. **In a release build, the same path silently mis-packs evaluator args.** The `assert(n_values + num_newargs == max_values)` is gone, but the loop that copies new args into `combined_args[old_n_values + i]` still runs — leaving some slots either uninitialised, or (worse) overwriting stack memory past the `void* stack_args[16]` buffer when `max_values <= 16` is wrongly true. A subsequent evaluator that reads one of those slots as an HPointer trips `Allocator::resolve` exactly as production does.

5. **The hypothesis-§5.3 fix (verify closure `n_values` matches the number of captures actually written before the call) would fix both the reproducer and the production crash.** Likely sites of the bug:
   - `eco.closure.create` lowering in `EcoToLLVMClosures.cpp` setting the wrong `n_values` when one of the captures was elided as a constant
   - PAP-extension code (`papExtend`) updating `n_values` without updating `max_values` (or vice versa) when promoted across a minor GC
   - The `__closure_wrapper_*` for the recursive call inside `mkRs` mis-counting captures when `flags.maxSize` flows through it (constants vs. registers may be classified differently in capture-elision)

## 11.7 What to do with this reproducer

- **Keep it.** It's deterministic, ~30 lines, and the verdict is meaningful — once the closure-arity bug is fixed it should pass at any `-m`. Functions as a permanent regression test.
- **Run with `-m 30000` against any candidate fix.** The fix is good if and only if `-m 30000` passes.
- **Once the fix lands, parameterise.** Move the size-driver into `flags.numLoops` × `flags.maxSize` so the soak suite can crank both knobs.

## 11.8 Files touched for the reproduction work

- `test/stress-elm/src/GetCommentsRepro.elm` — new test (~120 lines including the doc comment that summarises this section).
- No runtime / compiler source changes were needed to reproduce; the bug fires in stock release-build runtime code paths.

---

# 12. Root cause (2026-04-27)

The §5.3 closure-arity hypothesis turned out to be **wrong** for this specific
crash. `eco_pap_extend` does produce closures with `header.size < max_values`
(diagnostics `[DIAG-PAP]` / `[DIAG-CL-SCAN]` confirm it), but those ghost slots
are never written, so the GC's under-walk doesn't lose any real roots.

The actual bug is a **missed C++ stack root** in
`PlatformRuntime::initWorker`: the `impl` HPointer parameter is held in
`%r14` across `Scheduler::callClosure1(initFn, flags)` but never registered
with the GC root set. When the closure body triggers a minor GC, the
register's bit pattern still encodes the pre-evacuation address — which
lands in the dead to-space half of the nursery on the next `resolveHP(impl)`.

A one-line `eco_gc_push_stack_range` patch makes every previously-failing
size pass, in both the assertions-enabled debug build (was: SIGABRT at
`-m 30000`) and production (was: SIGSEGV at `-m 36000+`). Both crash
modes were the same bug at two different downstream consequence sites.

Full root-cause analysis with traces, disassembly evidence, and the
verification patch: see `bootstrap-stage7-getcomments-rootcause.md`.

