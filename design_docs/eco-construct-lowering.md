# Construct Lowering: Construct Fusion Optimization

This document describes the Construct Fusion optimization for the Eco compiler, which optimizes record update patterns by replacing multiple field projections and a full reconstruction with a bulk copy and selective field updates.

## Table of Contents

1. [Overview](#overview)
2. [Pattern to Detect](#pattern-to-detect)
3. [Current vs Optimized Lowering](#current-vs-optimized-lowering)
4. [Implementation Approaches](#implementation-approaches)
5. [Runtime Support](#runtime-support)
6. [Profitability Analysis](#profitability-analysis)
7. [Edge Cases](#edge-cases)
8. [Implementation Phases](#implementation-phases)
9. [Unresolved Questions](#unresolved-questions)

---

## Overview

The Construct Fusion optimization detects patterns where most fields of a record/ADT are projected from an existing value and then used to construct a new value with only a few fields changed. Instead of N individual field loads followed by N field stores, we can optimize this to a single memcpy plus K stores (where K is the number of changed fields).

This optimization is particularly valuable for Elm's record update syntax, which is heavily used in Model-View-Update architectures.

---

## Pattern to Detect

### Record Update Pattern in Elm

```elm
{ record | name = newName, age = newAge }
```

### Current MLIR (unoptimized)

For a record with 5 fields, updating 2:

```mlir
%f0 = eco.project %record[0] : !eco.value -> !eco.value  // unchanged
%f1 = eco.project %record[1] : !eco.value -> !eco.value  // unchanged
%f2 = eco.project %record[2] : !eco.value -> !eco.value  // unchanged
// %new_name is the new value for field 3
// %new_age is the new value for field 4
%new = eco.construct(%f0, %f1, %f2, %new_name, %new_age) {tag = 0, size = 5}
```

---

## Current vs Optimized Lowering

### Current Lowering (unoptimized)

```llvm
; 3 loads for unchanged fields
%f0 = load ptr, %record + 16
%f1 = load ptr, %record + 24
%f2 = load ptr, %record + 32

; allocate new record
%new = call eco_alloc_custom(0, 5, 0)

; 5 stores for all fields
call eco_store_field(%new, 0, %f0)
call eco_store_field(%new, 1, %f1)
call eco_store_field(%new, 2, %f2)
call eco_store_field(%new, 3, %new_name)
call eco_store_field(%new, 4, %new_age)
```

**Cost:** 3 loads + 1 allocation + 5 stores = 9 operations

### Optimized Lowering

```llvm
; allocate new record
%new = call eco_alloc_custom(0, 5, 0)

; bulk copy (copies ctor/unboxed + all fields, skips header)
; Source offset 8 (skip header), size = 8 + 5*8 = 48 bytes
call llvm.memcpy(%new + 8, %record + 8, 48, false)

; overwrite only changed fields
call eco_store_field(%new, 3, %new_name)
call eco_store_field(%new, 4, %new_age)
```

**Cost:** 1 allocation + 1 memcpy + 2 stores = 4 operations

**Savings:** Eliminates 3 loads and 3 stores, replaces with vectorized memcpy.

---

## Implementation Approaches

### Approach A: New eco.record_update Op (Recommended)

Add a high-level op that explicitly represents record update semantics:

```tablegen
def Eco_RecordUpdateOp : Eco_Op<"record_update", [Pure]> {
  let summary = "Update specific fields of a record/ADT";
  let description = [{
    Creates a new record by copying an existing record and updating
    specific fields. More efficient than project-all + construct.

    Example:
    ```mlir
    %new = eco.record_update %old [3, 4] (%new_name, %new_age) {
      tag = 0, size = 5
    } : (!eco.value, !eco.value, !eco.value) -> !eco.value
    ```

    The `updated_indices` array specifies which field indices are being
    updated. The `new_values` operands provide the new values for those
    fields, in the same order as the indices.
  }];

  let arguments = (ins
    Eco_Value:$source,
    DenseI64ArrayAttr:$updated_indices,
    Variadic<Eco_AnyValue>:$new_values,
    I64Attr:$tag,
    I64Attr:$size,
    OptionalAttr<I64Attr>:$unboxed_bitmap
  );
  let results = (outs Eco_Value:$result);

  let hasVerifier = 1;
  let assemblyFormat = [{
    $source `[` $updated_indices `]` `(` $new_values `)` attr-dict
    `:` functional-type(operands, $result)
  }];
}
```

**Lowering Implementation:**

```cpp
struct RecordUpdateOpLowering : public OpConversionPattern<RecordUpdateOp> {
    LogicalResult matchAndRewrite(RecordUpdateOp op, OpAdaptor adaptor,
                                  ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();
        auto *ctx = rewriter.getContext();

        // 1. Allocate new Custom object
        int64_t tag = op.getTag();
        int64_t size = op.getSize();
        Value newObj = allocateCustom(rewriter, loc, tag, size);

        // 2. Copy from source (skip header, copy ctor/unboxed + fields)
        Value source = adaptor.getSource();
        int64_t copySize = 8 + size * 8;  // ctor/unboxed(8) + fields(size*8)
        emitMemcpy(rewriter, loc, newObj, source, /*srcOffset=*/8,
                   /*dstOffset=*/8, copySize);

        // 3. Overwrite updated fields
        auto indices = op.getUpdatedIndices();
        auto newValues = adaptor.getNewValues();
        for (auto [idx, value] : llvm::zip(indices, newValues)) {
            emitStoreField(rewriter, loc, newObj, idx, value);
        }

        // 4. Handle unboxed bitmap if needed
        if (auto unboxed = op.getUnboxedBitmap()) {
            emitSetUnboxed(rewriter, loc, newObj, *unboxed);
        }

        rewriter.replaceOp(op, newObj);
        return success();
    }
};
```

### Approach B: Pattern-Based Fusion Pass

Create an optimization pass that detects and transforms the pattern:

```cpp
class ConstructFusionPass : public PassWrapper<ConstructFusionPass,
                                                OperationPass<func::FuncOp>> {
    void runOnOperation() override {
        getOperation().walk([&](ConstructOp op) {
            if (auto candidate = analyzeConstruct(op)) {
                fuseConstruct(op, *candidate);
            }
        });
    }
};
```

**Detection Algorithm:**

```cpp
struct FusionCandidate {
    Value source;                      // Common source record
    SmallVector<int64_t> newIndices;   // Indices with new values
    SmallVector<Value> newValues;      // New values for those indices
};

std::optional<FusionCandidate> analyzeConstruct(ConstructOp op) {
    Value commonSource = nullptr;
    SmallVector<int64_t> projectedIndices;
    SmallVector<int64_t> newIndices;
    SmallVector<Value> newValues;

    for (auto [idx, field] : llvm::enumerate(op.getFields())) {
        if (auto project = field.getDefiningOp<ProjectOp>()) {
            // Check if projecting from same source
            if (!commonSource) {
                commonSource = project.getValue();
            } else if (commonSource != project.getValue()) {
                return std::nullopt;  // Multiple sources - can't fuse
            }

            // Check if index matches position (identity projection)
            if (project.getIndex() == static_cast<int64_t>(idx)) {
                projectedIndices.push_back(idx);
            } else {
                // Field reordering - more complex, skip for now
                return std::nullopt;
            }
        } else {
            newIndices.push_back(idx);
            newValues.push_back(field);
        }
    }

    // Must have a source record
    if (!commonSource) {
        return std::nullopt;
    }

    // Profitability check: worth fusing if copying more than changing
    if (projectedIndices.size() > newIndices.size()) {
        return FusionCandidate{commonSource, newIndices, std::move(newValues)};
    }
    return std::nullopt;
}
```

**Transformation:**

```cpp
void fuseConstruct(ConstructOp op, const FusionCandidate &candidate) {
    OpBuilder builder(op);

    // Create record_update op
    auto updateOp = builder.create<RecordUpdateOp>(
        op.getLoc(),
        op.getResult().getType(),
        candidate.source,
        builder.getDenseI64ArrayAttr(candidate.newIndices),
        candidate.newValues,
        op.getTagAttr(),
        op.getSizeAttr(),
        op.getUnboxedBitmapAttr()
    );

    // Replace construct with record_update
    op.replaceAllUsesWith(updateOp.getResult());
    op.erase();

    // DCE will clean up unused project ops
}
```

---

## Runtime Support

Add new runtime function for efficient record copying:

### Header Declaration

```cpp
// RuntimeExports.h

/// Copies a Custom object's data (excluding header) to a destination.
/// Used for record update optimization.
/// @param dest Pointer to destination Custom object (already allocated)
/// @param source Pointer to source Custom object
/// @param field_count Number of fields to copy
void eco_copy_custom_fields(void* dest, void* source, uint32_t field_count);
```

### Implementation

```cpp
// RuntimeExports.cpp

void eco_copy_custom_fields(void* dest, void* source, uint32_t field_count) {
    // Custom layout: Header(8) + ctor/unboxed(8) + fields[field_count * 8]
    // We copy everything after the header
    size_t copySize = 8 + field_count * 8;  // ctor/unboxed + fields

    std::memcpy(
        static_cast<char*>(dest) + sizeof(Header),
        static_cast<char*>(source) + sizeof(Header),
        copySize
    );
}
```

Alternatively, inline the memcpy directly in LLVM IR for better optimization:

```cpp
// In RecordUpdateOpLowering
void emitInlineMemcpy(ConversionPatternRewriter &rewriter, Location loc,
                      Value dest, Value src, int64_t size) {
    auto i8Ty = rewriter.getI8Type();
    auto ptrTy = LLVM::LLVMPointerType::get(rewriter.getContext());
    auto i64Ty = rewriter.getI64Type();
    auto i1Ty = rewriter.getI1Type();

    // GEP to skip header (8 bytes)
    auto offset = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, 8);
    auto destPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, dest,
                                                 ValueRange{offset});
    auto srcPtr = rewriter.create<LLVM::GEPOp>(loc, ptrTy, i8Ty, src,
                                                ValueRange{offset});

    // Emit llvm.memcpy intrinsic
    auto sizeConst = rewriter.create<LLVM::ConstantOp>(loc, i64Ty, size);
    auto isVolatile = rewriter.create<LLVM::ConstantOp>(loc, i1Ty, false);
    rewriter.create<LLVM::MemcpyOp>(loc, destPtr, srcPtr, sizeConst, isVolatile);
}
```

---

## Profitability Analysis

### When to Fuse

| Record Size | Changed Fields | Unchanged Fields | Decision |
|-------------|----------------|------------------|----------|
| 3 | 1 | 2 | Fuse (2 > 1) |
| 3 | 2 | 1 | Don't fuse (1 < 2) |
| 5 | 1 | 4 | Fuse (4 > 1) |
| 5 | 2 | 3 | Fuse (3 > 2) |
| 5 | 3 | 2 | Don't fuse (2 < 3) |
| 10 | 2 | 8 | Fuse (8 > 2) |
| 10 | 5 | 5 | Borderline |

### Heuristic

**Simple rule:** Fuse when `unchanged_fields > changed_fields`

### Cost Model

Without fusion:
- Cost = N loads + N stores = 2N memory operations

With fusion:
- Cost = 1 memcpy(N fields) + K stores
- memcpy cost ~ N/4 equivalent operations (vectorized, sequential access)
- Total ~ N/4 + K

**Net benefit when:** `2N > N/4 + K` → `K < 1.75N`

Since K < N always (otherwise no fields unchanged), fusion is almost always beneficial when any fields are unchanged. The simple heuristic `unchanged > changed` is conservative.

---

## Edge Cases

### 1. Reordered Fields

```mlir
%a = eco.project %rec[0]
%b = eco.project %rec[1]
%new = eco.construct(%b, %a, %c)  // a and b swapped
```

**Handling:** Phase 1 skips this case. Phase 2 could support by tracking permutation.

### 2. Partial Projection

Some fields from project, some computed:

```mlir
%f0 = eco.project %rec[0]
%f1 = eco.int.add %x, %y : i64    // computed
%new = eco.construct(%f0, %f1)
```

**Handling:** Track which fields are "unchanged" (project with matching index) vs "new" (anything else).

### 3. Different Constructor Tags

Source has tag 1, result has tag 2:

```mlir
%f0 = eco.project %rec[0]
%new = eco.construct(%f0, %f1) {tag = 2, ...}  // different tag
```

**Handling:** For now, don't fuse. The ctor field would need explicit overwrite after memcpy.

### 4. Unboxed Bitmap Differences

Source has different unboxed fields than result:

```mlir
// Source: field 0 is boxed
// Result: field 0 is unboxed
```

**Handling:** After memcpy, explicitly set the unboxed bitmap via `eco_set_unboxed`.

### 5. Multiple Sources

Fields projected from different records:

```mlir
%f0 = eco.project %rec1[0]
%f1 = eco.project %rec2[0]  // different source!
%new = eco.construct(%f0, %f1)
```

**Handling:** Don't fuse. No single source to copy from.

### 6. Non-Identity Projection

```mlir
%f = eco.project %rec[2]
%new = eco.construct(%f) {size = 1}  // f goes to index 0, not 2
```

**Handling:** Phase 1 skips (index mismatch). Phase 2 could handle with field mapping.

---

## Implementation Phases

### Phase 1: eco.record_update Op and Lowering

1. Add `eco.record_update` op to `Ops.td`
2. Implement op verifier (indices in range, count matches values)
3. Implement `RecordUpdateOpLowering` in `EcoToLLVM.cpp`
4. Add tests for direct `eco.record_update` usage
5. Optionally add `eco_copy_custom_fields` to RuntimeExports

### Phase 2: Fusion Pass

1. Create `ConstructFusionPass` in new file `Passes/ConstructFusion.cpp`
2. Implement pattern detection with identity-projection requirement
3. Implement transformation from `project*+construct` to `record_update`
4. Add profitability heuristic (`unchanged > changed`)
5. Add pass to pipeline (Stage 1: Eco → Eco)
6. Add tests for fusion detection

### Phase 3: Advanced Optimizations

1. Support field reordering with permutation tracking
2. Support different tags (copy + overwrite ctor field)
3. Integrate with escape analysis for true in-place updates
4. Add cost model tuning based on benchmarks

---

## Unresolved Questions

### 1. Approach Selection

**Options:**
- **A)** New `eco.record_update` op generated by frontend (Elm → Eco IR)
- **B)** Pattern-matching pass that fuses `project*+construct` into `record_update`
- **C)** Both: frontend generates `record_update` when obvious, pass catches remaining cases

### 2. Profitability Threshold

What's the minimum savings to justify fusion?

**Options:**
- **A)** Always fuse when any field is unchanged (`unchanged >= 1`)
- **B)** Fuse when majority unchanged (`unchanged > changed`)
- **C)** Fuse when significant majority (`unchanged > 2 * changed`)
- **D)** Use cost model with memcpy overhead estimate

### 3. Field Reordering Support

Should we support fusing when field order changes?

```mlir
%a = eco.project %rec[0]
%b = eco.project %rec[1]
%new = eco.construct(%b, %a, %c)  // swapped a, b
```

**Options:**
- **A)** Phase 1: Identity only, Phase 2: Add reordering support
- **B)** Support reordering from the start (more complex but more general)
- **C)** Never support reordering (simpler, covers 99% of record updates)

### 4. In-Place Updates (Escape Analysis)

Should this pass integrate with escape analysis for true mutation?

```mlir
// If %record is not used after this:
%new = eco.record_update %record [3] (%new_val) ...
// Could become:
eco.store_field %record[3], %new_val  // in-place, no allocation!
```

**Options:**
- **A)** Phase 1: Always copy, separate escape analysis pass later
- **B)** Integrate escape analysis into this pass
- **C)** Defer entirely to LLVM's optimization passes

### 5. memcpy vs Field-by-Field Copy

For small records, memcpy overhead may exceed individual loads.

**Options:**
- **A)** Always use memcpy (simpler, let LLVM optimize small cases)
- **B)** Use memcpy only for records > N fields (tune N)
- **C)** Generate inline loads/stores for small records, memcpy for large

### 6. Tag Handling

When source and result have same tag, should we:

**Options:**
- **A)** Always include tag in memcpy region (simpler)
- **B)** Skip tag, rely on allocation setting it (slightly more efficient)
- **C)** Add assertion that tags match, error if they don't

### 7. Dead Code Elimination

After fusion, the original `eco.project` ops may become dead. Should we:

**Options:**
- **A)** Let standard DCE pass clean them up
- **B)** Eagerly delete them in the fusion pass
- **C)** Mark them for deletion but defer to avoid iterator invalidation

---

## References

- Current implementation: `runtime/src/codegen/Passes/EcoToLLVM.cpp`
- Op definitions: `runtime/src/codegen/Ops.td`
- Heap layout: `runtime/src/allocator/Heap.hpp`
- Related design: `/work/design_docs/llvm-optimization-ideas.md`
