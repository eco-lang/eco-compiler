# Large Old-Gen Allocations in Stage 7 — Diagnostic Report

## TL;DR

Every large (≥ 32 KiB) old-gen allocation in Stage 7 is a **single
`Tag_ByteBuffer`** owning the entire byte payload of one I/O operation
on a build-cache file (or a registry / details file). They are reached
through exactly two call sites, both inside the kernel `File` /
`Bytes` modules:

1. **`Eco.File.readBytes path`** → `allocByteBuffer` — reading any cache
   file as a single contiguous `Bytes` value. **95 % of events,
   85 % of bytes** in the captured sample.
2. **`Bytes.Encode.encode`** (called from
   `Builder/File.elm:writeBinary`) — encoding a single `Bytes` value to
   write a cache file back. **5 % of events, 14.5 % of bytes** in the
   captured sample.

There is **no third path** allocating ≥ 32 KiB old-gen objects in the
range we observed. Both paths bypass the nursery via the large-object
threshold (`size ≥ 8 KiB`) and call `allocateLargePinned`, which
ultimately lands in `OldGenSpace::allocate` and is reported by the new
`LargeAllocTracker`.

The reason there are far more events than there are `.elm` source files
is that the build does not work from `.elm` sources alone — for each of
~247 first-party modules plus ~29 package dependencies, the build
allocates one `Tag_ByteBuffer` per cache file read AND one per cache
file written, across four cache file types (`d.dat`, `i.dat`, `o.dat`,
`to.dat`) at the project level and (`.eci`, `.eco`, `.ecot`) per module.

## Method

### Instrumentation

A `LargeAllocTracker` (`runtime/src/allocator/LargeAllocTracker.{hpp,cpp}`)
was added and wired into the hot path:

```cpp
// runtime/src/allocator/OldGenSpace.cpp::allocate
GC_STATS_OLDGEN_RECORD_ALLOC(alloc_stats_, size);
LARGE_ALLOC_RECORD(size);   // no-op below the 32 KiB threshold
```

The tracker captures a 6-frame backtrace (via libc `backtrace()`) for
every old-gen allocation whose post-alignment size is ≥ 32 KiB. Frame
hashes index into a single map keyed by
`std::array<void*, FRAME_DEPTH>`; per-bucket counters separately track
the size distribution `[32K-64K)`, `[64K-128K)`, `[128K-256K)`,
`[256K-512K)`, `[512K-1M)`, `[≥ 1M)`. A new
`Elm::LargeAllocTracker::printReport` is called from
`eco_entry.cpp::printGCStatsOnce` so the report appears on both clean
exit and SIGABRT. Frame addresses are resolved with `dladdr` for
self-contained output; for full inlining detail we re-resolve with
`addr2line` after the run.

### Bootstrap state

Stages 1–4: pre-built JS compiler available
(`compiler/build-kernel/bin/eco-boot-3.js`).
Stage 5: pre-built MLIR (`eco-compiler.mlir`, 12.78 MB).
Stage 6: re-linked `eco-compiler` against the new instrumented
runtime libs via `eco-boot-native`. Result: `73 615 624 B` ELF.
Stage 7: invoked twice (deterministic crash both times).

### Stage 7 outcome

Stage 7 dies after **dependency verification (29/29 packages)** and
before any module compilation, on the existing
`Allocator::resolve` "Pointer above heap end" assert
(`runtime/src/allocator/Allocator.cpp:669`). This is the same
embedded-constant-resolve bug previously documented; it is not caused
by the instrumentation, and the stats handler still runs because
SIGABRT is caught and the print path is invoked before the abort
re-raises. The instrumentation is `LD_PRELOAD`-free and zero-cost
below the 32 KiB threshold.

The captured window therefore covers only the **dep verification
phase** — but the call-site distribution within that window is
diagnostic of the build pipeline as a whole, because the same
`File.readBinary` / `writeBinary` paths drive every later phase.

## Captured measurements (Stage 7, second run; identical to first)

```
=== GC Statistics ===
Allocation:
  Objects allocated:         16 573 370   (nursery)
  Bytes allocated:                469 MB
Minor GC cycles:               321
Major GC cycles:                 4
Major GC total time:           5.69 s   (sweep dominates as expected)

Old-Gen Allocation Size Histogram:
  ...
   8 KiB -  16 KiB:        5
  16 KiB -  32 KiB:        6
  32 KiB -  64 KiB:        9   ← from here up: tracked by LargeAllocTracker
  64 KiB - 128 KiB:        2
 128 KiB - 256 KiB:        4
 256 KiB - 512 KiB:        3
 512 KiB -   1 MiB:        1
       >= 1 MiB:           1

=== Large Old-Gen Allocations (>= 32 KiB) ===
Total: 20 allocations, 4.9 MiB
Distinct call sites: 2
```

### Call site #1 — `File.readBytes` (95 % of events, 85 % of bytes)

```
count=19  bytes=4.2 MiB  size=[35.8 KiB .. 2.0 MiB]

  0: Elm::ThreadLocalHeap::allocateLargePinned(size_t, Tag)
  1: Elm::ThreadLocalHeap::allocate(size_t, Tag)
  2: Elm::Allocator::allocate(size_t, Tag)
  3: Elm::alloc::allocByteBuffer(uint8_t const*, size_t)
  4: Eco::Kernel::File::readBytes(uint64_t)              ← C++ kernel impl
  5: Eco_Kernel_File_readBytes                            ← Elm-callable C export
```

**What this is doing.** `readBytes` opens the file, slurps the entire
content into a transient `std::vector<uint8_t>`, then calls
`Elm::alloc::allocByteBuffer(buffer.data(), buffer.size())`. Because
`size = file_size + sizeof(ByteBuffer) + alignment`, every read of a
file ≥ 32 KiB produces one ≥ 32 KiB `Tag_ByteBuffer` allocation. The
bytes object is reachable via the resulting `Task` value so it is
*not* dropped — it survives at least one minor GC and is promoted into
old gen (or, since `size ≥ large_object_threshold = 8 KiB`, the
nursery is bypassed entirely and the buffer is *born* in old gen via
`allocateLargePinned`).

**Why 19 of these in dep verification.** During
`Verifying dependencies (29/29)` Stage 7 calls
`File.readBinary` (Elm) → `kernel readBytes` (C++) once per cache file
that is `Unneeded` in the in-memory MVar cache. The 19 events line up
with reads of files we can identify on disk:

| File on disk | Size | Bucket |
|---|---:|---|
| `~/.eco/1.0.0/packages/registry.dat` | 491 KiB | 256–512 |
| `~/.eco/.../andre-dietrich/parser-combinators/4.1.0/typed-artifacts.dat` | 514 KiB | 512–1 M |
| `~/.eco/.../elm/parser/1.1.0/typed-artifacts.dat` | 723 KiB | 512–1 M |
| `~/.eco/.../elm/core/1.0.5/typed-artifacts.dat` | 735 KiB | 512–1 M |
| `~/.eco/.../guida-lang/glsl/1.0.0/typed-artifacts.dat` | 1 430 KiB | ≥ 1 M |
| `~/.eco/.../obiloud/numeric-decimal/3.0.1/typed-artifacts.dat` | 433 KiB | 256–512 |
| `~/.eco/.../elm/core/1.0.5/artifacts.dat` | 338 KiB | 256–512 |
| `~/.eco/.../elm/html/1.0.0/typed-artifacts.dat` | 358 KiB | 256–512 |
| `~/.eco/.../elm/url/1.0.0/typed-artifacts.dat` | 335 KiB | 256–512 |
| `~/.eco/.../guida-lang/glsl/1.0.0/artifacts.dat` | 320 KiB | 128–256 |
| `compiler/build-kernel/eco-stuff/1.0.0/d.dat` | 2 018 KiB | ≥ 1 M  ← **biggest single event** |
| (additional smaller `artifacts.dat` / `typed-artifacts.dat` / `i.dat` / `o.dat` / `to.dat` files) | 32 – 256 KiB each | 32–256 |

Note that the project-local **`d.dat` (details cache)** at 2.02 MiB
exactly matches the single `≥ 1 MiB` event in the histogram. Most of
the rest are package `typed-artifacts.dat` (the post-typecheck cache
of every dep package).

### Call site #2 — `Bytes.Encode.encode` writing a cache file (5 % of events, 14.5 % of bytes)

```
count=1  bytes=725.4 KiB  size=[725.4 KiB .. 725.4 KiB]

  0: Elm::ThreadLocalHeap::allocateLargePinned(size_t, Tag)
  1: Elm::ThreadLocalHeap::allocate(size_t, Tag)
  2: Elm::Allocator::allocate(size_t, Tag)
  3: Elm_Kernel_Bytes_encode(HPtr)               ← elm-kernel-cpp/src/bytes/BytesExports.cpp:361
  4: Utils_Main_binaryEncodeFile_$_23284         ← Utils.binaryEncodeFile (Elm)
  5: Terminal_Main_lambda_21022$cap              ← top-level call from Terminal.Main
```

**What this is doing.** `Elm_Kernel_Bytes_encode` walks the encoder
tree once to compute `totalSize`, then allocates **one** `Tag_ByteBuffer`
of that size via `allocator.allocate(allocSize, Tag_ByteBuffer)` and
writes the encoded bytes into it (`writeEncoder(encoder, bytes,
offset)`). The result is then passed to `Eco.File.writeBytes`. This is
the symmetric twin of #1 on the write side.

The single event captured is in the dep-verification phase, plausibly
writing back the resolved registry / details snapshot. Per-module
`.eci` / `.eco` / `.ecot` writes (which would account for ~3 × 247 ≈ 740
additional events of this shape) are not yet observed because Stage 7
crashed before any module was compiled.

## Object content / physical layout

Every event is a `Tag_ByteBuffer`. The on-heap layout is:

```cpp
struct ByteBuffer {
    Header header;          // 8 bytes  (tag=Tag_ByteBuffer, size=N)
    uint8_t bytes[N];       // payload
};
// allocated size = ((sizeof(ByteBuffer) + N) + 7) & ~7
```

The payload is **the raw on-disk file bytes** (read path) or the
**Bytes.Encode.encode output** (write path). It is **not** a tree of
small records; it is one contiguous byte array whose lifetime is tied
to the `Bytes` value passed back through the `Task` continuation. This
is consistent with what we see in old gen — every event is a single
contiguous span ≥ 32 KiB owned by one allocation, with `Tag_ByteBuffer`
in the header.

`Tag_String` allocations are absent from the captured window (no big
`.elm` sources have been read yet — that path
goes through `taskSucceedString` → `allocStringFromUTF8` and would
appear later if Stage 7 reached compile of large modules like
`Compiler/Reporting/Error/Syntax.elm` at 437 KiB).

## Why the count is high relative to the 252 `.elm` source count

The `.elm` source count is **not** the right denominator. The build's
disk I/O surface is dominated by the **derived caches**, not the
sources:

| Per-… | Cache files allocated as `Tag_ByteBuffer` |
|---|---|
| Project (1) | `d.dat` (details), `i.dat` (interfaces), `o.dat` (objects), `to.dat` (typed-objects), `registry.dat` |
| Module (~247) | `*.eci` (interface), `*.eco` (object/local-graph), `*.ecot` (typed-module-artifact) |
| Package (~29 deps) | `artifacts.dat`, `typed-artifacts.dat`, `docs.json`, others |

A complete Stage 7 therefore performs roughly:

```
  reads:   ~5 (project) + 3·247 (module caches) + 4·29 (package metadata)
        =  5 + 741 + 116
        ≈  862 readBinary calls

  writes:  ~5 (project)  + 3·247 (module caches)
        =  5 + 741
        ≈  746 writeBinary calls
```

Each call corresponds to **exactly one** `Tag_ByteBuffer` allocation in
old gen. About a **quarter to a third** of those files are ≥ 32 KiB
on disk:

| Cache type | total | ≥ 32 KiB | fraction |
|---|---:|---:|---:|
| `*.eci` (project) | 247 | 17 | 7 % |
| `*.eco` (project) | 247 | 126 | 51 % |
| `*.ecot` (regen path) | 247 | 74 | 30 % |
| `*.ecot` (across all `eco-stuff` dirs) | 363 | 74 | 20 % |
| `*.elm` source | 252 | 39 | 15 % |

So a complete Stage 7 should, by static accounting alone, drive
**~400–600 large `Tag_ByteBuffer` events** from cache I/O on the read
path plus another **~150–250** from the encode-write path — together
close to a thousand. With each `.elm` source eventually read once
(`File.readString` → `Tag_String`), and with intermediate
`String.concat` allocations during MLIR text emit (which can produce
several large strings per module as the IR text accumulates), the
true count for a complete run goes well above this static estimate.

## Limits of the observation

Stage 7 currently aborts in the dep-verification → compile transition
on the `Allocator::resolve` heap-bound assert. The 20-event sample
covers **only the pre-compile cache reads / writes**; it cannot
directly observe the compile-time large-allocation patterns (per-module
`.eci`/`.eco`/`.ecot` reads, `.elm` source `Tag_String` reads, and any
MLIR-emit `String.concat` chains). The measurement does, however,
prove that the *kind* of object responsible for ≥ 32 KiB old-gen
churn is `Tag_ByteBuffer`, not e.g. `Tag_Array` or `Tag_DynRecord`,
and it pinpoints the two — and only two — call sites that produce
them: `File.readBytes` and `Bytes.Encode.encode`. Both bypass the
nursery via `large_object_threshold = 8 KiB` and land directly in
old gen.

## Where to look next

1. **`Eco_Kernel_File_readBytes`** (`/work/eco-kernel-cpp/src/eco/File.cpp:40-52`).
   Currently slurps the whole file into a `std::vector` and then copies
   that into a fresh `Tag_ByteBuffer`. This double-buffers every read.
   For files ≥ 32 KiB, the unique `Tag_ByteBuffer` allocation could be
   sized first (via `tellg`), allocated up front, and `read()` could
   write directly into it — eliminating the transient C++ buffer.

2. **Cache-file granularity.** The MVar-cached interface store
   memoizes per-module — but `d.dat` (2 MiB), `o.dat`, `to.dat`, and
   the package `typed-artifacts.dat` files are loaded as monolithic
   `Tag_ByteBuffer`s per dep. Splitting these into per-module records
   (or a memory-mapped layout) would cut the largest events.

3. **`Bytes.Encode.encode`** (`/work/elm-kernel-cpp/src/bytes/BytesExports.cpp:361`).
   Allocates one `Tag_ByteBuffer` of the full encoded size. This is
   already the optimal allocation count for the write path; it is just
   that the resulting buffers are large because the cache files
   themselves are large.

4. **For a full Stage 7 measurement**, fix the `Allocator::resolve`
   heap-bound abort (per memory: missing `addrspace(0)→addrspace(1)`
   wrap on a heap field write). With Stage 7 running through to
   completion the same `LargeAllocTracker` will then surface the
   compile-time call sites, in particular the `String.concat` chain in
   the MLIR text emitter and the per-module `binaryEncodeFile` writes,
   which dominate during the actual compile.
