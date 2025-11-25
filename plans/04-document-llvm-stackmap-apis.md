# Plan: Document LLVM Stack Map APIs

**Related PLAN.md Sections**:
- §1.2.2 LLVM Stack Map Integration
- §3.3 GC Stack Root Tracing

## Objective

Research and document LLVM's statepoint and stackmap intrinsics for garbage collection integration. Create a comprehensive reference document.

## Background

From PLAN.md §1.2.2:
> Research LLVM stack map and statepoint APIs
> Build a small example program in LLVM using recursion to create stack frames with heap pointers

From PLAN.md §3.3:
> LLVM stack map generation
> Runtime stack root registration
> Safepoint insertion in generated code

## Tasks

### 1. Research LLVM Documentation

Fetch and summarize information from:
- LLVM Statepoints documentation: https://llvm.org/docs/Statepoints.html
- LLVM Stack Maps documentation: https://llvm.org/docs/StackMaps.html
- LLVM GC documentation: https://llvm.org/docs/GarbageCollection.html

### 2. Document Key Concepts

Create `design_docs/llvm_stackmap_integration.md` covering:

#### 2.1 Stack Maps Overview
- What stack maps are and why they're needed for precise GC
- The relationship between stack maps and garbage collection
- When stack maps are generated (at safepoints)

#### 2.2 Statepoint Intrinsics
- `@llvm.experimental.gc.statepoint` - the main intrinsic
- `@llvm.experimental.gc.result` - extracting return values
- `@llvm.experimental.gc.relocate` - getting relocated pointers after GC
- Parameter meanings and usage patterns

#### 2.3 Stack Map Format
- Binary format of the stack map section
- How to parse stack map records at runtime
- Location types (register, direct, indirect, constant)

#### 2.4 Integration Points
- How the MLIR/LLVM lowering should insert statepoints
- What the runtime needs to do to use stack maps
- How to iterate over GC roots during collection

### 3. Provide Code Examples

Include code snippets showing:
- LLVM IR with statepoint intrinsics
- C++ code to parse stack map sections
- Pseudocode for stack walking during GC

### 4. Document ECO-Specific Considerations

- How ECO's 40-bit logical pointers interact with stack maps
- Integration with NurserySpace and OldGenSpace
- Thread-local vs global considerations

### 5. List Open Questions

Document any questions that need resolution:
- Which LLVM version to target?
- Statepoint vs older gc.root approach?
- How to handle stack maps with our logical pointer representation?

## Success Criteria

1. Document exists at `design_docs/llvm_stackmap_integration.md`
2. Covers all key LLVM APIs (statepoint, gc.result, gc.relocate)
3. Includes stack map binary format description
4. Has code examples
5. Links to official LLVM documentation

## Files to Create

- **Create**: `design_docs/llvm_stackmap_integration.md`

## Research Sources

1. https://llvm.org/docs/Statepoints.html
2. https://llvm.org/docs/StackMaps.html
3. https://llvm.org/docs/GarbageCollection.html
4. LLVM source: `llvm/include/llvm/IR/Statepoint.h`
5. LLVM source: `llvm/include/llvm/CodeGen/StackMaps.h`

## Estimated Complexity

Low - research and documentation only, no code changes required.
