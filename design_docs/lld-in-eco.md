# Embedding `lld` inside `eco`

A report on what it would take to replace the spawned `/usr/bin/ld`
subprocess in `EcoNativeDriverStatic::linkExecutable` with an in-process
call to `lld::elf::link()`, producing a single self-contained `eco` ELF
that does not depend on any system linker at runtime.

## TL;DR

- **Embedding `lld` is possible** and is what Phase 3 of the Stage 9
  plan originally called for. We backed off only because the
  `/opt/llvm-mlir` LLVM 21.1.4 install on this host doesn't ship lld
  headers / static libs.
- **The one real obstacle is the `.llvm_stackmaps` relocations.** lld
  rejects the `R_X86_64_64` absolute relocations the Elm-compiled
  object carries (GC safepoint records of function-entry addresses) in
  PIE mode. GNU ld.bfd accepts them with a `DT_TEXTREL` warning;
  switching the embedded linker doesn't change lld's policy, so this
  has to be resolved on our side.
- **None of the options touch RS4GC correctness.** The 8-byte absolute
  function pointer in the stackmap binary format is a *representation
  choice*, not a GC-semantics requirement.
- **Recommended path:** ship option 1 (`-z notext`) first — it's a
  one-line change that gives us an all-in-one binary with the same
  TEXTREL we already tolerate. Layer option 3 (fix StackMaps to emit
  PC-relative encoding) on top later for a properly W^X PIE.

---

## 1. Where we are today (post Phase 3)

`EcoNativeDriverStatic::linkExecutable` invokes `/usr/bin/ld` via
`llvm::sys::ExecuteAndWait`. CMake discovers, at configure time:

| Path | How found | Use |
|---|---|---|
| `/usr/bin/ld` | `find_program(ECO_SYSTEM_LD ld REQUIRED)` | the linker |
| `/lib64/ld-linux-x86-64.so.2` | hardcoded platform ABI constant | dynamic linker |
| `Scrt1.o`, `crti.o`, `crtn.o`, `crtbeginS.o`, `crtendS.o` | `clang -print-file-name=…` | PIE crt prologue/epilogue |
| `libgcc.a` | `clang -print-file-name=libgcc.a` | unwinder helpers |
| `<gcc libdir>` | `dirname(libgcc.a)` | `-L` |
| library search dirs (multilib `/lib`, `/usr/lib`, etc.) | parse `clang -print-search-dirs` | `-L` for system `-lc` etc. |

All baked into `runtime/src/codegen/include/eco/EcoBootConfig.h`. The
link command itself is hand-built:

```
ld -pie --eh-frame-hdr -dynamic-linker /lib64/ld-linux-x86-64.so.2 \
   -L<libdirs> Scrt1.o crti.o crtbeginS.o \
   <user.o> \
   --start-group <project static archives> \
              --whole-archive ElmKernel_Utils.a --no-whole-archive \
              <other ElmKernel/EcoKernel> --end-group \
   -lpthread -lm -lstdc++ -lc -lcurl -lssl -lcrypto -lzip \
   -lgcc_s libgcc.a -lgcc_s \
   libunwind.so \
   crtendS.o crtn.o \
   -rpath <libunwind dir>
```

The *only* externally-discovered tool we actually invoke at AOT-link
time is `ld`. Everything else (paths, crt files, libraries) lives in
the generated config header.

This means **the missing piece for an all-in-one `eco` is replacing
that one `ExecuteAndWait` call with `lld::elf::link`**. The remaining
external dependencies (`libcurl.so`, `libssl.so`, `libcrypto.so`,
`libc.so`, etc.) are dynamic libraries the *user binaries* link
against; they're loaded by the dynamic linker at runtime and aren't
something we'd statically embed into `eco`.

---

## 2. The LLVM API for embedded lld

`lld` ships as both a CLI binary and a library. The relevant header
is `lld/Common/Driver.h` (would be at
`/opt/llvm-mlir/include/lld/Common/Driver.h` if lld were enabled).

The pre-LLVM-17 entry point:

```cpp
namespace lld::elf {
bool link(llvm::ArrayRef<const char *> args,
          llvm::raw_ostream &stdoutOS,
          llvm::raw_ostream &stderrOS,
          bool exitEarly,
          bool disableOutput);
}
```

The LLVM 17+ unified entry point (which is what LLVM 21 ships):

```cpp
namespace lld {
enum Flavor { Invalid, Gnu, WinLink, Darwin, Wasm };
struct DriverDef {
    Flavor f;
    Driver d;   // function pointer, signature like elf::link()
};
struct Result { int retCode; bool canRunAgain; };
Result lldMain(llvm::ArrayRef<const char *> args,
               llvm::raw_ostream &stdoutOS,
               llvm::raw_ostream &stderrOS,
               llvm::ArrayRef<DriverDef> drivers);
}
```

You pass the same `argv` you'd give `ld.lld` on the command line:

```cpp
std::vector<const char *> argv;
argv.push_back("ld.lld");      // argv[0] for lld's own diagnostics
for (auto &a : args)
    argv.push_back(a.data());

lld::Result r = lld::lldMain(argv,
                             llvm::outs(), llvm::errs(),
                             {{lld::Gnu, &lld::elf::link}});
if (!r.canRunAgain) {
    // lld 14 had global state; 15+ supports re-entry.
}
int rc = r.retCode;
```

The relevant lld static libraries to link:

- `lldELF` — the ELF backend (what we need).
- `lldCommon` — shared driver utilities (argument parsing, diagnostic
  state).
- *(skipped)* `lldMachO`, `lldCOFF`, `lldWasm`, `lldMinGW` — other
  output formats. Not needed.

Plus lld's transitive LLVM dependencies, all of which are already on
`EcoNativeDriverStatic`'s link line: `LLVMSupport`, `LLVMObject`,
`LLVMBitReader`, `LLVMCore`, `LLVMMC`, `LLVMBinaryFormat`,
`LLVMTargetParser`, `LLVMDemangle`.

Approximate binary-size cost: ~20–30 MB added to the current 217 MB
`eco`. Negligible relative to the MLIR/LLVM static libs we already
carry.

---

## 3. What's blocking lld today

The Elm-compiled object (`eco-stage9.o`, produced by
`eco-boot-native --emit=obj`) contains an `.llvm_stackmaps` section
that GC needs at runtime. Inside, V3 format (see
[LLVM StackMaps docs](https://llvm.org/docs/StackMaps.html)):

```
Header: version=3, …
NumFunctions
NumConstants
NumRecords
StkSizeRecords[NumFunctions]:
    uint64 FunctionAddress       ← THE PROBLEM: R_X86_64_64 reloc here
    uint64 StackSize
    uint64 RecordCount
Constants[NumConstants]: uint64
StkMapRecords[NumRecords]:
    uint64 PatchPointID
    uint32 InstructionOffset     ← bytes from FunctionAddress to safepoint
    uint16 Reserved
    uint16 NumLocations
    Location[NumLocations]:      ← register / stack-slot descriptors,
        Type, Size, Reg, Offset    where the live GC roots are
    uint16 NumLiveOuts
    LiveOuts[NumLiveOuts]
```

The 8-byte `FunctionAddress` field is emitted by LLVM's
`lib/CodeGen/StackMaps.cpp` as
`emitSymbolValue(funcSym, /*size=*/8)`. On x86-64 that lowers to
`R_X86_64_64` against the function's local symbol.

When lld links a PIE binary, it does:

```
ld.lld: error: relocation R_X86_64_64 cannot be used against local
symbol; recompile with -fPIC
>>> defined in eco-stage9.o
>>> referenced by LLVMDialectModule
>>>               eco-stage9.o:(.llvm_stackmaps+0x178)
```

Why lld is strict here:

- `R_X86_64_RELATIVE` (which the dynamic loader can apply at load
  time) requires the symbol to be in `.dynsym`. Local function
  symbols aren't dynamic.
- `R_X86_64_64` against a local symbol in read-only data needs the
  loader to make the page temporarily writable, apply the
  relocation, then re-mprotect. That's `DT_TEXTREL` — a security and
  startup-cost hit ld.lld considers undesirable by default.

GNU ld.bfd takes the pragmatic stance: emit the relocation,
mark the binary with `DT_TEXTREL`, warn:

```
ld.bfd: warning: relocation in read-only section `.llvm_stackmaps'
ld.bfd: warning: creating DT_TEXTREL in a PIE
```

This is what the current `eco` build (via CMake `-fuse-ld=bfd`) does
and what `linkExecutable` produces. The user gets a working PIE binary
with a `DT_TEXTREL` flag in the dynamic section.

---

## 4. What's load-bearing vs representational

The user asked: "Can we fix stack maps? This is essential for RS4GC
and C++ GC stack roots and so on, correct?"

Let's separate concerns.

**Essential for RS4GC and GC correctness:**

- The `.llvm_stackmaps` section *exists* and is read by the runtime
  (`eco_entry.cpp::initStackMapFromSelf` → `StackMap::parse`).
- Each safepoint can be looked up by some key the runtime has access
  to at safepoint time — currently the return address into a function.
- The `Location[]` records (register / stack-slot / derived-pointer
  descriptors) accurately describe where the live GC roots are at that
  safepoint.

**Representational, not load-bearing:**

- The fact that `FunctionAddress` is an 8-byte absolute pointer.
- The fact that the runtime gets the absolute PC by adding
  `FunctionAddress + InstructionOffset` rather than
  `SectionBase + FuncRelOffset + InstructionOffset`.

If we change the encoding consistently on both ends — LLVM's emitter
and our runtime parser — the GC keeps working. RS4GC itself runs
*before* the stackmap is emitted: it inserts `gc.statepoint` /
`gc.relocate` IR ops; the AsmPrinter/StackMaps phase then serializes
those into the section. RS4GC doesn't care how the serialization
encodes function pointers.

---

## 5. Four options, ranked

### Option 1: pass `-z notext` to lld

```cpp
argv.push_back("-z");
argv.push_back("notext");
```

`lld::elf::link()` accepts `-z notext` just like ld.bfd's
`--allow-multiple-definition`-style overrides. It produces a binary
with `DT_TEXTREL` set — exactly what we get from ld.bfd today.

**Effort:** 1 line of C++ in `linkExecutable`, plus the
LLVM-rebuild-with-lld and CMake-link-against-lld changes covered
below.

**Pros:**
- No LLVM patch. No runtime patch.
- Security profile identical to today (already accepting TEXTREL).
- Unblocks "all-in-one `eco` binary" immediately.

**Cons:**
- We continue carrying `DT_TEXTREL`. Slightly slower binary startup
  (loader has to do the relocation pass), some loader-warning chatter
  on some distros, technically a W^X violation during load.
- Doesn't fix the underlying issue — just chooses the same workaround
  ld.bfd was choosing for us.

### Option 2: switch eco's output to non-PIE

`-no-pie` in the link line. lld accepts absolute relocations in
non-PIE binaries because there's no load-time fixup needed.

**Effort:** 1 line.

**Pros:**
- Trivial.

**Cons:**
- Loses ASLR for `eco` itself and (if applied to the linker-driver
  flags too) for every user binary `eco` produces. For a compiler we
  ship to users, removing ASLR for everything they compile is a
  worse story than TEXTREL.
- Distros increasingly require PIE for packaged binaries.

**Verdict:** skip.

### Option 3: fix StackMaps to emit PC-relative encoding (LLVM patch + runtime parser update)

The proper fix. Two coordinated changes:

#### 3a. LLVM patch

In `lib/CodeGen/StackMaps.cpp` (roughly the `emitFunctionFrameRecords`
or equivalent function — name varies by LLVM version), replace
absolute emission with PC-relative emission:

```cpp
// Before (current):
OutStreamer->emitSymbolValue(FuncSym, /*size=*/8);

// After (PIC-safe):
const MCExpr *RelExpr = MCBinaryExpr::createSub(
    MCSymbolRefExpr::create(FuncSym, OutContext),
    MCSymbolRefExpr::create(StackMapSectionStartSym, OutContext),
    OutContext);
OutStreamer->emitValue(RelExpr, /*size=*/4);  // R_X86_64_PC32, link-time
```

This generates an `R_X86_64_PC32` relocation that the linker fully
resolves at link time, leaving the read-only data section
load-time-fixup-free. No runtime relocation, no TEXTREL.

Format change: `FunctionAddress` shrinks from 8 bytes to 4 bytes. The
field semantically becomes "byte offset from the start of
`.llvm_stackmaps`, relative" — *not* "absolute function pointer."

To avoid breaking other LLVM users sharing the install, gate the
behavior on a flag:

- New `-stackmap-encoding={absolute,pic}` `cl::opt`, defaulting to
  `absolute` (backward-compatible).
- Or bump format version to V4 with the new encoding and let
  consumers pick by emitting `version=4` in the header.

Patch size: roughly 20–40 lines in `lib/CodeGen/StackMaps.cpp`,
`lib/CodeGen/AsmPrinter/AsmPrinter.cpp` (which calls into
StackMaps), plus a doc update in `docs/StackMaps.rst` and a version
bump.

Carrying the patch in `/opt/llvm-mlir`: since `/opt/llvm-mlir` is
already a custom LLVM build (we control it for the libunwind
inclusion), adding one more local patch is incremental. The patch
is targeted enough that rebasing across LLVM releases is low-effort.

#### 3b. Runtime parser update

`runtime/src/allocator/StackMap.cpp::parse` currently reads:

```cpp
StkSizeRecord {
    uint64_t functionAddress;       // absolute PC
    uint64_t stackSize;
    uint64_t recordCount;
};
```

After 3a's encoding change, it reads:

```cpp
StkSizeRecord {
    uint32_t functionOffset;        // bytes from section start
    uint32_t padding_or_other_data;
    uint64_t stackSize;
    uint64_t recordCount;
};

// When matching a PC against a function:
uintptr_t functionAddress =
    reinterpret_cast<uintptr_t>(stackmapSectionBase) + functionOffset;
```

The runtime already knows `stackmapSectionBase` —
`eco_entry.cpp::initStackMapFromSelf` reads the section's address via
`dl_iterate_phdr` and passes it as `loadBase` to
`StackMap::parse`. The plumbing exists.

If we keep the field 8 bytes wide (uint64) but interpret the value as
section-relative offset, the parser change is even smaller — no
struct layout change, just a reinterpret in the lookup path.

Patch size: ~10 lines in `runtime/src/allocator/StackMap.cpp`, plus
matching tests in `test/allocator/`.

#### Combined effort and tradeoffs

**Effort:** Maybe a day of work for someone familiar with both LLVM's
CodeGen and our runtime. Pattern after `.eh_frame`'s
`FDE.initial_location_offset` (4-byte PC-relative, same problem
domain, accepted upstream form).

**Pros:**
- No `DT_TEXTREL`. Proper W^X PIE binary.
- lld is happy without `-z notext`.
- Smaller `.llvm_stackmaps` section (4-byte fields instead of 8-byte).
- Upstream-able: GC users in PIE binaries (Erlang BEAM-on-LLVM,
  Pyston, LuaJIT-on-LLVM experiments, etc.) hit this exact problem.

**Cons:**
- Requires the LLVM patch to be applied to `/opt/llvm-mlir`'s LLVM
  21 build. Local patch maintenance until upstreamed.
- Touches the GC's stackmap reader — a part of the runtime we'd
  rather leave alone. Needs careful testing across all our existing
  binaries (ecor, ecoc, EcoRunner, eco-boot-native, eco) because all
  of them read this section.

### Option 4: export all function symbols dynamically

`--export-dynamic-symbol=<name>` for every Elm function. The linker
moves them to `.dynsym`. `R_X86_64_64` against a dynamic symbol *can*
be relocated at load time without TEXTREL (via lazy binding or
eager `R_X86_64_GLOB_DAT`).

**Effort:** 5–10 lines in `linkExecutable` to enumerate symbols and
append `--export-dynamic-symbol=…` for each.

**Pros:**
- No LLVM patch.
- No runtime patch.

**Cons:**
- Symbol-table explosion. Stage 5 produces tens of thousands of
  monomorphized functions; promoting all to `.dynsym` measurably
  bloats the binary (tens of MB of strings + symbol entries) and
  slows startup as the loader resolves them.
- Exposes implementation symbols externally. Anyone with `ldd` /
  `objdump -T` on `eco` sees the full internal function list.
- The dynamic-symbol approach interacts poorly with `--gc-sections`
  and dead-code elimination — externally visible symbols can't be
  stripped.

**Verdict:** skip.

---

## 6. Recommended path

For shipping a single all-in-one `eco`:

### Step 1: rebuild `/opt/llvm-mlir` with lld enabled

Out-of-tree work, but it's the prerequisite. Re-run the LLVM build
with `LLVM_ENABLE_PROJECTS=mlir;lld` (or
`LLVM_ENABLE_RUNTIMES=libunwind` + `LLVM_ENABLE_PROJECTS=mlir;lld`).
Result: `/opt/llvm-mlir/include/lld/Common/Driver.h`,
`/opt/llvm-mlir/lib/liblldELF.a`, `liblldCommon.a`.

Effort: ~30 minutes of build time. No code change.

### Step 2: link lld libraries into `EcoNativeDriverStatic`

In `runtime/src/codegen/CMakeLists.txt`:

```cmake
target_link_libraries(EcoNativeDriverStatic PUBLIC
    …existing…
    lldELF
    lldCommon
)
```

If `find_package(LLD CONFIG)` works in the rebuilt LLVM install, use
that; otherwise the `lldELF`/`lldCommon` targets come from the same
`add_llvm_library` machinery as the LLVM bits we already link, so
listing them directly works.

### Step 3: swap `ExecuteAndWait` for `lld::elf::link` in `linkExecutable`

```cpp
#include "lld/Common/Driver.h"

// In linkExecutable, replace the ExecuteAndWait block:
std::vector<const char *> lldArgv;
lldArgv.push_back("ld.lld");
for (auto &a : args)
    lldArgv.push_back(a.data());

// Option 1: accept TEXTREL (matches current ld.bfd behavior).
lldArgv.push_back("-z");
lldArgv.push_back("notext");

lld::Result r = lld::lldMain(lldArgv,
                             llvm::outs(), llvm::errs(),
                             {{lld::Gnu, &lld::elf::link}});
return r.retCode;
```

Delete the `find_program(ECO_SYSTEM_LD ld REQUIRED)` and the
`systemLinker` field of `EcoBootConfig.h`. Everything else in the
generated header (crt paths, libgcc, search dirs, dynamic linker
constant) stays — `lld` doesn't have a driver to fill those in.

### Step 4 (deferred): land the StackMaps PIC encoding patch

Once the embedded-lld path is in CI and shipping, queue option 3:

1. Patch `/opt/llvm-mlir`'s LLVM 21 source with the PC-relative
   StackMaps encoding (gated on a new `-stackmap-encoding=pic` flag).
2. Add the matching parser branch in
   `runtime/src/allocator/StackMap.cpp`. Detect the new encoding via
   the V4 version header (or via the new flag's presence).
3. Pass `-stackmap-encoding=pic` in the `eco-boot-native`
   `compileMlirFileToExecutable` pipeline (via `TargetOptions` or
   `--mllvm` flag).
4. Drop `-z notext` from `linkExecutable`.
5. Open an upstream RFC on `discourse.llvm.org`. The likely audience
   (GC implementers using statepoints) would benefit; the format
   bump is precedented.

### Step 5 (separately): consider RELRO / `-z now`

Independent of the lld swap, when we no longer need TEXTREL we
should add `-z now -z relro` to the link line to lock down the GOT
after load. Cheap defense-in-depth.

---

## 7. Out-of-scope clarifications

A few things worth being explicit about:

**System dynamic libraries don't get embedded.** `libcurl.so`,
`libssl.so`, `libcrypto.so`, `libc.so`, `libpthread.so`,
`libstdc++.so`, `libunwind.so` are linked dynamically into the user
binaries `eco` produces. They get resolved by the dynamic loader at
runtime, not by `eco`'s linker pass. Embedding lld doesn't (and
shouldn't) change that — every Linux distro provides those.

**`eco`'s own runtime dependencies are already minimal.** Currently
`eco` itself dynamically links `libc`, `libpthread`, `libm`,
`libstdc++`, plus our `libunwind.so` from `/opt/llvm-mlir/lib/…`
(via `-rpath`). With embedded lld these don't change. The "all-in-one"
goal is specifically about **not needing `/usr/bin/ld` at runtime**;
glibc and the standard C++ runtime are still expected on the host.

**Distributing `eco` to other hosts.** With embedded lld + option 1
or 3 above, `eco` works on any glibc-2.31+ x86-64 Linux without
needing binutils installed. The crt paths baked into
`EcoBootConfig.h` are host-specific though, so the *binary `eco`
produces* still needs its target host to have a matching libc and
matching crt files at the baked-in paths. If we want the user
binaries themselves to be truly portable, we'd separately need to
embed the crt files into `eco` and write them out at link time — a
much larger ask, orthogonal to lld embedding.

**Stackmaps as a wire-protocol.** If we change the encoding (option
3), every binary that reads `.llvm_stackmaps` needs to be in lockstep
with what produced the section. Today that's only `eco_entry.cpp`'s
init. After option 3, the *user binaries* `eco` produces also carry
the new-encoding stackmaps and they read their own section via the
same `eco_entry.cpp` code (linked into them from `EcoEntryStatic`).
So the lockstep happens automatically as long as we don't ship a mix
of old-encoding objects with a new-encoding runtime. Bumping the
section version provides a guard.

---

## 8. Estimated work breakdown

| Step | Where | LoC | Effort |
|---|---|---|---|
| Rebuild `/opt/llvm-mlir` with `LLVM_ENABLE_PROJECTS=mlir;lld` | out-of-tree | 0 | 30 min build time |
| Add `lldELF`, `lldCommon` to `EcoNativeDriverStatic` | `runtime/src/codegen/CMakeLists.txt` | ~5 | 5 min |
| Swap `ExecuteAndWait` → `lld::lldMain` | `EcoNativeDriver.cpp::linkExecutable` | ~20 net | 30 min |
| Add `-z notext` to argv | same | 2 | trivial |
| Drop `find_program(ECO_SYSTEM_LD …)` and the `systemLinker` field | `runtime/src/codegen/CMakeLists.txt`, `EcoNativeDriver.cpp` | ~5 | 5 min |
| Smoke test: Stages 6, 7, 8, 9 all build + run | — | 0 | 30 min |
| **Option 1 (TEXTREL-tolerant) total** | | **~30 net** | **~2 hours** |
| Patch `lib/CodeGen/StackMaps.cpp` (PIC encoding, version 4) | `/opt/llvm-mlir/src` (local LLVM tree) | 20–40 | 2–4 hours |
| Patch `runtime/src/allocator/StackMap.cpp` (parse new encoding) | runtime | ~30 | 1 hour |
| Wire `-stackmap-encoding=pic` through `eco-boot-native` | `EcoNativeDriver.cpp::compileMlirFileToExecutable` | ~5 | 30 min |
| Drop `-z notext`; add `-z now -z relro` | same | 3 | trivial |
| Test all binaries (ecor, ecoc, EcoRunner, eco-boot-native, eco) | — | 0 | 1–2 hours |
| **Option 3 (proper PIC) increment** | | **~60 LoC + LLVM patch** | **~6 hours** |

---

## 9. Open questions / decisions to confirm

1. **LLVM patch maintenance:** the `/opt/llvm-mlir` LLVM tree is
   already a custom build (we patch in libunwind). Adding the
   StackMaps PIC patch on top is incremental, but we should agree
   on a policy: do we carry it indefinitely, or commit to an
   upstream RFC and tracking? Upstreaming is plausible because
   the change is small and there are other GC-in-PIE users, but
   the RFC + review cycle is months.

2. **Format version bump or opt-in flag?** Bumping the stackmap
   format version from V3 to V4 is the cleanest signal, but any
   tooling that reads our stackmaps (none today besides
   `eco_entry.cpp`, but plausibly future LLVM-aware tools like
   `llvm-objdump --stackmap`) would need to handle V4. An opt-in
   `-stackmap-encoding=pic` flag without a version bump is
   stealthier but riskier if encoding-aware tools assume V3.
   Lean toward version bump.

3. **Do we want `eco`'s user binaries to also use embedded lld?**
   Today `eco`'s `linkExecutable` is called once per `eco make`
   invocation to link the user's program. With embedded lld,
   that call happens in-process. Memory-wise that's fine
   (`lld::elf::link` cleans up its own context). But conceptually:
   the user is now linking with "the lld that ships inside eco,"
   not the system lld. That's actually a *good* property for
   reproducibility, and it's what we want.

4. **Cross-platform.** Stage 9 is Linux x86-64 only, by design. If
   we ever target macOS or Windows, the embedded linker story
   changes (need `lldMachO` and `lldCOFF`), and the crt path
   discovery is platform-specific. That's out of scope for this
   report.
