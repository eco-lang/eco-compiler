### 1. `eco.call` type consistency is “fixed late” and in two places

**What’s going on**
- The invariant you want:  
  “For every `eco.call`, the operand and result types match the callee’s function type (after any boxing/unboxing).”
- Instead, you currently have:
  - **Compile‑time pass (`EcoPAPSimplify.cpp`)**  
    - Tries to make `eco.call` well‑typed by:
      - Looking at the callee’s return type,
      - Inserting `eco.unbox` when it sees mismatches between papExtend’s expected type and the function’s actual result type.
  - **Runner‑time patch (`EcoRunner::fixCallResultTypes()`)**
    - Runs after MLIR parsing, before verification.
    - Walks the IR to:
      - Rewrite the result types of `eco.call` ops to match the callee’s function type,
      - Insert `eco.unbox` / `eco.box` where it finds type mismatches.

**How it manifests**

- There are effectively two “implementations” of the rule “make `eco.call` types match the callee”:
  - One embedded in a normal MLIR optimization/lowering pass.
  - One embedded in a special runner‑side repair pass.
- Other passes or tools that inspect the IR:
  - Cannot assume `eco.call` is correct unless they know exactly whether they run before or after `fixCallResultTypes()`.
  - Might see inconsistent or temporarily “wrong” types.

**Why it’s problematic**

- **Dual ownership of an invariant** – if you adjust how calls should be typed, you must remember to update both places.
- **IR is not self‑consistent by construction** – correctness relies on a late repair step that is easy to forget or bypass.
- **Harder debugging and reasoning** – subtle bugs in either the simplifier or the fixer can lead to confusing type states that only appear at certain pipeline points.
---
### 2. Closure ABI & boxing/unboxing logic is duplicated and fragile

**What’s going on**
- You’ve established a nontrivial **closure calling convention / ABI**:
  - Evaluator wrapper expects all arguments in a `void**` array as HPointer‑encoded values.
  - Primitive types (Int, Float, Char) and `!eco.value` are represented differently in memory and must be boxed/unboxed appropriately.
  - Closure captures can be marked as “unboxed” via a bitmap; those need special handling when constructing/binding closures and when calling them.
- This ABI is implemented across several components:
  - `EcoToLLVMClosures.cpp`
    - `getOrCreateWrapper` unboxes arguments from HPointer to typed parameters and boxes results back.
    - `emitInlineClosureCall` and `PapExtendOpLowering` decide when to box i16/i64/f64 arguments before storing in the args array.
  - C++ kernels (`ListExports.cpp`, `JsArrayExports.cpp`, `StringExports.cpp`, `BytesExports.cpp`)
    - Helpers like `loadCapturedValues()`:
      - Read the closure’s `unboxed` bitmap,
      - Conditionally box values into HPointer representation before invoking the evaluator.
  - Runtime (`RuntimeExports.cpp`)
    - `eco_closure_call_saturated` and `eco_apply_closure`:
      - Implement the same “look at unboxed bitmap, box captures/args accordingly” logic.

**How it manifests**

- The same low‑level knowledge (e.g., what `unboxed` means, how captures are stored, how HPointer works) is:
  - Re‑encoded in multiple files.
  - Often via manual bit‑twiddling and pointer manipulation.
- The prior bug where:
  - Code used `closure->unboxed >> 12` instead of `closure->unboxed`
  - Demonstrates how a tiny misinterpretation of the bitfield, in just one of these places, can:
    - Completely break boxing behavior,
    - Cause widespread crashes or bad values in closures.

**Why it’s problematic**

- **High fragility** – small ABI changes (e.g. adding another primitive, tweaking capture layout) risk breaking any site that hand‑implements the protocol.
- **Hard to evolve** – improving or simplifying the ABI requires coordinated edits across many components.
- **Difficult onboarding/maintenance** – contributors have to internalize subtle ABI details instead of relying on a single helper/abstraction, which increases the chance of adding yet more ad‑hoc fixes.
---
### 3. Kernel function type information is reconstructed post‑hoc from usage

**What’s going on**
- Kernel functions can be referenced in IR only via `papCreate` / `papExtend`, without a direct `func.call`.
- Historically, such functions didn’t get a corresponding `func.func` declaration with accurate parameter types.
- To fix that, you now do two things:
  - In the **compiler**:
    - `Expr.elm` and `Types.elm` were changed to:
      - “Register” kernel calls so declarations with correct parameter types can be emitted.
      - Use `flattenFunctionType` to derive ABI parameter types from Elm’s curried `MonoType`.
  - In the **runtime / lowering (`EcoToLLVM.cpp`)**:
    - There is a scan over `papCreate` / `papExtend` to:
      - Infer kernel function parameter types from:
        - The types of captured operands,
        - The types of new arguments passed in papExtend,
      - Instead of assuming all `i64`.

**How it manifests**

- There are two sources of truth for kernel function types:
  - The compiler’s understanding (Elm type system → MLIR `func.func`).
  - The runtime’s inference based on how the function is used in papCreate/papExtend.
- If these ever diverge (e.g. due to a change in how Elm types are flattened, or how currying/partial application is represented), you can:
  - Generate declarations with types that don’t match actual uses.
  - Or “repair” types incorrectly during lowering based on outdated inference.

**Why it’s problematic**

- **Reconstruction instead of propagation** – you’re reverse‑engineering type information that the compiler already knows, instead of cleanly propagating it through the IR.
- **Risk of drift** – any change in compiler type‑flattening, currying representation, or pap semantics must be mirrored in the inference logic, or bugs will appear silently.
- **Increased complexity** – future contributors need to understand:
  - Both the “true” type system logic in the compiler,
  - And the fallback inference logic in `EcoToLLVM.cpp`, and how they interact.
---

Those three together are the core technical debt: they split ownership of key invariants (call typing, ABI, kernel types) across multiple layers and reconstruct or repair information late instead of enforcing it once, centrally.
