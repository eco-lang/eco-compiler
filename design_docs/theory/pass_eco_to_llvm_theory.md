# EcoToLLVM Pass

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
└── EcoToLLVMFunc.cpp          # func.func lowering (kernel declarations reflected from compiler-declared types)
```

### Shared Infrastructure

**EcoTypeConverter**: Extends `LLVMTypeConverter` to convert `!eco.value` → `i64`.

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
| `!eco.value` | `i64` | Tagged pointer representation |
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
eco.construct.list %head, %tail, head_unboxed
    -> eco_alloc_cons(inttoptr head, inttoptr tail, head_unboxed)
    -> ptrtoint result
```

**Tuples:**
```
eco.construct.tuple2 %a, %b, unboxed_bitmap
    -> eco_alloc_tuple2(inttoptr a, inttoptr b, bitmap)
    -> ptrtoint result

eco.construct.tuple3 %a, %b, %c, unboxed_bitmap
    -> eco_alloc_tuple3(inttoptr a, b, c, bitmap)
    -> ptrtoint result
```

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

**papCreate (create partial application):**
```
eco.papCreate @func, arity, captured=[]
    -> closure = eco_alloc_closure(addressof @func, arity)
    -> packed = n_captured | (arity << 6) | (unboxed_bitmap << 12)
    -> store packed at offset 8
    -> FOR i, val IN captured: store val at offset (24 + i*8)
    -> ptrtoint closure
```

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

### 17. Debug and Safepoints

```
eco.safepoint -> erased (no-op for tracing GC)
eco.dbg %args -> call eco_dbg_print[_int|_float|_char] per arg type
```

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
3. `!eco.value` types are converted to `i64`
4. Global root initialization function is generated
5. Module is valid LLVM dialect IR

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
