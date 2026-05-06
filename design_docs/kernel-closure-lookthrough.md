**Kernel Closure Look‑Through — Design Overview (Sketch)**
---
### 1. Motivation

Today:
- When a kernel is used as a *value* (e.g. `List.sortWith compare`, or wrapped inside an Elm function), we represent it as a closure created by `generateVarKernel`.
- Calls then go through the generic closure path (`eco_apply_closure` / `CallGenericApply`), even when the callee is a known kernel with a fixed ABI.

**Goal:** For call sites where we can *prove* that a closure value is always a particular kernel instance, replace the generic closure call with a **direct call to that kernel symbol**, using the already‑known ABI. This removes dynamic dispatch, boxing in the generic path, and some allocation.
---
### 2. High‑Level Idea

Introduce a late optimization pass (“kernel closure look‑through”) that:
1. Identifies closure values that are *just* kernel instances (e.g. from `generateVarKernel` / `papCreate` on a kernel symbol).
2. Finds uses where those values are **only called**, with no other observable behavior (no storing in unknown places, etc.).
3. Specializes those call sites by:
   - replacing `eco.papExtend` / generic apply with a **direct kernel call** (`func.call @Eco_Kernel_…` or equivalent), and
   - passing arguments using the **instance’s primitive‑aware ABI** (unboxed Int/Float/Char, boxed others).

The optimization is **purely structural**: it doesn’t change which kernel is called or how many times, only how the call is encoded.
---
### 3. Preconditions / Required Metadata

To make this feasible and simple:
1. **Stable kernel instance identity**

   - Kernel‑as‑value closures must carry enough metadata to say:
     > “This closure is the instance of kernel `(home, name)` with Mono arg types `argTypes` and result `resultType`.”
   - We already have `KernelInstanceKey` (home, name, argTypes, resultType) and `registerKernelInstance` on the MLIR side. The closure creation site should be clonable back to such a key (via attributes or a small registry).
2. **Single source of truth for ABI**

   - For any `KernelInstanceKey`, `registerKernelInstance` (or equivalent) must give:
     - the concrete C/MLIR symbol name (possibly suffixed like `_Int` / `_Float` / `_Char`), and
     - its fully resolved MLIR parameter and result types (with primitives unboxed).
   - The look‑through pass just *reuses* this; it does not recompute ABIs.

3. **Primitive‑clean kernel ABIs**

   - The kernel ABI design should already enforce:
     - If a parameter/result is Elm `Int`/`Float`/`Char` at this instantiation, the ABI type is `i64`/`f64`/`i16`, not `!eco.value`.
   - This ensures the specialized direct call can reuse argument SSA values as‑is, rather than inserting extra boxing/unboxing.
---
### 4. Where the Optimization Runs

- **Timing:** After Monomorphization and GlobalOpt (so types, staging, and CallKind are fixed), but before EcoToLLVM.
- **IR Level:** Eco MLIR, working over `func.func`, `eco.papCreate`, `eco.papExtend`, and `eco.call`.
---
### 5. Core Transformation

For each function in the module, conceptually:
1. **Find kernel closures**

   - Scan for `eco.papCreate` (or similar) whose `function` attribute names a kernel symbol and is known to have come from `generateVarKernel` / `instanceClosureResult`.
   - From attributes or side tables, reconstruct the `KernelInstanceKey` and therefore the instance ABI.

2. **Track uses**

   - For each such closure SSA value:
     - Collect all uses.
     - If all uses are *call‑like* (`eco.papExtend` / `eco.call` as closure application) and there are no “escaping” uses (storing into unknown records, returning, etc.), mark it as **eligible**.

3. **Specialize call sites**

   For each eligible call site:

   - Replace:
     - `eco.papExtend` or generic closure apply on the kernel closure
   - With:
     - A direct `eco.call` to the instance’s kernel symbol, passing the same actual argument values.
   - Ensure:
     - Argument and result MLIR types at the call site match the ABI types from `KernelInstanceKey` (relying on existing invariants like CGEN_057 / KERN_006).

4. **Clean up**

   - If all uses of the kernel closure have been specialized away, the closure‑creation (`papCreate`) node is now dead and can be removed by existing DCE.
---
### 6. Safety Conditions (when *not* to transform)

Do **not** perform look‑through if:
- The closure value **escapes**:
  - Stored in a data structure that survives beyond the current function.
  - Returned from the function.
  - Passed to unknown external code that might call it later.
- The same closure SSA value flows to multiple call sites that would require **different** ABIs (e.g. due to inconsistent monomorphization; ideally this can’t happen if KernelAbi invariants hold, but the pass should be conservative).
- The kernel’s ABI for this instance is not trusted (e.g., if KernelAbi invariants failed and were only “soft” checks).

In those cases, the generic closure representation and `eco_apply_closure` remain correct and must be preserved.
---
### 7. Interactions with Existing Subsystems

- **Monomorphization / KernelAbiMode**

  - Look‑through assumes KernelAbi has already produced a fully monomorphic `MonoType` for this kernel instance and that `KernelInstanceKey` reflects that.
  - For kernels that still use boxed polymorphic ABIs (`PreserveVars`/`NumberBoxed`), look‑through still works; it just yields a direct call with `!eco.value` arguments instead of going through `eco_apply_closure`.
- **GlobalOpt / CallKind**

  - GlobalOpt decides staging and `CallKind` for ordinary calls.
  - Look‑through can:
    - Either run *after* GlobalOpt and only rewrite generic‑apply call sites (`CallGenericApply`) where the callee can be statically identified as a kernel instance.
    - Or, more ambitiously, feed back information so that some calls are re‑classified as `CallDirectFlat` (flattened external) once they become plain kernel calls.

- **EcoToLLVM**

  - EcoToLLVM already trusts MLIR types and kernel declarations.
  - As long as look‑through produces well‑typed `eco.call` ops to declared kernel symbols, LLVM lowering just works; no changes are needed there.
---
### 8. Future Extensions

Once the basic kernel closure look‑through is in place, similar techniques could be applied to:
- User‑defined functions whose closures are always a specific specialization (effectively “defunctionalization via specialization”).
- Higher‑order library combinators (e.g. particular `List.map` or `fold` instances) where both the function argument and its type are known, enabling inlining or unrolling.

But the core idea to save now is just:
> “Track kernel instances through closure creation and calls, and when a closure is provably ‘just this kernel instance’, replace the generic closure call with a direct kernel call using the existing instance ABI.”
