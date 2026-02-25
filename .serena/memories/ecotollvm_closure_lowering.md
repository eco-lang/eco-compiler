# EcoToLLVM Closure Lowering - Complete Analysis

## Executive Summary

The EcoToLLVM pass lowers closure operations from ECO dialect to LLVM. It implements three distinct call paths:
1. **Typed Closure Calling (Fast Path)**: Direct calls to fast clones when closure structure is known
2. **Generic Closure Calling**: Indirect calls via closure evaluator pointer
3. **Legacy Inline Path**: Fallback args-array convention for when closure kind info unavailable

All paths handle the heterogeneous/homogeneous dispatch problem through closure kind metadata and dynamic mode attributes.

---

## Architecture Overview

**File**: `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`
**Lines**: ~1100 lines
**Patterns**: 5 lowering patterns

### Modular Structure (Single Pass, Multiple Concerns)

```
EcoToLLVM Pass (orchestrator in EcoToLLVM.cpp)
├── EcoToLLVMClosures.cpp (this file)
│   ├── ProjectClosureOpLowering - load captures from closure
│   ├── AllocateClosureOpLowering - allocate empty closure
│   ├── PapCreateOpLowering - create partial application
│   ├── PapExtendOpLowering - extend closure or saturated call
│   └── CallOpLowering - direct or indirect calls
├── EcoToLLVMHeap.cpp - heap allocation/boxing
├── EcoToLLVMControlFlow.cpp - case/joinpoint/jump
├── EcoToLLVMArith.cpp - arithmetic ops
└── ... other patterns
```

---

## Data Structures

### Closure Memory Layout

```
[Header:8 bytes]
[packed:8 bytes]         // n_values:6 | max_values:6 | unboxed:52
[evaluator:8 bytes]      // Function pointer
[values:N*8 bytes]       // Captured values array
```

**Constants** (in `EcoToLLVMInternal.h`):
```cpp
namespace layout {
    ClosurePackedOffset = 8      // offset to packed field
    ClosureEvaluatorOffset = 16  // offset to evaluator pointer
    ClosureValuesOffset = 24     // offset to values array
}
```

**Packed Field Encoding**:
- Bits 0-5: `n_values` - number of currently captured values
- Bits 6-11: `max_values` - arity (maximum values when fully saturated)
- Bits 12+: `unboxed` - 52-bit bitmap indicating which captures are unboxed (raw Int/Float bits vs HPointer)

### Type Conversion

All values are converted to `i64` (tagged pointers) except:
- `f64` stays `f64` (unboxed floats in some paths)
- `i1` stays `i1` (booleans)
- Pointers stay pointers

---

## Closure Call Mechanism: Three Paths

### Path 1: Fast Closure Call (Typed Closure Calling)

**Dispatcher**: `emitFastClosureCall()` (lines 483-546)
**Trigger**: `_dispatch_mode = "fast"` attribute + `_capture_abi` + `_fast_evaluator`

**Pattern**:
```
1. Resolve closure HPointer to raw pointer
2. Load captures from closure.values array (24 + i*8)
3. Type-convert each capture based on _capture_abi attribute
4. Build argument list: [capture0, capture1, ..., newarg0, newarg1, ...]
5. Call fast clone function via function pointer (direct, not array-based)
6. Return result
```

**Code Walk-through**:
```cpp
// Load captures
for (size_t i = 0; i < captureAbiTypes.size(); ++i) {
    int64_t valueOffset = layout::ClosureValuesOffset + i * layout::PtrSize;
    // Load as i64
    Value loadedValue = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valuePtr);
    
    // Convert to capture's actual type (from _capture_abi)
    auto captureType = mlir::dyn_cast<TypeAttr>(captureAbiTypes[i]).getValue();
    if (captureType.isF64()) {
        captureVal = rewriter.create<LLVM::BitcastOp>(loc, f64Ty, loadedValue);
    } else if (isa<LLVM::LLVMPointerType>(captureType)) {
        captureVal = rewriter.create<LLVM::IntToPtrOp>(loc, captureType, loadedValue);
    }
    callArgs.push_back(captureVal);
}

// Build function type and indirect call
auto funcType = LLVM::LLVMFunctionType::get(llvmResultType, paramTypes, false);
auto callOp = rewriter.create<LLVM::CallOp>(loc, funcType, callOperands);
```

**When Used**:
- Compiler analyzes closure flow and determines all callsites produce same closure kind
- AbiCloning.elm generates fast clone with direct parameters
- MLIR generation tags `eco.papCreate` with `_closure_kind` ID and `eco.call` with `_dispatch_mode="fast"`

**Performance Benefit**:
- No runtime array construction
- Direct typed function call
- LLVM can inline
- Register allocation optimized

---

### Path 2: Generic Closure Call

**Dispatcher**: `emitClosureCall()` (lines 551-592)
**Trigger**: `_dispatch_mode = "closure"` attribute

**Pattern**:
```
1. Resolve closure HPointer to raw pointer
2. Load evaluator pointer from closure.evaluator (offset 16)
3. Build argument list: [closure_ptr, newarg0, newarg1, ...]
4. Indirect call to evaluator(closure_ptr, args...)
5. Return result
```

**Code Walk-through**:
```cpp
// Load evaluator pointer
auto offset16 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::ClosureEvaluatorOffset);
auto evalPtrPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, closurePtr, ValueRange{offset16});
Value evaluator = rewriter.create<LLVM::LoadOp>(loc, ptrTy, evalPtrPtr);

// Build args: [closure_ptr, args...]
SmallVector<Value> callArgs;
callArgs.push_back(closurePtr);  // closure pointer (not HPointer)
for (Value arg : newArgs) {
    callArgs.push_back(arg);
    paramTypes.push_back(arg.getType());
}

// Indirect call
auto funcType = LLVM::LLVMFunctionType::get(llvmResultType, paramTypes, false);
auto callOp = rewriter.create<LLVM::CallOp>(loc, funcType, callOperands);
```

**When Used**:
- Different branches produce closures with different structures
- Compiler marks as heterogeneous (`_closure_kind = "heterogeneous"`)
- evaluator points to generic clone (takes Closure* + params)

**Generic Clone Signature**:
```c++
// Generated by AbiCloning.elm
i64 lambdaName$clo(Closure* closure, i64 arg0, i64 arg1) {
    // Load captures from closure
    i64 cap0 = closure->values[0];
    i64 cap1 = closure->values[1];
    // Call fast clone
    return lambdaName$cap(cap0, cap1, arg0, arg1);
}
```

---

### Path 3: Legacy Inline Closure Call

**Implementation**: `emitInlineClosureCall()` (lines 665-898)
**Trigger**: No `_dispatch_mode` attribute OR `_dispatch_mode = "unknown"`

**Pattern** (args-array convention):
```
1. Resolve closure HPointer to raw pointer
2. Load packed field, extract n_values and unboxed bitmap
3. Load evaluator pointer
4. Allocate args array on stack: [totalArgs]
5. LOOP: Copy captured values, boxing unboxed captures via eco_alloc_int
6. LOOP: Copy new args, boxing raw primitives based on origNewArgTypes
7. Call evaluator(argsArray)
8. Unbox result based on origResultType
```

**Key Innovation**: Uses `scf.while` for captured values loop (not `llvm.br`) so it can be nested inside `scf.if` without violating single-block regions.

**Boxing Unboxed Captures** (lines 745-770):
```cpp
// Load captured value (raw i64 bits)
Value capturedVal = rewriter.create<LLVM::LoadOp>(loc, i64Ty, srcPtr);

// Check if unboxed: (unboxedBitmap >> iIter) & 1
Value shiftedBitmap = rewriter.create<LLVM::LShrOp>(loc, unboxedBitmap, iIter);
Value isUnboxed = rewriter.create<LLVM::AndOp>(loc, shiftedBitmap, one64Const);

// Conditionally box using scf.if
auto ifOp = rewriter.create<scf::IfOp>(loc, TypeRange{i64Ty}, isUnboxedBit, true);

// Then branch: box via eco_alloc_int
{
    auto boxCall = rewriter.create<LLVM::CallOp>(loc, allocIntFunc, ValueRange{capturedVal});
    rewriter.create<scf::YieldOp>(loc, ValueRange{boxCall.getResult()});
}

// Else branch: already HPointer, pass through
{
    rewriter.create<scf::YieldOp>(loc, ValueRange{capturedVal});
}
```

**Why Box Unboxed Captures?**
- Evaluator wrapper expects all args as HPointer-encoded i64
- Unboxed captures (raw Int/Float bits) stored as-is in closure
- Must wrap them as heap objects for wrapper to read
- Bitmap tells us which captures need boxing

**New Arguments Boxing** (lines 798-836):
```cpp
for (size_t j = 0; j < newArgs.size(); ++j) {
    Value arg = newArgs[j];
    Type origArgType = origNewArgTypes[j];

    if (isa<eco::ValueType>(origArgType)) {
        // Already HPointer, pass through
    } else if (origArgType.isInteger(64)) {
        // Int: box via eco_alloc_int
        auto boxCall = rewriter.create<LLVM::CallOp>(loc, allocIntFunc, ValueRange{arg});
        arg = boxCall.getResult();
    } else if (origArgType.isF64()) {
        // Float: box via eco_alloc_float
        auto boxCall = rewriter.create<LLVM::CallOp>(loc, allocFloatFunc, ValueRange{arg});
        arg = boxCall.getResult();
    } else if (isa<IntegerType>(origArgType) && width < 64) {
        // Char: box via eco_alloc_char
        auto boxCall = rewriter.create<LLVM::CallOp>(loc, allocCharFunc, ValueRange{arg});
        arg = boxCall.getResult();
    }
    // Store to argsArray
}
```

**Result Unboxing** (lines 852-895):
```cpp
// wrapper returns ptr (HPointer-encoded)
Value resultI64 = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, wrapperResult);

if (isa<eco::ValueType>(origResultType)) {
    // HPointer pass-through
    result = resultI64;
} else if (origResultType.isInteger(64)) {
    // Int: unbox via eco_resolve_hptr + load
    auto resolveResult = rewriter.create<LLVM::CallOp>(loc, resolveFunc, ValueRange{resultI64});
    auto off8 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, layout::HeaderSize);
    auto valPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, resolveResult.getResult(), ...);
    result = rewriter.create<LLVM::LoadOp>(loc, i64Ty, valPtr);
} else if (origResultType.isF64()) {
    // Float: unbox via resolve + load + bitcast
    // ...same as Int but bitcast to f64
}
```

---

## Partial Application: papExtend

**Pattern** (`PapExtendOpLowering`, lines 918-1008):

**Case 1: Saturated** (newArgCount == remainingArity)
```cpp
bool isSaturated = (numNewArgs == remainingArity);

if (isSaturated) {
    // Check for typed closure attributes
    auto fastEval = op->getAttrOfType<SymbolRefAttr>("_fast_evaluator");
    auto captureAbi = op->getAttrOfType<ArrayAttr>("_capture_abi");
    auto closureKind = op->getAttr("_closure_kind");

    if (fastEval && captureAbi) {
        // Fast path: known homogeneous closure
        result = emitFastClosureCall(...);
    } else if (closureKind) {
        // Heterogeneous but has kind info: generic closure call
        result = emitClosureCall(...);
    } else {
        // No closure kind: legacy inline
        result = emitInlineClosureCall(...);
    }
}
```

**Case 2: Unsaturated** (newArgCount < remainingArity)
```cpp
else {
    // Extend the PAP via runtime helper
    auto helperFunc = runtime.getOrCreatePapExtend(rewriter);

    // Build args array
    Value argsArray = rewriter.create<LLVM::AllocaOp>(loc, ptrTy, i64Ty, numArgsConst);

    // Store new args
    for (size_t i = 0; i < newargs.size(); ++i) {
        Value arg = newargs[i];
        if (arg.getType() != i64Ty && isa<LLVM::LLVMPointerType>(arg.getType())) {
            arg = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, arg);
        }
        rewriter.create<LLVM::StoreOp>(loc, arg, slotPtr);
    }

    // Call runtime helper
    auto call = rewriter.create<LLVM::CallOp>(
        loc, helperFunc, ValueRange{closureI64, argsArray, numNewArgsConst, bitmapConst});
}
```

**Runtime Helper Signature**:
```c++
extern "C" uint64_t eco_pap_extend(
    uint64_t closure,           // Input closure HPointer
    uint64_t* new_args,        // Array of new args
    uint32_t num_new_args,     // Count
    uint64_t new_args_bitmap   // Unboxed bitmap for new args
);
```

---

## eco.call (Direct vs Indirect)

**Pattern** (`CallOpLowering`, lines 1014-1079):

```cpp
auto callee = op.getCallee();

if (callee) {
    // Direct call to known function
    auto callOp = rewriter.create<func::CallOp>(loc, *callee, resultTypes, adaptor.getOperands());
} else {
    // Indirect call through closure
    int64_t remainingArity = op.getRemainingArity().value();
    Value closureI64 = allOperands[0];
    auto newArgs = allOperands.drop_front(1);

    auto dispatchMode = op->getAttrOfType<StringAttr>("_dispatch_mode");
    if (dispatchMode) {
        // Use typed closure calling dispatcher
        result = emitDispatchedClosureCall(rewriter, loc, runtime, op, closureI64, newArgs, ...);
    } else {
        // No _dispatch_mode: use legacy inline
        result = emitInlineClosureCall(rewriter, loc, runtime, closureI64, newArgs, ...);
    }
}
```

---

## Wrapper Function Generation

**Function**: `getOrCreateWrapper()` (lines 142-369)

**Purpose**: Adapts from args-array calling convention to typed function signature.

**Key Insight**: The wrapper bridges two worlds:
1. **Input**: args-array calling convention (void** array of HPointer-encoded i64)
2. **Output**: Direct typed function signature

**Wrapper Logic**:

```cpp
// Get wrapper signature (ptr) -> ptr (always)
auto wrapperType = LLVM::LLVMFunctionType::get(ptrTy, {ptrTy}, false);

// For each parameter position:
Type origType = origParamTypes[i];
Type convertedType = targetParamTypes[i];
Value argI64 = load from args[i];

if (origType && isa<eco::ValueType>(origType)) {
    // !eco.value: pass through as-is (already i64 HPointer)
    convertedArg = argI64;
} else if (origType && origType.isInteger(64)) {
    // Int: resolve HPointer -> load i64 at offset 8
    auto resolved = eco_resolve_hptr(argI64);
    auto valPtr = gep(resolved, 8);
    convertedArg = load i64 from valPtr;
} else if (origType && origType.isF64()) {
    // Float: resolve -> load -> bitcast
    auto resolved = eco_resolve_hptr(argI64);
    auto loaded = load i64 from offset 8;
    convertedArg = bitcast to f64;
} else if (origType && <64-bit int) {
    // Char: resolve -> load -> trunc
    auto resolved = eco_resolve_hptr(argI64);
    auto loaded = load i64 from offset 8;
    convertedArg = trunc to target width;
}

// Call target function with converted args
auto call = call @target(convertedArg0, convertedArg1, ...);

// Convert result back to HPointer
if (origResultType && isa<eco::ValueType>(origResultType)) {
    // Already HPointer, convert i64 to ptr
    resultPtr = inttoptr(call result);
} else if (origResultType && origResultType.isInteger(64)) {
    // Int result: box via eco_alloc_int
    auto boxed = eco_alloc_int(call result);
    resultPtr = inttoptr(boxed);
} else if (origResultType && origResultType.isF64()) {
    // Float result: box via eco_alloc_float
    auto boxed = eco_alloc_float(call result);
    resultPtr = inttoptr(boxed);
}
```

**Original Types Metadata**:

The pass pre-scans all `func::FuncOp` and `papCreate` ops to build `runtime.origFuncTypes` map. This distinguishes:
- `Int` (i64): stored as raw i64 value inside ElmInt heap object
- `!eco.value` (i64): stored as HPointer (tagged pointer)

Both become LLVM `i64` after type conversion, so original types are needed for wrapper codegen.

---

## Closure Creation: papCreate

**Pattern** (`PapCreateOpLowering`, lines 371-474):

```cpp
// 1. Allocate closure via eco_alloc_closure
auto allocFunc = runtime.getOrCreateAllocClosure(rewriter);
Value funcPtr = addressof(@wrapper_function);
auto arityConst = i32 constant(arity);
Value closureHPtr = eco_alloc_closure(funcPtr, arity);

// 2. Get wrapper evaluator (fast clone for typed closure calling)
StringRef funcSymbol;
if (auto fastEval = op->getAttrOfType<SymbolRefAttr>("_fast_evaluator")) {
    // Typed closure calling: use fast clone
    funcSymbol = fastEval.getRootReference();
} else {
    // Legacy: use function directly
    funcSymbol = op.getFunction();
}
auto wrapperFunc = getOrCreateWrapper(rewriter, module, funcSymbol, ...);
Value funcPtr = addressof(wrapperFunc);

// 3. Resolve to raw pointer for memory ops
Value closurePtr = eco_resolve_hptr(closureHPtr);

// 4. Store packed field (n_values=0, max_values=arity, unboxed)
uint64_t packedValue = 0 | (arity << 6) | (unboxedBitmap << 12);
store packedValue at offset 8;

// 5. Store captured values (offset 24 + i*8)
for (size_t i = 0; i < captured.size(); ++i) {
    Value capturedValue = captured[i];
    
    // Normalize to i64 for storage
    if (capturedValue is i16) {
        capturedValue = zext to i64;
    } else if (capturedValue is f64) {
        capturedValue = bitcast to i64;
    } else if (capturedValue is ptr) {
        capturedValue = ptrtoint to i64;
    }
    // i64 stored directly
    
    store capturedValue at offset (24 + i*8);
}

// 6. Handle self-capturing closures
if (auto selfCaptureIndices = op->getAttrOfType<ArrayAttr>("self_capture_indices")) {
    for (auto idx : selfCaptureIndices) {
        // Backpatch: store closure's own HPointer at capture slot
        store closureHPtr at offset (24 + idx*8);
    }
}

return closureHPtr;
```

**Key Points**:
- Evaluator is set to **wrapper function**, not the actual lambda
- Wrapper adapts from args-array to typed calling convention
- Captures are stored as raw bits (unboxed per bitmap) or HPointers (boxed)
- Self-capturing (recursive) closures backpatch their own pointer

---

## Dispatch Dispatcher

**Function**: `emitDispatchedClosureCall()` (lines 604-639)

Routes to one of three paths based on `_dispatch_mode` attribute:

```cpp
auto dispatchMode = op->getAttrOfType<StringAttr>("_dispatch_mode");

if (!dispatchMode) {
    op->emitError("closure call missing _dispatch_mode attribute");
    return Value();
}

StringRef mode = dispatchMode.getValue();

if (mode == "fast") {
    auto fastEval = op->getAttrOfType<SymbolRefAttr>("_fast_evaluator");
    auto captureAbi = op->getAttrOfType<ArrayAttr>("_capture_abi");
    // Must have both attributes
    return emitFastClosureCall(...);
}

if (mode == "closure") {
    return emitClosureCall(...);
}

if (mode == "unknown") {
    // Emit warning and fall back to legacy
    return emitUnknownClosureCall(...);
}

op->emitError("unrecognized _dispatch_mode: ") << mode;
```

---

## Project Closure

**Pattern** (`ProjectClosureOpLowering`, lines 26-79):

Load a single capture from a closure:

```cpp
int64_t index = op.getIndex();
bool isUnboxed = op.getIsUnboxed();

// Resolve closure HPointer
Value closurePtr = eco_resolve_hptr(closureI64);

// Compute offset: ClosureValuesOffset (24) + index*8
int64_t valueOffset = layout::ClosureValuesOffset + index * layout::PtrSize;
Value loadedValue = load i64 from (closurePtr + valueOffset);

// Convert based on type
Type resultType = op.getResult().getType();
Value result = loadedValue;

if (isUnboxed && resultType == f64) {
    result = bitcast loadedValue : i64 to f64;
} else if (isUnboxed && resultType == ptr) {
    result = inttoptr loadedValue;
}
// else: i64, no conversion
```

---

## Allocated Closure

**Pattern** (`AllocateClosureOpLowering`, lines 85-107):

Allocate an empty closure:

```cpp
auto func = eco_alloc_closure;
Value funcPtr = addressof(@function);
auto arity = i32 constant(op.getArity());
Value closureHPtr = eco_alloc_closure(funcPtr, arity);
return closureHPtr;
```

---

## Integration with Compiler Pipeline

### Elm Frontend (compiler/src/Compiler/)

1. **AbiCloning.elm** (GlobalOpt phase):
   - Analyzes closure parameter usage across callsites
   - Detects heterogeneous closure ABIs
   - Clones functions once per distinct ABI
   - Generates `$cap` (fast clone) and `$clo` (generic clone)

2. **Functions.elm** (MLIR generation):
   - Tags `eco.papCreate` with `_closure_kind` ID
   - Tags `eco.call` / `papExtend` with `_dispatch_mode`
   - Attaches `_fast_evaluator` and `_capture_abi` for fast path

### C++ Runtime (runtime/src/codegen/)

3. **EcoToLLVM Pass** (this analysis):
   - Reads typed closure calling attributes
   - Dispatches to appropriate lowering path
   - Generates wrapper functions for args-array convention
   - Emits direct calls (fast) or indirect calls (generic/legacy)

---

## Runtime Functions Referenced

**Called from LLVM lowering**:

| Function | Signature | Purpose |
|----------|-----------|---------|
| `eco_alloc_closure` | `i64 (ptr, i32)` | Allocate closure object |
| `eco_alloc_int` | `i64 (i64)` | Box int to heap object |
| `eco_alloc_float` | `i64 (f64)` | Box float to heap object |
| `eco_alloc_char` | `i64 (i16)` | Box char to heap object |
| `eco_resolve_hptr` | `ptr (i64)` | Convert HPointer to raw pointer |
| `eco_pap_extend` | `i64 (i64, ptr, i32, i64)` | Create extended closure |

**NOT directly called from MLIR**:
- `eco_closure_call_saturated` - Used by old C++ kernel path, not in MLIR lowering
- `eco_apply_closure` - Wrapper naming convention

---

## Invariants Enforced

1. **CGEN_012**: Type mapping (eco.value → i64)
2. **HEAP_001-002**: Object layout and alignment
3. **HEAP_008**: HPointer encoding (40-bit offset)
4. **HEAP_010**: Embedded constants via constant field
5. **ABI_001**: Every closure-producing op has `_closure_kind`
6. **ABI_002**: Every closure call has `_dispatch_mode`
7. **ABI_003**: Fast calls only used with matching capture ABIs
8. **ABI_004**: Generic clone unpacks captures and calls fast clone

---

## Performance Characteristics

### Fast Path (typed closure calling):
- ✓ Direct function pointer call
- ✓ No array allocation
- ✓ Captures as typed parameters
- ✓ LLVM-inlinable

### Generic Path:
- ○ One indirect call through evaluator pointer
- ○ No boxing overhead (evaluator takes Closure* directly)
- ○ Must load captures from closure
- ○ LLVM can still inline if type info available

### Legacy Path:
- ✗ Array allocation on stack
- ✗ Capture boxing loop (scf.while)
- ✗ Argument boxing per type
- ✗ Wrapper call overhead
- ✗ Result unboxing per type

---

## Key Implementation Details

### Float Handling
- f64 values stored in closures as bitcast i64
- Fast path: bitcasts back to f64 when loading
- Legacy path: loads i64, then bitcasts when boxing/unboxing

### Unboxed Bitmap
- Separates "raw value bits" from "HPointer heap references"
- Critical for GC: GC doesn't trace unboxed captures
- Bits 12+ of packed field
- Bit i set means capture[i] is raw (unboxed)

### Original Types Metadata
- Pre-scanned before conversion (lines 248-318 in EcoToLLVM.cpp)
- Stored in `runtime.origFuncTypes` map
- Allows wrapper to distinguish Int (i64) from !eco.value (i64)
- Reconstructed from papCreate/papExtend when func::FuncOp unavailable

---

## See Also

- `design_docs/theory/pass_eco_to_llvm_theory.md` - Theory overview
- `design_docs/theory/typed_closure_calling_theory.md` - ABI cloning theory
- `compiler/src/Compiler/GlobalOpt/AbiCloning.elm` - ABI cloning frontend
- `runtime/src/allocator/Heap.hpp` - Closure struct definition
