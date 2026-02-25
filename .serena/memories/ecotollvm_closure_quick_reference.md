# EcoToLLVM Closure Lowering - Quick Reference

## File Organization

| File | Lines | Purpose |
|------|-------|---------|
| `EcoToLLVM.cpp` | 415 | Orchestrator, pass setup, pattern registration |
| `EcoToLLVMClosures.cpp` | 1097 | 5 closure lowering patterns |
| `EcoToLLVMInternal.h` | 282 | Shared types, constants, runtime helpers |

## Five Closure Lowering Patterns

| Pattern | Lines | Ops Lowered | Key Function |
|---------|-------|-------------|--------------|
| `ProjectClosureOpLowering` | 26-79 | `eco.project.closure` | Load capture from closure |
| `AllocateClosureOpLowering` | 85-107 | `eco.allocate_closure` | Allocate empty closure object |
| `PapCreateOpLowering` | 371-474 | `eco.papCreate` | Create partial application |
| `PapExtendOpLowering` | 918-1008 | `eco.papExtend` | Extend closure or saturated call |
| `CallOpLowering` | 1014-1079 | `eco.call` | Direct or indirect function call |

## Three Closure Call Paths

### 1. Fast Path (Typed Closure Calling)

| Aspect | Details |
|--------|---------|
| **Function** | `emitFastClosureCall()` (lines 483-546) |
| **Trigger** | `_dispatch_mode="fast"` + `_fast_evaluator` + `_capture_abi` |
| **Call Type** | Direct to fast clone `@lambda$cap(...)` |
| **Captures** | Loaded, typed via `_capture_abi`, passed as parameters |
| **Overhead** | Minimal (direct call, no array) |
| **LLVM-friendly** | Yes (inlinable) |

### 2. Generic Path (Heterogeneous Dispatch)

| Aspect | Details |
|--------|---------|
| **Function** | `emitClosureCall()` (lines 551-592) |
| **Trigger** | `_dispatch_mode="closure"` |
| **Call Type** | Indirect via `closure.evaluator` pointer |
| **Signature** | `(Closure*, i64, i64, ...) → i64` (generic clone) |
| **Captures** | Evaluator unpacks from closure |
| **Overhead** | One function pointer load + indirect call |
| **LLVM-friendly** | Somewhat (indirect call, but typed) |

### 3. Legacy Path (Fallback)

| Aspect | Details |
|--------|---------|
| **Function** | `emitInlineClosureCall()` (lines 665-898) |
| **Trigger** | No `_dispatch_mode` OR `_dispatch_mode="unknown"` |
| **Call Type** | Indirect via args-array convention |
| **Signature** | `(void*[]) → void*` (wrapper) |
| **Captures** | Loaded from closure, conditionally boxed |
| **Overhead** | Array allocation, capture boxing, arg boxing, result unboxing |
| **LLVM-friendly** | No (loops, boxing, complex control flow) |

## Data Structures & Constants

### Closure Memory Layout

```
Offset  Size  Field           Encoding
0       8     Header          Tag, color, age, pin, size
8       8     packed          n_values:6 | max_values:6 | unboxed:52
16      8     evaluator       Function pointer (ptr)
24      N*8   values          Captured values array
```

### Constants (namespace eco::detail::layout)

| Constant | Value |
|----------|-------|
| `HeaderSize` | 8 |
| `PtrSize` | 8 |
| `ClosurePackedOffset` | 8 |
| `ClosureEvaluatorOffset` | 16 |
| `ClosureValuesOffset` | 24 |

### Packed Field Bits

| Bits | Field | Max Value |
|------|-------|-----------|
| 0-5 | n_values | 63 |
| 6-11 | max_values (arity) | 63 |
| 12+ | unboxed bitmap | 2^52 |

## Runtime Functions Called

### Allocation

| Function | Signature | Purpose |
|----------|-----------|---------|
| `eco_alloc_closure` | `i64 (ptr, i32)` | Allocate closure object |
| `eco_alloc_int` | `i64 (i64)` | Box int to heap |
| `eco_alloc_float` | `i64 (f64)` | Box float to heap |
| `eco_alloc_char` | `i64 (i16)` | Box char to heap |

### Utility

| Function | Signature | Purpose |
|----------|-----------|---------|
| `eco_resolve_hptr` | `ptr (i64)` | Convert HPointer to raw pointer |
| `eco_pap_extend` | `i64 (i64, i64*, i32, i64)` | Extend closure |

## Type Conversions

### At eco.value Boundaries

| Stage | eco.value | i64 | f64 | ptr |
|-------|-----------|-----|-----|-----|
| **MLIR** | HPointer | Raw int | Raw float | Raw ptr |
| **LLVM Fast** | HPointer | Pass-through | Bitcast ← | IntToPtr ← |
| **LLVM Generic** | HPointer | Pass-through | Bitcast ← | IntToPtr ← |
| **LLVM Legacy** | HPointer | Box/Unbox | Box/Unbox | Box/Unbox |

### Boxing Decisions

```
Input Type       → Boxing Rule
─────────────────────────────────
!eco.value       → No boxing (already HPointer)
Int (i64)        → Box via eco_alloc_int
Float (f64)      → Box via eco_alloc_float
Char (i16)       → Box via eco_alloc_char
ptr              → PtrToInt then box as Int

Unboxed Capture  → Conditionally box if bitmap bit set
                   (uses scf.if to avoid array allocation)
```

## Attributes on Operations

### On eco.papCreate

| Attribute | Type | Value | Meaning |
|-----------|------|-------|---------|
| `_closure_kind` | IntegerAttr or StringAttr | ID or "heterogeneous" | Which closure structure |
| `_fast_evaluator` | SymbolRefAttr | @fn$cap | Fast clone function (optional) |
| `unboxed_bitmap` | IntegerAttr | Bits | Which captures are unboxed |
| `self_capture_indices` | ArrayAttr | [0, 2, ...] | Closure backrefs (optional) |

### On eco.call / papExtend

| Attribute | Type | Value | Meaning |
|-----------|------|-------|---------|
| `_dispatch_mode` | StringAttr | "fast" / "closure" / "unknown" | Call strategy |
| `_closure_kind` | IntegerAttr or StringAttr | ID or "heterogeneous" | Closure structure |
| `_fast_evaluator` | SymbolRefAttr | @fn$cap | Fast clone (if mode="fast") |
| `_capture_abi` | ArrayAttr | [TypeAttr, ...] | Capture types (if mode="fast") |
| `remaining_arity` | IntegerAttr | N | Arity left to saturate |

## Control Flow

### papExtend Decision Tree

```
papExtend(closure, [newargs])
│
├─ Is numNewArgs == remainingArity?
│  │
│  ├─ YES (saturated)
│  │  │
│  │  ├─ Has _fast_evaluator + _capture_abi?
│  │  │  → emitFastClosureCall()
│  │  │
│  │  ├─ Has _closure_kind?
│  │  │  → emitClosureCall()
│  │  │
│  │  └─ else
│  │     → emitInlineClosureCall()
│  │
│  └─ NO (unsaturated)
│     → Call eco_pap_extend() runtime helper
│
```

### eco.call Decision Tree

```
eco.call(fn, [args])
│
├─ callee is known?
│  │
│  ├─ YES
│  │  → func.call @fn([args])
│  │
│  └─ NO (indirect, closure)
│     │
│     ├─ Has _dispatch_mode?
│     │  │
│     │  ├─ "fast"
│     │  │  → emitFastClosureCall()
│     │  │
│     │  ├─ "closure"
│     │  │  → emitClosureCall()
│     │  │
│     │  └─ "unknown"
│     │     → emitUnknownClosureCall() [warning + fallback]
│     │
│     └─ NO _dispatch_mode
│        → emitInlineClosureCall() [legacy]
```

## Wrapper Function Logic

### What: Why We Need Wrappers

```
Problem: Two calling conventions
┌─────────────────────────────────────────────────────┐
│ Wrapper bridges:                                    │
│                                                     │
│  IN (from evaluator):   (ptr) → ptr                │
│                         args-array convention      │
│                         all values HPointer i64    │
│                                                     │
│  OUT (to kernel):       (i64, f64, ...) → i64     │
│                         typed ABI                  │
│                         primitives unboxed         │
└─────────────────────────────────────────────────────┘
```

### How: Wrapper Body (pseudo-code)

```
wrapper(args_array) {
    // 1. Load all args as i64 from array
    for i in 0..arity:
        arg[i] = load i64 from args_array[i]
    
    // 2. Convert based on original type
    for i in 0..arity:
        if origType[i] == !eco.value:
            // HPointer pass-through
            converted[i] = arg[i]
        else if origType[i] == Int:
            // Unbox: resolve HPointer → load i64 at offset 8
            ptr = eco_resolve_hptr(arg[i])
            converted[i] = load i64 from (ptr + 8)
        else if origType[i] == Float:
            // Unbox: resolve → load i64 → bitcast to f64
            ptr = eco_resolve_hptr(arg[i])
            loaded = load i64 from (ptr + 8)
            converted[i] = bitcast loaded to f64
        else if origType[i] == Char:
            // Unbox: resolve → load i64 → trunc to i16
            ptr = eco_resolve_hptr(arg[i])
            loaded = load i64 from (ptr + 8)
            converted[i] = trunc loaded to i16
    
    // 3. Call target with converted args
    result = @target(converted[0], converted[1], ...)
    
    // 4. Convert result back to HPointer
    if origResultType == !eco.value:
        // Already HPointer
        result_hptr = result
    else if origResultType == Int:
        // Box: eco_alloc_int(result)
        result_hptr = eco_alloc_int(result)
    else if origResultType == Float:
        // Box: eco_alloc_float(result)
        result_hptr = eco_alloc_float(result)
    
    // 5. Return as ptr
    return inttoptr(result_hptr)
}
```

## Bitmap Operations

### Unboxed Bitmap Interpretation

```
unboxedBitmap = load(closure.packed) >> 12

For each capture[i]:
  isUnboxed = (unboxedBitmap >> i) & 1
  
  if (isUnboxed):
      // capture[i] is raw bits (Int/Float/Char as i64)
      // Must box for wrapper: call eco_alloc_int
  else:
      // capture[i] is HPointer
      // Pass through directly
```

### Setting Bitmap in papCreate

```cpp
uint64_t unboxedBitmap = op.getUnboxedBitmap();
for (size_t i = 0; i < captured.size(); ++i) {
    if (captureType[i].isInteger(64) || captureType[i].isF64()) {
        // Store as raw bits
        unboxedBitmap |= (1ULL << i);
    } else {
        // Store as HPointer
        unboxedBitmap &= ~(1ULL << i);
    }
}

uint64_t packedValue = n_values | (arity << 6) | (unboxedBitmap << 12);
```

## Pre-Scanning (EcoToLLVM.cpp:244-319)

**Goal**: Preserve original types before they're converted to LLVM.

**Why**: After lowering, all values are i64 or f64 in LLVM. Can't distinguish:
- `Int` (i64) from `!eco.value` (i64) by looking at LLVM types

**Method**:

1. Walk all `func::FuncOp` ops (lines 248-250)
   - Store `funcName → FunctionType` in `runtime.origFuncTypes`

2. For kernel functions with no `func::FuncOp` (lines 256-319)
   - Find all `papCreate` ops referencing the function
   - Collect captures from `papCreate`
   - Follow uses to `papExtend` ops to get new arg types
   - Reconstruct `FunctionType` and store in `runtime.origFuncTypes`

**Used by**: `getOrCreateWrapper()` to determine unboxing strategy

## Common Patterns

### Load Capture with Type Conversion

```cpp
int64_t offset = layout::ClosureValuesOffset + index * layout::PtrSize;
auto offsetConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, offset);
auto valuePtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, closurePtr, ValueRange{offsetConst});
Value loadedValue = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valuePtr);

// Convert based on type
if (type.isF64()) {
    value = rewriter.create<LLVM::BitcastOp>(loc, f64Ty, loadedValue);
} else if (isa<LLVM::LLVMPointerType>(type)) {
    value = rewriter.create<LLVM::IntToPtrOp>(loc, type, loadedValue);
}
```

### Box Value for Wrapper

```cpp
Value toBox = ...;  // i64, f64, or i16
Value boxed;

if (origType.isInteger(64)) {
    // Int: eco_alloc_int
    auto call = rewriter.create<LLVM::CallOp>(loc, allocIntFunc, ValueRange{toBox});
    boxed = call.getResult();
} else if (origType.isF64()) {
    // Float: eco_alloc_float
    auto call = rewriter.create<LLVM::CallOp>(loc, allocFloatFunc, ValueRange{toBox});
    boxed = call.getResult();
}
```

### Check Bitmap Bit

```cpp
auto mask = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 1);
auto shifted = rewriter.create<LLVM::LShrOp>(loc, unboxedBitmap, iIter);
auto isBitSet = rewriter.create<LLVM::AndOp>(loc, shifted, mask);
auto isBitSetCond = rewriter.create<LLVM::ICmpOp>(
    loc, LLVM::ICmpPredicate::ne, isBitSet, zero);
```

## Diagnostic Points

| Warning | Line | Condition |
|---------|------|-----------|
| "closure kind metadata not propagated" | 906 | `_dispatch_mode="unknown"` |
| Missing attributes | 612 | `_dispatch_mode` missing |
| Missing required attrs | 621 | `_dispatch_mode="fast"` but missing `_fast_evaluator` |
| Invalid remaining_arity | 1036 | `eco.call` indirect but no `remaining_arity` |

## Integration Summary

```
Elm Frontend (compiler/src/Compiler/)
  │
  ├─ AbiCloning.elm (GlobalOpt)
  │  │
  │  └─ Analyzes closure ABIs
  │     └─ Generates $cap and $clo clones
  │
  └─ Functions.elm (MLIR gen)
     │
     └─ Tags ops with closure metadata
        ├─ _closure_kind
        ├─ _dispatch_mode
        ├─ _fast_evaluator
        └─ _capture_abi

Runtime C++ (runtime/src/codegen/)
  │
  └─ EcoToLLVM Pass
     │
     └─ EcoToLLVMClosures.cpp (this analysis)
        │
        ├─ Reads metadata
        ├─ Routes to dispatch path
        ├─ Generates LLVM lowering
        └─ Emits calls to runtime functions

Native Execution
  │
  └─ Fast clone or generic evaluator
     │
     └─ Wrapper function for args-array convention
        │
        └─ Direct kernel function call
```

## Performance Characteristics

| Path | Alloc | Calls | Boxes | GC? |
|------|-------|-------|-------|-----|
| **Fast** | 0 | 1 direct | 0 | No |
| **Generic** | 0 | 1 indirect | 0 | No |
| **Legacy** | 1 (array) | 1 indirect | Many | Yes (array) |

**Note**: Allocations shown are on-stack only. Closure object allocated in `papCreate`.
