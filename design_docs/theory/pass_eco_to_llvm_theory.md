# EcoToLLVM Pass

> **Note (HPointer representation redesign):** Sections referencing the old
> constant encoding (`ConstFieldShift = 40`, `kind << 40`, constants 1–15, the
> bits-0-39-offset diagram) are superseded. Embedded constants now lower to the
> words `False = 0x4`, `True = 0x5`, `Empty = 0x6` (`encodeConstant(kind) =
> (1 << PtrIndBit) | kind`, `PtrIndBit = 2`); `ptr` is a raw absolute address at
> bit 3; the ADT-case constant discriminator is the `ptr_ind` bit; and the merged
> empty ctor dispatches via `CONSTANT_TAG` (0xFFFD). See `THEORY.md`, invariants
> HEAP_008/010/028/029, and `plans/hpointer-representation-redesign.md`
> (D1/D3/D6/D9) for the authoritative description.

## Overview

The EcoToLLVM pass is the main lowering pass that converts ECO dialect operations to LLVM dialect. It handles type conversion, heap allocation, control flow, arithmetic operations, and function calls. This is the final dialect conversion before LLVM IR generation.

**Phase**: MLIR_Codegen (Stage 3)

**Pipeline Position**: Final ECO-to-LLVM step, runs after all Stage 2 passes

## Modular Structure

The pass is internally modularized by concern while remaining a single pass externally. This improves maintainability while keeping the public API stable.

**Architectural simplification (Feb 25, 2026):** The pass underwent significant simplification through two refactoring steps: (1) all closure calling logic was centralized into `EcoToLLVMClosures.cpp`, and (2) the pass no longer attempts to reverse-engineer or repair kernel ABI types -- the Elm compiler is now the sole ABI arbiter (see [Centralized Closure ABI and Simplified EcoToLLVM](#centralized-closure-abi-and-simplified-ecotollvm) below).

### File Organization

```
runtime/src/codegen/Passes/
├── EcoToLLVM.cpp              # Pass orchestrator (~150 lines)
├── EcoToLLVMInternal.h        # Private header: EcoRuntime, layout constants, type converter, shared utilities
├── EcoToLLVMRuntime.cpp       # Runtime function helper generation
├── EcoToLLVMTypes.cpp         # Constants, string literals
├── EcoToLLVMHeap.cpp          # Heap allocation, boxing, construct/project
├── EcoToLLVMClosures.cpp      # All closure calling: PAP create/extend, direct/indirect calls, kernel calls
├── EcoToLLVMControlFlow.cpp   # Case, joinpoint, jump, return, get_tag
├── EcoToLLVMArith.cpp         # Arithmetic, comparisons, conversions
├── EcoToLLVMGlobals.cpp       # Globals, GC root initialization
├── EcoToLLVMErrorDebug.cpp    # Crash, expect, dbg, safepoint
├── EcoToLLVMFunc.cpp          # func.func lowering (kernel declarations reflected from compiler-declared types)
├── EcoGCPrepare.cpp           # GC root attachment on allocating ops (Stage 2, runs before EcoToLLVM)
└── EcoGCStrategy.cpp          # Registers the "eco-gc" GC strategy with LLVM (drives RS4GC)
```

Statepoints themselves (`gc.statepoint` / `gc.relocate`) are inserted by
LLVM's upstream **`RewriteStatepointsForGC`** (RS4GC) pass, which runs as a
function pass on the translated LLVM IR immediately after MLIR → LLVM
translation and before the base optimizer. RS4GC identifies GC pointers by
type (`ptr addrspace(1)`, per the `"eco-gc"` strategy), computes liveness
at the LLVM IR level via backward dataflow, and handles relocation via
alloca+mem2reg internally — Eco contributes no custom statepoint-insertion
pass.

### RewriteStatepointsForGC migration *(Apr 18-22, 2026)*

The bespoke `StatepointConversion` pass that Eco used to carry has been
retired and replaced with LLVM's upstream `RewriteStatepointsForGC`. The new
`EcoGCStrategy.cpp` registers an `eco-gc` GC strategy; non-leaf calls in
functions marked `gc "eco-gc"` automatically get `gc.statepoint` /
`gc.relocate` pairs emitted by RS4GC, with liveness and base-pointer
inference done upstream. Runtime helpers that cannot trigger GC are
annotated `gc-leaf-function` (via the MLIR `passthrough` attribute) so RS4GC
skips them when choosing statepoint sites.

### Shared Infrastructure

**EcoTypeConverter**: Extends `LLVMTypeConverter` to convert `!eco.value` → `ptr addrspace(1)` (GC-managed pointer). `ptrtoint`/`inttoptr` conversions appear only at heap/global/closure storage boundaries (i64 memory slots) and for embedded constant encoding.

**EcoRuntime**: Lightweight helper (passed by value) for declaring and caching runtime function references. Provides `getOrCreate*()` methods for all runtime functions.

**EcoCFContext**: Per-pass context for control flow lowering. Stores joinpoint block mappings keyed by `(function, joinpoint-id)` to avoid clashes across functions and eliminate static global state.

**Layout Constants**: Centralized in `namespace eco::detail::layout`:
- `HeaderSize`, `PtrSize`, `Alignment`
- Object-specific offsets (Cons, Tuple, Record, Custom, Closure)

**Value Encoding**: Centralized in `namespace eco::detail::value_enc`:
- `ConstFieldShift = 40`
- `ConstantKind` enum (Unit, True, False, Nil, EmptyString, etc.)
- `encodeConstant()` helper

### Pattern Modules

Each module provides an internal `populate*Patterns()` function:

| Module | Patterns | Purpose |
|--------|----------|---------|
| Types | 2 | `eco.constant`, `eco.string_literal` |
| Heap | 17 | Box, Unbox, Allocate*, List*, Tuple*, Record*, Custom* |
| Closures | 4+ | `papCreate`, `papExtend`, `call` (direct + indirect), kernel calls |
| ControlFlow | 5 | `case`, `joinpoint`, `jump`, `return`, `get_tag` |
| Arith | 59 | Int*, Float*, Bool*, Char* ops |
| Globals | 3 | `global`, `load_global`, `store_global` |
| ErrorDebug | 4 | `safepoint`, `dbg`, `crash`, `expect` |
| Func | 1 | `func.func` lowering (kernel declarations use compiler-declared ABI types) |

## Related Invariants

This pass implements and depends on several documented invariants:

| Invariant | Relevance |
|-----------|-----------|
| **CGEN_012** | Type mapping: MInt→i64, MFloat→f64, MBool→i1, MChar→i32, others→eco.value |
| **HEAP_001** | Every heap object begins with 8-byte Header; tag encodes object kind |
| **HEAP_002** | All heap objects are 8-byte aligned |
| **HEAP_008** | HPointer is 40-bit offset from heap_base (encoded in i64) |
| **HEAP_010** | Embedded constants (Unit, True, False, Nil, EmptyString) via HPointer.constant field |
| **HEAP_014** | HPointer with constant≠0 are embedded constants, not heap pointers |
| **HEAP_016** | Runtime eco_alloc_* functions return uint64_t (HPointer representation) |
| **XPHASE_001** | RecordLayout/TupleLayout/CtorLayout must match eco.construct attributes and C++ structs |
| **XPHASE_002** | eco.value pointers correspond to HPointer-based heap objects |

## Type Conversion

The pass uses `EcoTypeConverter`, extending `LLVMTypeConverter`:

| ECO Type | LLVM Type | Notes |
|----------|-----------|-------|
| `!eco.value` | `ptr addrspace(1)` | GC-managed pointer (HPtr) |
| `i1`, `i16`, `i32`, `i64` | Same | Preserved |
| `f64` | Same | Preserved |

### Tagged Pointer Encoding

ECO uses 64-bit tagged pointers with embedded constants:

```
Bits 0-39:  Heap offset (40 bits = 1TB address space)
Bits 40-43: Constant field (0 = heap pointer, 1-15 = embedded constant)
Bits 44-63: Reserved
```

Embedded constants (no heap allocation):
| ConstantKind | Value | Encoded as |
|--------------|-------|------------|
| Unit | 1 | `1 << 40` |
| True | 3 | `3 << 40` |
| False | 4 | `4 << 40` |
| Nil | 5 | `5 << 40` |
| EmptyString | 7 | `7 << 40` |

## Lowering Patterns by Category

### 1. Constants and Literals

```
eco.constant Unit    -> LLVM i64 constant (1 << 40)
eco.constant True    -> LLVM i64 constant (3 << 40)
eco.constant False   -> LLVM i64 constant (4 << 40)
eco.constant Nil     -> LLVM i64 constant (5 << 40)
eco.string_literal   -> LLVM global + address (UTF-8 to UTF-16 conversion)
```

**String Literal Pseudocode:**
```
FUNCTION lowerStringLiteral(op):
    IF value.empty():
        RETURN LLVM constant (7 << 40)  // EmptyString

    utf16 = utf8ToUtf16(value)

    // Create global: struct { i64 header, [N x i16] chars }
    header = Tag_String | (length << 32)
    global = llvm.global { header, utf16_array }

    RETURN llvm.addressof(global) -> ptrtoint -> i64
```

### 2. Boxing and Unboxing

**Box (primitive to heap object):**
```
eco.box %i64_val     -> eco_alloc_int(%val) -> ptrtoint
eco.box %f64_val     -> eco_alloc_float(%val) -> ptrtoint
eco.box %i16_val     -> eco_alloc_char(%val) -> ptrtoint
eco.box %i1_val      -> select(%val, True_const, False_const)
```

**Unbox (heap object to primitive):**
```
eco.unbox %val : i1  -> icmp eq, %val, True_const
eco.unbox %val : T   -> inttoptr -> gep[offset=8] -> load T
```

### 3. Heap Allocation

```
eco.allocate           -> eco_allocate(size, Tag_Custom)
eco.allocate_ctor      -> eco_alloc_custom(tag, size, scalar_bytes)
eco.allocate_string    -> eco_alloc_string(length)
eco.allocate_closure   -> eco_alloc_closure(func_ptr, arity)
```

### 4. Data Structure Construction

**Lists:**
```
eco.construct.list %head, %tail, head_unboxed, head_kind
    -> eco_alloc_cons(inttoptr head, inttoptr tail, head_kind)
    -> ptrtoint result
```
The `head_kind` attribute encodes the 2-bit slot kind (0=boxed HPointer,
1=Int, 2=Float, 3=Char) stored into `cons->header.unboxed` slot 0.

**Tuples:**
```
eco.construct.tuple2 %a, %b, unboxed_bitmap
    -> eco_alloc_tuple2(inttoptr a, inttoptr b, bitmap)
    -> ptrtoint result

eco.construct.tuple3 %a, %b, %c, unboxed_bitmap
    -> eco_alloc_tuple3(inttoptr a, b, c, bitmap)
    -> ptrtoint result
```
`unboxed_bitmap` is 2-bit-per-slot: slot i's kind lives at bits [2i, 2i+1].

**Records:**
```
eco.construct.record fields=[], field_count, unboxed_bitmap
    -> obj = eco_alloc_record(count, bitmap)
    -> FOR EACH field: eco_store_record_field[_i64|_f64](obj, idx, val)
    -> ptrtoint obj
```

**Custom Types (ADTs):**
```
eco.construct.custom tag, size, fields=[], unboxed_bitmap
    -> obj = eco_alloc_custom(tag, size, 0)
    -> FOR EACH field: eco_store_field[_i64|_f64](obj, idx, val)
    -> IF bitmap != 0: eco_set_unboxed(obj, bitmap)
    -> ptrtoint obj
```

### 5. Data Structure Projection

Object layouts:
```
Cons:    [Header:8][head:8][tail:8]
Tuple2:  [Header:8][a:8][b:8]
Tuple3:  [Header:8][a:8][b:8][c:8]
Record:  [Header:8][unboxed:8][values:N*8]
Custom:  [Header:8][ctor/unboxed:8][values:N*8]
```

```
eco.project.list_head %list -> inttoptr -> gep[8] -> load
eco.project.list_tail %list -> inttoptr -> gep[16] -> load
eco.project.tuple2 %t, field -> inttoptr -> gep[8 + field*8] -> load
eco.project.record %r, index -> inttoptr -> gep[16 + index*8] -> load
eco.project.custom %c, index -> inttoptr -> gep[16 + index*8] -> load
```

### 6. Closures and Partial Application

**Closure Layout:**
```
[Header:8][packed:8][evaluator:8][values:N*8]
packed = n_values:6 | max_values:6 | unboxed:52
```
`unboxed` is 2-bit-per-slot encoding kinds for captured values (max 26 typed
captures). Kind 00=boxed HPointer, 01=Int, 10=Float, 11=Char. Slot i's kind
lives at bits [2i, 2i+1].

**papCreate (create partial application):**
```
eco.papCreate @func, arity, captured=[]
    -> closure = eco_alloc_closure(addressof @func, arity)
    -> packed = n_captured | (arity << 6) | (unboxed_bitmap << 12)
    -> store packed at offset 8
    -> FOR i, val IN captured: store val at offset (24 + i*8)
    -> ptrtoint closure
```

**papCreateGroup (mutually-recursive closure SCC, Apr 24, 2026):**

Lowered to a single contiguous-region allocation via a new runtime helper (`eco_alloc_pap_group_region` etc., declared in `RuntimeExports.{h,cpp}`). The lowering writes each sibling's header at its offset, then writes cross-sibling captures after all HPointers in the group are known. Because the writes target same-generation memory, no write barrier is needed. The compiler-side detection lives in `Compiler/Generate/MLIR/Expr.elm`; the dialect op is defined in `runtime/src/codegen/Ops.td` with verifier in `EcoOps.cpp`; closure-capture verification is updated in `CheckEcoClosureCaptures.cpp`. See [MLIR Generation Theory](pass_mlir_generation_theory.md#mutually-recursive-closure-sccs-apr-24-2026) for the front-end side.

**papExtend (apply arguments to closure):**

The `papExtend` operation is now lowered inline (as of Feb 2026) rather than calling a runtime helper. This enables better optimization by LLVM.

```
FUNCTION lowerPapExtend(op):
    closurePtr = inttoptr closure
    packed = load [offset 8]
    nCaptured = packed & 0x3F
    maxValues = (packed >> 6) & 0x3F
    unboxedBitmap = packed >> 12
    evaluator = load [offset 16]

    remainingArity = maxValues - nCaptured
    newArgCount = op.newargs.size

    IF saturated (newArgCount == remainingArity):
        -- Inline saturated call
        totalArgs = nCaptured + newArgCount
        argsArray = alloca [totalArgs x i64]

        -- Copy captured values, handling unboxed types
        FOR i in 0..nCaptured:
            val = load [offset 24 + i*8]
            IF isUnboxed(i, unboxedBitmap):
                -- f64 values need bitcast from i64
                IF type(i) == f64:
                    val = bitcast val : i64 to f64
            store val to argsArray[i]

        -- Copy new arguments, handling f64 -> i64 conversion
        FOR i, arg in newargs:
            IF arg.type == f64:
                val = bitcast arg : f64 to i64
            ELSE:
                val = arg
            store val to argsArray[nCaptured + i]

        -- Indirect call to evaluator
        result = llvm.call %evaluator(argsArray)

        -- Handle f64 result type
        IF op.resultType == f64:
            result = bitcast result : i64 to f64

        RETURN result

    ELSE:
        -- Unsaturated: extend the PAP
        eco_pap_extend(closure, args_array, num_args)
```

**Float Bitcasting**: Since the closure stores all values as `i64` but may contain `f64` captures/arguments, the lowering includes bitcasts between `i64` and `f64` as needed.

### 7. Function Calls

**Direct Call (including kernel calls):**

As of Feb 25, 2026, kernel function calls follow the same direct call path. The Elm compiler determines kernel ABI types via `kernelBackendAbiPolicy` and emits `func.func` declarations with `is_kernel=true`. EcoToLLVM simply reflects the declared types into LLVM -- no ABI inference or repair is performed by the lowering pass.

```
eco.call @func(%args) : (T...) -> R
    -> func.call @func(%converted_args) : (T...) -> R
    // Later converted to llvm.call by func-to-llvm
```

**Typed Closure Calling (PAP Wrapper Elimination):**

As of Feb 2026, the compiler implements typed closure calling which enables direct function calls even when partial application and closures are involved. This eliminates the overhead of runtime PAP type checking.

The call ABI is split based on whether the closure structure is statically known:

**Homogeneous Call Path**: When all callsites flow to closures with the same structure (same captures, same types), the compiler generates a direct call with captures unpacked:

```
eco.call %closure(%newargs) call_abi="homogeneous"
    -- The closure structure is known: unpacks captures as direct arguments
    -> closurePtr = inttoptr %closure
    -> capture0 = load [offset 24]     -- Unpacked capture
    -> capture1 = load [offset 32]     -- Unpacked capture
    -> func.call @target(capture0, capture1, newargs...)
```

**Heterogeneous Call Path**: When different branches may produce closures with different capture structures, the compiler passes the entire closure pointer:

```
eco.call %closure(%newargs) call_abi="heterogeneous"
    -- Closure structure varies: pass closure pointer
    -> closurePtr = inttoptr %closure
    -> func.call @target_indirect(closurePtr, newargs...)
    -- The callee unpacks its own captures
```

**ABI Cloning**: For heterogeneous cases, the compiler generates two entry points per function:
- `@func_direct(captures..., args...)` — for homogeneous calls
- `@func_indirect(closure_ptr, args...)` — for heterogeneous calls

This is handled by `AbiCloning.elm` which clones functions and rewrites callsites.

**Legacy Indirect Call (fallback):**
```
eco.call %closure(%newargs) remaining_arity=N
    -> closurePtr = inttoptr %closure
    -> packed = load [offset 8]
    -> nValues = packed & 0x3F
    -> evaluator = load [offset 16]
    -> totalArgs = nValues + N
    -> argsArray = alloca [totalArgs x i64]
    -> LOOP: copy captured values from closure to argsArray
    -> copy newargs to argsArray[nValues..]
    -> result = llvm.call %evaluator(argsArray)
    -> ptrtoint result
```

### 8. Control Flow

**EcoCFContext**: Manages joinpoint block mappings with per-function scoping:
```cpp
struct EcoCFContext {
    DenseMap<pair<Operation*, int64_t>, Block*> joinpointBlocks;
};
```

**eco.case (non-SCF lowered):**
```
eco.case %scrutinee [tags...] { alternatives... }

IF scrutinee.type == i1:
    ctorTag = zext i1 to i32
ELSE:
    // Check for embedded constant
    constField = (scrutinee >> 40) & 0xF
    IF constField != 0:
        // Map Nil (5) to tag 0, others unchanged
        ctorTag = (constField == 5) ? 0 : constField
    ELSE:
        ctorTag = load [offset 8] as i32

-> cf.switch ctorTag, default=mergeBlock [tags -> caseBlocks]
-> inline each alternative into its case block
-> replace eco.return with cf.br to mergeBlock
```

**String case empty-pattern `inttoptr` fix** *(Apr 24, 2026)*: In `EcoToLLVMControlFlow.cpp` `CaseOpLowering`'s string-case path, the `pattern.empty()` branch was creating the encoded `EmptyString` constant as `i64` and passing it directly to `Elm_Kernel_Utils_equal`, whose declared signature is `(ptr addrspace(1), ptr addrspace(1)) -> ptr addrspace(1)`. Every other embedded-HPointer constant in the file (e.g. the `True` constant a few lines below) wraps the `LLVM::ConstantOp` in an `LLVM::IntToPtrOp` to the `ptr<1>` HPtr type. The fix adds the missing `inttoptr` so both operands match the callee's signature. Regression test: `CaseStringEmptyPatternTest.elm`.

**eco.joinpoint / eco.jump:**
```
eco.joinpoint id(args) { body } continuation { ... }
    -> contBlock: continuation code, jumps to jpBlock
    -> jpBlock(args): body code
    -> exitBlock: code after joinpoint
    -> Store jpBlock in EcoCFContext keyed by (func, id)

eco.jump id(args)
    -> Look up target block from EcoCFContext
    -> cf.br jpBlock(args)
```

### 9. Arithmetic Operations

**Integer:**
```
eco.int.add    -> arith.addi
eco.int.sub    -> arith.subi
eco.int.mul    -> arith.muli
eco.int.div    -> safe_div (guards against div-by-zero, returns 0)
eco.int.modBy  -> floored modulo (Elm semantics, not truncated)
eco.int.remainderBy -> arith.remsi with div-by-zero guard
eco.int.negate -> 0 - x
eco.int.abs    -> select(x < 0, -x, x)
eco.int.pow    -> eco_int_pow runtime call
```

**Float:**
```
eco.float.add  -> arith.addf
eco.float.sub  -> arith.subf
eco.float.mul  -> arith.mulf
eco.float.div  -> arith.divf (IEEE 754 handles NaN/Inf)
eco.float.neg  -> arith.negf
eco.float.abs  -> llvm.fabs
eco.float.pow  -> llvm.pow
eco.float.sqrt -> llvm.sqrt
eco.float.sin  -> llvm.sin
eco.float.cos  -> llvm.cos
eco.float.tan  -> sin/cos
eco.float.asin -> call libc asin
eco.float.acos -> call libc acos
eco.float.atan -> call libc atan
eco.float.atan2-> call libc atan2
eco.float.log  -> llvm.log
eco.float.isNaN -> arith.cmpf uno, x, x
eco.float.isInfinite -> |x| == inf
```

### 10. Type Conversions

```
eco.int_to_float   -> arith.sitofp
eco.float.round    -> llvm.round -> arith.fptosi
eco.float.floor    -> llvm.floor -> arith.fptosi
eco.float.ceiling  -> llvm.ceil -> arith.fptosi
eco.float.truncate -> arith.fptosi (inherently truncates)
```

### 11. Comparisons

**Integer (signed):**
```
eco.int.lt -> arith.cmpi slt
eco.int.le -> arith.cmpi sle
eco.int.gt -> arith.cmpi sgt
eco.int.ge -> arith.cmpi sge
eco.int.eq -> arith.cmpi eq
eco.int.ne -> arith.cmpi ne
eco.int.min -> arith.minsi
eco.int.max -> arith.maxsi
```

**Float (ordered - false if NaN):**
```
eco.float.lt -> arith.cmpf olt
eco.float.le -> arith.cmpf ole
eco.float.gt -> arith.cmpf ogt
eco.float.ge -> arith.cmpf oge
eco.float.eq -> arith.cmpf oeq
eco.float.ne -> arith.cmpf one
eco.float.min -> llvm.minnum
eco.float.max -> llvm.maxnum
```

### 12. Bitwise Operations

```
eco.int.and     -> arith.andi
eco.int.or      -> arith.ori
eco.int.xor     -> arith.xori
eco.int.complement -> xor x, -1
eco.int.shiftLeft  -> arith.shli
eco.int.shiftRight -> arith.shrsi (arithmetic, preserves sign)
eco.int.shiftRightZf -> arith.shrui (logical, zero fill)
```

### 13. Boolean Operations

```
eco.bool.not -> xor x, 1
eco.bool.and -> arith.andi
eco.bool.or  -> arith.ori
eco.bool.xor -> arith.xori
```

### 14. Character Operations

```
eco.char_to_int -> arith.extui i16 to i64
eco.char_from_int -> clamp to [0, 0xFFFF] -> arith.trunci to i16
```

### 15. Globals

```
eco.global @name      -> llvm.global internal i64 = 0
eco.load_global @name -> llvm.addressof @name -> llvm.load
eco.store_global @name, %val -> llvm.addressof @name -> llvm.store
```

### 16. Error Handling

```
eco.crash %msg -> eco_crash(inttoptr msg) -> llvm.unreachable

eco.expect %cond, %msg, %passthrough
    -> IF cond: continue with passthrough
    -> ELSE: eco_crash(msg) -> unreachable
```

### 17. Debug

```
eco.dbg %args -> call eco_dbg_print[_int|_float|_char] per arg type
```

Statepoint insertion is fully delegated to LLVM's
`RewriteStatepointsForGC`; there is no MLIR-level safepoint op. The
integration pipeline:

1. **EcoGCPrepare** (Stage 2): Groups adjacent fixed-size allocations into a single allocation region, and attaches live `!eco.value` roots to allocation-group leaders, `eco.call`, `eco.papExtend`, and `eco.papCreate` via the GCRootCarrier interface. Uses MLIR inter-block `Liveness` analysis unioned with each carrier op's front-end operand set; embedded constants are excluded. These operands become redundant once RS4GC recomputes liveness at the LLVM level, but they are harmless.
2. **Allocation lowering**: `emitAllocWithSafepoint` simply emits the allocation call (no custom marker). Adjacent fixed-size allocs lower to a single fast/slow/merge group (see §Allocation Groups). In the slow path, `eco_gc_alloc_region_slow` is a non-leaf call, so RS4GC wraps it in a statepoint.
3. **Leaf annotation**: Runtime helpers declared in `EcoToLLVMRuntime.cpp` that cannot trigger GC (`eco_*_fast`, `eco_store_*`, `eco_init_*_at`, `eco_get_*`, `eco_gc_add_root`, math kernels, etc.) are tagged `gc-leaf-function` via the MLIR `passthrough` attribute. RS4GC skips these when deciding where statepoints go. Non-leaf helpers (`eco_alloc_*`, `eco_alloc_*_slow`, `eco_apply_closure`, `eco_pap_extend`, `eco_closure_call_saturated`, `eco_clone_array`, `eco_minor_gc`, `eco_major_gc`) do **not** carry the attribute and thus become RS4GC safepoints automatically.
4. **GC attribute**: All non-external functions carry `gc "eco-gc"`. The matching `EcoGCStrategy` (in `EcoGCStrategy.cpp`) tells LLVM that `ptr addrspace(1)` identifies a GC-managed pointer and that `RewriteStatepointsForGC` should run.
5. **RewriteStatepointsForGC** (LLVM function pass, scheduled by driver transformers): For every non-leaf call/invoke in a `gc "eco-gc"` function, RS4GC computes the live `ptr addrspace(1)` set via backward dataflow, wraps the call in `llvm.experimental.gc.statepoint` with a `gc-live` operand bundle, emits `llvm.experimental.gc.relocate` for each live pointer, and rewrites post-safepoint uses through alloca + `PromoteMemToReg`. Constants (including `inttoptr` of constant integers) are excluded by `GCStrategy::isGCManagedPointer` + RS4GC's constant filtering, so embedded `ConstantKind << 40` values never enter `gc-live`.
6. **EcoPtrIntVerify** (optional, gated by `ECO_GC_DEBUG_LIVENESS`): Function pass that runs **after** RS4GC and checks that every `ptrtoint`/`inttoptr` involving `ptr addrspace(1)` is one of the allow-listed boundary patterns. See `EcoPtrIntVerify.cpp` and `guides/gc-diagnostics.md`.

> **Historical note.** Earlier revisions of this pipeline emitted an
> `eco.safepoint` op at front-end-chosen program points. That op was
> removed once every safepoint site was found to immediately precede a
> GCRootCarrier op (alloc / construct / call / pap*); the front-end now
> threads its conservative root hint list directly onto that carrier's
> `live_roots` operand segment, where `EcoGCPrepare` unions it with the
> liveness-derived set. Loop back-edges no longer carry a hint — they
> never produced runtime polls anyway, since the safepoint op was
> erased before RS4GC.

## Allocation Groups

*(Apr 16, 2026)* Adjacent fixed-size alloc ops identified by `EcoGCPrepare` lower to a single fast/slow/merge CFG. The fast path calls `eco_gc_alloc_region_fast` (a gc-leaf-function) guarded by a shared `__eco_safepoint_marker`; on bump-pointer exhaustion control falls through to `eco_gc_alloc_region_slow`, and members are initialized at fixed offsets via `eco_init_*_at` runtime functions:

```
fastBlock:
    result = call eco_gc_alloc_region_fast(totalBytes)    ; gc-leaf-function
    br (result == null) ? slowBlock : mergeBlock

slowBlock:
    result = call eco_gc_alloc_region_slow(totalBytes)    ; non-leaf — RS4GC statepoint
    br mergeBlock

mergeBlock(result):
    %m0 = call eco_init_cons_at(result + 0,    head, tail, ...)   ; gc-leaf-function
    %m1 = call eco_init_tuple2_at(result + 24, a, b, ...)         ; gc-leaf-function
    ...
```

- `eco_init_*_at` helpers write header/fields into the pre-allocated region and return the HPointer of that member; they are marked `gc-leaf-function` so RS4GC does not treat them as safepoints
- `eco_gc_alloc_region_slow` is the sole non-leaf call in the group, so RS4GC wraps exactly that call in a `gc.statepoint` — one safepoint per group
- Variable-size ops (`AllocateClosureOp`, `AllocateOp`) are excluded from groups
- Group size is capped below the 32 KiB large-object threshold
- `EcoGCPrepare` unions the alloc group leader's own `!eco.value` operands into its attached root set so construct-op field values are visible to any downstream debugging tool that consumes the MLIR-level root annotations; RS4GC recomputes liveness independently at the LLVM level, so the `gc-live` bundle on the resulting statepoint is always complete regardless
- `EcoGCLivenessAudit` skips `eco.gc_group_member` ops since their liveness is covered by the leader's root set

## EcoGCPrepare Liveness

`EcoGCPrepare` uses MLIR's inter-block `Liveness` analysis, unioned with each carrier op's front-end operand set, to compute the live `!eco.value` root set attached to each allocating op. Roots are pre-converted by the type-converter adaptor to avoid `!eco.value` type erasure races during dialect conversion. The pass walks nested regions (`scf.while`, `scf.if`, ...) via `func.walk()` so roots inside loop bodies are not missed. `arith.constant` and other embedded-constant ops are excluded from root sets (they are not GC-managed). GC roots are supplied to `eco.call`, `eco.papExtend`, and `eco.papCreate` as well as to allocation-group leaders.

## Shadow Stack *(Apr 18, 2026)*

`eco.shadow_roots` is a `UnitAttr` attached by the compiler on `main_$_0` and on tail join blocks; it declares that the function participates in shadow-stack rooting. `RootSet::stack_ranges` is the shadow stack proper — it holds ranges for dynamic arg arrays (alloca'd `uint64_t*` buffers) that static stack maps cannot describe. The runtime closure dispatch helpers — `eco_apply_closure`, `eco_apply_segmentation_unknown`, `eco_pap_extend`, `eco_closure_call_saturated` — register their combined / unboxed-masked arg arrays via `eco_gc_push_stack_range` before allocating and `pop` after returning. The shared `emitRootedBoxedArgsArray` helper encapsulates the alloca → zero-init → push-range → box-and-populate pattern used by the generic-apply and segmentation-unknown lowerings.

### StackMapRoots class split *(Apr 18, 2026)*

Stack-map-derived roots now live in their own `StackMapRoots` class owned by `ThreadLocalHeap`, separated from `RootSet`'s shadow / stack ranges. This makes the two root sources independently mutable (RS4GC-driven stack maps vs. shadow-stack push/pop) and clarifies which roots a minor GC walks.

### LLVM libunwind *(Apr 19-21, 2026)*

`libunwind` is built directly into the JIT, with per-FDE `.eh_frame` registration for every emitted function. All emitted functions carry `frame-pointer=all` so libunwind can walk the stack reliably for stack-map scanning and for native-backtrace diagnostics.

## eco.value → ptr addrspace(1)

*(Apr 17, 2026, REP_LLVM_001)* `!eco.value` now lowers to `ptr addrspace(1)` (GC-managed pointer) instead of `i64`. The migration spanned every EcoToLLVM module (Heap, Closures, Func, Runtime, ControlFlow, Globals, Types) and the BFToLLVM pass:

- Primary type conversion in `EcoTypeConverter` and unified in `BFTypeConverter`
- `ptrtoint`/`inttoptr` conversions only at:
  - Heap storage boundaries (i64 slots in heap objects)
  - Global storage boundaries (globals are i64)
  - Closure capture storage boundaries (closure values are i64)
  - Embedded-constant encoding (`ConstantKind << 40`)
  - ADT case bit manipulation: `valueToI64` converts `ptr<1>` scrutinee before `LShr`/`And` to extract the constant-field
- Role-specific boundary helpers (`heap*`, `global*`, `closure*`, `argsSlot*`, `caseScrutineeToI64`, `wrapperReturnValueToPtr0`, `wrapperLoadArgSlotToValue` — see §4 below) funnel every `ptr<1>↔i64` conversion through a named, documented path.
- `widenToI64ForInit` for alloc-group member operands routes through `castToHPtr` first (eco.value → ptr<1>) then `PtrToIntOp`, so after replacement the inverse casts ptr<1> → eco.value → ptr<1> cancel in the reconcile pass
- `widenFieldToI64` (Custom/RecordConstructOp lowering) handles Bool `ptr<1>` constants via `PtrToIntOp` instead of pointer ZExt (which would crash — pointer ZExt is not legal on `ptr<1>`)
- ADT case bit manipulation lifts the `ptr<1>` scrutinee to `i64` via `valueToI64` before extracting the constant-field bits
- String case True comparison compares `Elm_Kernel_Utils_equal` result (`ptr<1>`) against a `ptr<1>` True constant via inttoptr — not a raw i64 constant
- BF runtime LLVM declarations use `ptr<1>` for HPtr params/returns; `ReadUtf8OpLowering` compares `elm_utf8_decode` result against null `ptr<1>` via `LLVM::ZeroOp`

### EcoPtrIntVerify

`EcoPtrIntVerify` is a post-RS4GC LLVM function pass that walks every
`ptrtoint`/`inttoptr` involving `ptr addrspace(1)` and rejects any that
escapes the allow-listed boundary helpers. It is the enforcement mechanism
for the addrspace(1) boundary invariants (heap / global / closure / args
slot / case scrutinee / wrapper bridges); see `EcoPtrIntVerify.cpp` and
`guides/gc-diagnostics.md`.

## Global Root Initialization

After lowering, the pass generates `__eco_init_globals`:

```llvm
define void @__eco_init_globals() {
entry:
    call void @eco_gc_add_root(ptr @global1)
    call void @eco_gc_add_root(ptr @global2)
    ...
    ret void
}
```

This registers global variables as GC roots.

## Pre-conditions

1. All previous passes have run (SCF lowering, undefined function stubs, etc.)
2. No reference counting operations remain (verified by RCElimination)
3. All eco.case operations have proper structure
4. All eco.joinpoint operations have valid body and continuation regions

## Post-conditions

1. All ECO dialect operations are converted to LLVM/arith/cf dialects
2. All `func.func` operations are converted to `llvm.func`
3. `!eco.value` types are converted to `ptr addrspace(1)`
4. Global root initialization function is generated
5. Module is valid LLVM dialect IR
6. All non-external functions carry `gc "eco-gc"` attribute
7. Leaf runtime helpers carry `gc-leaf-function` (via MLIR `passthrough`); non-leaf helpers do not, so RS4GC promotes their callsites to statepoints automatically
8. No custom safepoint-marker call remains in LLVM IR; RS4GC is the sole statepoint mechanism

## Pass Behavior Guarantees

These are behavioral properties of the pass itself (see "Related Invariants" section above for system-wide invariants):

1. **Type Preservation**: Converted types maintain bit-width and semantics
2. **Memory Safety**: All heap accesses use correct offsets from object layouts (per HEAP_001, HEAP_002)
3. **SSA Preservation**: Value flow through control flow is preserved via block arguments
4. **No Dead Code**: Every path through converted case/joinpoint has proper terminator
5. **No Static Global State**: Joinpoint mappings use per-pass EcoCFContext, not static globals
6. **No ABI Inference**: The pass does not infer, guess, or repair kernel ABI types. It reflects the types declared by the compiler in `func.func` declarations (see [Compiler as Sole ABI Arbiter](#2-compiler-as-sole-abi-arbiter))

## Runtime Functions Referenced

The pass generates calls to these runtime functions:

| Function | Purpose |
|----------|---------|
| `eco_allocate` | Generic allocation |
| `eco_alloc_int`, `_float`, `_char` | Box primitives |
| `eco_alloc_cons` | List construction |
| `eco_alloc_tuple2`, `_tuple3` | Tuple construction |
| `eco_alloc_record` | Record construction |
| `eco_alloc_custom` | ADT construction |
| `eco_alloc_string` | String allocation |
| `eco_alloc_closure` | Closure allocation |
| `eco_store_*_field*` | Field storage |
| `eco_pap_extend` | Partial application |
| `eco_closure_call_saturated` | Saturated closure call (C++ kernel only, not used by MLIR lowering) |
| `eco_resolve_hptr` | Convert HPointer to raw pointer |
| `eco_crash` | Runtime error |
| `eco_dbg_print*` | Debug output |
| `eco_gc_add_root` | GC root registration |
| `eco_int_pow` | Integer power |
| `asin`, `acos`, `atan`, `atan2` | Trig functions (libc) |

## Relationship to Other Passes

- **Requires**: All earlier ECO passes (JoinpointNormalization, EcoControlFlowToSCF, RCElimination, UndefinedFunction)
- **Enables**: LLVM optimization and code generation
- **Pipeline Position**: Final ECO-to-LLVM step (Stage 3)

## Centralized Closure ABI and Simplified EcoToLLVM

*Architectural change: Feb 25, 2026*

The EcoToLLVM pass underwent significant simplification through two refactoring steps that reduced complexity and removed dead code.

### 1. Centralized Closure Calling Logic

All closure calling logic that was previously spread across multiple files has been consolidated into `EcoToLLVMClosures.cpp`. This includes:

- PAP creation and extension (`papCreate`, `papExtend`)
- Direct and indirect calls
- Kernel function calls (previously handled separately)

The `EcoToLLVMInternal.h` header provides shared utilities consumed by all modules, and `EcoToLLVMRuntime.cpp` handles runtime helper generation. This consolidation means there is a single authoritative location for understanding how any kind of function call is lowered to LLVM.

### 2. Compiler as Sole ABI Arbiter

Previously, the EcoToLLVM lowering pass contained logic to infer or repair what types a kernel function expected based on its name or usage patterns. This was fragile and created a second source of truth for kernel ABI types. The pass has been simplified so that:

- The **Elm compiler** determines definitive ABI types via `kernelBackendAbiPolicy` + `monoTypeToAbi` (audited against the actual C++ `KernelExports.h`)
- MLIR `func.func` declarations carry these types with the `is_kernel=true` attribute
- **EcoToLLVM simply reflects** the declared types into LLVM and implements the calling convention
- All dead code for ABI inference/repair has been removed

This means the lowering pass is now a straightforward type-reflecting translator for kernel calls rather than an ABI decision-maker. If kernel ABI types need to change, the change is made in the compiler's `kernelBackendAbiPolicy`, not in the lowering pass.

### 3. Removal of fixCallResultTypes

The `fixCallResultTypes` pass that was previously part of `EcoPAPSimplify.cpp` has been removed. It was a compensating pass that corrected incorrect `papExtend` result types after the fact. With the **CGEN_056** invariant now enforced at the compiler level, saturating `papExtend` operations always carry correct result types from the start, making the fixup pass unnecessary.

### 4. ptr<1> ↔ i64 Boundary

All conversions between `ptr addrspace(1)` (HPointer) and `i64` are funnelled
through role-specific helpers defined in `EcoToLLVMInternal.h`:

| Helper | Role | Allowed pattern |
| --- | --- | --- |
| `heapStoreValueToI64` / `heapLoadI64ToValue` | Heap field store/load | Result immediately stored into / loaded from a heap struct GEP |
| `globalStoreValueToI64` / `globalLoadI64ToValue` | Module-level eco.value | Result immediately stored into / loaded from a global address |
| `closureStoreValueToI64` / `closureLoadI64ToValue` | Closure.values[] | Result immediately stored into / loaded from closure values GEP |
| `argsSlotStoreValueToI64` / `argsSlotLoadI64ToValue` | Stack args arrays | Alloca registered via `eco_gc_push_stack_range` |
| `caseScrutineeToI64` | ADT case tag tests | Consumed by lshr/and/icmp in the same basic block |
| `wrapperReturnValueToPtr0` | Wrapper return bridging | ptr<1> → i64 → ptr AS0, the only GC→AS0 exit |
| `wrapperLoadArgSlotToValue` | Wrapper arg unboxing | LoadOp from wrapper args array GEP |

These helpers are thin wrappers over the raw `valueToI64`/`i64ToValue` primitives
(also in `EcoToLLVMInternal.h`), but their names encode the boundary role for
documentation, code review, and verifier diagnostics.

**Post-RS4GC verification:** `EcoPtrIntVerify` (gated by `ECO_GC_DEBUG_LIVENESS`)
runs as a function pass after `RewriteStatepointsForGC`. It scans for
`ptrtoint`/`inttoptr` instructions involving `ptr addrspace(1)` and rejects any
that escape the allow-listed boundary helpers (heap/global/closure/args-slot
stores and loads, case scrutinee, wrapper bridges) with a hard error. See
`EcoPtrIntVerify.cpp` and `guides/gc-diagnostics.md` for details.
