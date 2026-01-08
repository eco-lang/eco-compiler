# EcoToLLVM Pass

## Overview

The EcoToLLVM pass is the main lowering pass that converts ECO dialect operations to LLVM dialect. It handles type conversion, heap allocation, control flow, arithmetic operations, and function calls. This is the final dialect conversion before LLVM IR generation.

**File**: `runtime/src/codegen/Passes/EcoToLLVM.cpp`

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
```
IF saturated (newargs.size == remaining_arity):
    -> eco_closure_call_saturated(closure, args_array, num_args)
ELSE:
    -> eco_pap_extend(closure, args_array, num_args)
```

### 7. Function Calls

**Direct Call:**
```
eco.call @func(%args) : (T...) -> R
    -> func.call @func(%converted_args) : (T...) -> R
    // Later converted to llvm.call by func-to-llvm
```

**Indirect Call (through closure):**
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

eco.jump id(args)
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

## Invariants

1. **Type Preservation**: Converted types maintain bit-width and semantics
2. **Memory Safety**: All heap accesses use correct offsets from object layouts
3. **SSA Preservation**: Value flow through control flow is preserved via block arguments
4. **No Dead Code**: Every path through converted case/joinpoint has proper terminator

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
| `eco_closure_call_saturated` | Saturated closure call |
| `eco_crash` | Runtime error |
| `eco_dbg_print*` | Debug output |
| `eco_gc_add_root` | GC root registration |
| `eco_int_pow` | Integer power |
| `asin`, `acos`, `atan`, `atan2` | Trig functions (libc) |

## Relationship to Other Passes

- **Requires**: All earlier ECO passes
- **Enables**: LLVM optimization and code generation
- **Pipeline Position**: Final ECO-to-LLVM step
