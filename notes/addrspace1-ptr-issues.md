# Hard Issues with `eco.value` as `ptr addrspace(1)`

This document describes the structurally difficult problems encountered
during implementation. These are not bugs that can be fixed by adding
more casts in more places — they are design-level tensions in the
approach.

---

## Issue 1: Two type systems with incompatible ABI at every kernel boundary

### The problem

After the type converter change, the IR has **two incompatible calling
conventions coexisting in the same module**:

- Elm-to-Elm functions: `!eco.value` → `ptr addrspace(1)`
- Kernel functions (C++): `!eco.value` → `i64` (via `KernelFuncOpLowering`)

Every call from Elm code to a kernel function crosses an ABI boundary
that requires explicit `ptrtoint`/`inttoptr` casts on every
`!eco.value` operand and result. This boundary is **not** localized to
one place in the code — it is distributed across:

1. `eco::CallOp` direct calls to kernel functions
   (`EcoToLLVMClosures.cpp`, `CallOpLowering`)
2. `func::CallOp` to kernel functions created by earlier passes
   (`EcoControlFlowToSCF.cpp` creates `func.call @Elm_Kernel_Utils_equal`)
3. The closure wrapper (`getOrCreateWrapper`) which bridges between
   the runtime's args-array convention and typed Elm functions
4. `emitInlineClosureCall` / `eco_closure_call_saturated` / `eco_apply_closure`
   — runtime functions that return `i64` HPointers

### Why it is hard

MLIR's `applyFullConversion` applies the type converter uniformly to
all operand types. The `func::CallOp` lowering from
`populateFuncToLLVMConversionPatterns` uses the type converter to
determine operand types, producing `ptr<1>` for `!eco.value` args. But
the target `llvm.func` for a kernel has `i64` params. This creates a
verifier failure (`operand type mismatch: '!llvm.ptr<1>' != 'i64'`).

The fix requires intercepting **every** `func::CallOp` that targets a
kernel function and inserting casts. But `func::CallOp` lowering is a
shared MLIR pattern that doesn't know about the Eco kernel convention.
We added a `KernelCallOpLowering` pattern with higher priority
(benefit=10), but:

- The standard `populateFuncToLLVMConversionPatterns` also registers a
  `func::CallOp` pattern, and **pattern priority is not guaranteed to
  be respected across different pattern sets** in MLIR's greedy
  rewriter. The framework may choose the standard pattern first in
  some cases.
- The `eco::CallOp` lowering in `EcoToLLVMClosures.cpp` **also**
  handles kernel calls internally (creating `func::CallOp` with i64
  types). This means the same ABI boundary is handled by two
  independent code paths that must agree on convention.
- Future passes that create `func::CallOp` to kernel functions must
  also know about this boundary.

### Impact

457 test failures on first attempt (reduced to ~55 after adding the
pattern, but not fully resolved). Stage 6 of bootstrap fails with the
same error.

### Structural question

Is the dual-convention approach (ptr<1> for Elm, i64 for kernels)
worth the complexity? An alternative would be to convert kernel
declarations to `ptr<1>` too and let the C++ implementations receive
`ptr<1>` (which is the same bits as `uint64_t` at the machine level).
This would eliminate the ABI boundary entirely, but requires verifying
that LLVM doesn't misoptimize `ptr addrspace(1)` arguments that are
actually opaque 64-bit tagged values passed to C functions.

---

## Issue 2: Allocation group lowering creates unresolvable materialization chains

### The problem

`lowerAllocGroups` runs **before** `applyFullConversion`. It produces
merge-block arguments typed as `i64` (the raw HPointer from init-at-pointer
calls) and wraps them in `UnrealizedConversionCastOp(ptr<1> → eco.value)`
to feed downstream Eco ops that expect `!eco.value`.

After `applyFullConversion` runs, the type converter converts
`eco.value → ptr<1>`, creating a target materialization
`UnrealizedConversionCastOp(eco.value → ptr<1>)`. The chain is now:

```
i64 → inttoptr → ptr<1> → UnrealizedCast → eco.value → UnrealizedCast → ptr<1>
```

The `reconcileUnrealizedCasts` pass (which runs later in the pipeline)
resolves **identity chains** where `A → B → A`. The sub-chain
`ptr<1> → eco.value → ptr<1>` IS identity and should resolve. But
in practice this depends on MLIR correctly identifying the paired
casts.

The deeper problem: `castToI64` (also in the alloc group code) creates
`UnrealizedConversionCastOp(eco.value → i64)` for field values. After
conversion, `eco.value` becomes `ptr<1>`, yielding:

```
ptr<1> → UnrealizedCast → eco.value → UnrealizedCast → i64
```

This is `ptr<1> → eco.value → i64`. The reconcile pass cannot resolve
this because `ptr<1> ≠ i64`. The cast chain has no valid resolution.

### Why it is hard

The allocation group lowering operates on **mixed Eco + LLVM IR**
before the type converter runs. It must produce values that are
consumable by both:
- Runtime C functions (which need `i64`)
- Downstream Eco ops (which need `!eco.value`, soon to be `ptr<1>`)

With `eco.value = i64`, both consumers wanted the same type, so a
single `UnrealizedConversionCastOp(i64 → eco.value)` worked. With
`eco.value = ptr<1>`, the two consumers want different types from the
same `i64` source, and the pre-conversion IR cannot express `ptr<1>`
(that type doesn't exist yet at this stage).

### Impact

~90 test failures from leftover `unrealized_conversion_cast` ops that
prevent LLVM translation.

### Structural question

Should `lowerAllocGroups` be refactored to run **after** type
conversion (as a post-conversion LLVM dialect pass), or should it emit
`LLVM::IntToPtrOp` / `LLVM::PtrToIntOp` directly instead of using
`UnrealizedConversionCastOp`? The former requires significant
restructuring; the latter means the pre-conversion pass must know about
the post-conversion type mapping, breaking the separation between
Eco IR and LLVM IR.

---

## Issue 3: The closure wrapper straddles three type domains

### The problem

`getOrCreateWrapper` builds a function with signature
`ptr (*)(ptr)` that bridges between:

1. The runtime's args-array convention (all args are `i64` HPointers
   in a `void**` array)
2. The target Elm function's typed signature (where `!eco.value` args
   are now `ptr<1>`, Int args are `i64`, Float args are `f64`)
3. The wrapper's own return value, which is `ptr` (address space 0) —
   the generic function-pointer type

After the change:
- Loading an arg from the array yields `i64`. For `!eco.value` params,
  this must become `ptr<1>` via `inttoptr` before calling the target.
- The target function returns `ptr<1>` for `!eco.value` results. The
  wrapper must convert this to `ptr` (AS0) for its return type. This
  requires `ptrtoint(ptr<1> → i64)` then `inttoptr(i64 → ptr)`.
- The `origFuncTypes` pre-scan map determines how to convert, but if
  the target function isn't in the map (e.g., it was already lowered
  to `llvm.func`), the wrapper falls back to heuristics that don't
  distinguish `ptr<1>` (eco.value) from `ptr` (code pointer).

### Why it is hard

The wrapper is generated **during** conversion, in the middle of
`applyFullConversion`. At this point:
- Some functions have been converted (have `ptr<1>` signatures)
- Some haven't (still have `eco.value` signatures)
- The `origFuncTypes` map has the **pre-conversion** types
- The runtime symbol cache has a mix of `func::FuncOp` and
  `LLVM::LLVMFuncOp` entries

The wrapper must correctly handle all combinations, and the address
space distinction between `ptr` (AS0, code pointers) and `ptr<1>`
(AS1, GC pointers) adds a dimension that didn't exist before. A
single missed conversion produces garbage bits at runtime — the
`resolve() bad HPointer` crashes.

### Impact

71 runtime crashes (SIGABRT from assertion failures, SIGSEGV from
dereferencing garbage pointers).

### Structural question

The wrapper is inherently complex because it mediates between the
runtime (C, untyped) and compiled Elm code (typed). With the old
`eco.value = i64` mapping, `i64` was the universal currency — the
wrapper loaded `i64` from the array, the target function took `i64`,
and the return was `i64`. All three domains agreed.

With `ptr<1>`, the wrapper must translate at every boundary. This
tripled the number of conversion paths. Is this complexity justified
for the GC-visibility benefit, or would a different approach
(e.g., keeping `i64` in the wrapper and only using `ptr<1>` in the
body of Elm functions) be more tractable?

---

## Issue 4: Embedded HPointer constants are non-pointer values in pointer type

### The problem

Eco's embedded constants (`True = 3 << 40`, `Nil = 5 << 40`, etc.)
are not heap pointers. They are tagged sentinel values where the
upper bits encode the constant kind and the lower 40 bits are zero.
After the change, these become:

```llvm
%nil = inttoptr i64 5497558138880 to ptr addrspace(1)
```

This is a `ptr addrspace(1)` that does **not** point to any
allocation. It is a synthetic bit pattern masquerading as a pointer.

### Why it is concerning

Today, with the manual `StatepointConversion` pass, this works because:
- RS4GC is not enabled
- The manual pass explicitly handles `inttoptr` of constants (via
  `stripIntToPtr`)
- No LLVM optimization pass sees these as "real" pointers

But the **stated motivation** for this change is to prepare for RS4GC
adoption. RS4GC's INV-2 says constants (including `inttoptr` of
constants) are excluded from gc-live and never relocated — so
**RS4GC itself handles this correctly**.

However, LLVM optimization passes that run **before** RS4GC may
still cause problems:
- `InstCombine` may fold `icmp eq %nil, null` to `false` (since the
  constant is non-null), which is correct for Eco but could interact
  badly with other optimizations.
- Alias analysis may assume `ptr addrspace(1)` values don't alias
  with other address spaces, which is true but could expose
  previously-hidden optimization opportunities that change behavior.
- Null-pointer checks: LLVM may assume `inttoptr(non-zero) != null`,
  which is correct for Eco's constants but adds an implicit invariant.

### Impact

No known test failures from this issue today. It is a latent risk
for the RS4GC migration path.

### Structural question

The plan (Decision 7) chose `inttoptr(i64 constant) → ptr<1>` over
`llvm.mlir.zero : ptr<1>` to avoid overloading null-pointer
semantics. This is sound. But it means every `icmp` that compares an
`!eco.value` against an embedded constant must first `ptrtoint` the
value back to `i64` (since you can't meaningfully compare two
`ptr<1>` values that aren't real pointers). This adds casts around
every case-expression scrutinee comparison, every equality check
against `Nil`/`True`/`False`, etc. — and those casts are the exact
`ptrtoint` operations that break RS4GC's relocation chain.

Is there a representation that avoids this tension — one where
embedded constants don't require `ptrtoint` for comparison?

---

## Issue 5: BFToLLVM has its own type converter that must stay in sync

### The problem

`BFToLLVM.cpp` defines `BFTypeConverter` with its own
`eco.value → ptr<1>` conversion and its own source/target
materializations. This is a **separate type converter instance** from
`EcoTypeConverter`. The two must agree on the mapping.

If someone changes `EcoTypeConverter` without updating
`BFTypeConverter` (or vice versa), the two passes will produce
incompatible types for `!eco.value` values that flow between BF and
Eco ops.

### Why it is hard

The BF pass runs before the Eco pass (line 83 vs 84 in
`EcoPipeline.cpp`). It produces LLVM dialect ops with `ptr<1>` for
`eco.value`. The Eco pass then runs and must consume these values
consistently. If the BF pass's type converter has slightly different
materialization behavior, leftover `unrealized_conversion_cast` ops
can result.

### Impact

Small — currently only affects BF-specific tests. But it is a
maintenance hazard.

### Structural question

Should `BFToLLVM` reuse `EcoTypeConverter` instead of defining its
own? This would require restructuring the BF pass to depend on the
Eco pass's header, or extracting the type converter into a shared
utility.

---

## Summary: Is the design viable?

The `ptr addrspace(1)` representation is **architecturally correct**
for the long-term goal of RS4GC adoption. The spike results in
`plans/migrate-to-rewritestatepointsforgc.md` confirm that RS4GC
requires `ptr<1>` throughout and cannot work with `i64`.

However, the implementation reveals that the **transitional cost** is
high. The old `eco.value = i64` representation had the property that
every consumer (runtime, Elm code, closure wrappers, heap slots)
wanted the same type. With `ptr<1>`, we introduce a type boundary at
every interaction with:
- C runtime functions (i64)
- Heap storage (i64)
- Closure capture slots (i64)
- Global variables (i64)
- Embedded constants (i64 bit patterns)

The 249 test failures break down as:

| Category | Count | Root cause |
|----------|-------|------------|
| Kernel call ABI mismatch | ~55 | Issue 1 |
| Unresolvable materializations | ~90 | Issue 2 |
| Runtime crashes | ~71 | Issue 3 |
| Wrong output | ~33 | Downstream effects |

### Design alternatives to consider

1. **Keep `i64` everywhere, use RS4GC's `addrspacecast` approach.**
   Some GC implementations use `addrspacecast(i64* → ptr<1>*)` only
   at gc-live bundle insertion points, not throughout the IR. This
   keeps the uniform `i64` representation and only introduces `ptr<1>`
   at the specific points where RS4GC needs to see them.

2. **Convert kernel declarations to `ptr<1>` too.** Since `ptr<1>` and
   `i64` are the same machine-level value on x86-64, the C++ kernel
   implementations would receive `ptr<1>` values that are actually
   `uint64_t` bits. This eliminates Issue 1 entirely but requires
   verifying that LLVM doesn't misoptimize through the C function
   boundary.

3. **Move the ABI boundary casts into the runtime function declarations.**
   Instead of converting at every call site, declare the runtime
   functions with `ptr<1>` signatures in LLVM IR and add
   `ptrtoint`/`inttoptr` inside the runtime function bodies (or use
   LLVM's `addrspacecast`). This localizes the boundary to function
   declarations rather than spreading it across all call sites.

4. **Use a custom LLVM GC strategy instead of address spaces.**
   Define an Eco-specific `GCStrategy` that identifies GC roots by
   metadata or attributes rather than by pointer type. This avoids the
   type-level distinction entirely but requires more custom LLVM
   infrastructure.
