## Constraints / what I can ground in *your* repo vs extrapolate

I can see (from the uploaded repo inventory + docs) that:
- The compiler is written in Elm and has an MLIR backend split across `compiler/src/Compiler/Generate/MLIR/*`  and a monomorphization stage that includes `Compiler/Generate/Monomorphize/KernelAbi.elm` .
- The runtime/MLIR side has an `EcoDialect` + `EcoToLLVM` pass pipeline under `runtime/src/codegen/*` .
- There is already a *bytes kernel package* stubbed in C++ at `elm-kernel-cpp/src/bytes/BytesExports.cpp` and wired via `RuntimeSymbols.cpp` , .
- There is allocator/runtime infrastructure for bytes at `runtime/src/allocator/BytesOps.cpp/.hpp` , but it is **not currently linked** into `EcoRunner` in the `runtime/src/codegen/CMakeLists.txt` snippet you shared (it links `StringOps.cpp`, `ListOps.cpp`, but not `BytesOps.cpp`) .

I **cannot** see the contents of those source files in the uploaded material (only names/paths), so where I’d normally provide exact line-level diffs, I instead provide:

- exact *file paths* to create/modify,
- complete code “drop-ins” for new files,
- and precise “edit instructions” for existing files (what to add where), but with a small amount of extrapolation about the surrounding code structure.

This is still implementable incrementally and is “complete” in the sense that it covers every subsystem that must change (compiler recognition → IR → MLIR dialect → lowering → runtime ABI → build + symbol registration), consistent with the design you posted .
- The compiler is written in Elm and has an MLIR backend split across `compiler/src/Compiler/Generate/MLIR/*`  and a monomorphization stage that includes `Compiler/Generate/Monomorphize/KernelAbi.elm` .
- The runtime/MLIR side has an `EcoDialect` + `EcoToLLVM` pass pipeline under `runtime/src/codegen/*` .
- There is already a *bytes kernel package* stubbed in C++ at `elm-kernel-cpp/src/bytes/BytesExports.cpp` and wired via `RuntimeSymbols.cpp` , .
- There is allocator/runtime infrastructure for bytes at `runtime/src/allocator/BytesOps.cpp/.hpp` , but it is **not currently linked** into `EcoRunner` in the `runtime/src/codegen/CMakeLists.txt` snippet you shared (it links `StringOps.cpp`, `ListOps.cpp`, but not `BytesOps.cpp`) .

I **cannot** see the contents of those source files in the uploaded material (only names/paths), so where I’d normally provide exact line-level diffs, I instead provide:

- exact *file paths* to create/modify,
- complete code “drop-ins” for new files,
- and precise “edit instructions” for existing files (what to add where), but with a small amount of extrapolation about the surrounding code structure.

This is still implementable incrementally and is “complete” in the sense that it covers every subsystem that must change (compiler recognition → IR → MLIR dialect → lowering → runtime ABI → build + symbol registration), consistent with the design you posted .
- The compiler is written in Elm and has an MLIR backend split across `compiler/src/Compiler/Generate/MLIR/*`  and a monomorphization stage that includes `Compiler/Generate/Monomorphize/KernelAbi.elm` .
- The runtime/MLIR side has an `EcoDialect` + `EcoToLLVM` pass pipeline under `runtime/src/codegen/*` .
- There is already a *bytes kernel package* stubbed in C++ at `elm-kernel-cpp/src/bytes/BytesExports.cpp` and wired via `RuntimeSymbols.cpp` , .
- There is allocator/runtime infrastructure for bytes at `runtime/src/allocator/BytesOps.cpp/.hpp` , but it is **not currently linked** into `EcoRunner` in the `runtime/src/codegen/CMakeLists.txt` snippet you shared (it links `StringOps.cpp`, `ListOps.cpp`, but not `BytesOps.cpp`) .

I **cannot** see the contents of those source files in the uploaded material (only names/paths), so where I’d normally provide exact line-level diffs, I instead provide:

- exact *file paths* to create/modify,
- complete code “drop-ins” for new files,
- and precise “edit instructions” for existing files (what to add where), but with a small amount of extrapolation about the surrounding code structure.

This is still implementable incrementally and is “complete” in the sense that it covers every subsystem that must change (compiler recognition → IR → MLIR dialect → lowering → runtime ABI → build + symbol registration), consistent with the design you posted .
- The compiler is written in Elm and has an MLIR backend split across `compiler/src/Compiler/Generate/MLIR/*`  and a monomorphization stage that includes `Compiler/Generate/Monomorphize/KernelAbi.elm` .
- The runtime/MLIR side has an `EcoDialect` + `EcoToLLVM` pass pipeline under `runtime/src/codegen/*` .
- There is already a *bytes kernel package* stubbed in C++ at `elm-kernel-cpp/src/bytes/BytesExports.cpp` and wired via `RuntimeSymbols.cpp` , .
- There is allocator/runtime infrastructure for bytes at `runtime/src/allocator/BytesOps.cpp/.hpp` , but it is **not currently linked** into `EcoRunner` in the `runtime/src/codegen/CMakeLists.txt` snippet you shared (it links `StringOps.cpp`, `ListOps.cpp`, but not `BytesOps.cpp`) .

I **cannot** see the contents of those source files in the uploaded material (only names/paths), so where I’d normally provide exact line-level diffs, I instead provide:

- exact *file paths* to create/modify,
- complete code “drop-ins” for new files,
- and precise “edit instructions” for existing files (what to add where), but with a small amount of extrapolation about the surrounding code structure.

This is still implementable incrementally and is “complete” in the sense that it covers every subsystem that must change (compiler recognition → IR → MLIR dialect → lowering → runtime ABI → build + symbol registration), consistent with the design you posted .
---
# Rewritten end-to-end implementation design (repo-integrated)
## Goal

Compile *Elm-level* `Bytes.Encode` / `Bytes.Decode` combinators into a single fused “byte kernel” loop, bypassing the current (stubbed) kernel C++ implementations for elm/bytes .
Concretely:
- **Before:** Elm `Bytes.Encode.encode encoder` becomes calls into `Elm.Kernel.Bytes.encode` (currently stubbed).
- **After:** the compiler recognizes eligible encoder/decoder expressions and emits a specialized MLIR function that:
  - allocates one `ByteBuffer` (encoder),
  - does a single linear sequence (or loop) of writes/reads with a cursor,
  - returns `Bytes` (which in ECO should be your heap `ByteBuffer` / `Heap::Bytes` equivalent).
---
# A. Runtime ABI & data model changes

You already defined the `ByteBuffer` heap layout (flex array, aligned, `header.size` is byte count) in the design . The implementation must **stabilize ABI accessors** so MLIR lowering never depends on C bitfield layout (also called out explicitly in your design ).
## A1) Add a small C ABI “bytes runtime” surface
### Create: `runtime/src/allocator/ElmBytesRuntime.h`
> Location rationale: you already keep low-level heap/ops in `runtime/src/allocator/*` .
```c
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint8_t  u8;
typedef uint32_t u32;

// Forward-declare your heap object
typedef struct elm_bytebuffer ByteBuffer;

// Allocate ByteBuffer with header.size = byteCount (in bytes).
ByteBuffer* elm_alloc_bytebuffer(u32 byteCount);

// Return ByteBuffer byte length (must be header.size interpreted as bytes).
u32 elm_bytebuffer_len(ByteBuffer* bb);

// Return pointer to first payload byte (bb->bytes).
u8* elm_bytebuffer_data(ByteBuffer* bb);

// UTF-8 helpers (delegate to your existing string representation).
u32  elm_utf8_width(void* elmString);
u32  elm_utf8_copy(void* elmString, u8* dst);
void* elm_utf8_decode(const u8* src, u32 len);

#ifdef __cplusplus
}
#endif
```
### Create: `runtime/src/allocator/ElmBytesRuntime.cpp`
```cpp
#include "ElmBytesRuntime.h"

// You will need to include your actual heap/object definitions here.
#include "Heap.hpp"              // runtime/src/allocator/Heap.hpp  
#include "Allocator.hpp"
#include "StringOps.hpp"

// NOTE: This file is intentionally “thin wrappers” around existing allocator+string code.
// Where you see TODOs, connect to your actual APIs.

extern "C" {

ByteBuffer* elm_alloc_bytebuffer(u32 byteCount) {
  // TODO: implement using your allocator/heap object tags.
  // Must allocate header + payload (byteCount) and set header.size = byteCount.
  // Must return 8-byte aligned.
  //
  // If you already have a Bytes object constructor in BytesOps, call it here.
  //
  // Example shape (pseudo):
  //   return (ByteBuffer*)alloc::bytebuffer(byteCount);
  (void)byteCount;
  __builtin_trap();
}

u32 elm_bytebuffer_len(ByteBuffer* bb) {
  // TODO: implement as stable accessor: bb->header.size
  (void)bb;
  __builtin_trap();
}

u8* elm_bytebuffer_data(ByteBuffer* bb) {
  // TODO: return &bb->bytes[0]
  (void)bb;
  __builtin_trap();
}

u32 elm_utf8_width(void* elmString) {
  // TODO: call your existing UTF-8 sizing helper in StringOps
  (void)elmString;
  __builtin_trap();
}

u32 elm_utf8_copy(void* elmString, u8* dst) {
  // TODO: call your existing UTF-8 encoder/copy helper in StringOps
  (void)elmString; (void)dst;
  __builtin_trap();
}

void* elm_utf8_decode(const u8* src, u32 len) {
  // TODO: call your existing UTF-8 decode that builds Heap::ElmString
  (void)src; (void)len;
  __builtin_trap();
}

} // extern "C"
```

**Write-up:** Your design explicitly requires stable `elm_bytebuffer_len` to avoid reading `Header` bitfields from LLVM lowering . These wrappers make `bf → llvm` lowering straightforward and robust.
## A2) Link the new runtime file into the runner/compiler
### Modify: `runtime/src/codegen/CMakeLists.txt`

In the `add_mlir_library(EcoRunner ...)` source list (shown in your snippet)  add:
- `../allocator/ElmBytesRuntime.cpp`

Optionally also add `../allocator/BytesOps.cpp` (it exists in the repo inventory ) if you plan to reuse it inside `elm_alloc_bytebuffer`.

**Write-up:** without this, the JIT engine won’t be able to resolve `elm_alloc_bytebuffer` etc.
- `../allocator/ElmBytesRuntime.cpp`

Optionally also add `../allocator/BytesOps.cpp` (it exists in the repo inventory ) if you plan to reuse it inside `elm_alloc_bytebuffer`.

**Write-up:** without this, the JIT engine won’t be able to resolve `elm_alloc_bytebuffer` etc.
- `../allocator/ElmBytesRuntime.cpp`

Optionally also add `../allocator/BytesOps.cpp` (it exists in the repo inventory ) if you plan to reuse it inside `elm_alloc_bytebuffer`.

**Write-up:** without this, the JIT engine won’t be able to resolve `elm_alloc_bytebuffer` etc.
## A3) Register JIT symbols for the new runtime API
### Modify: `runtime/src/codegen/RuntimeSymbols.cpp`

This file already registers kernel symbols for JIT resolution . Add entries for:
- `elm_alloc_bytebuffer`
- `elm_bytebuffer_len`
- `elm_bytebuffer_data`
- `elm_utf8_width`
- `elm_utf8_copy`
- `elm_utf8_decode`

Exactly how depends on your existing macro scheme (often something like `RUNTIME_SYM(name)` / `KERNEL_SYM(name)`), but the end state must be: when MLIR lowering emits `llvm.call @elm_alloc_bytebuffer`, the engine can resolve it.

**Write-up:** your fused path should not depend on the elm/bytes kernel stubs. These are *runtime primitives* used by bf-lowering.
- `elm_alloc_bytebuffer`
- `elm_bytebuffer_len`
- `elm_bytebuffer_data`
- `elm_utf8_width`
- `elm_utf8_copy`
- `elm_utf8_decode`

Exactly how depends on your existing macro scheme (often something like `RUNTIME_SYM(name)` / `KERNEL_SYM(name)`), but the end state must be: when MLIR lowering emits `llvm.call @elm_alloc_bytebuffer`, the engine can resolve it.

**Write-up:** your fused path should not depend on the elm/bytes kernel stubs. These are *runtime primitives* used by bf-lowering.
- `elm_alloc_bytebuffer`
- `elm_bytebuffer_len`
- `elm_bytebuffer_data`
- `elm_utf8_width`
- `elm_utf8_copy`
- `elm_utf8_decode`

Exactly how depends on your existing macro scheme (often something like `RUNTIME_SYM(name)` / `KERNEL_SYM(name)`), but the end state must be: when MLIR lowering emits `llvm.call @elm_alloc_bytebuffer`, the engine can resolve it.

**Write-up:** your fused path should not depend on the elm/bytes kernel stubs. These are *runtime primitives* used by bf-lowering.
---
# B. New MLIR dialect: `bf` (ByteFusion)

Your original design calls for a minimal `bf` dialect . In ECO terms, dialects and passes live under `runtime/src/codegen/*` .
## B1) Add bf dialect & ops (TableGen)
### Create: `runtime/src/codegen/BF/BFDialect.td`
```tablegen
include "mlir/IR/OpBase.td"

def BFDialect : Dialect {
  let name = "bf";
  let cppNamespace = "::eco::bf";
}
```
### Create: `runtime/src/codegen/BF/BFOps.td`

This is a *concrete* MVP set (encoder + decoder primitives), aligned with your Loop IR ops list .
```tablegen
include "BFDialect.td"
include "mlir/IR/OpBase.td"

def BF_CurType : TypeDef<BFDialect, "Cur"> {
  let mnemonic = "cur";
  let summary = "Cursor (ptr,end) lowered to LLVM";
}

def BF_StatusType : TypeDef<BFDialect, "Status"> {
  let mnemonic = "status";
  let summary = "i1 ok/fail";
}

def BF_AllocOp : Op<BFDialect, "alloc", [Pure]> {
  let arguments = (ins I32:$byteCount);
  let results   = (outs LLVM_Pointer:$bufPtr);
}

def BF_CursorInitOp : Op<BFDialect, "cursor.init", [Pure]> {
  let arguments = (ins LLVM_Pointer:$bufPtr);
  let results   = (outs BF_CurType:$cur);
}

def BF_RequireOp : Op<BFDialect, "require", [Pure]> {
  let arguments = (ins BF_CurType:$cur, I32:$n);
  let results   = (outs BF_StatusType:$ok);
}

def BF_AdvanceOp : Op<BFDialect, "advance", [Pure]> {
  let arguments = (ins BF_CurType:$cur, I32:$n);
  let results   = (outs BF_CurType:$cur2);
}

def BF_WriteU8Op : Op<BFDialect, "write.u8", [Pure]> {
  let arguments = (ins BF_CurType:$cur, I8:$v);
  let results   = (outs BF_CurType:$cur2);
}

def BF_ReadU8Op : Op<BFDialect, "read.u8", [Pure]> {
  let arguments = (ins BF_CurType:$cur);
  let results   = (outs I8:$v, BF_CurType:$cur2, BF_StatusType:$ok);
}

// Add BF_WriteU16BEOp, BF_WriteU16LEOp, BF_ReadU16BEOp, ... similarly.
// Add BF_WriteBytesCopyOp: takes src ByteBuffer* and memcpy.
// Add BF_WriteUtf8Op / BF_ReadUtf8Op calling runtime helpers.
```

**Write-up:** keep `bf.cur` abstract at the IR level, but lower it to `(i8* ptr, i8* end)` in LLVM as recommended in your design.
## B2) Add bf C++ dialect registration scaffolding
### Create: `runtime/src/codegen/BF/BFDialect.h/.cpp`
### Create: `runtime/src/codegen/BF/BFOps.h/.cpp` (generated includes)

Follow the same pattern as EcoDialect/EcoOps (they exist in your tree) .
Key requirements:
- `BFDialect::initialize()` registers:
  - bf types (`CurType`, `StatusType`)
  - generated ops from `BFOps.cpp.inc`
## B3) Update build to tablegen bf ops

You already tablegen Eco ops (`EcoOpsIncGen` referenced by the build) . You must replicate that for bf:
### Modify: `runtime/src/codegen/CMakeLists.txt` (or whichever CMake file defines `EcoOpsIncGen`)

Add something like:
- `mlir_tablegen(BFOps.h.inc -gen-op-decls ...)`
- `mlir_tablegen(BFOps.cpp.inc -gen-op-defs ...)`
- `add_public_tablegen_target(BFOpsIncGen)`

Then add bf sources to `EcoRunner` / `ecoc` libraries (similar to EcoDialect).

**Write-up:** Without this, the bf dialect won’t be built/registered and parsing/printing will fail.
- `mlir_tablegen(BFOps.h.inc -gen-op-decls ...)`
- `mlir_tablegen(BFOps.cpp.inc -gen-op-defs ...)`
- `add_public_tablegen_target(BFOpsIncGen)`

Then add bf sources to `EcoRunner` / `ecoc` libraries (similar to EcoDialect).

**Write-up:** Without this, the bf dialect won’t be built/registered and parsing/printing will fail.
- `mlir_tablegen(BFOps.h.inc -gen-op-decls ...)`
- `mlir_tablegen(BFOps.cpp.inc -gen-op-defs ...)`
- `add_public_tablegen_target(BFOpsIncGen)`

Then add bf sources to `EcoRunner` / `ecoc` libraries (similar to EcoDialect).

**Write-up:** Without this, the bf dialect won’t be built/registered and parsing/printing will fail.
---
# C. Lowering: `bf` → LLVM

Your runtime already has `EcoToLLVM.cpp` . Don’t mix bf patterns into EcoToLLVM initially—add a dedicated pass and run it before EcoToLLVM in the pipeline.
## C1) New pass: `BFToLLVM`
### Create: `runtime/src/codegen/Passes/BFToLLVM.cpp`

Implement lowering patterns for each bf op using `ConvertOpToLLVMPattern` (as in your design sketches).
The key lowering decisions (match your design):
- Represent `bf.cur` as an LLVM struct `{ i8*, i8* }` (ptr/end).
- `bf.cursor.init(bufPtr)`:
  - `data = call @elm_bytebuffer_data(bufPtr)` (returns `i8*`)
  - `len  = call @elm_bytebuffer_len(bufPtr)` (returns `i32`)
  - `end  = gep data, len`
- `bf.require(cur, n)`:
  - `ok = (ptr+n <= end)` using `llvm.icmp ule`
- Read/write:
  - byte-wise loads/stores (portable, alignment-safe), as you called out in the hazards section .
- `bf.write.utf8`:
  - call `elm_utf8_copy(str, cur.ptr)` returns bytes written; advance ptr.
- `bf.read.utf8`:
  - call `elm_utf8_decode(cur.ptr, len)`; check non-null; advance ptr.
### Modify: `runtime/src/codegen/Passes.h`

Register `createBFToLLVMPass()` similarly to the other passes listed in the repo inventory .
## C2) Add bf-to-llvm into the pipeline
### Modify: `runtime/src/codegen/EcoPipeline.cpp`

This file exists  and orchestrates passes.
Insert:
1. `createBFToLLVMPass()`
2. then the existing `EcoToLLVM` / standard MLIR conversions

**Write-up:** This ensures bf ops are eliminated before reaching LLVM translation.
1. `createBFToLLVMPass()`
2. then the existing `EcoToLLVM` / standard MLIR conversions

**Write-up:** This ensures bf ops are eliminated before reaching LLVM translation.
---
# D. Compiler frontend: recognizing and compiling Bytes.Encode / Bytes.Decode

Your original design introduces a Loop IR in Elm and then emits bf MLIR . In ECO, the correct place is *inside the MLIR backend*, because that’s where you can replace the normal call-lowering with a specialized emission path.
The MLIR backend modules are enumerated in your docs , with expression lowering in `Compiler/Generate/MLIR/Expr.elm` .
## D1) Add Loop IR modules in the compiler
### Create: `compiler/src/Compiler/Generate/MLIR/BytesFusion/LoopIR.elm`

Port your Loop IR almost exactly (minor namespace tweaks). Keep it untyped if that matches your MonoGraph representation.
Minimum:
- `WidthExpr`
- `Op` list including:
  - `InitCursor`
  - `WriteU8/U16/U32/F32/F64`
  - `WriteBytesCopy`
  - `WriteUtf8`
  - `RequireBytes` / `RequireBytesDyn`
  - `Read*`
  - `Fail` / `Return`
### Create: `compiler/src/Compiler/Generate/MLIR/BytesFusion/Encode.elm`

Responsibilities:
- Pattern-match the *monomorphized representation* of an encoder expression to a normalized list of encoder primitives.
- Compute `WidthExpr`
- Emit LoopIR ops
### Create: `compiler/src/Compiler/Generate/MLIR/BytesFusion/Decode.elm` (Phase 2+)

Same idea for decoders.
**Write-up:** Keeping LoopIR in Elm makes it testable without MLIR and matches the architecture you outlined .
## D2) Implement recognition: intercept `Bytes.Encode.encode` / `Bytes.Decode.decode`
### Modify: `compiler/src/Compiler/Generate/MLIR/Expr.elm` 

Find the function that lowers calls (often something like `lowerCall` / `genCall`).
Add a “fast path” before the generic call emission:
- If the callee resolves to `Bytes.Encode.encode`:
  1. Attempt to “reify” the `Encoder` argument into your `EncoderNode` / normalized list.
  2. If successful:
     - generate a specialized bf kernel function (either as a nested `func.func` or as a private helper in the module),
     - emit a call to that kernel function,
     - return the result as the normal expression value.
  3. If not successful (encoder is opaque/dynamic), fall back to existing lowering (which may call the kernel stub).

Do the same for `Bytes.Decode.decode`.

**Write-up:** This answers your integration question “how are kernel functions recognized” by avoiding kernel-call plumbing entirely and doing a targeted rewrite at MLIR emission time (the most robust integration point given your current backend modularization) .
- If the callee resolves to `Bytes.Encode.encode`:
  1. Attempt to “reify” the `Encoder` argument into your `EncoderNode` / normalized list.
  2. If successful:
     - generate a specialized bf kernel function (either as a nested `func.func` or as a private helper in the module),
     - emit a call to that kernel function,
     - return the result as the normal expression value.
  3. If not successful (encoder is opaque/dynamic), fall back to existing lowering (which may call the kernel stub).

Do the same for `Bytes.Decode.decode`.

**Write-up:** This answers your integration question “how are kernel functions recognized” by avoiding kernel-call plumbing entirely and doing a targeted rewrite at MLIR emission time (the most robust integration point given your current backend modularization) .
- If the callee resolves to `Bytes.Encode.encode`:
  1. Attempt to “reify” the `Encoder` argument into your `EncoderNode` / normalized list.
  2. If successful:
     - generate a specialized bf kernel function (either as a nested `func.func` or as a private helper in the module),
     - emit a call to that kernel function,
     - return the result as the normal expression value.
  3. If not successful (encoder is opaque/dynamic), fall back to existing lowering (which may call the kernel stub).

Do the same for `Bytes.Decode.decode`.

**Write-up:** This answers your integration question “how are kernel functions recognized” by avoiding kernel-call plumbing entirely and doing a targeted rewrite at MLIR emission time (the most robust integration point given your current backend modularization) .
## D3) Emitting bf ops from Loop IR
### Create: `compiler/src/Compiler/Generate/MLIR/BytesFusion/EmitBF.elm`

This module should:
- create bf ops using whatever builder infrastructure you already have in `Compiler/Generate/MLIR/Ops.elm` .
- If `Ops.elm` does not currently support custom dialect ops, add minimal generic op builder support.

You will need:

- `bf.alloc`
- `bf.cursor.init`
- `bf.write.*`
- `bf.require`
- `scf.if` for failure blocks (or structured CFG)

**Failure strategy (decoder):**

- Maintain a single “fail continuation” block.
- After each read/require producing `ok`, branch to fail if false.
- Return `Nothing` or `Result` according to Elm semantics (see below).

This matches your design recommendation .
- create bf ops using whatever builder infrastructure you already have in `Compiler/Generate/MLIR/Ops.elm` .
- If `Ops.elm` does not currently support custom dialect ops, add minimal generic op builder support.

You will need:

- `bf.alloc`
- `bf.cursor.init`
- `bf.write.*`
- `bf.require`
- `scf.if` for failure blocks (or structured CFG)

**Failure strategy (decoder):**

- Maintain a single “fail continuation” block.
- After each read/require producing `ok`, branch to fail if false.
- Return `Nothing` or `Result` according to Elm semantics (see below).

This matches your design recommendation .
- create bf ops using whatever builder infrastructure you already have in `Compiler/Generate/MLIR/Ops.elm` .
- If `Ops.elm` does not currently support custom dialect ops, add minimal generic op builder support.

You will need:

- `bf.alloc`
- `bf.cursor.init`
- `bf.write.*`
- `bf.require`
- `scf.if` for failure blocks (or structured CFG)

**Failure strategy (decoder):**

- Maintain a single “fail continuation” block.
- After each read/require producing `ok`, branch to fail if false.
- Return `Nothing` or `Result` according to Elm semantics (see below).

This matches your design recommendation .
- create bf ops using whatever builder infrastructure you already have in `Compiler/Generate/MLIR/Ops.elm` .
- If `Ops.elm` does not currently support custom dialect ops, add minimal generic op builder support.

You will need:

- `bf.alloc`
- `bf.cursor.init`
- `bf.write.*`
- `bf.require`
- `scf.if` for failure blocks (or structured CFG)

**Failure strategy (decoder):**

- Maintain a single “fail continuation” block.
- After each read/require producing `ok`, branch to fail if false.
- Return `Nothing` or `Result` according to Elm semantics (see below).

This matches your design recommendation .
- create bf ops using whatever builder infrastructure you already have in `Compiler/Generate/MLIR/Ops.elm` .
- If `Ops.elm` does not currently support custom dialect ops, add minimal generic op builder support.

You will need:

- `bf.alloc`
- `bf.cursor.init`
- `bf.write.*`
- `bf.require`
- `scf.if` for failure blocks (or structured CFG)

**Failure strategy (decoder):**

- Maintain a single “fail continuation” block.
- After each read/require producing `ok`, branch to fail if false.
- Return `Nothing` or `Result` according to Elm semantics (see below).

This matches your design recommendation .
- create bf ops using whatever builder infrastructure you already have in `Compiler/Generate/MLIR/Ops.elm` .
- If `Ops.elm` does not currently support custom dialect ops, add minimal generic op builder support.

You will need:

- `bf.alloc`
- `bf.cursor.init`
- `bf.write.*`
- `bf.require`
- `scf.if` for failure blocks (or structured CFG)

**Failure strategy (decoder):**

- Maintain a single “fail continuation” block.
- After each read/require producing `ok`, branch to fail if false.
- Return `Nothing` or `Result` according to Elm semantics (see below).

This matches your design recommendation .
---
# E. Semantics decisions (must be fixed in code)
## E1) What does decode return on failure?

Elm `Bytes.Decode.decode : Decoder a -> Bytes -> Maybe a` returns `Nothing` on failure.
So the fused decoder kernel should return:
- an Elm `Maybe` heap object
  - `Just value` when ok,
  - `Nothing` when fail.

Your runtime already has constructors/helpers for Maybe patterns noted in the plan (custom tags) , so the compiler should emit those (or call the existing constructors).

**Implementation change (compiler):**
- In the “fail block”, emit allocation of `Nothing`.
- In success path, allocate `Just`.
- an Elm `Maybe` heap object
  - `Just value` when ok,
  - `Nothing` when fail.

Your runtime already has constructors/helpers for Maybe patterns noted in the plan (custom tags) , so the compiler should emit those (or call the existing constructors).

**Implementation change (compiler):**
- In the “fail block”, emit allocation of `Nothing`.
- In success path, allocate `Just`.
- an Elm `Maybe` heap object
  - `Just value` when ok,
  - `Nothing` when fail.

Your runtime already has constructors/helpers for Maybe patterns noted in the plan (custom tags) , so the compiler should emit those (or call the existing constructors).

**Implementation change (compiler):**
- In the “fail block”, emit allocation of `Nothing`.
- In success path, allocate `Just`.
- an Elm `Maybe` heap object
  - `Just value` when ok,
  - `Nothing` when fail.

Your runtime already has constructors/helpers for Maybe patterns noted in the plan (custom tags) , so the compiler should emit those (or call the existing constructors).

**Implementation change (compiler):**
- In the “fail block”, emit allocation of `Nothing`.
- In success path, allocate `Just`.
## E2) Bytes value representation

Your plan indicates `Heap::Bytes` representation is still TODO . The fused path needs a concrete representation.
You have two viable options:
1. **Adopt `ByteBuffer*` as the canonical `Bytes` representation** in ECO (recommended).
2. Wrap `ByteBuffer*` in another heap object (extra indirection).

Given your design’s use of `elm_bytebuffer` directly , pick (1) and make kernel/ports code treat that as `Bytes`.

**Runtime change required:** implement `elm_alloc_bytebuffer` etc to create this object.
1. **Adopt `ByteBuffer*` as the canonical `Bytes` representation** in ECO (recommended).
2. Wrap `ByteBuffer*` in another heap object (extra indirection).

Given your design’s use of `elm_bytebuffer` directly , pick (1) and make kernel/ports code treat that as `Bytes`.

**Runtime change required:** implement `elm_alloc_bytebuffer` etc to create this object.
1. **Adopt `ByteBuffer*` as the canonical `Bytes` representation** in ECO (recommended).
2. Wrap `ByteBuffer*` in another heap object (extra indirection).

Given your design’s use of `elm_bytebuffer` directly , pick (1) and make kernel/ports code treat that as `Bytes`.

**Runtime change required:** implement `elm_alloc_bytebuffer` etc to create this object.
---
# F. Phase plan (incremental, testable)

Your original phase plan is good ; here it is rewritten to match repo structure and to include the concrete file edits above.
## Phase 1 — Encoder fusion only
### Deliverables
1. Runtime wrappers:
   - `runtime/src/allocator/ElmBytesRuntime.h/.cpp`
   - link + JIT symbol registration
2. bf dialect MVP:
   - ops: alloc, cursor.init, advance, write.u8/u16/u32, write.utf8, write.bytescopy
   - lowering pass BFToLLVM
3. Compiler:
   - `BytesFusion/LoopIR.elm`
   - `BytesFusion/Encode.elm`
   - `BytesFusion/EmitBF.elm`
   - intercept in `Compiler/Generate/MLIR/Expr.elm`
### Test
- Add an end-to-end test that encodes a known structure and compares bytes to expected constants.
- Use the existing JIT test harness mentioned in your plan .
## Phase 2 — Decoder (no andThen/loop)

- Add bf read ops + require + decode-failure plumbing.
- Return `Maybe a`.
## Phase 3 — `andThen` (bounded patterns)

- Recognize common `length-prefixed bytes/string` patterns.
## Phase 4 — `loop`

- Emit `scf.while` for list decoding.
---
# G. Complete “code change list” (checklist)

This is the “all code changes needed” list in one place.
## New runtime files
- `runtime/src/allocator/ElmBytesRuntime.h` (new)
- `runtime/src/allocator/ElmBytesRuntime.cpp` (new)
## Runtime modifications
- `runtime/src/codegen/CMakeLists.txt`: link the new runtime source(s) 
- `runtime/src/codegen/RuntimeSymbols.cpp`: register new `elm_*` symbols
## New MLIR dialect files
- `runtime/src/codegen/BF/BFDialect.td` (new)
- `runtime/src/codegen/BF/BFOps.td` (new)
- `runtime/src/codegen/BF/BFDialect.h/.cpp` (new)
- `runtime/src/codegen/BF/BFOps.h/.cpp` (new, generated includes)
## New lowering pass
- `runtime/src/codegen/Passes/BFToLLVM.cpp` (new)
- `runtime/src/codegen/Passes.h`: register pass factory (edit) 
- `runtime/src/codegen/EcoPipeline.cpp`: run BFToLLVM in the pipeline (edit)
## Compiler (Elm) new modules
- `compiler/src/Compiler/Generate/MLIR/BytesFusion/LoopIR.elm` (new)
- `compiler/src/Compiler/Generate/MLIR/BytesFusion/Encode.elm` (new)
- `compiler/src/Compiler/Generate/MLIR/BytesFusion/Decode.elm` (new, phase 2)
- `compiler/src/Compiler/Generate/MLIR/BytesFusion/EmitBF.elm` (new)
## Compiler modifications
- `compiler/src/Compiler/Generate/MLIR/Expr.elm`: intercept and lower encode/decode using BytesFusion 
- Potentially `compiler/src/Compiler/Generate/MLIR/Ops.elm`: add ability to emit bf ops if you don’t already have a generic op builder
---
# H. Open integration questions (answered with recommended choices)

These are the architecture questions you listed; here are the recommended resolutions to unblock implementation.
1) **Separate bf dialect vs extend eco?**  
Use **separate bf dialect** (as in your design) . It keeps eco semantic IR stable and makes it easy to disable/enable bytefusion independently.

2) **Cursor representation**  
Lower `bf.cur` to `(ptr,end)` in LLVM. This matches your design and makes require checks minimal.

3) **Loop IR in Elm or C++?**  
Implement LoopIR in **Elm** first (compiler side) because:
- your backend is already modularized in Elm ,
- you can unit-test LoopIR generation without MLIR.

4) **How to intercept Bytes.Encode.encode?**  
Intercept in `Compiler/Generate/MLIR/Expr.elm` during call lowering (fast path). This avoids having to thread a new “kernel recognition” mechanism through monomorphization.

5) **Bytes support status**  
Kernel stubs exist but real implementation is not done . ByteFusion becomes the real implementation path for many programs, while you can keep kernel stubs as fallback.

6) **Endianness handling**  
Start with portable bytewise stores/loads (safe alignment) as you recommended . Add `llvm.bswap` optimization later.
1) **Separate bf dialect vs extend eco?**  
Use **separate bf dialect** (as in your design) . It keeps eco semantic IR stable and makes it easy to disable/enable bytefusion independently.

2) **Cursor representation**  
Lower `bf.cur` to `(ptr,end)` in LLVM. This matches your design and makes require checks minimal.

3) **Loop IR in Elm or C++?**  
Implement LoopIR in **Elm** first (compiler side) because:
- your backend is already modularized in Elm ,
- you can unit-test LoopIR generation without MLIR.

4) **How to intercept Bytes.Encode.encode?**  
Intercept in `Compiler/Generate/MLIR/Expr.elm` during call lowering (fast path). This avoids having to thread a new “kernel recognition” mechanism through monomorphization.

5) **Bytes support status**  
Kernel stubs exist but real implementation is not done . ByteFusion becomes the real implementation path for many programs, while you can keep kernel stubs as fallback.

6) **Endianness handling**  
Start with portable bytewise stores/loads (safe alignment) as you recommended . Add `llvm.bswap` optimization later.
1) **Separate bf dialect vs extend eco?**  
Use **separate bf dialect** (as in your design) . It keeps eco semantic IR stable and makes it easy to disable/enable bytefusion independently.

2) **Cursor representation**  
Lower `bf.cur` to `(ptr,end)` in LLVM. This matches your design and makes require checks minimal.

3) **Loop IR in Elm or C++?**  
Implement LoopIR in **Elm** first (compiler side) because:
- your backend is already modularized in Elm ,
- you can unit-test LoopIR generation without MLIR.

4) **How to intercept Bytes.Encode.encode?**  
Intercept in `Compiler/Generate/MLIR/Expr.elm` during call lowering (fast path). This avoids having to thread a new “kernel recognition” mechanism through monomorphization.

5) **Bytes support status**  
Kernel stubs exist but real implementation is not done . ByteFusion becomes the real implementation path for many programs, while you can keep kernel stubs as fallback.

6) **Endianness handling**  
Start with portable bytewise stores/loads (safe alignment) as you recommended . Add `llvm.bswap` optimization later.
---

If you upload (or paste) the contents of these specific files:
- `compiler/src/Compiler/Generate/MLIR/Expr.elm`
- `compiler/src/Compiler/Generate/MLIR/Ops.elm`
- `runtime/src/codegen/EcoPipeline.cpp`
- `runtime/src/codegen/RuntimeSymbols.cpp`
- `runtime/src/allocator/BytesOps.hpp` / `Heap.hpp` (bytes/string parts)

…I can turn the above into *exact* patch-style diffs (with precise function names and minimal intrusion), rather than the small amount of “connect this into your existing macro/pipeline” extrapolation.
- `compiler/src/Compiler/Generate/MLIR/Expr.elm`
- `compiler/src/Compiler/Generate/MLIR/Ops.elm`
- `runtime/src/codegen/EcoPipeline.cpp`
- `runtime/src/codegen/RuntimeSymbols.cpp`
- `runtime/src/allocator/BytesOps.hpp` / `Heap.hpp` (bytes/string parts)

…I can turn the above into *exact* patch-style diffs (with precise function names and minimal intrusion), rather than the small amount of “connect this into your existing macro/pipeline” extrapolation.
