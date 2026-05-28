# Static MUSL Build — Flags & GC/Unwinder Risk Report

**Scope:** The fully-static `eco` binary produced by
`docker/static-build.Dockerfile` (Stage B of `plans/static-link-eco-binary.md`),
built with `cmake --preset ninja-clang-lld-linux-musl` → `cmake --build build
--target eco`.

**Focus:** (1) the exact compiler/linker parameters that go into that binary and
what each does, (2) which of them touch exceptions / stack traces / frame
pointers, and (3) the static-build-specific risks to GC correctness — in
particular the libunwind-driven stack-root scan that can cause heap root
pointers to be read or rewritten at the wrong stack slot after a moving GC.

---

## 1. How the static MUSL binary is assembled

The shipped binary comes from three layers of flags:

1. **The preset** `ninja-clang-lld-linux-musl` (`CMakePresets.json:66-83`) —
   sets `ECO_STATIC`, `ECO_STATIC_MUSL`, `ECO_LINK_WITH_BFD=OFF`, the libc++
   compile flag, and the full static link line.
2. **The `eco` target rules** (`compiler/CMakeLists.txt:444-510`) — linker
   selection and the `--start-group`/`--whole-archive` layout of the kernel and
   runtime archives.
3. **The static libraries** that get linked in (`runtime/src/codegen/CMakeLists.txt`,
   `elm-kernel-cpp/`, `eco-kernel-cpp/`) — their per-target compile options.

Important: the everyday `ecor` allocator-test binary carries `-g` and
`-rdynamic`, but `ecor` is **not** built in the Docker image (only
`--target eco` is). Those flags therefore do **not** reach the shipped `eco`.

The Elm program itself (the compiler's own code) arrives as `eco-stage9.o`,
produced separately by `eco-boot-native --emit=obj` from `eco-compiler.mlir`.
That object carries its own `.eh_frame` CFI and `.llvm_stackmaps` section and is
where the frame-pointer policy in §4 is applied.

---

## 2. Compiler & linker parameters

### 2.1 Link line — `CMAKE_EXE_LINKER_FLAGS_INIT` (preset) + `eco` target

| Flag | What it does |
|---|---|
| `-static` | Fully static link — no `NEEDED` entries, no dynamic linker. Makes the binary **non-PIE (ET_EXEC)**, which is what lets lld resolve the `R_X86_64_64` relocations in `.llvm_stackmaps` at link time. (The dev/glibc build is a PIE, where lld rejects those relocs, so it falls back to GNU `ld`/bfd — `ECO_LINK_WITH_BFD`.) |
| `-stdlib=libc++` | Use LLVM libc++ as the C++ standard library instead of GNU libstdc++. |
| `-rtlib=compiler-rt` | Use compiler-rt builtins instead of `libgcc`. Because libgcc is gone, the `_Unwind_*` symbol collision that forces `--allow-multiple-definition` on the glibc static path never arises. |
| **`-unwindlib=libunwind`** | **Use LLVM libunwind as the unwinder** (not libgcc's `_Unwind_*`). This is the unwinder the GC root scan runs on. ⚠️ stack-trace/unwinding — see §3/§5. |
| `-lc++abi` | Explicitly pull in libc++abi; omitting it leaves libc++ vtables undefined. Provides the C++ ABI and exception personality routines. |
| `-fuse-ld=lld` | Link with lld. `ECO_LINK_WITH_BFD=OFF` in this preset, so `eco` inherits lld (the glibc build forces `bfd` for the PIE stackmap relocs). |
| `-Wl,--start-group … -Wl,--end-group` | Resolve circular symbol references among the kernel/runtime static archives (CMake 3.20 lacks `LINK_GROUP`). |
| `-Wl,--whole-archive ElmKernel_Utils -Wl,--no-whole-archive` | Force-link the `Order` GC-root registrar (`Eco_Kernel_Order_register_gc_roots`) even though nothing references it directly. |
| `pthread` / `m` / `eco::llvm_libunwind` | Threads, libm, and the libunwind static archive (`libunwind.a`, located by `cmake/LLVMLibunwind.cmake` under `ECO_STATIC`, with no rpath). |

**Deliberately *absent* under `ECO_STATIC_MUSL`** (these are the Stage-A glibc
extras, skipped here — `compiler/CMakeLists.txt:465-471`):
`-static-libstdc++`, `-static-libgcc`, `-Wl,--allow-multiple-definition`.

### 2.2 Compile flags on the libraries that make up `eco`

| Flag | Applied to | What it does |
|---|---|---|
| `-stdlib=libc++` (`CMAKE_CXX_FLAGS_INIT`) | all C++ TUs | Compile against libc++ headers. |
| **`-fexceptions`** | `EcoRuntimeStatic`, `EcoEntryStatic` (`runtime/src/codegen/CMakeLists.txt:577,601`); also `ecoc`, `EcoRunner`, `eco-boot-native`, test binaries | **Forces emission of `.eh_frame` CFI for every function, not just throwing ones.** ⚠️ unwinding — see §3/§5. |
| `cxx_std_20` | all kernel/runtime libs | C++20. |
| `-UNDEBUG` | all kernel/runtime libs (`elm-kernel-cpp:341`, `eco-kernel-cpp:259`, `…:577,601`) | Keep `assert()` live even in a Release build. |
| *(implicit)* `-fasynchronous-unwind-tables` | clang default on x86-64 | Async unwind tables (CFI) on by default — independent of `-g`. This is what gives non-throwing functions usable `.eh_frame`. |
| `CMAKE_BUILD_TYPE=Release` → `-O3 -DNDEBUG` | global | `-UNDEBUG` above overrides `NDEBUG` for the kernel/runtime libs. |

`ECO_GC_DEBUG`, `ECO_HEAP_VALIDATE`, `ECO_LOWERING_VALIDATION`, and
`ECO_HEAP_TRACE` are all **OFF** in this Release build (see §5.2 — this matters
because the unwinder/stackmap diagnostics are compiled out).

### 2.3 Frame pointers — applied via an LLVM function attribute, not a CMake flag

There is **no** `-fno-omit-frame-pointer` in the musl path (it appears only in
the `ninja-clang-lld-linux-profile` preset, for `perf`). Frame pointers are
instead force-enabled on the **Elm-generated code** by injecting the LLVM
function attribute `"frame-pointer"="all"` during the backend pipeline:

```cpp
// runtime/src/codegen/EcoBackend.cpp:82
// Force frame pointers so libunwind can walk JIT/AOT frames for GC root
// discovery.
if (opts.addFramePointerAttr) {
    for (Function &F : m)
        if (!F.isDeclaration())
            F.addFnAttr("frame-pointer", "all");
}
```

This is enabled (`needsFramePointerAttr = true`) at **every native execution
site**, in both the static and dynamic builds:

- `eco-boot.cpp:674` — **EmitObj path, which builds `eco-stage9.o` (the `eco`
  binary itself)**
- `eco-boot.cpp:608` — EmitLLVM text path
- `EcoNativeDriver.cpp:223` — in-process AOT (the `Eco.NativeDriver.lowerAndLink`
  intrinsic)
- `EcoRunner.cpp:204` — JIT
- `ecoc.cpp:277` — execute path (`:232` sets it `false` only for pure IR dump)

**Consequence:** frame pointers are load-bearing, not optional. See §4.

### 2.4 Dockerfile post-link

| Step | What it does |
|---|---|
| `strip -s` (`docker/static-build.Dockerfile:156`) | Strip all symbols + `.debug_*`. Keeps `SHF_ALLOC` sections (`.eh_frame`, `.eh_frame_hdr`, `.llvm_stackmaps`) and the section header table, so unwinding and stackmap discovery still work — but **function names for backtraces are gone**. |
| `readelf -d … | grep NEEDED` → hard fail | Asserts the binary has zero dynamic dependencies. |

---

## 3. Flags touching exceptions / stack traces / frame pointers (highlighted)

- **`-unwindlib=libunwind`** (link) — the GC's entire stack-root-scanning
  mechanism runs on libunwind (`unw_getcontext` / `unw_init_local` / `unw_step`
  / `unw_get_reg` in `runtime/src/allocator/StackUnwind.cpp`). The single
  most safety-critical flag for GC correctness in this report.
- **`-fexceptions` on `EcoRuntimeStatic` / `EcoEntryStatic`** (compile) — the
  *protective* flag: it guarantees the C++ runtime frames the GC must unwind
  *through* (the `eco_alloc_*` → `minorGC`/`majorGC` →
  `collectStackRootsFromStackMap` chain) carry `.eh_frame` CFI, so libunwind can
  restore callee-saved registers across them.
- **`"frame-pointer"="all"` LLVM attribute** (codegen, §2.3) — forces a stable
  RBP frame on every Elm function specifically so libunwind can walk them for
  GC root discovery. Applied in both static and dynamic builds.
- **`strip -s`** (post-link) — strips symbols but keeps `.eh_frame`; backtraces
  lose names, unwinding survives.
- **Frame pointers on the *C++ runtime* are NOT forced** — those frames get only
  `-fexceptions` CFI, no guaranteed frame pointer. This is the refined residual
  risk in §5.1.

---

## 4. The frame-pointer / libunwind dependency (why it is load-bearing)

The root scan (`ThreadLocalHeap::collectStackRootsFromStackMap`,
`runtime/src/allocator/ThreadLocalHeap.cpp:636`) does, for each `Indirect`
stackmap location in a frame:

```cpp
uintptr_t base = 0;
if (!cur.getRegister(loc.dwarfRegNum, base)) continue;   // libunwind register read
uintptr_t addr = base + static_cast<int32_t>(loc.offset);
auto* slot = reinterpret_cast<HPointer*>(addr);          // the GC root slot
```

`base` is a register value libunwind **reconstructs for that frame**. The slot
address is `base + offset`. After a moving collection the GC reads `*slot`,
evacuates the object, and **writes the forwarded HPointer back into `*slot`**.
If `base` is wrong by even a little, `slot` points at unrelated stack memory and
the GC clobbers it with a heap pointer — i.e. *a root pointer is rewritten
incorrectly post-GC*, the exact corruption class under investigation.

With `"frame-pointer"="all"`:

- Every Elm function has a standard `push rbp; mov rbp,rsp` prologue, so RBP is a
  stable frame base.
- Statepoint spill slots are anchored to a base libunwind can always recover
  (RBP chain + simple CFI), and libunwind's RBP-chain fallback stays valid even
  where DWARF CFI is thin.

Without frame pointers (`-O2/-O3` omit):

- RBP becomes a general-purpose register; slots are RSP-relative with RSP moving
  through the function. The stackmap offset is relative to the register value
  **at the safepoint**, but libunwind reconstructs registers from CFI at the
  **return address**; any mismatch makes `base + offset` land on the wrong slot.
- If CFI lookup fails for *any* frame in the chain (including intervening C++
  runtime frames), libunwind's fallback assumes an RBP chain that no longer
  exists, producing garbage register values.

This matches the project's empirical experience that dropping frame pointers
breaks libunwind-based GC scanning. Frame pointers are required, not optional,
and are deliberately forced on Elm code in all native paths.

**Note for the static-build analysis:** because the frame-pointer attribute is
applied identically in static and dynamic builds (the EmitObj path always sets
`needsFramePointerAttr=true`), the static binary's **Elm** frames are not the
differentiator. The static-specific exposure is in the C++ runtime frames the
unwinder steps through — see §5.1.

---

## 5. Static-build-specific risks

These are differences between the dev/glibc dynamic build and the static MUSL
build that bear on GC/unwinder correctness, ordered by likelihood × severity.

### 5.1 (Primary) CFI coverage of the C++ runtime frames libunwind steps through

The GC root scan must unwind *through* the C++ frames on the GC-triggering call
stack (`eco_alloc_*` → `ThreadLocalHeap::minorGC`/`majorGC` →
`collectStackRootsFromStackMap`, plus libc++ `std::vector::push_back` in
`StackMapRoots` and `std::make_unique` for the `Context`/`Cursor` objects, plus
pthread/musl) to (a) reach the Elm frames and (b) **recover callee-saved
registers** (RBX, R12–R15, RBP) that an Elm frame's `Indirect` location may use
as `dwarfRegNum`.

In the static MUSL build those frames come from a **different toolchain stack**
than the dev build: musl libc, libc++/libc++abi, compiler-rt, and a
possibly-different-version LLVM libunwind — versus glibc, libstdc++, libgcc in
the dev build. The runtime libs get `-fexceptions` (so CFI is present), but
frame pointers are *not* forced on them. If a callee-saved register is restored
incorrectly across one of these frames (thin/synchronous-only CFI, or a libc++
TU compiled with frame pointer omitted), the Elm frame's `base` register is
wrong → wrong root slot → post-GC clobber. **This is the prime suspect for a
static-only GC corruption.**

*Verification:* dump `.eh_frame` for the runtime/libc++/musl frames on a real GC
stack (`readelf --debug-dump=frames`, or `llvm-dwarfdump --eh-frame`) and
confirm callee-saved register rules exist for the exact return addresses the
unwinder visits.

### 5.2 Silent failure mode — `ECO_GC_DEBUG=OFF` in Release

Every diagnostic in the unwinder/scan path is `#if ECO_GC_DEBUG`:
`unw_step failed` and `unw_get_reg failed` (`StackUnwind.cpp:50,62,75`), "no
stack map records found" (`ThreadLocalHeap.cpp:639`), and the per-root /
per-range dumps (`ThreadLocalHeap.cpp:709-734`). The musl preset is
`CMAKE_BUILD_TYPE=Release`, so `ECO_GC_DEBUG` is **OFF** and all of this is
compiled out. If unwinding partially fails in the static binary, `unw_step`
returning ≤ 0 just ends the walk early and the upper frames' roots silently
vanish — **no output at all**.

*Recommendation:* a build (or a small always-on counter independent of
`ECO_GC_DEBUG`) that reports frames-walked vs records-matched vs roots-pushed,
run against the static binary, would immediately distinguish "libunwind isn't
matching Elm frames" from a genuine pointer-rewrite bug.

### 5.3 libunwind *version* skew and `unw_step` IP semantics

`findRecord(ip + kIpToReturnAddressBias)` with `kIpToReturnAddressBias = 0`
(`ThreadLocalHeap.cpp:659,672`) assumes `cur.ip()` for a non-top frame returns
the **return address**, which is the key LLVM uses for statepoint records. The
dev image and the Docker image build libunwind from **different LLVM trees**
(dev `/opt/llvm-mlir` vs the Dockerfile's pinned LLVM 21.1.4). If the static
build's libunwind returns the *call-site* address instead of the return address
for non-top frames, **every Elm-frame lookup misses**, no `Indirect` roots are
collected, and live objects are swept. The bias is documented as "verified
empirically" — but only for the dev unwinder.

### 5.4 `.eh_frame_hdr` / `dl_iterate_phdr` discovery in a static binary

LLVM libunwind locates each PC's CFI via `dl_iterate_phdr`, looking for the
`PT_GNU_EH_FRAME` program header (the `.eh_frame_hdr`). In a `-static` musl
binary this depends on (a) lld emitting `--eh-frame-hdr` + the
`PT_GNU_EH_FRAME` segment (default for executables, but worth confirming) and
(b) musl's static `dl_iterate_phdr` synthesizing the main-program entry. If
either is missing, `unw_step` fails at the first frame → see §5.2.

*Verification:* `readelf -l eco | grep GNU_EH_FRAME` on the shipped binary.

### 5.5 Stackmap discovery by section-header name from `/proc/self/exe`

`initStackMapFromSelf` (`runtime/src/codegen/eco_entry.cpp:33`) finds
`.llvm_stackmaps` by parsing ELF section headers out of `/proc/self/exe`, not via
a linker `__start_/__stop_` symbol. `strip -s` keeps section headers, so it
works today. But any heavier strip (`--strip-section-headers`, `sstrip`, or an
aggressive `llvm-strip`) would make `hasRecords()` return `false`, after which
the GC silently tracks **no** stack roots (§5.2). A linker-defined
`__start___llvm_stackmaps`-style anchor (kept with `__attribute__((used))`)
would be far more robust than `/proc/self/exe` parsing.

### 5.6 Not a bug (checked) — the `loadBase=0` / non-PIE relocation path

The `loadBase=0` handling (`eco_entry.cpp:94`, `StackMap.cpp:145`) is consistent
across both builds. Non-PIE static → `dlpi_addr == 0` and link-time-absolute
stackmap function addresses; PIE glibc → loader-relocated absolute addresses.
Both end with absolute function addresses, and `parse(..., loadBase=0)` is
correct for each. No action needed.

---

## 6. Static vs dynamic — side-by-side flag comparison

The dynamic column is the default dev preset `ninja-clang-lld-linux`; the static
column is `ninja-clang-lld-linux-musl`. Both produce the same `eco` binary
target, so this compares that build. "✅ match" / "❌ differ" is relative to the
*effective* setting that reaches the binary.

### 6.1 Configure / preset cache variables

| Setting | Static MUSL | Dynamic | |
|---|---|---|---|
| `CMAKE_C_COMPILER` | `clang` | `clang` | ✅ match |
| `CMAKE_CXX_COMPILER` | `clang++` | `clang++` | ✅ match |
| Generator | `Ninja` | `Ninja` | ✅ match |
| `CMAKE_BUILD_TYPE` | `Release` | `RelWithDebInfo` | ❌ differ |
| `CMAKE_CXX_FLAGS_INIT` | `-stdlib=libc++` | *(unset)* → libstdc++ | ❌ differ |
| `CMAKE_EXE_LINKER_FLAGS_INIT` | `-static -stdlib=libc++ -rtlib=compiler-rt -unwindlib=libunwind -lc++abi -fuse-ld=lld` | `-fuse-ld=lld` | ❌ differ |
| `CMAKE_SHARED_LINKER_FLAGS_INIT` | *(unset)* | `-fuse-ld=lld` | ❌ differ |
| `CMAKE_PREFIX_PATH` | `/opt/llvm-mlir` | *(unset; discovered)* | ❌ differ |
| `LLVM_INSTALL_PREFIX` | `/opt/llvm-mlir` | *(unset; discovered)* | ❌ differ |
| `ECO_STATIC` | `ON` | `OFF` (default) | ❌ differ |
| `ECO_STATIC_MUSL` | `ON` | `OFF` (default) | ❌ differ |
| `ECO_LINK_WITH_BFD` | `OFF` | `ON` (default) | ❌ differ |

### 6.2 Build type → resulting global compile flags

| Setting | Static MUSL | Dynamic | |
|---|---|---|---|
| Optimization | `-O3` (Release default) | `-O2` (`…_RELWITHDEBINFO`) | ❌ differ |
| Debug info `-g` | *(none)* | `-g` | ❌ differ |
| `NDEBUG` (global) | `-DNDEBUG` (Release default) | `-UNDEBUG` (preset override) | ❌ differ¹ |
| C++ standard library | libc++ (via `-stdlib=libc++`) | libstdc++ (default) | ❌ differ |

¹ The global default differs, but per-target `-UNDEBUG` (§6.5) re-enables asserts
on the kernel/runtime libs in *both* builds, so the asserts that matter end up
live either way.

### 6.3 Linker flags — `eco` executable

| Setting | Static MUSL | Dynamic | |
|---|---|---|---|
| Configured linker (preset) | lld (`-fuse-ld=lld`) | lld (`-fuse-ld=lld`) | ✅ match |
| **Effective linker for `eco`** (after `ECO_LINK_WITH_BFD`) | **lld** (BFD off) | **bfd** (`-fuse-ld=bfd` added) | ❌ differ |
| Linkage | `-static` (non-PIE, ET_EXEC) | dynamic (PIE) | ❌ differ |
| `-rtlib` (compiler builtins) | `compiler-rt` | `libgcc` (default) | ❌ differ |
| `-unwindlib` (EH unwinder) | `libunwind` | `libgcc` (default) | ❌ differ² |
| `-stdlib` at link | `libc++` + `-lc++abi` | libstdc++ (`-lstdc++` added) | ❌ differ |
| `-static-libstdc++ -static-libgcc` | no (skipped under MUSL) | no (only Stage-A glibc static) | ✅ match (both off) |
| `-Wl,--allow-multiple-definition` | no | no | ✅ match (both off) |
| `--start-group/--end-group`, `--whole-archive ElmKernel_Utils` | yes | yes | ✅ match |
| `pthread`, `m` | yes | yes | ✅ match |
| Bare `-lcurl -lssl -lcrypto -lzip` | no (vendored/static) | yes (dynamic) | ❌ differ |

² Both builds *also* link LLVM libunwind explicitly (`eco::llvm_libunwind`) for
the GC stack scan. The difference is the **C++ exception** unwinder: static
routes EH through LLVM libunwind too; dynamic routes EH through libgcc's
`_Unwind_*` while the GC scan still uses LLVM libunwind — i.e. dynamic
effectively has two unwinder implementations present.

### 6.4 libunwind resolution (`cmake/LLVMLibunwind.cmake`, gated on `ECO_STATIC`)

| Setting | Static MUSL | Dynamic | |
|---|---|---|---|
| Library kind | `libunwind.a` (static archive) | `libunwind.so` (shared) | ❌ differ |
| `-Wl,-rpath,<dir>` | no (static needs none) | yes | ❌ differ |
| Refuses nongnu libunwind | yes | yes | ✅ match |

### 6.5 Per-target compile options (kernel/runtime static libs) — identical logic

| Setting | Static MUSL | Dynamic | |
|---|---|---|---|
| `cxx_std_20` | yes | yes | ✅ match |
| `-fexceptions` (EcoRuntimeStatic, EcoEntryStatic, ecoc, EcoRunner, eco-boot-native) | yes | yes | ✅ match |
| `-UNDEBUG` (all kernel/runtime libs) | yes | yes | ✅ match |
| `-fasynchronous-unwind-tables` (clang default) | yes | yes | ✅ match |

### 6.6 Codegen / LLVM attributes (Elm-generated code) — identical

| Setting | Static MUSL | Dynamic | |
|---|---|---|---|
| `"frame-pointer"="all"` attr (`needsFramePointerAttr=true`) | yes | yes | ✅ match |
| RS4GC statepoint pipeline | yes | yes | ✅ match |
| `.llvm_stackmaps` emission | yes | yes | ✅ match |

### 6.7 Top-level option-gated compile definitions — identical

| Setting | Static MUSL | Dynamic | |
|---|---|---|---|
| `ECO_GC_DEBUG` | OFF (Release, not Debug) | OFF (RelWithDebInfo, not Debug) | ✅ match (both OFF) |
| `ECO_LOWERING_VALIDATION` | OFF (default) | OFF (default) | ✅ match |
| `ECO_HEAP_VALIDATE` | OFF (default) | OFF (default) | ✅ match |
| `ECO_HEAP_TRACE` | OFF (default) | OFF (default) | ✅ match |

### 6.8 Post-build (Docker only)

| Setting | Static MUSL | Dynamic | |
|---|---|---|---|
| `strip -s` | yes (`static-build.Dockerfile:156`) | no | ❌ differ |
| `readelf -d` zero-NEEDED gate | yes | no | ❌ differ |

### 6.9 Where they match

The **correctness-critical layers are identical** between the two builds:

- Same compilers (clang/clang++), same configured base linker (lld), same Ninja
  generator.
- Same per-target compile contract on the runtime/kernel libs: `cxx_std_20`,
  **`-fexceptions`** (CFI on every function), `-UNDEBUG` (asserts live), default
  async unwind tables.
- Same codegen for Elm code: **`"frame-pointer"="all"`**, RS4GC statepoints,
  `.llvm_stackmaps`.
- Same GC/validation gating: `ECO_GC_DEBUG`, `ECO_HEAP_VALIDATE`,
  `ECO_LOWERING_VALIDATION`, `ECO_HEAP_TRACE` all OFF in both.
- Both link LLVM libunwind for the GC scan (and refuse to mix in nongnu
  libunwind).

So everything the GC stack-root scan depends on at the *source/codegen* level —
frame pointers on Elm frames, CFI on runtime frames, stackmaps, the libunwind
API — is configured the same way in both builds.

### 6.10 Where they differ

All differences are in the **toolchain/runtime substrate and link model**, not
in the source-level GC contract:

1. **C++ runtime stack:** libc++ + libc++abi + compiler-rt (static) vs
   libstdc++ + libgcc (dynamic). This changes the actual `.eh_frame` CFI of the
   *intervening C++ frames* the unwinder steps through — the §5.1 risk.
2. **Unwinder for exceptions:** LLVM libunwind everywhere (static) vs
   libgcc-`_Unwind` for EH alongside LLVM libunwind for GC (dynamic).
3. **Effective `eco` linker:** lld (static) vs **bfd** (dynamic), driven by
   `ECO_LINK_WITH_BFD`, because lld rejects the `.llvm_stackmaps` `R_X86_64_64`
   relocs in a PIE but accepts them in the non-PIE static layout.
4. **Link model:** `-static` non-PIE ET_EXEC (static) vs PIE + shared libs
   (dynamic) → different stackmap relocation timing (link-time-absolute vs
   loader-relocated; both end absolute, §5.6 cleared).
5. **libunwind linkage:** `libunwind.a` no-rpath (static) vs `libunwind.so` +
   rpath (dynamic), and the version may differ (dev `/opt/llvm-mlir` vs Docker
   LLVM 21.1.4) — the §5.3 risk.
6. **Optimization / debug:** `-O3`, no `-g`, stripped (static) vs `-O2 -g`,
   unstripped (dynamic) → static has no symbol names for backtraces (unwinding
   still works; `.eh_frame` survives strip).

**Net:** the build contract that keeps GC root scanning correct is byte-for-byte
the same in both builds. Every difference is in the substrate libunwind must
traverse and the link model — which is exactly why the residual static-only GC
risk lives in the C++ runtime frames' CFI (§5.1) and in libunwind version skew
(§5.3), not in the Elm code or the GC's own configuration.

---

## 7. Summary

- The static MUSL binary is `-static` (non-PIE) + libc++ + compiler-rt + LLVM
  libunwind + lld, with `-fexceptions` on the runtime/entry libs and
  `"frame-pointer"="all"` forced onto all Elm code by the backend.
- Frame pointers are **required** for libunwind-based GC root scanning; they are
  injected via an LLVM function attribute (not a CMake flag) and applied
  identically in static and dynamic builds. The earlier suggestion that they
  were unused/unneeded was incorrect.
- The static-build-specific GC risk has narrowed to the **C++ runtime frames the
  unwinder traverses** (§5.1), compounded by the build's **silent failure mode**
  (§5.2) and possible **libunwind version skew** (§5.3). §5.4–§5.5 are latent
  discovery fragilities; §5.6 is cleared.
- Quickest path to a verdict: enable the frames-walked/records-matched/roots
  counter (independent of `ECO_GC_DEBUG`) and run the static binary on a
  GC-heavy workload, plus the §5.1/§5.3/§5.4 readelf/dwarfdump checks.
