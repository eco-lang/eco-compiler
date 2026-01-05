Below is a self‑contained design / implementation plan for the **Construct Fusion Optimization** in Eco, integrating the clarifications we’ve discussed (especially around semantics and immutability).

---

# Construct Fusion & `eco.record_update` – Design and Implementation Plan

## 1. Goals and Context

Elm code frequently uses record updates:

```elm
{ record | name = newName, age = newAge }
```

The naive lowering pattern is:

1. Project each field from `record` (`eco.project`).
2. Reconstruct a new record with `eco.construct`, passing all fields (unchanged + changed).

This results in many loads and stores. The Construct Fusion optimization replaces these with:

- A *single bulk copy* of the original record (memcpy‑style), and
- A few field overwrites for the changed fields.

This is especially important for Elm’s MVU workloads, where records tend to be moderately sized and frequently updated.

Eco has strict immutability: **never mutate after construction**; no write barriers are needed.  The design must preserve this.

---

## 2. High‑Level Strategy

We introduce a dedicated high‑level IR op and a fusion pass:

1. **`eco.record_update` op** (new)
    - Frontend or early Eco IR emits this for obvious record update semantics.
    - Semantically: *allocate a fresh record*, copy fields from a source record, then overwrite listed fields with new values. The source record is never mutated.

2. **ConstructFusionPass (Eco→Eco)**
    - Eco‑level optimization pass that detects `eco.project* + eco.construct` patterns and rewrites them into `eco.record_update` where profitable.
    - Uses a conservative pattern: identity projections from a single source record, same tag/size.

3. **Future, separate pass: In‑place Update via Escape Analysis (optional)**
    - A later optimization may turn *some* `eco.record_update` ops into true in‑place updates when it is *semantically safe* (source record provably dead).
    - This pass is distinct and must not change observable program behavior (e.g., it cannot touch cases like the `bob` / `alice` example where the original record is still needed).

---

## 3. Semantics and Immutability

### 3.1. Elm Behavior

Given:

```elm
let
    bob = { name = "bob" }
    alice = { bob | name = "alice" }
in
    (bob, alice)
```

Semantic requirements:

- `bob` and `alice` *must* refer to distinct heap objects.
- `bob.name` remains `"bob"`.
- `alice.name` is `"alice"`.

### 3.2. `eco.record_update` Semantics

`eco.record_update` is explicitly designed to be **pure**:

- It *always* allocates a new record object.
- It copies the original record’s data (ctor/unboxed + all fields) into the new object.
- It overwrites only the specified fields in the new object.
- The source object is not modified.

This directly preserves Elm’s immutability: every high‑level record update is a “copy+modify”, never “modify in place”.

---

## 4. IR Extension: `eco.record_update` Op

### 4.1. Op Definition

From the Construct Lowering design:

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

Key points:

- `source: !eco.value` – the record we are logically copying.
- `updated_indices: DenseI64ArrayAttr` – field indices to overwrite.
- `new_values: variadic Eco_AnyValue` – new values for those indices.
- `tag`, `size`, `unboxed_bitmap` – layout metadata for the new record.

### 4.2. Verifier

The verifier should enforce:

- `updated_indices.size == new_values.size`.
- Each index is in `[0, size)`.
- Indices are strictly increasing (avoid duplicates, keep it simple).
- (Optional) In debug mode, assert that tag/size match the `source`’s runtime layout; this helps catch misuse.

---

## 5. Lowering `eco.record_update` to LLVM

### 5.1. Overview

Lowering is a single pattern (`RecordUpdateOpLowering`) in `EcoToLLVM.cpp`, as sketched in the doc:

1. Allocate a new “Custom” record object.
2. Copy ctor/unboxed + fields from the source.
3. Overwrite the updated fields with the new values.
4. Optionally, set the unboxed bitmap.

### 5.2. Detailed Steps

Pseudo‑implementation (from the design):

```cpp
struct RecordUpdateOpLowering : public OpConversionPattern<RecordUpdateOp> {
    LogicalResult matchAndRewrite(RecordUpdateOp op, OpAdaptor adaptor,
                                  ConversionPatternRewriter &rewriter) const override {
        auto loc = op.getLoc();

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

Key properties:

- **Allocation is always performed** (immutability preserved).
- **Single memcpy** replaces multiple loads/stores.
- Tag/unboxed are copied along with fields; if tag/size differ from the source, we *do not* generate `record_update` in the first place (see fusion pass below).

### 5.3. memcpy Implementation

You can either:

- Call a small runtime helper `eco_copy_custom_fields` that wraps `std::memcpy`.
- Or emit `llvm.memcpy` directly in the LLVM dialect, as sketched in the design.

Initial design choice:

- **Always use memcpy** for simplicity and rely on LLVM to shrink/inline for small records. We can later add a size‑based threshold if benchmarks warrant it.

---

## 6. Construct Fusion Pass

### 6.1. Purpose

Transform the common pattern:

```mlir
%f0 = eco.project %record[0]
%f1 = eco.project %record[1]
%f2 = eco.project %record[2]
...
%new = eco.construct(%f0, %f1, %f2, %new_name, %new_age) {tag = 0, size = 5}
```

into:

```mlir
%new = eco.record_update %record [3, 4] (%new_name, %new_age) {
  tag = 0, size = 5
} : ...
```

This avoids N projections, N stores, and instead does one memcpy + K stores.

### 6.2. Placement in Pipeline

- Runs as an Eco→Eco pass in the early optimization stage (Stage 1: Eco → Eco), before lowering to LLVM.
- After basic SSA formation, but before canonicalization / DCE, so the patterns are still transparent.

### 6.3. Pattern and Restrictions (Phase 1)

For the initial implementation, we use a **conservative pattern**:

- All fields in the `eco.construct` must come from either:
    - An `eco.project` from a *single* source record, or
    - Some non‑project expression (i.e., a “new” value).
- Each `eco.project` must be an **identity projection**:
    - `eco.project %src[idx]` must feed the field at position `idx` in the `construct`.
- The `construct`’s `tag` and `size` must be the same as the source record’s layout.
    - If tags/sizes differ, we **do not** fuse (edge case 3).
- Fields must all come from the same `source` value:
    - If fields are taken from multiple records, we do not fuse (edge case 5).

These choices match the “Phase 1: identity only, same tag” approach in the doc.

### 6.4. Detection Algorithm

The design already sketches a suitable algorithm:

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

    // Profitability: fuse if copying more fields than we’re changing
    if (projectedIndices.size() > newIndices.size()) {
        return FusionCandidate{commonSource, newIndices, std::move(newValues)};
    }
    return std::nullopt;
}
```

### 6.5. Profitability Heuristic

We adopt the design’s **simple rule**:

> Fuse when `unchanged_fields > changed_fields`.

Rationale:

- Without fusion: ~`2N` memory operations (N loads + N stores).
- With fusion: `~N/4 + K` (memcpy plus K stores). Net benefit whenever `K < 1.75N`, which is almost always when any fields are unchanged.
- The `unchanged > changed` rule is conservative and easy to reason about.

### 6.6. Transformation

From the design:

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

Notes:

- We do **not** mutate the source record; we create `record_update` which, by its lowering, allocates and copies.
- After this pass, a standard DCE/canonicalizer pass will remove the now‑dead `eco.project` uses.

---

## 7. In‑Place Updates and Escape Analysis (Future Work)

### 7.1. Motivation

The design mentions an advanced optimization: if the original record is *not used afterward*, we could perform a true in‑place update:

```mlir
// Before:
%new = eco.record_update %record [3] (%new_val) ...

// After (advanced optimization):
eco.store_field %record[3], %new_val  // in-place, no allocation!
```



### 7.2. Separation of Concerns

To preserve semantics and simplicity:

- **Phase 1:** `eco.record_update` always allocates a new record (copy+update). This is the only behavior that the frontend and other passes rely on.
- **Phase 2:** A dedicated “record update in‑place” pass — later in the pipeline — may rewrite a subset of `record_update`s to in‑place `eco.store_field` operations, but *only* when it is provably safe (i.e., the source record does not “escape” or have further uses).

This respects immutability at the IR abstraction level and isolates the tricky alias/escape reasoning.

### 7.3. Safety Condition (Conceptual)

While not fully specified in the existing docs, a safe conceptual rule is:

- For `%r = eco.record_update %src [...]`, we may rewrite to in-place if:
    - `%src` has no uses after this `record_update` (SSA liveness).
    - `%src` does not alias any other live variable (requires alias analysis / object identity reasoning).
    - We’re in a context where in‑place modification is acceptable for the GC and runtime (no write barriers needed for Elm immutability).

This step is explicitly deferred to **Phase 3: Advanced Optimizations** in the design.

---

## 8. Edge Cases and Non‑Goals (Phase 1)

We stick with the documented handling:

1. **Reordered Fields:**
    - Pattern: swapping indices in `construct`.
    - Handling (Phase 1): skip fusion; future work may track permutations.

2. **Partial Projection / Computed Fields:**
    - Allowed; those fields simply go into `updated_indices` with new values.

3. **Different Constructor Tags:**
    - If source and result’s tags differ, **do not fuse** in Phase 1.

4. **Unboxed Bitmap Differences:**
    - `record_update` can explicitly set a new unboxed bitmap after memcpy via `emitSetUnboxed`.

5. **Multiple Source Records:**
    - If projections come from multiple records, skip fusion.

6. **Non‑identity Projection:**
    - If `project.index != construct position`, skip fusion in Phase 1.

These choices keep the first implementation small and robust while still capturing the main Elm record update patterns.

---

## 9. Testing Plan

1. **Unit tests for `eco.record_update`:**
    - Direct IR tests that:
        - Create small records via `construct`.
        - Apply `record_update` to change various fields.
        - Check resulting values at runtime.
    - Include tests with:
        - No changed fields (should still copy).
        - Single changed field.
        - Multiple changed fields.
        - Different unboxed bitmap.

2. **Fusion tests:**
    - Eco MLIR patterns with `project* + construct` should be rewritten to `record_update`.
    - Verify both:
        - The IR before/after the ConstructFusionPass.
        - Runtime behavior (results identical to unoptimized variant).

3. **Immutability regression tests:**
    - Patterns like the `bob` / `alice` example:
        - Verify that both original and updated records remain distinct and correct, even after all optimizations.

4. **Performance benchmarks:**
    - Elm programs with heavy record updates:
        - Compare runtime and allocation behavior with fusion enabled vs disabled.

---

## 10. Summary of Design Decisions

- **Front‑end op:** Use a new `eco.record_update` op to represent “copy+update” record semantics.
- **Semantics:** `record_update` *always* allocates a new record and never mutates the source; this preserves Elm’s immutability.
- **Lowering:** Implement `RecordUpdateOpLowering` with allocation + memcpy + field overwrites, optionally adjusting unboxed bitmap.
- **Fusion pass:** Add a ConstructFusionPass that:
    - Detects `project* + construct` patterns with a single source, identity projections, and identical tag/size.
    - Applies the heuristic `unchanged_fields > changed_fields` for profitability.
    - Rewrites to `eco.record_update` and leaves dead code cleanup to DCE.
- **Advanced optimizations:** Defer field reordering support, tag‑changing fusion, and in‑place updates with escape analysis to later phases.

This gives you a clear, implementable path that is faithful to Elm’s semantics, leverages Eco’s immutability and tracing GC design, and offers a straightforward way to grow into more advanced optimizations.

