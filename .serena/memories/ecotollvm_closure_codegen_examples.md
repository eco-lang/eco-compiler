# EcoToLLVM Closure Lowering - Detailed Code Examples

## Example 1: Fast Closure Call (Typed Closure Calling)

**Scenario**: Compiler analyzed closure flow and determined all callsites have same structure.

**Elm Code**:
```elm
applyTwice : (Int -> Int) -> Int -> Int
applyTwice f x = f (f x)

main = applyTwice (\a -> a + 1) 5
```

**Generated MLIR** (before EcoToLLVM):
```mlir
%fn = eco.papCreate @lambda, 1 {_closure_kind = 42, _fast_evaluator = @lambda$cap} : !eco.value
%result = eco.call %fn(%x) {_dispatch_mode = "fast", _closure_kind = 42, _fast_evaluator = @lambda$cap, _capture_abi = []} : !eco.value
```

**LLVM Generated** (after EcoToLLVM):

```llvm
; Fast clone: no captures, just takes x
define i64 @lambda$cap(i64 %x) {
    %add = add i64 %x, 1
    ret i64 %add
}

; papCreate lowering
define i64 @applyTwice_main_block(...) {
    ; 1. Allocate closure via eco_alloc_closure
    %fn_ptr = addressof @lambda$cap
    %closure_hptr = call i64 @eco_alloc_closure(ptr %fn_ptr, i32 1)
    
    ; (No captures, so skip storing values)
    
    ; 2. Call the function
    %x = 5
    
    ; 3. eco.call lowering (fast path)
    ; No captures to load, just call directly
    %result = call i64 @lambda$cap(i64 %x)
    
    ret i64 %result
}
```

**LLVM Operations**:
1. `eco_alloc_closure(ptr, i32)` → allocate closure object
2. Direct `call @lambda$cap(i64)` → no array construction

---

## Example 2: Heterogeneous Closure Call (Generic Path)

**Scenario**: Different branches produce closures with different captures.

**Elm Code**:
```elm
test : Bool -> (Int -> Int)
test flag =
    if flag then
        let add1 = 1
        in \x -> x + add1
    else
        let add2 = 2
        in \x -> x + add2

main = (test True) 5
```

**Generated MLIR**:
```mlir
%cond = ...
%closure = scf.if %cond -> !eco.value {
    ; Then: closure with capture=1
    %c1 = eco.constant 1
    %closure_then = eco.papCreate @add_lambda, 1, %c1 
                    {_closure_kind = 42, _fast_evaluator = @add_lambda$cap}
    scf.yield %closure_then
} else {
    ; Else: closure with capture=2
    %c2 = eco.constant 2
    %closure_else = eco.papCreate @add_lambda, 1, %c2 
                    {_closure_kind = 42, _fast_evaluator = @add_lambda$cap}
    scf.yield %closure_else
}
; At merge, compiler analyzes: all closures have same _closure_kind but different captures
; Marks as heterogeneous to be safe
%result = eco.call %closure(5) {_dispatch_mode = "closure", _closure_kind = "heterogeneous"} : i64
```

**LLVM Generated**:

```llvm
; Fast clone: takes capture + param
define i64 @add_lambda$cap(i64 %capture, i64 %x) {
    %sum = add i64 %x, %capture
    ret i64 %sum
}

; Generic clone: takes closure pointer, unpacks, calls fast clone
define i64 @add_lambda$clo(ptr %closure_ptr, i64 %x) {
    ; Load capture from closure->values[0] (offset 24)
    %cap_ptr = getelementptr i8, ptr %closure_ptr, i64 24
    %capture = load i64, ptr %cap_ptr
    
    ; Call fast clone with unpacked capture
    %result = call i64 @add_lambda$cap(i64 %capture, i64 %x)
    ret i64 %result
}

define i64 @test(...) {
    ; Branch creates closures with same kind but different captures
    %closure = ...  ; either closure_then or closure_else
    
    ; 2. emitClosureCall path (heterogeneous)
    ; Resolve closure HPointer
    %closure_ptr = call ptr @eco_resolve_hptr(i64 %closure)
    
    ; Load evaluator from closure.evaluator (offset 16)
    %eval_ptr_ptr = getelementptr i8, ptr %closure_ptr, i64 16
    %evaluator = load ptr, ptr %eval_ptr_ptr
    
    ; Call with closure pointer (not unpacked captures)
    %result = call i64 %evaluator(ptr %closure_ptr, i64 5)
    
    ret i64 %result
}
```

**Key Difference from Fast Path**:
- Evaluator is `@add_lambda$clo`, not `@add_lambda$cap`
- Pass closure pointer, let evaluator unpack
- Single evaluator works for all ABI variants

---

## Example 3: Legacy Indirect Call (Fallback)

**Scenario**: No typed closure calling attributes (pipeline gap or Elm kernel function).

**Code**:
```c++
// emitInlineClosureCall pseudocode from EcoToLLVMClosures.cpp:665-898

define i64 @legacy_call(i64 %closure_hptr, i64 %arg0) {
    ; 1. Resolve closure HPointer
    %closure_ptr = call ptr @eco_resolve_hptr(i64 %closure_hptr)
    
    ; 2. Load packed field at offset 8
    %packed_ptr = getelementptr i8, ptr %closure_ptr, i64 8
    %packed = load i64, ptr %packed_ptr
    
    ; 3. Extract n_values (bits 0-5)
    %mask = 0x3F
    %n_values = and i64 %packed, %mask
    
    ; 4. Extract unboxed bitmap (bits 12+)
    %shift = lshr i64 %packed, 12
    %unboxed_bitmap = %shift
    
    ; 5. Load evaluator pointer at offset 16
    %eval_ptr_ptr = getelementptr i8, ptr %closure_ptr, i64 16
    %evaluator = load ptr, ptr %eval_ptr_ptr
    
    ; 6. Compute total args = n_values + 1
    %total_args = add i64 %n_values, 1
    
    ; 7. Allocate args array on stack
    %args_array = alloca i64, %total_args
    
    ; 8. Copy captured values (uses scf.while loop)
    %i0 = 0
    %loop = scf.while %cond(%i = %i0) {
        %cond_check = icmp slt %i, %n_values
        scf.condition(%cond_check, %i)
    } do {
        ^bb0(%i_iter : i64):
        
        ; Load captured value from closure->values[i]
        %offset = mul i64 %i_iter, 8
        %val_offset = add i64 24, %offset
        %val_ptr = getelementptr i8, ptr %closure_ptr, i64 %val_offset
        %captured = load i64, ptr %val_ptr
        
        ; Check if unboxed
        %shifted = lshr i64 %unboxed_bitmap, %i_iter
        %is_unboxed = and i64 %shifted, 1
        %is_unboxed_bit = icmp ne %is_unboxed, 0
        
        ; Conditionally box
        %boxed = scf.if %is_unboxed_bit -> i64 {
            ; Box via eco_alloc_int
            %box_result = call i64 @eco_alloc_int(i64 %captured)
            scf.yield %box_result
        } else {
            ; Already HPointer, pass through
            scf.yield %captured
        }
        
        ; Store to args_array[i]
        %dst_ptr = getelementptr i64, ptr %args_array, i64 %i_iter
        store i64 %boxed, ptr %dst_ptr
        
        ; Next iteration
        %i_next = add i64 %i_iter, 1
        scf.yield %i_next
    }
    
    ; 9. Store new arg at args_array[n_values]
    %arg_idx = %n_values
    %arg_ptr = getelementptr i64, ptr %args_array, i64 %arg_idx
    ; Box new arg (if needed based on origNewArgTypes)
    ; For Int (i64), box via eco_alloc_int
    %boxed_arg0 = call i64 @eco_alloc_int(i64 %arg0)
    store i64 %boxed_arg0, ptr %arg_ptr
    
    ; 10. Call evaluator(args_array)
    %eval_sig = type ptr (ptr) -> ptr  ; (ptr) -> ptr wrapper convention
    %result_ptr = call %eval_sig %evaluator(ptr %args_array)
    
    ; 11. Unbox result
    %result_hptr = ptrtoint %result_ptr to i64
    ; For Int result (i64), unbox via resolve + load
    %resolved = call ptr @eco_resolve_hptr(i64 %result_hptr)
    %val_ptr = getelementptr i8, ptr %resolved, i64 8
    %result = load i64, ptr %val_ptr
    
    ret i64 %result
}
```

**Key Points**:
- scf.while used for captured values loop (nests inside scf.if if needed)
- Unboxed captures conditionally boxed based on bitmap
- New args boxed based on origNewArgTypes
- Result unboxed based on origResultType
- Evaluator expects (ptr) signature

---

## Example 4: Wrapper Function for Args-Array Convention

**Scenario**: Kernel function called via closure with args-array convention.

**Source Function** (before wrapper):
```c++
// Original typed signature
i64 kernel_add(i64 x, i64 y);
```

**Wrapper Function** (generated by getOrCreateWrapper):

```llvm
; Wrapper adapts from (ptr) -> ptr to (i64, i64) -> i64
define ptr @__closure_wrapper_kernel_add(ptr %args_array) {
    %i64_ty = type i64
    %f64_ty = type double
    %ptr_ty = type ptr
    
    ; 1. Load args from array (stored as HPointer-encoded i64)
    %x_ptr = getelementptr i64, ptr %args_array, i64 0
    %x_hptr = load i64, ptr %x_ptr
    %y_ptr = getelementptr i64, ptr %args_array, i64 1
    %y_hptr = load i64, ptr %y_ptr
    
    ; 2. Convert args based on original types
    ; (Both are Int params in this case)
    
    ; x: unbox from HPointer
    %x_resolved = call ptr @eco_resolve_hptr(i64 %x_hptr)
    %x_off8 = getelementptr i8, ptr %x_resolved, i64 8
    %x_val = load i64, ptr %x_off8
    
    ; y: unbox from HPointer
    %y_resolved = call ptr @eco_resolve_hptr(i64 %y_hptr)
    %y_off8 = getelementptr i8, ptr %y_resolved, i64 8
    %y_val = load i64, ptr %y_off8
    
    ; 3. Call target function with converted args
    %result = call i64 @kernel_add(i64 %x_val, i64 %y_val)
    
    ; 4. Box result (Int -> HPointer)
    %result_hptr = call i64 @eco_alloc_int(i64 %result)
    
    ; 5. Convert to ptr for wrapper return
    %result_ptr = inttoptr i64 %result_hptr to ptr
    
    ret ptr %result_ptr
}
```

**Usage in papCreate**:
```llvm
define i64 @make_add_closure() {
    ; Get wrapper function (takes ptr) -> ptr signature
    %wrapper_ptr = addressof @__closure_wrapper_kernel_add
    
    ; Allocate closure with max arity 2
    %closure = call i64 @eco_alloc_closure(ptr %wrapper_ptr, i32 2)
    
    ; Store captured values (none in this case)
    
    ret i64 %closure
}
```

**Call via closure**:
```llvm
define i64 @call_via_closure(i64 %closure) {
    ; Using legacy inline path (no typed closure attrs)
    
    ; Allocate args array for 2 args
    %args = alloca i64, 2
    
    ; Box arguments
    %arg0 = 3  ; i64 value
    %arg0_boxed = call i64 @eco_alloc_int(i64 %arg0)
    store %arg0_boxed, ptr %args, offset 0
    
    %arg1 = 5  ; i64 value
    %arg1_boxed = call i64 @eco_alloc_int(i64 %arg1)
    store %arg1_boxed, ptr %args, offset 8
    
    ; Load closure evaluator (the wrapper)
    %closure_ptr = call ptr @eco_resolve_hptr(i64 %closure)
    %eval_ptr_ptr = getelementptr i8, ptr %closure_ptr, i64 16
    %eval = load ptr, ptr %eval_ptr_ptr
    
    ; Call wrapper with args array
    %result_ptr = call ptr %eval(ptr %args)
    
    ; Unbox result
    %result_hptr = ptrtoint %result_ptr to i64
    %result_ptr2 = inttoptr %result_hptr to ptr
    %result_off8 = getelementptr i8, ptr %result_ptr2, i64 8
    %result = load i64, ptr %result_off8
    
    ret i64 %result
}
```

---

## Example 5: papExtend - Saturated vs Unsaturated

**Saturated Case** (saturating the closure):

```llvm
; Before saturation: closure with max_values=3, currently n_values=1
; papExtend adds 2 new args, saturating it

define i64 @papExtend_saturated(i64 %closure, i64 %arg1, i64 %arg2) {
    ; remainingArity = 2, numNewArgs = 2, so isSaturated = true
    
    ; Path 1: Fast path (if typed closure attrs present)
    %closure_ptr = call ptr @eco_resolve_hptr(i64 %closure)
    
    ; Load captured value at offset 24 (capture[0])
    %cap0_ptr = getelementptr i8, ptr %closure_ptr, i64 24
    %cap0 = load i64, ptr %cap0_ptr
    ; (Assume capture is i64, no conversion needed)
    
    ; Call fast clone with all captures + new args
    ; Signature: i64 (i64 cap0, i64 arg1, i64 arg2)
    %result = call i64 @lambda$cap(i64 %cap0, i64 %arg1, i64 %arg2)
    
    ret i64 %result
}
```

**Unsaturated Case** (extending the closure):

```llvm
; Before: closure with max_values=3, currently n_values=1
; papExtend adds only 1 new arg, so max_values=3, n_values=2
; Not saturated, so create new extended closure

define i64 @papExtend_unsaturated(i64 %closure, i64 %arg1) {
    ; remainingArity = 2, numNewArgs = 1, so isSaturated = false
    
    ; Allocate args array for 1 new arg
    %args = alloca i64, 1
    
    ; Store new arg (assume it's already i64, no boxing needed)
    %arg_ptr = getelementptr i64, ptr %args, i64 0
    store i64 %arg1, ptr %arg_ptr
    
    ; Call runtime helper to extend closure
    ; Signature: i64 (i64 closure, i64* args, i32 num_args, i64 bitmap)
    %num_args = 1
    %bitmap = 0  ; No unboxed values in new args
    %extended = call i64 @eco_pap_extend(i64 %closure, ptr %args, i32 %num_args, i64 %bitmap)
    
    ret i64 %extended
}
```

**Runtime Helper** (`eco_pap_extend`):
```c++
extern "C" uint64_t eco_pap_extend(
    uint64_t closure_hptr,
    uint64_t* new_args,
    uint32_t num_new_args,
    uint64_t new_args_bitmap
) {
    // 1. Resolve closure HPointer
    Closure* closure = resolve_hptr(closure_hptr);
    
    // 2. Load current state
    uint32_t n_values = closure->packed & 0x3F;
    uint32_t max_values = (closure->packed >> 6) & 0x3F;
    uint64_t unboxed = closure->packed >> 12;
    
    // 3. Check if we can extend (not saturated)
    uint32_t remaining = max_values - n_values;
    if (num_new_args > remaining) {
        // Error: can't extend beyond max_values
        return 0;
    }
    
    // 4. Append new args to closure->values
    for (uint32_t i = 0; i < num_new_args; ++i) {
        closure->values[n_values + i] = new_args[i];
        
        // Update unboxed bitmap
        if (new_args_bitmap & (1ULL << i)) {
            unboxed |= (1ULL << (n_values + i));
        }
    }
    
    // 5. Update packed field: new n_values
    closure->packed = (n_values + num_new_args) | (max_values << 6) | (unboxed << 12);
    
    return closure_hptr;  // Return same closure (modified in-place)
}
```

---

## Example 6: Closure with Unboxed Captures

**Scenario**: Closure captures a raw Float value (unboxed).

**Elm Code**:
```elm
makeMultiplier : Float -> (Int -> Int)
makeMultiplier factor =
    \x -> x * floor factor
```

**Closure Layout** (after papCreate):
```
Closure {
    header = ...
    packed = n_values:1 | max_values:6 | unboxed:(1 << 0)  // bit 0 set = capture[0] is unboxed
    evaluator = @wrapper
    values[0] = <raw i64 bits of factor (f64 as i64)>
}
```

**Legacy Call Path** (using emitInlineClosureCall):

```llvm
define i64 @call_with_unboxed_capture(i64 %closure) {
    ; 1. Load captured value
    %closure_ptr = call ptr @eco_resolve_hptr(i64 %closure)
    %cap_ptr = getelementptr i8, ptr %closure_ptr, i64 24
    %cap_val = load i64, ptr %cap_ptr
    
    ; 2. Check unboxed bitmap
    %packed_ptr = getelementptr i8, ptr %closure_ptr, i64 8
    %packed = load i64, ptr %packed_ptr
    %unboxed_bitmap = lshr i64 %packed, 12
    %cap_is_unboxed = and i64 %unboxed_bitmap, 1
    %cap_unboxed_bit = icmp ne i64 %cap_is_unboxed, 0
    
    ; 3. Conditionally box the capture
    %cap_boxed = scf.if %cap_unboxed_bit -> i64 {
        ; Box unboxed capture via eco_alloc_int
        ; (Actually would be more sophisticated for f64, but simplified here)
        %boxed = call i64 @eco_alloc_int(i64 %cap_val)
        scf.yield %boxed
    } else {
        ; Already HPointer, pass through
        scf.yield %cap_val
    }
    
    ; 4. Store to args array
    %args = alloca i64, 1
    %args_ptr = getelementptr i64, ptr %args, i64 0
    store i64 %cap_boxed, ptr %args_ptr
    
    ; 5. Call evaluator
    %eval_ptr = getelementptr i8, ptr %closure_ptr, i64 16
    %eval = load ptr, ptr %eval_ptr
    %result_ptr = call ptr %eval(ptr %args)
    
    ; 6. Unbox result
    %result = ptrtoint %result_ptr to i64
    ; ... further unboxing based on result type
    
    ret i64 %result
}
```

**Key Insight**: The unboxed bitmap tells the lowering which captures need boxing before being passed to the wrapper. This is critical because:
1. Unboxed captures store raw bits (f64 as i64, i64, i16 as i64)
2. Wrapper expects all args as HPointer-encoded i64
3. Must box unboxed captures so wrapper can unbox them properly

---

## Type System at Each Stage

```
┌─────────────┬──────────────┬────────────────┬──────────────┐
│ Elm         │ MLIR (ECO)   │ LLVM (EcoToLLVM)│ Native       │
├─────────────┼──────────────┼────────────────┼──────────────┤
│ Int         │ !eco.value   │ i64 (HPointer) │ i64 (heap)   │
│ Float       │ !eco.value   │ i64 (HPointer) │ f64/i64      │
│             │              │                │              │
│ (capturing) │ (unboxed)    │ bitcast/shift  │ raw bits     │
│ Closure     │ papCreate    │ store as i64   │              │
└─────────────┴──────────────┴────────────────┴──────────────┘

Fast Path Conversion:
  MLIR eco.value (i64 HPointer)
  → LLVM load from closure values[i] (i64)
  → bitcast if f64 (i64 → f64)
  → inttoptr if ptr
  → direct call @lambda$cap(i64, ...)

Legacy Path Conversion:
  MLIR eco.value (i64 HPointer)
  → LLVM load from closure values[i] (i64)
  → conditional box if unboxed (call eco_alloc_int)
  → store to args array
  → wrapper loads from array, unboxes
  → calls @kernel_add(i64, i64)
  → wrapper boxes result
  → unboxes result
```

---

## Closure Kind Flow

```
AbiCloning.elm (frontend):
  Analyze closure parameter usage
  │
  ├─ Same capture ABI across callsites
  │  → Single clone (fast path)
  │  → Tag with _closure_kind = N (Known)
  │
  └─ Different capture ABIs
     → Multiple clones (one per ABI)
     → Tag with _closure_kind = "heterogeneous"

MLIR Generation:
  eco.papCreate
  │
  ├─ Has _closure_kind = N
  │  → Store _fast_evaluator = @fn$cap
  │  → Store _capture_abi = [Type, ...]
  │
  └─ Has _closure_kind = heterogeneous
     → evaluator = @fn$clo (generic clone)
     → Still have _closure_kind for diagnostics

EcoToLLVM Lowering:
  eco.call / papExtend
  │
  ├─ Has _dispatch_mode = "fast"
  │  → emitFastClosureCall
  │  → Load captures
  │  → Direct call @fn$cap(cap0, cap1, ...)
  │
  ├─ Has _dispatch_mode = "closure"
  │  → emitClosureCall
  │  → Load evaluator from closure
  │  → Indirect call evaluator(closure_ptr, ...)
  │
  └─ Has _dispatch_mode = "unknown"
     → emitUnknownClosureCall
     → Emit warning
     → Fall back to legacy inline path
```
