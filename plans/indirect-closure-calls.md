# Indirect Closure Calls Design

## Overview

This document describes the design for implementing indirect closure calls in the Eco dialect - calling a function through a closure value rather than a known function symbol.

## Background

### Direct vs Indirect Calls

**Direct call** - function known at compile time:
```mlir
%result = eco.call @add_two(%a, %b) : (i64, i64) -> i64
```

**Indirect call** - function stored in a closure variable:
```mlir
%result = "eco.call"(%closure, %x) {remaining_arity = 1} : (!eco.value, !eco.value) -> !eco.value
```

### Why Indirect Calls Matter

Indirect calls are essential for higher-order functions - the foundation of functional programming:

```elm
-- List.map needs to call an unknown function
List.map square [1, 2, 3]  -- [1, 4, 9]
List.map double [1, 2, 3]  -- [2, 4, 6]

-- applyTwice calls f without knowing what f is
applyTwice : (a -> a) -> a -> a
applyTwice f x = f (f x)
```

### Closure Layout (from Heap.hpp)

```
┌─────────────────────────────────────────────────────────────┐
│ Header (8 bytes)                                            │
├─────────────────────────────────────────────────────────────┤
│ n_values:6 │ max_values:6 │ unboxed:52   (8 bytes packed)   │
├─────────────────────────────────────────────────────────────┤
│ evaluator: function pointer (8 bytes)                       │
├─────────────────────────────────────────────────────────────┤
│ values[0], values[1], ... (captured args)                   │
└─────────────────────────────────────────────────────────────┘

Offsets:
- Header: 0
- Packed field: 8
- Evaluator: 16
- Values array: 24
```

Where:
- `n_values` = number of arguments already captured
- `max_values` = total arity of underlying function
- `remaining_arity` = `max_values - n_values`

### The Challenge

Even with compile-time type information, we don't know `n_values` statically. A closure of type `Int -> Int` could be:

| Origin | n_values | max_values |
|--------|----------|------------|
| Fresh 1-arg function | 0 | 1 |
| PAP of 2-arg function | 1 | 2 |
| PAP of 3-arg function | 2 | 3 |

All have remaining arity 1, but different captured value counts. We must read `n_values` from the closure at runtime.

## Design

### 1. Ops.td Changes

Add `remaining_arity` attribute to `eco.call` for indirect calls:

```tablegen
def Eco_CallOp : Eco_Op<"call"> {
  let summary = "Call function or closure";
  let description = [{
    Function/closure application. Used for both direct calls to known
    functions and indirect calls through closures.

    For direct calls, specify the callee attribute:
    ```mlir
    %result = eco.call @function_name(%arg1, %arg2)
      : (!eco.value, i64) -> !eco.value
    ```

    For indirect calls, omit callee and pass closure as first operand.
    The remaining_arity attribute specifies how many arguments the closure
    needs. This must equal the number of additional operands (saturated call).
    ```mlir
    %result = "eco.call"(%closure, %arg) {remaining_arity = 1 : i64}
      : (!eco.value, !eco.value) -> !eco.value
    ```

    For partial application of closures, use eco.papExtend instead.
  }];

  let arguments = (ins
    Variadic<Eco_AnyValue>:$operands,
    OptionalAttr<FlatSymbolRefAttr>:$callee,
    OptionalAttr<BoolAttr>:$musttail,
    OptionalAttr<I64Attr>:$remaining_arity  // For indirect calls
  );
  let results = (outs Variadic<Eco_AnyValue>:$results);
}
```

### 2. Semantics

For indirect calls (`eco.call` without `callee`):
- First operand is the closure
- Remaining operands are the new arguments
- `remaining_arity` attribute must be provided
- Must be a saturated call: `num_new_args == remaining_arity`
- For partial application, use `eco.papExtend` instead

### 3. Lowering Algorithm

```
Input: closure, new_args[0..N-1], remaining_arity=N

1. closurePtr = inttoptr closure
2. packed = load i64 from closurePtr + 8
3. n_values = packed & 0x3F  (bits 0-5)
4. evaluator = load ptr from closurePtr + 16
5. total_args = n_values + N
6. args = alloca i64[total_args]
7. Loop i = 0 to n_values-1:
     args[i] = load from closurePtr + 24 + i*8
8. For j = 0 to N-1:
     args[n_values + j] = new_args[j]
9. result = indirect call evaluator(args)
10. return ptrtoint result
```

### 4. Control Flow Graph

```
                    ┌─────────────────┐
                    │  Load n_values  │
                    │  Load evaluator │
                    │  Alloca args[]  │
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
                    │   i = 0         │
                    └────────┬────────┘
                             │
              ┌──────────────▼──────────────┐
              │  ^copy_loop:                │
              │  if (i >= n_values) goto    │◄──────┐
              │     ^copy_done              │       │
              └──────────────┬──────────────┘       │
                             │ (i < n_values)       │
              ┌──────────────▼──────────────┐       │
              │  args[i] = closure.values[i]│       │
              │  i = i + 1                  │───────┘
              └─────────────────────────────┘

              ┌──────────────▼──────────────┐
              │  ^copy_done:                │
              │  args[n_values+0] = new_arg0│  (unrolled)
              │  args[n_values+1] = new_arg1│
              │  ...                        │
              └──────────────┬──────────────┘
                             │
              ┌──────────────▼──────────────┐
              │  result = call evaluator(   │
              │              args)          │
              └─────────────────────────────┘
```

### 5. Lowering Implementation

```cpp
// In CallOpLowering::matchAndRewrite

if (!callee) {
    // === Indirect call through closure ===

    if (!op.getRemainingArity()) {
        return op.emitError("indirect calls require remaining_arity attribute");
    }

    int64_t remainingArity = op.getRemainingArity().value();
    auto allOperands = adaptor.getOperands();
    Value closureI64 = allOperands[0];
    auto newArgs = allOperands.drop_front(1);

    if (newArgs.size() != static_cast<size_t>(remainingArity)) {
        return op.emitError("remaining_arity must equal number of new arguments");
    }

    auto i8Ty = IntegerType::get(ctx, 8);
    auto i64Ty = IntegerType::get(ctx, 64);
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);

    // Convert closure to pointer
    Value closurePtr = rewriter.create<LLVM::IntToPtrOp>(loc, ptrTy, closureI64);

    // Load packed field at offset 8: [n_values:6 | max_values:6 | unboxed:52]
    auto offset8 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 8);
    auto packedPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, closurePtr,
                                                   ValueRange{offset8});
    Value packed = rewriter.create<LLVM::LoadOp>(loc, i64Ty, packedPtr);

    // Extract n_values (bits 0-5)
    auto mask6 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 0x3F);
    Value nValues = rewriter.create<LLVM::AndOp>(loc, packed, mask6);

    // Load evaluator pointer at offset 16
    auto offset16 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 16);
    auto evalPtrPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, closurePtr,
                                                    ValueRange{offset16});
    Value evaluator = rewriter.create<LLVM::LoadOp>(loc, ptrTy, evalPtrPtr);

    // Total args = n_values + remainingArity
    auto remainingConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, remainingArity);
    Value totalArgs = rewriter.create<LLVM::AddOp>(loc, nValues, remainingConst);

    // Allocate args array on stack
    Value argsArray = rewriter.create<LLVM::AllocaOp>(loc, ptrTy, i64Ty, totalArgs);

    // === Create loop to copy captured values ===
    Block *currentBlock = rewriter.getInsertionBlock();
    Region *region = currentBlock->getParent();

    // Split current block - ops after eco.call go to continuation
    Block *contBlock = rewriter.splitBlock(currentBlock, rewriter.getInsertionPoint());

    Block *loopCheck = rewriter.createBlock(region, contBlock->getIterator());
    Block *loopBody = rewriter.createBlock(region, contBlock->getIterator());
    Block *loopDone = rewriter.createBlock(region, contBlock->getIterator());

    // Current block: jump to loop with i=0
    rewriter.setInsertionPointToEnd(currentBlock);
    auto zero = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 0);
    rewriter.create<LLVM::BrOp>(loc, ValueRange{zero}, loopCheck);

    // Loop check: if i >= n_values, exit loop
    loopCheck->addArgument(i64Ty, loc);  // %i
    Value i = loopCheck->getArgument(0);
    rewriter.setInsertionPointToStart(loopCheck);
    auto cmp = rewriter.create<LLVM::ICmpOp>(loc, LLVM::ICmpPredicate::uge, i, nValues);
    rewriter.create<LLVM::CondBrOp>(loc, cmp, loopDone, loopBody);

    // Loop body: copy closure->values[i] to args[i]
    rewriter.setInsertionPointToStart(loopBody);
    auto offset24 = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 24);
    auto eight = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 8);
    auto valueOffset = rewriter.create<LLVM::MulOp>(loc, i, eight);
    auto totalOffset = rewriter.create<LLVM::AddOp>(loc, offset24, valueOffset);
    auto srcPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, closurePtr,
                                                ValueRange{totalOffset});
    Value capturedVal = rewriter.create<LLVM::LoadOp>(loc, i64Ty, srcPtr);

    auto dstPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i64Ty, argsArray,
                                                ValueRange{i});
    rewriter.create<LLVM::StoreOp>(loc, capturedVal, dstPtr);

    // i++, back to loop check
    auto one = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 1);
    Value iNext = rewriter.create<LLVM::AddOp>(loc, i, one);
    rewriter.create<LLVM::BrOp>(loc, ValueRange{iNext}, loopCheck);

    // Loop done: copy new arguments (unrolled since count is compile-time known)
    rewriter.setInsertionPointToStart(loopDone);
    for (size_t j = 0; j < newArgs.size(); ++j) {
        auto jConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, j);
        auto idx = rewriter.create<LLVM::AddOp>(loc, nValues, jConst);
        auto dstPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i64Ty, argsArray,
                                                    ValueRange{idx});
        rewriter.create<LLVM::StoreOp>(loc, newArgs[j], dstPtr);
    }

    // Indirect call through evaluator
    // Evaluator signature: ptr @eval(ptr %args) -> ptr
    auto evalFuncTy = LLVM::LLVMFunctionType::get(ptrTy, {ptrTy});
    auto callOp = rewriter.create<LLVM::CallOp>(loc, evalFuncTy, evaluator,
                                                 ValueRange{argsArray});

    // Convert result ptr to i64
    Value result = rewriter.create<LLVM::PtrToIntOp>(loc, i64Ty, callOp.getResult());

    // Branch to continuation
    rewriter.create<LLVM::BrOp>(loc, contBlock);

    // Replace op uses with result
    rewriter.replaceOp(op, result);
    return success();
}
```

### 6. Example

**Input MLIR:**
```mlir
func.func @apply_twice(%f: !eco.value, %x: !eco.value) -> !eco.value {
    // f is a closure of type (a -> a), remaining arity = 1
    %first = "eco.call"(%f, %x) {remaining_arity = 1 : i64}
        : (!eco.value, !eco.value) -> !eco.value
    %second = "eco.call"(%f, %first) {remaining_arity = 1 : i64}
        : (!eco.value, !eco.value) -> !eco.value
    eco.return %second : !eco.value
}
```

**Output LLVM IR (conceptual):**
```llvm
define i64 @apply_twice(i64 %f, i64 %x) {
entry:
    %closure = inttoptr i64 %f to ptr
    %packed_ptr = getelementptr i8, ptr %closure, i64 8
    %packed = load i64, ptr %packed_ptr
    %n_values = and i64 %packed, 63

    %eval_ptr = getelementptr i8, ptr %closure, i64 16
    %evaluator = load ptr, ptr %eval_ptr

    %total = add i64 %n_values, 1
    %args = alloca i64, i64 %total

    br label %copy_loop

copy_loop:
    %i = phi i64 [0, %entry], [%i_next, %copy_body]
    %done = icmp uge i64 %i, %n_values
    br i1 %done, label %copy_done, label %copy_body

copy_body:
    %offset = add i64 24, mul(i64 %i, 8)
    %src = getelementptr i8, ptr %closure, i64 %offset
    %val = load i64, ptr %src
    %dst = getelementptr i64, ptr %args, i64 %i
    store i64 %val, ptr %dst
    %i_next = add i64 %i, 1
    br label %copy_loop

copy_done:
    ; Store new argument at args[n_values]
    %new_slot = getelementptr i64, ptr %args, i64 %n_values
    store i64 %x, ptr %new_slot

    ; Indirect call
    %result_ptr = call ptr %evaluator(ptr %args)
    %first = ptrtoint ptr %result_ptr to i64

    ; Second call follows same pattern...
    ...
}
```

## Implementation Tasks

- [x] Add `remaining_arity` attribute to `Eco_CallOp` in `Ops.td`
- [x] Update `CallOpLowering` in `EcoToLLVM.cpp` to handle indirect calls
- [x] Add verifier to ensure `remaining_arity` is set for indirect calls
- [x] Add verifier to ensure `remaining_arity == num_new_args`
- [x] Update test `call_indirect.mlir` to use `remaining_arity` attribute
- [x] Update test `closure_higher_order.mlir`
- [x] Update test `map_closure.mlir`
- [x] Add function signature conversion pattern for `func.func` with `!eco.value` types
- [ ] Add documentation to `eco-lowering.md`

## Notes

- The loop for copying captured values is typically small (0-3 iterations)
- LLVM's optimizer can unroll small loops if beneficial
- For partial application through closures, use `eco.papExtend` instead
- The evaluator function always has signature `ptr @eval(ptr %args) -> ptr`
