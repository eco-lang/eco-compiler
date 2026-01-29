# Variant B: **MLIR-level ECO Dialect Simplifier + (optional) ECO Call Inliner** (C++ pass, before EcoToLLVM)
## Goal
If you prefer to keep Mono IR unchanged, or want a “cleanup layer” after codegen, this pass rewrites the *ECO dialect* before it’s lowered to LLVM.
This targets patterns where MLIR generation has already introduced closure ops, which otherwise lower to runtime closure allocation/calls per the ECO lowering theory .
## Placement in the runtime pass pipeline
Your plan describes a lowering pipeline with EcoToLLVM and other passes , and your repo uses `runtime/src/codegen/*` for that pipeline (as referenced in your design docs and internal notes) .
Insert the new pass **after ECO generation** and **before EcoToLLVM**, e.g.:
`... → (Canonicalize) → EcoPAPSimplify → EcoToLLVM → ...`
---
## B1. Implement the pass: EcoPAPSimplify
### Change 1 — **Add new pass file**
**File:** `runtime/src/codegen/Passes/EcoPAPSimplify.cpp` *(new)*  
**Purpose:** MLIR rewrite pass over `func.func` bodies that performs:
- **PAP fusion/elimination**
- **saturated PAP → direct call conversion**
- **dead closure elimination**
- (optional) direct call inlining (requires extra plumbing; see B2)
**File:** `runtime/src/codegen/Passes/EcoPAPSimplify.cpp` *(new)*  
**Purpose:** MLIR rewrite pass over `func.func` bodies that performs:
- **PAP fusion/elimination**
- **saturated PAP → direct call conversion**
- **dead closure elimination**
- (optional) direct call inlining (requires extra plumbing; see B2)
#### Core rewrite rules (implementable with PatternRewriter)
### Rule P1 — “papCreate + saturated papExtend → direct call”
Match:
- `%c = eco.papCreate @f(%captured...) { arity = A, num_captured = C, ... }`
- `%r = eco.papExtend %c(%newArgs...) { remaining_arity = K }`
Match:
- `%c = eco.papCreate @f(%captured...) { arity = A, num_captured = C, ... }`
- `%r = eco.papExtend %c(%newArgs...) { remaining_arity = K }`
And check saturation:
- ECO’s own op definition: saturated when `remaining_arity == newargs.size()` .
And check saturation:
- ECO’s own op definition: saturated when `remaining_arity == newargs.size()` .
Rewrite to:
- `%r = eco.call @f(%captured..., %newArgs...)`
Rewrite to:
- `%r = eco.call @f(%captured..., %newArgs...)`
This removes:
- closure allocation
- argument packing via closure evaluator path
- runtime helper calls described in the lowering theory
This removes:
- closure allocation
- argument packing via closure evaluator path
- runtime helper calls described in the lowering theory
### Rule P2 — “papExtend chain fusion”
If you see:
- `%c1 = eco.papExtend %c0(%a...) { remaining_arity = K }` (not saturated)
- `%c2 = eco.papExtend %c1(%b...) { remaining_arity = K2 }`
If you see:
- `%c1 = eco.papExtend %c0(%a...) { remaining_arity = K }` (not saturated)
- `%c2 = eco.papExtend %c1(%b...) { remaining_arity = K2 }`
and `%c1` has a single use (the second extend), fuse into:
- `%c2 = eco.papExtend %c0(%a..., %b...) { remaining_arity = K }` (adjust attributes accordingly)
and `%c1` has a single use (the second extend), fuse into:
- `%c2 = eco.papExtend %c0(%a..., %b...) { remaining_arity = K }` (adjust attributes accordingly)
(Exact attribute math is your design choice, but note the dialect meaning: `remaining_arity` is “before application” .)
### Rule P3 — DCE of unused papCreate / papExtend results
After rewrites, remove:
- `eco.papCreate` results unused
- intermediate `eco.papExtend` closures unused
After rewrites, remove:
- `eco.papCreate` results unused
- intermediate `eco.papExtend` closures unused
This can be done by relying on MLIR’s canonical DCE, or implement local checks.
---
## B2. Optional: Inlining of `eco.call @f(...)`

This is optional and more involved than Variant A.
You have `eco.call` as a custom op that supports direct calls via a `callee` attribute . MLIR’s built-in inliner typically wants ops to implement the call interfaces. To inline at this stage, you have two options:
### Option B2.1 — Implement MLIR CallOpInterface for Eco_CallOp *(best long-term)*
**Changes required:**
1) **EDIT:** ECO dialect op definition / C++ op class generation to implement MLIR’s call interface.
   - The op definition exists in your TableGen `Ops.td` .
   - Extrapolation: you likely have the real `.td` in `runtime/src/codegen/Eco/Ops.td` or similar; update it accordingly.
**Changes required:**
1) **EDIT:** ECO dialect op definition / C++ op class generation to implement MLIR’s call interface.
   - The op definition exists in your TableGen `Ops.td` .
   - Extrapolation: you likely have the real `.td` in `runtime/src/codegen/Eco/Ops.td` or similar; update it accordingly.
2) **EDIT:** Add/enable `mlir::createInlinerPass()` in your pipeline after this interface exists.
   - Extrapolation file location: a pipeline driver like `runtime/src/codegen/EcoPipeline.cpp` is referenced in your internal planning docs .
### Option B2.2 — Write a tiny custom “inline eco.call” pattern *(quick)*
This pattern inlines only when:
- callee is a `func.func` symbol
- callee is below size threshold
- callee is not recursive
- call is not `musttail` (if you rely on tail-call lowering later)
This pattern inlines only when:
- callee is a `func.func` symbol
- callee is below size threshold
- callee is not recursive
- call is not `musttail` (if you rely on tail-call lowering later)
This is essentially re-implementing a subset of inlining at MLIR level.
Given complexity, I’d do **PAP simplification first** (B1) and only add inlining if needed.
---
## B3. Register and run the new pass
### Change 2 — **Register pass factory**
**File:** `runtime/src/codegen/Passes.h` *(edit)*  
Add:
- `std::unique_ptr<mlir::Pass> createEcoPAPSimplifyPass();`
**File:** `runtime/src/codegen/Passes.h` *(edit)*  
Add:
- `std::unique_ptr<mlir::Pass> createEcoPAPSimplifyPass();`
### Change 3 — **Add pass to build system**
**File:** `runtime/src/codegen/CMakeLists.txt` *(edit)*  
Add `Passes/EcoPAPSimplify.cpp` to the library target.
(This is consistent with how new lowering components are wired in your repo; similar wiring is described in your design notes .)
### Change 4 — **Insert into pipeline**
**File:** `runtime/src/codegen/EcoPipeline.cpp` *(edit; name inferred from repo docs)*  
Insert `createEcoPAPSimplifyPass()` before `EcoToLLVM`.
Your plan describes EcoToLLVM as the final lowering stage and mentions closure conversion and runtime calls happening there , so this is the right point to clean up closure/PAP IR beforehand.
---
## B4. Add MLIR-level regression tests
### Change 5 — **Add new MLIR test**
**File:** `test/codegen/pap_saturated_fuses_to_call.mlir` *(new)*  
- Construct an input containing:
  - `eco.papCreate @f(...)`
  - `eco.papExtend` with `remaining_arity == newargs.size()`
- Run `mlir-opt` with your pipeline (including EcoPAPSimplify) and CHECK that:
  - `eco.papCreate` / `eco.papExtend` are gone
  - replaced by `eco.call @f(...)`
**File:** `test/codegen/pap_saturated_fuses_to_call.mlir` *(new)*  
- Construct an input containing:
  - `eco.papCreate @f(...)`
  - `eco.papExtend` with `remaining_arity == newargs.size()`
- Run `mlir-opt` with your pipeline (including EcoPAPSimplify) and CHECK that:
  - `eco.papCreate` / `eco.papExtend` are gone
  - replaced by `eco.call @f(...)`
This matches your existing “mlir test programs with RUN and CHECK” approach .
---
## B5. Summary: ALL code changes for Variant B

1. **NEW:** `runtime/src/codegen/Passes/EcoPAPSimplify.cpp`  
   - Implements P1/P2/P3 rewrite patterns for PAPs.
2. **EDIT:** `runtime/src/codegen/Passes.h`  
   - Pass factory declaration.

3. **EDIT:** `runtime/src/codegen/CMakeLists.txt`  
   - Build the pass.

4. **EDIT:** `runtime/src/codegen/EcoPipeline.cpp` *(name inferred from internal docs)*  
   - Insert pass before EcoToLLVM.

5. **NEW:** `test/codegen/pap_saturated_fuses_to_call.mlir`  
   - Regression test.

6. **OPTIONAL (if you want real inlining):**
   - **EDIT:** ECO dialect op definition / generated C++ to support call interfaces for `eco.call` .
   - **EDIT:** pipeline to run MLIR inliner pass.

