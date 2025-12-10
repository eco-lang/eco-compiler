# Eco Lowering Implementation Plan

This plan describes the implementation of the Eco dialect lowering pipeline, transforming `.mlir` files containing Eco dialect operations into executable code via LLVM. The design follows `design_docs/eco-lowering.md` and uses `toy-example/src/toyc.cpp` as a reference for MLIR pipeline construction.

## Overview

### Goals
1. Build a compiler tool (`ecoc`) that takes `.mlir` files containing Eco dialect operations
2. Lower Eco operations through multiple stages to LLVM IR
3. Support JIT execution for rapid testing
4. Interface heap operations with the existing `runtime/src/allocator/Allocator.hpp` runtime

### Non-Goals (Deferred)
- Parsing/compilation from `.elm` source files
- Full GC statepoint integration (placeholder for now)
- Incremental/concurrent GC coordination

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                           ecoc Pipeline                              │
├─────────────────────────────────────────────────────────────────────┤
│  Input: .mlir file with Eco dialect                                 │
│                                                                      │
│  Stage 1: Eco High-Level → Eco Low-Level (eco-to-eco passes)        │
│    - eco.construct → eco.allocate_ctor + stores                     │
│    - Closure normalization                                           │
│    - RC placeholder elimination                                      │
│                                                                      │
│  Stage 2: Eco → Standard MLIR (func/cf/arith)                       │
│    - eco.case → cf.switch/cf.cond_br                                │
│    - eco.joinpoint/jump → basic blocks + cf.br                      │
│    - eco.return → func.return                                        │
│                                                                      │
│  Stage 3: Eco Heap Ops → LLVM Dialect                               │
│    - eco.allocate_* → llvm.call @eco_alloc_* + ptrtoint             │
│    - eco.project → inttoptr + llvm.getelementptr + llvm.load        │
│    - eco.value type → i64 (tagged pointer representation)           │
│    - eco.constant → i64 constant with embedded constant bits        │
│                                                                      │
│  Stage 4: LLVM Dialect → LLVM IR → JIT/Object                       │
│    - mlir-to-llvm translation                                        │
│    - LLVM optimization pipeline                                      │
│    - JIT execution or object file emission                          │
└─────────────────────────────────────────────────────────────────────┘
```

**Key Type Representation:**
- `!eco.value` → `i64` (not `ptr`) to support embedded constants via tag bits
- Heap pointers stored as i64, converted to ptr only when dereferencing
- Embedded constants (Nil, True, False, etc.) encoded in bits 40-43

## File Structure

```
runtime/src/codegen/
├── Ops.td                    # (existing) Eco dialect operations
├── EcoDialect.h/cpp          # (existing) Dialect registration
├── EcoOps.h/cpp              # (existing) Op implementations
├── EcoTypes.h/cpp            # (existing) Type implementations
├── CMakeLists.txt            # (existing, will extend)
│
├── Passes.h                  # NEW: Pass declarations
├── Passes/                   # NEW: Pass implementations
│   ├── ConstructLowering.cpp     # eco.construct → allocate + stores
│   ├── ControlFlowLowering.cpp   # case/joinpoint/jump → cf dialect
│   ├── HeapOpsLowering.cpp       # allocate_* → LLVM runtime calls
│   ├── TypeConversion.cpp        # eco.value → LLVM pointer types
│   └── RCElimination.cpp         # Remove incref/decref placeholders
│
├── Runtime/                  # NEW: Runtime interface declarations
│   ├── RuntimeDecls.h            # C++ declarations for runtime functions
│   └── RuntimeDecls.cpp          # Insert LLVM function declarations
│
└── ecoc.cpp                  # NEW: Main compiler driver (replaces ecogen.cpp)

runtime/src/allocator/
├── Allocator.hpp             # (existing) Main allocator interface
├── RuntimeExports.h          # NEW: C-linkage exports for LLVM calls
└── RuntimeExports.cpp        # NEW: Wrapper implementations
```

## Implementation Phases

### Phase 1: Infrastructure Setup

#### 1.1 Extend CMakeLists.txt

Update `runtime/src/codegen/CMakeLists.txt` to:
- Add pass implementations as library targets
- Add conversion pattern libraries
- Create the `ecoc` executable with JIT support
- Link against MLIR conversion libraries and ExecutionEngine

#### 1.2 Create Passes.h

```cpp
// runtime/src/codegen/Passes.h
#ifndef ECO_PASSES_H
#define ECO_PASSES_H

#include <memory>

namespace mlir {
class Pass;

namespace eco {

// Stage 1: Eco → Eco transformations
std::unique_ptr<Pass> createConstructLoweringPass();
std::unique_ptr<Pass> createRCEliminationPass();

// Stage 2: Eco → Standard MLIR
std::unique_ptr<Pass> createControlFlowLoweringPass();

// Stage 3: Eco → LLVM
std::unique_ptr<Pass> createHeapOpsToLLVMPass();

// Full pipeline
void registerEcoToLLVMPipeline();

} // namespace eco
} // namespace mlir

#endif // ECO_PASSES_H
```

### Phase 2: Add eco.constant Op

Add a new operation to `Ops.td` for embedded constants:

```tablegen
def Eco_ConstantOp : Eco_Op<"constant", [Pure]> {
  let summary = "Create embedded constant value";
  let description = [{
    Creates an embedded constant value that is stored directly in the pointer
    representation without heap allocation. These correspond to the Constant
    enum in Heap.hpp: Unit, EmptyRec, True, False, Nil, Nothing, EmptyString.

    Example:
    ```mlir
    %nil = eco.constant #eco.nil : !eco.value
    %true = eco.constant #eco.true : !eco.value
    %unit = eco.constant #eco.unit : !eco.value
    ```

    Lowering produces an i64 with the constant field set appropriately,
    not a heap allocation.
  }];

  let arguments = (ins Eco_ConstantAttr:$value);
  let results = (outs Eco_Value:$result);

  let assemblyFormat = "$value attr-dict `:` type($result)";
}

// Constant attribute for embedded values
def Eco_ConstantAttr : AttrDef<Eco_Dialect, "Constant"> {
  let mnemonic = "const";
  let parameters = (ins "ConstantKind":$kind);

  // ConstantKind enum mirrors Heap.hpp Constant enum
  let extraClassDeclaration = [{
    enum class ConstantKind {
      Unit,       // Const_Unit
      EmptyRec,   // Const_EmptyRec
      True,       // Const_True
      False,      // Const_False
      Nil,        // Const_Nil
      Nothing,    // Const_Nothing
      EmptyString // Const_EmptyString
    };
  }];
}
```

**eco.constant lowering:**
```mlir
// Before:
%nil = eco.constant #eco.const<Nil> : !eco.value

// After (LLVM):
// HPointer encoded as i64 with ptr=0, constant=5 (Const_Nil index + 1)
// Bit layout: [ptr:40][constant:4][padding:20]
// constant field is at bits 40-43, so Nil (index 5) = 5 << 40
%nil = llvm.mlir.constant(5497558138880 : i64) : i64  // 5 << 40
```

The constant encoding matches `HPointer` layout:
- `ptr` field (bits 0-39): 0
- `constant` field (bits 40-43): 1-7 for the constant kind (0 = regular pointer)
- `padding` field (bits 44-63): 0

**Note:** We use i64 representation throughout to avoid LLVM `inttoptr` semantics issues.
Only convert to pointer when actually dereferencing heap memory.

### Phase 3: Type Conversion System

#### 3.1 Eco Type Converter

Create `TypeConversion.cpp` implementing `EcoTypeConverter`:

```cpp
class EcoTypeConverter : public LLVMTypeConverter {
public:
  EcoTypeConverter(MLIRContext *ctx) : LLVMTypeConverter(ctx) {
    // eco.value → i64 (tagged pointer representation)
    // We use i64 instead of ptr to:
    // 1. Make tagged pointers explicit (embedded constants use tag bits)
    // 2. Avoid LLVM inttoptr semantics issues
    // 3. Match HPointer layout from Heap.hpp
    addConversion([](eco::ValueType type) {
      return IntegerType::get(type.getContext(), 64);
    });

    // Primitive types pass through
    addConversion([](IntegerType type) { return type; });
    addConversion([](FloatType type) { return type; });
  }
};
```

Type mapping based on `Heap.hpp`:
| Eco Type | LLVM Type | Notes |
|----------|-----------|-------|
| `!eco.value` | `i64` | Tagged pointer (HPointer encoded as integer) |
| `i64` | `i64` | Elm Int (unboxed) |
| `f64` | `double` | Elm Float (unboxed) |
| `i32` | `i32` | Elm Char (unboxed) |
| `i1` | `i1` | Elm Bool (unboxed) |

**Why i64 instead of ptr:**
- Embedded constants (Nil, True, False, etc.) use tag bits in the pointer representation
- LLVM's pointer semantics assume pointers reference valid memory
- Using `inttoptr` on small integers causes undefined behavior in LLVM optimizers
- i64 makes the tagging explicit and allows clean bit manipulation
- Only convert to `ptr` when actually dereferencing heap memory

### Phase 3: Runtime Interface Layer

#### 3.1 C-Linkage Runtime Exports

Create `runtime/src/allocator/RuntimeExports.h`:

```cpp
// C-linkage functions callable from LLVM-generated code
extern "C" {

// Allocation functions (called by lowered eco.allocate_* ops)
void* eco_alloc_custom(uint32_t ctor_tag, uint32_t field_count, uint32_t scalar_bytes);
void* eco_alloc_string(uint32_t length);
void* eco_alloc_closure(void* func_ptr, uint32_t num_captures);
void* eco_alloc_int(int64_t value);
void* eco_alloc_float(double value);

// Closure operations
void* eco_apply_closure(void* closure, void** args, uint32_t num_args);
void* eco_pap_extend(void* closure, void** args, uint32_t num_newargs);

// Runtime utilities
void eco_crash(void* message);
void eco_dbg_print(void** args, uint32_t num_args);

// GC interface
void eco_safepoint();
void eco_add_root(void** root_slot);
void eco_remove_root(void** root_slot);

}
```

#### 3.2 Runtime Declaration Insertion

Create `Runtime/RuntimeDecls.cpp` to insert LLVM function declarations:

```cpp
void insertRuntimeDeclarations(ModuleOp module, OpBuilder &builder) {
  auto *ctx = module.getContext();
  auto ptrTy = LLVM::LLVMPointerType::get(ctx);
  auto i32Ty = IntegerType::get(ctx, 32);
  auto i64Ty = IntegerType::get(ctx, 64);
  auto f64Ty = FloatType::getF64(ctx);
  auto voidTy = LLVM::LLVMVoidType::get(ctx);

  // eco_alloc_custom: (i32, i32, i32) -> ptr
  auto allocCustomTy = LLVM::LLVMFunctionType::get(ptrTy, {i32Ty, i32Ty, i32Ty});
  getOrInsertFunction(module, "eco_alloc_custom", allocCustomTy);

  // eco_alloc_int: (i64) -> ptr
  auto allocIntTy = LLVM::LLVMFunctionType::get(ptrTy, {i64Ty});
  getOrInsertFunction(module, "eco_alloc_int", allocIntTy);

  // ... etc for other runtime functions
}
```

### Phase 4: Lowering Passes

#### 4.1 Construct Lowering Pass (Eco → Eco)

File: `Passes/ConstructLowering.cpp`

Transforms `eco.construct` into lower-level operations:

```mlir
// Before:
%val = eco.construct(%f0, %f1) { tag = 1, size = 2 } : ... -> !eco.value

// After:
%obj = eco.allocate_ctor { tag = 1, size = 2, scalar_bytes = 0 } : !eco.value
// Store fields (represented as eco.store_field or inline in LLVM lowering)
```

#### 4.2 Control Flow Lowering Pass (Eco → cf/func)

File: `Passes/ControlFlowLowering.cpp`

**eco.case lowering:**
```mlir
// Before:
eco.case %scrutinee [0, 1] {
  eco.return %nil_result
}, {
  %head = eco.project %scrutinee[0]
  eco.return %head
}

// After:
%tag = // extract tag from %scrutinee header
cf.switch %tag : i32, [
  default: ^default,
  0: ^case0,
  1: ^case1
]
^case0:
  func.return %nil_result
^case1:
  %head = eco.project %scrutinee[0]
  func.return %head
```

**eco.joinpoint/jump lowering:**
```mlir
// Before:
eco.joinpoint @loop(%acc: i64) {
  // body using eco.jump @loop(...)
} continuation {
  // after joinpoint
}

// After:
cf.br ^loop_entry(%init_acc : i64)
^loop_entry(%acc: i64):
  // body with cf.br ^loop_entry(...) replacing eco.jump
^loop_exit:
  // continuation
```

#### 4.3 Heap Ops to LLVM Pass

File: `Passes/HeapOpsLowering.cpp`

**eco.allocate_ctor lowering:**
```mlir
// Before:
%obj = eco.allocate_ctor { tag = 1, size = 2, scalar_bytes = 0 }

// After:
%tag = llvm.mlir.constant(1 : i32)
%size = llvm.mlir.constant(2 : i32)
%scalar = llvm.mlir.constant(0 : i32)
%obj_ptr = llvm.call @eco_alloc_custom(%tag, %size, %scalar) : (i32, i32, i32) -> !llvm.ptr
// Convert ptr to i64 for eco.value representation
%obj = llvm.ptrtoint %obj_ptr : !llvm.ptr to i64
// Note: Runtime calls use C calling convention (ccc)
```

**eco.project lowering:**

Based on `Heap.hpp` layouts. Must convert i64 → ptr before dereferencing:
```mlir
// Before:
%field = eco.project %custom[1] : !eco.value -> !eco.value

// After (for Custom type):
// 1. Convert i64 to ptr for dereferencing
%custom_ptr = llvm.inttoptr %custom : i64 to !llvm.ptr

// 2. Calculate offset: Header(8) + ctor/unboxed(8) + index * sizeof(Unboxable)
%offset = llvm.mlir.constant(24 : i64)  // 8 + 8 + 1*8
%field_ptr = llvm.getelementptr inbounds %custom_ptr[%offset] : (!llvm.ptr, i64) -> !llvm.ptr

// 3. Load the field (returns i64 since eco.value is i64)
%field = llvm.load %field_ptr : !llvm.ptr -> i64
```

**Note:** The `inttoptr` here is safe because we only reach this code path when
`%custom` is a real heap pointer (not an embedded constant). The caller must
check for embedded constants before calling project if needed.

**eco.box/unbox lowering:**
```mlir
// eco.box %int_val : i64 -> !eco.value
%boxed_ptr = llvm.call @eco_alloc_int(%int_val) : (i64) -> !llvm.ptr
%boxed = llvm.ptrtoint %boxed_ptr : !llvm.ptr to i64

// eco.unbox %boxed : !eco.value -> i64
// Convert i64 to ptr, then load from ElmInt.value (offset 8, after Header)
%boxed_ptr = llvm.inttoptr %boxed : i64 to !llvm.ptr
%value_ptr = llvm.getelementptr inbounds %boxed_ptr[8] : (!llvm.ptr, i64) -> !llvm.ptr
%value = llvm.load %value_ptr : !llvm.ptr -> i64
```

**Helper: Check for embedded constant:**
```mlir
// To check if an eco.value is an embedded constant (not a heap pointer):
// Extract bits 40-43 (constant field)
%shifted = llvm.lshr %value, llvm.mlir.constant(40 : i64) : i64
%const_field = llvm.and %shifted, llvm.mlir.constant(15 : i64) : i64  // 0xF mask
%is_constant = llvm.icmp "ne" %const_field, llvm.mlir.constant(0 : i64) : i1
// If is_constant is true, this is an embedded constant, not a heap pointer
```

#### 4.4 Call Lowering with Calling Conventions

File: `Passes/CallLowering.cpp`

**Direct Eco-to-Eco calls (tailcc):**

We use `tailcc` (tail call convention) instead of `fastcc` because it guarantees
tail call optimization support, which is essential for functional languages.

```mlir
// Before:
%result = eco.call @elm_function(%arg1, %arg2) : (!eco.value, i64) -> !eco.value

// After:
// Eco functions declared with tailcc for guaranteed TCO support
llvm.func tailcc @elm_function(i64, i64) -> i64  // eco.value is i64
%result = llvm.call tailcc @elm_function(%arg1, %arg2) : (i64, i64) -> i64
```

**Tail calls with musttail:**
```mlir
// Before:
%result = eco.call @elm_function(%args) {musttail = true} : ... -> !eco.value

// After:
// musttail + tailcc ensures the call becomes a jump (no stack growth)
%result = llvm.call tailcc @elm_function(%args) {musttail} : ...
llvm.return %result
```

**Why tailcc instead of fastcc:**
- `tailcc` is specifically designed for guaranteed tail call optimization
- Works more reliably with `musttail` across different targets
- Essential for functional languages where recursion replaces loops
- `fastcc` optimizes for speed but doesn't guarantee TCO

The `musttail` attribute is critical for:
- Recursive functions to avoid stack overflow
- Joinpoint-style tail recursion
- Converting recursive algorithms into efficient loops

**Runtime calls (C convention):**
```mlir
// Runtime functions use standard C calling convention
llvm.func @eco_alloc_custom(i32, i32, i32) -> !llvm.ptr

// Calls to runtime do NOT use tailcc - they use default C convention
%obj_ptr = llvm.call @eco_alloc_custom(%tag, %size, %scalar) : (i32, i32, i32) -> !llvm.ptr
%obj = llvm.ptrtoint %obj_ptr : !llvm.ptr to i64
```

**Closure calls:**
```mlir
// Before:
%result = eco.call(%closure, %arg) : (!eco.value, !eco.value) -> !eco.value

// After:
// Closure calls go through runtime dispatcher (C convention)
// TODO: Determine exact signature and calling convention for closures
// The runtime dispatcher handles arity checking and PAP extension
%closure_ptr = llvm.inttoptr %closure : i64 to !llvm.ptr
%result_ptr = llvm.call @eco_apply_closure(%closure_ptr, %args_array, %num_args)
              : (!llvm.ptr, !llvm.ptr, i32) -> !llvm.ptr
%result = llvm.ptrtoint %result_ptr : !llvm.ptr to i64
```

#### 4.5 Safepoint Lowering (No-Op)

File: `Passes/SafepointLowering.cpp`

For now, safepoints are eliminated without generating code:

```cpp
struct SafepointOpLowering : public OpConversionPattern<eco::SafepointOp> {
  using OpConversionPattern::OpConversionPattern;

  LogicalResult matchAndRewrite(eco::SafepointOp op, OpAdaptor adaptor,
                                ConversionPatternRewriter &rewriter) const override {
    // No-op: simply erase the safepoint
    // Future: generate llvm.experimental.gc.statepoint here
    rewriter.eraseOp(op);
    return success();
  }
};
```

#### 4.6 String Literal Lowering (UTF-8 → UTF-16)

File: `Passes/StringLiteralLowering.cpp`

```cpp
struct StringLiteralOpLowering : public OpConversionPattern<eco::StringLiteralOp> {
  LogicalResult matchAndRewrite(eco::StringLiteralOp op, OpAdaptor adaptor,
                                ConversionPatternRewriter &rewriter) const override {
    auto loc = op.getLoc();
    StringRef utf8Value = op.getValue();

    // Convert UTF-8 to UTF-16
    SmallVector<uint16_t> utf16Chars;
    convertUTF8ToUTF16(utf8Value, utf16Chars);

    // Create global constant for ElmString layout:
    // Header (8 bytes) + u16 chars[]
    auto module = op->getParentOfType<ModuleOp>();
    auto globalName = generateUniqueStringName(module);

    // Build the constant data: header + UTF-16 characters
    // Header: tag=Tag_String, size=char_count
    uint64_t header = buildStringHeader(utf16Chars.size());

    // Create LLVM global with the string data
    auto global = createStringGlobal(rewriter, module, globalName,
                                      header, utf16Chars);

    // Return address of the global
    Value addr = rewriter.create<LLVM::AddressOfOp>(loc, global);
    rewriter.replaceOp(op, addr);
    return success();
  }
};
```

#### 4.7 RC Elimination Pass

File: `Passes/RCElimination.cpp`

Simple pass that removes/errors on RC placeholder ops:
```cpp
void runOnOperation() override {
  getOperation()->walk([&](Operation *op) {
    if (isa<eco::IncrefOp, eco::DecrefOp, eco::FreeOp>(op)) {
      // In tracing GC mode, these should not exist
      op->emitError("RC operation not supported in tracing GC mode");
      signalPassFailure();
    }
  });
}
```

### Phase 5: Main Compiler Driver

File: `ecoc.cpp`

```cpp
int main(int argc, char **argv) {
  // Register command line options
  mlir::registerAsmPrinterCLOptions();
  mlir::registerMLIRContextCLOptions();
  mlir::registerPassManagerCLOptions();

  cl::opt<std::string> inputFilename(cl::Positional, ...);
  cl::opt<enum Action> emitAction("emit", ...);
  // Actions: DumpMLIR, DumpMLIREco, DumpMLIRLLVM, DumpLLVMIR, RunJIT

  cl::ParseCommandLineOptions(argc, argv, "Eco compiler\n");

  // Create context and register dialects
  DialectRegistry registry;
  func::registerAllExtensions(registry);
  LLVM::registerInlinerInterface(registry);

  MLIRContext context(registry);
  context.getOrLoadDialect<eco::EcoDialect>();
  context.getOrLoadDialect<func::FuncDialect>();
  context.getOrLoadDialect<cf::ControlFlowDialect>();
  context.getOrLoadDialect<arith::ArithDialect>();
  context.getOrLoadDialect<LLVM::LLVMDialect>();

  // Load .mlir input
  OwningOpRef<ModuleOp> module;
  if (loadMLIR(context, module))
    return 1;

  // Build pass pipeline
  PassManager pm(module.get()->getName());

  bool isLoweringToLLVM = emitAction >= DumpMLIRLLVM;

  if (isLoweringToLLVM) {
    // Stage 1: Eco → Eco
    pm.addPass(eco::createConstructLoweringPass());
    pm.addPass(eco::createRCEliminationPass());

    // Stage 2: Eco → cf/func
    pm.addPass(eco::createControlFlowLoweringPass());
    pm.addPass(mlir::createCanonicalizerPass());

    // Stage 3: Eco → LLVM
    pm.addPass(eco::createHeapOpsToLLVMPass());

    // Standard conversions
    pm.addPass(mlir::createConvertFuncToLLVMPass());
    pm.addPass(mlir::createConvertControlFlowToLLVMPass());
    pm.addPass(mlir::createArithToLLVMConversionPass());
  }

  if (failed(pm.run(*module)))
    return 1;

  // Handle output
  if (emitAction == RunJIT)
    return runJIT(*module);
  else if (emitAction == DumpLLVMIR)
    return dumpLLVMIR(*module);
  else
    module->dump();

  return 0;
}
```

### Phase 6: JIT Integration

Add JIT execution capability following `toyc.cpp`:

```cpp
int runJIT(ModuleOp module) {
  // Initialize LLVM targets
  llvm::InitializeNativeTarget();
  llvm::InitializeNativeTargetAsmPrinter();

  // Register translation
  mlir::registerBuiltinDialectTranslation(*module->getContext());
  mlir::registerLLVMDialectTranslation(*module->getContext());

  // Create execution engine
  mlir::ExecutionEngineOptions options;
  options.transformer = mlir::makeOptimizingTransformer(3, 0, nullptr);

  // Register runtime symbols
  options.jitTargetMachineBuilder = ...;
  options.symbolMap = [](llvm::orc::MangleAndInterner interner) {
    llvm::orc::SymbolMap map;
    map[interner("eco_alloc_custom")] =
        llvm::JITEvaluatedSymbol::fromPointer(&eco_alloc_custom);
    map[interner("eco_alloc_int")] =
        llvm::JITEvaluatedSymbol::fromPointer(&eco_alloc_int);
    // ... register all runtime functions
    return map;
  };

  auto engine = mlir::ExecutionEngine::create(module, options);
  if (!engine) {
    llvm::errs() << "Failed to create execution engine\n";
    return 1;
  }

  // Initialize the runtime
  Elm::Allocator::instance().initialize();
  Elm::Allocator::instance().initThread();

  // Run main
  auto result = engine->invokePacked("main");

  // Cleanup
  Elm::Allocator::instance().cleanupThread();

  return result ? 1 : 0;
}
```

## Heap Layout Reference

From `Heap.hpp`, key offsets for `eco.project` lowering:

| Type | Field | Offset (bytes) |
|------|-------|----------------|
| ElmInt | value | 8 |
| ElmFloat | value | 8 |
| ElmChar | value | 8 |
| Tuple2 | a | 8 |
| Tuple2 | b | 16 |
| Tuple3 | a | 8 |
| Tuple3 | b | 16 |
| Tuple3 | c | 24 |
| Cons | head | 8 |
| Cons | tail | 16 |
| Custom | ctor+unboxed | 8 |
| Custom | values[0] | 16 |
| Custom | values[N] | 16 + N*8 |
| Closure | n_values+max_values+unboxed | 8 |
| Closure | evaluator | 16 |
| Closure | values[0] | 24 |

## Testing Strategy

### Unit Tests
1. Individual pass tests with FileCheck
2. Type conversion tests
3. Runtime function wrapper tests

### Integration Tests
1. End-to-end `.mlir` → JIT execution tests
2. Memory allocation/GC stress tests
3. Closure and PAP tests

### Test Files Location
```
test/codegen/
├── construct-lowering.mlir
├── control-flow-lowering.mlir
├── heap-ops-lowering.mlir
├── full-pipeline.mlir
└── jit-tests/
    ├── simple-arithmetic.mlir
    ├── list-operations.mlir
    └── closure-tests.mlir
```

## Design Decisions (Resolved)

### D1: Tag Extraction Strategy
**Decision:** Combined approach.
- `Header.tag` (5-bit) identifies the object type (Int/Float/Custom/Cons/etc.)
- `Custom.ctor` (16-bit) identifies the constructor variant within Custom ADTs
- This supports full pattern matching where we may need to discriminate at both levels

### D2: Embedded Constants Handling
**Decision:** Add explicit `eco.constant` op.
- New `eco.constant` op creates embedded constants (Nil, True, False, Unit, Nothing, EmptyString, EmptyRec)
- `eco.project` will check for embedded constants before dereferencing when necessary
- This makes constant handling explicit in the IR

### D3: Unboxed Bitmap Handling
**Decision:** Carried as Eco dialect attributes.
- `eco.construct` and related ops carry `unboxed_bitmap` attribute
- Lowering uses these attributes to set the appropriate bitmap fields in heap objects
- Monomorphization is responsible for computing these bitmaps

### D4: GC Safepoint Implementation
**Decision:** No-op for now.
- `eco.safepoint` lowering generates nothing initially
- Full statepoint integration deferred to later phase
- GC only runs at the end of the Elm update loop, so no mid-computation safepoints needed initially
- Stack root tracking also deferred - will address when implementing proper GC integration

### D5: Function Calling Convention
**Decision:** tailcc for Eco-to-Eco, C for runtime.
- Eco functions use `tailcc` (tail call convention) for guaranteed TCO support
- `tailcc` is more reliable than `fastcc` for `musttail` across different targets
- Runtime calls (`@eco_alloc_*`, etc.) use standard C convention
- `musttail` attribute turns recursive calls into loops (essential for functional languages)

### D6: String Encoding
**Decision:** Convert UTF-8 → UTF-16 at lowering time.
- MLIR string literals remain UTF-8 (standard MLIR representation)
- `eco.string_literal` lowering converts to UTF-16 for `ElmString` storage
- Global constants emitted with proper UTF-16 encoding

### D7: eco.value Representation
**Decision:** Use i64 instead of ptr for `!eco.value` type.
- Embedded constants use tag bits in the HPointer representation
- LLVM's pointer semantics assume pointers reference valid memory
- Using `inttoptr` on small integers (embedded constants) causes undefined behavior
- i64 makes tagging explicit and allows clean bit manipulation
- Only convert to `ptr` when actually dereferencing heap memory (after checking for embedded constants)

### D8: Boxing/Unboxing Strategy
**Decision:** Explicit boxing via `eco.box`/`eco.unbox` ops.
- TODO: Details to be determined during implementation
- Monomorphization should insert box/unbox where needed
- Runtime provides `eco_alloc_int`, `eco_alloc_float` for boxing

### D9: Closure Calling Convention
**Decision:** Runtime dispatcher for closure calls.
- TODO: Exact signature and semantics to be determined during implementation
- Direct calls to known functions use `tailcc`
- Closure/PAP calls go through runtime dispatcher with C convention
- Runtime handles arity checking and PAP extension

## Implementation Order

### Step 1: Infrastructure
- [ ] Extend CMakeLists.txt for new passes and ecoc executable
- [ ] Create Passes.h and pass registration framework
- [ ] Create RuntimeExports.h/cpp with stub implementations
- [ ] Create ecoc.cpp skeleton with pipeline stages
- [ ] Add eco.constant op to Ops.td

### Step 2: Type System & Basic Lowering
- [ ] Implement EcoTypeConverter (eco.value → ptr)
- [ ] Implement RuntimeDecls insertion (declare @eco_alloc_* functions)
- [ ] Implement eco.return → func.return lowering
- [ ] Implement RCEliminationPass
- [ ] Implement eco.safepoint → no-op lowering

### Step 3: Constants & Primitives
- [ ] Implement eco.constant lowering (embedded constants)
- [ ] Implement eco.box lowering (primitive → heap object)
- [ ] Implement eco.unbox lowering (heap object → primitive)
- [ ] Test with simple constant and boxing examples

### Step 4: Heap Operations
- [ ] Implement eco.allocate_ctor lowering
- [ ] Implement eco.allocate_string lowering
- [ ] Implement eco.allocate_closure lowering
- [ ] Implement eco.project lowering (with offset calculations from Heap.hpp)
- [ ] Implement eco.construct lowering (→ allocate_ctor + stores)
- [ ] Implement eco.string_literal lowering (UTF-8 → UTF-16 conversion)
- [ ] Test with allocation and field access examples

### Step 5: Control Flow
- [ ] Implement eco.case lowering (tag extraction + cf.switch)
- [ ] Implement eco.joinpoint lowering (→ basic blocks)
- [ ] Implement eco.jump lowering (→ cf.br)
- [ ] Implement eco.crash lowering (→ runtime call + unreachable)
- [ ] Implement eco.expect lowering (→ conditional crash)
- [ ] Test with pattern matching examples

### Step 6: Calls & Closures
- [ ] Implement eco.call (direct) lowering with fastcc
- [ ] Implement eco.call with musttail attribute
- [ ] Implement eco.call (closure) lowering via runtime
- [ ] Implement eco.papCreate lowering
- [ ] Implement eco.papExtend lowering
- [ ] Test with function call and closure examples

### Step 7: JIT Integration
- [ ] Add LLVM target initialization
- [ ] Implement symbol map for runtime function registration
- [ ] Add Allocator initialization/cleanup in JIT wrapper
- [ ] Implement runJIT() function
- [ ] Test end-to-end JIT execution

### Step 8: Globals & Finishing
- [ ] Implement eco.global lowering
- [ ] Implement eco.load_global / eco.store_global lowering
- [ ] Implement eco.dbg lowering (optional debug prints)
- [ ] Write comprehensive test suite
- [ ] Documentation and examples

## Dependencies

- LLVM/MLIR 17+ (for opaque pointers)
- rapidcheck (existing, for testing)
- Existing runtime library (Allocator.hpp, Heap.hpp)
