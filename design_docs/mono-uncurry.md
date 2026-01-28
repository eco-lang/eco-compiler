Below is a concrete, engineer-oriented design to implement **Option A** (“flatten in monomorphization”) *correctly and consistently* across monomorphization + MLIR codegen + invariant tests.
The guiding rule is:
> In the monomorphized IR, a function type `MFunction argTypes ret` is treated as an **uncurried calling convention**: when it is eventually called, it expects `length(argTypes)` arguments “at once”.  
> Partial application is represented **only** via PAPs (`eco.papCreate`/`eco.papExtend`), not via staged/nested lambdas.

This design assumes you keep the existing type flattening in `TypeSubst.applySubst` which already flattens `TLambda` chains into `MFunction (arg :: restArgs) ret` .
> In the monomorphized IR, a function type `MFunction argTypes ret` is treated as an **uncurried calling convention**: when it is eventually called, it expects `length(argTypes)` arguments “at once”.  
> Partial application is represented **only** via PAPs (`eco.papCreate`/`eco.papExtend`), not via staged/nested lambdas.

This design assumes you keep the existing type flattening in `TypeSubst.applySubst` which already flattens `TLambda` chains into `MFunction (arg :: restArgs) ret` .
---
## 0. Required invariants (make these explicit in docs/tests)
### 0.1 MonoType arity definition (single source of truth)
- **Total argument count** = `Types.countTotalArity` (sums `List.length argTypes` across nested `MFunction` results) .
- **Do not** use `Types.functionArity` for PAP logic; it counts arrow depth, which becomes meaningless once types are flattened .
### 0.2 PAP semantics (already defined by the dialect)
The ECO dialect definitions make the intended semantics precise:
- `eco.papCreate`: remaining after creation is `(arity - num_captured)`   
- `eco.papExtend`: attribute `remaining_arity` is the closure’s remaining arity **before** this application 

So the compiler must:
- Set `papCreate.arity` to the total target function arity (including captured args as “already applied” arguments).
- Set `papExtend.remaining_arity` to the number of args still expected *at that point* (based on the MonoType of the function value being extended).
- `eco.papCreate`: remaining after creation is `(arity - num_captured)`   
- `eco.papExtend`: attribute `remaining_arity` is the closure’s remaining arity **before** this application 

So the compiler must:
- Set `papCreate.arity` to the total target function arity (including captured args as “already applied” arguments).
- Set `papExtend.remaining_arity` to the number of args still expected *at that point* (based on the MonoType of the function value being extended).
- `eco.papCreate`: remaining after creation is `(arity - num_captured)`   
- `eco.papExtend`: attribute `remaining_arity` is the closure’s remaining arity **before** this application 

So the compiler must:
- Set `papCreate.arity` to the total target function arity (including captured args as “already applied” arguments).
- Set `papExtend.remaining_arity` to the number of args still expected *at that point* (based on the MonoType of the function value being extended).
---
## 1. Monomorphization: eliminate staged lambdas (the big semantic change)
### Problem this fixes
Right now, `TypeSubst.applySubst` flattens function types , but lambda *values* are still built from the syntactic parameter list (which can be “first-level only” if lambdas are nested). `Specialize.elm` shows the current approach: it takes `params` from the AST and builds a `MonoClosure` with `closureInfo.params = monoParams` .
Under Option A, this is not allowed: **if types are flattened, lambda values must also be uncurried**.
### Goal
In monomorphization, rewrite any nested lambda chain into a single `MonoClosure` with a single parameter list whose length matches the flattened type’s argument list.
#### Example
Source-like structure:
```elm
add3 x = (\y z -> x + y + z)
```
Becomes one closure with params `[x,y,z]` and no nested function return.
### 1.1 Implement “lambda peeling” helper in `Compiler.Generate.Monomorphize.Specialize`

**Where:** `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm` (shown as `Specialize.elm.txt`)
**Add helper(s):**
- `peelFunctionChain : TOpt.Expr -> ( List params, bodyExpr )`
  - If the body is another `TOpt.Function`/`TOpt.TrackedFunction`, append its params and continue.
  - Stop at the first non-function body.
- You must support both `TOpt.Function` and `TOpt.TrackedFunction` because both are used .
**Add helper(s):**
- `peelFunctionChain : TOpt.Expr -> ( List params, bodyExpr )`
  - If the body is another `TOpt.Function`/`TOpt.TrackedFunction`, append its params and continue.
  - Stop at the first non-function body.
- You must support both `TOpt.Function` and `TOpt.TrackedFunction` because both are used .
Pseudo-shape:
```elm
peelFunctionChain expr =
  case expr of
    TOpt.Function params body _ ->
      let (moreParams, finalBody) = peelFunctionChain body in
      (params ++ moreParams, finalBody)

    TOpt.TrackedFunction params body _ ->
      let (moreParams, finalBody) = peelFunctionChain body in
      (params ++ moreParams, finalBody)

    _ ->
      ([], expr)
```
### 1.2 Modify `specializeExpr` handling for `TOpt.Function` and `TOpt.TrackedFunction`

**Current pattern:** It computes `monoType = TypeSubst.applySubst subst canType`, gets flattened param types via `TypeSubst.extractParamTypes monoType` , then maps only the *current* `params` list.
**New behavior:**
1. Compute `monoType` as before (keep flattening) .
2. Compute `funcTypeParams = TypeSubst.extractParamTypes monoType` (this already concatenates argument lists across nested `MFunction` results) .
3. Peel the lambda chain:
   - `(allParams, finalBody) = peelFunctionChain (TOpt.Function params body canType)`
4. Assert (debug / invariant) `List.length allParams == List.length funcTypeParams`
   - If not, crash with a clear message (this is a compiler bug).
5. Compute `monoParams` by indexing over `allParams` (not the first-level list) using the same `deriveParamType` logic you already have (choose from `funcTypeParams[idx]` when needed) .
6. Update `state.varTypes` with **all** `monoParams` (currently it inserts only the first-level params) .
7. Compute `augmentedSubst` using **all** params.
8. Specialize `finalBody` (not the old `body`) with this augmented state.
9. Compute captures with the full param list: `Closure.computeClosureCaptures monoParams monoBody` .
10. Emit a single `Mono.MonoClosure` with `closureInfo.params = monoParams`.
**New behavior:**
1. Compute `monoType` as before (keep flattening) .
2. Compute `funcTypeParams = TypeSubst.extractParamTypes monoType` (this already concatenates argument lists across nested `MFunction` results) .
3. Peel the lambda chain:
   - `(allParams, finalBody) = peelFunctionChain (TOpt.Function params body canType)`
4. Assert (debug / invariant) `List.length allParams == List.length funcTypeParams`
   - If not, crash with a clear message (this is a compiler bug).
5. Compute `monoParams` by indexing over `allParams` (not the first-level list) using the same `deriveParamType` logic you already have (choose from `funcTypeParams[idx]` when needed) .
6. Update `state.varTypes` with **all** `monoParams` (currently it inserts only the first-level params) .
7. Compute `augmentedSubst` using **all** params.
8. Specialize `finalBody` (not the old `body`) with this augmented state.
9. Compute captures with the full param list: `Closure.computeClosureCaptures monoParams monoBody` .
10. Emit a single `Mono.MonoClosure` with `closureInfo.params = monoParams`.
This change ensures: **no staged boundaries remain for user lambdas**; partial application is represented only by PAPs downstream.
### 1.3 Update (or keep) `Closure.ensureCallableTopLevel`

`ensureCallableTopLevel` currently flattens the function type via `flattenFunctionType`  and generates alias/general closures with `freshParams argTypes` and a single `MonoCall` .
Under Option A, this is *fine* and becomes *simpler*, because after 1.2, any function-valued expression should obey the flattened calling convention.
**One recommended fix (kernel correctness):**
In the `MonoVarKernel` branch, `ensureCallableTopLevel` explicitly keeps the original kernel ABI type (`kernelAbiType`) . However, it currently derives `argTypes` from `monoType` (not shown in snippet, but implied by structure).
- Change it to derive wrapper parameters from the **kernel ABI type** instead, because the call inside the wrapper is to the kernel symbol and must match kernel ABI stability.
**One recommended fix (kernel correctness):**
In the `MonoVarKernel` branch, `ensureCallableTopLevel` explicitly keeps the original kernel ABI type (`kernelAbiType`) . However, it currently derives `argTypes` from `monoType` (not shown in snippet, but implied by structure).
- Change it to derive wrapper parameters from the **kernel ABI type** instead, because the call inside the wrapper is to the kernel symbol and must match kernel ABI stability.
Implementation idea:
- `(argTypes, retType) = flattenFunctionType kernelAbiType` for the wrapper params/call.
- Keep the wrapper’s exposed `funcType` as `monoType` if you need the source-level type for specialization keys, but its *internal call* must match ABI.
Implementation idea:
- `(argTypes, retType) = flattenFunctionType kernelAbiType` for the wrapper params/call.
- Keep the wrapper’s exposed `funcType` as `monoType` if you need the source-level type for specialization keys, but its *internal call* must match ABI.
---
## 2. MLIR codegen: fix remaining arity everywhere (`functionArity` → `countTotalArity`)
### Problem this fixes
`Compiler.Generate.MLIR.Expr` currently computes `remainingArity` using `Types.functionArity funcType` in multiple places  . But `functionArity` counts arrow depth , and after flattening, arrow depth is typically 1 even for multi-arg functions.
### Required change
**Every place that sets `eco.papExtend remaining_arity` must use:**
```elm
remainingArity = Types.countTotalArity funcType
```
because `remaining_arity` is “args remaining before this application” .
### 2.1 Exact code edits in `compiler/src/Compiler/Generate/MLIR/Expr.elm`

Search for:
- `remainingArity = Types.functionArity`
and replace with:
- `remainingArity = Types.countTotalArity`

Search for:
- `remainingArity = Types.functionArity`
and replace with:
- `remainingArity = Types.countTotalArity`
Concrete locations (examples from excerpts):
- In `generateClosureApplication`, it currently does `remainingArity = Types.functionArity funcType` .
- In the “typed closure ABI” call path, also uses `Types.functionArity funcType` .
- In saturated-call fallback where a function value is a closure variable, also uses `Types.functionArity funcType` .
- There are other repeats in the file; treat this as a full-file mechanical replacement for PAP-related arity.
Concrete locations (examples from excerpts):
- In `generateClosureApplication`, it currently does `remainingArity = Types.functionArity funcType` .
- In the “typed closure ABI” call path, also uses `Types.functionArity funcType` .
- In saturated-call fallback where a function value is a closure variable, also uses `Types.functionArity funcType` .
- There are other repeats in the file; treat this as a full-file mechanical replacement for PAP-related arity.
### 2.2 Keep `papCreate` arity as-is
`generateClosure` computes:
```elm
arity = numCaptured + List.length closureInfo.params
```
and passes `(arity, num_captured)` to `eco.papCreate` .
This matches dialect semantics:
- remaining after create is `arity - num_captured` 
- so a closure’s remaining arity equals the number of explicit params, which is exactly the `MonoType` function arity after our monomorphization fix.
This matches dialect semantics:
- remaining after create is `arity - num_captured` 
- so a closure’s remaining arity equals the number of explicit params, which is exactly the `MonoType` function arity after our monomorphization fix.
So you do **not** change `generateClosure`’s arity computation; you change only `papExtend`’s `remaining_arity`.
---
## 3. Lambda codegen (MLIR function signatures): ensure arity matches `papCreate`

You have invariant CGEN_051: “papCreate arity matches function parameter count” . That implies:
- If `papCreate` is created for lambda `L` with `arity = numCaptured + numParams` ,
- then the generated `func.func @L` must have exactly `numCaptured + numParams` parameters.

`generateClosure` stores pending lambdas with:
- `captures = captureTypes`
- `params = closureInfo.params` 

**Required change (if not already done in `Lambdas.elm`):**
When generating the MLIR `func.func` for a pending lambda:
- add block args for captures first (using the capture types),
- then add block args for explicit params.

This aligns the callee parameter count with the `papCreate.arity` attribute and the dialect’s “captures are already-applied arguments” model .

(Your `pass_mlir_generation_theory.md` indicates there is a dedicated `Lambdas.elm` module for “Lambda/closure processing, PAP wrappers” ; this change belongs there.)
- If `papCreate` is created for lambda `L` with `arity = numCaptured + numParams` ,
- then the generated `func.func @L` must have exactly `numCaptured + numParams` parameters.

`generateClosure` stores pending lambdas with:
- `captures = captureTypes`
- `params = closureInfo.params` 

**Required change (if not already done in `Lambdas.elm`):**
When generating the MLIR `func.func` for a pending lambda:
- add block args for captures first (using the capture types),
- then add block args for explicit params.

This aligns the callee parameter count with the `papCreate.arity` attribute and the dialect’s “captures are already-applied arguments” model .

(Your `pass_mlir_generation_theory.md` indicates there is a dedicated `Lambdas.elm` module for “Lambda/closure processing, PAP wrappers” ; this change belongs there.)
- If `papCreate` is created for lambda `L` with `arity = numCaptured + numParams` ,
- then the generated `func.func @L` must have exactly `numCaptured + numParams` parameters.

`generateClosure` stores pending lambdas with:
- `captures = captureTypes`
- `params = closureInfo.params` 

**Required change (if not already done in `Lambdas.elm`):**
When generating the MLIR `func.func` for a pending lambda:
- add block args for captures first (using the capture types),
- then add block args for explicit params.

This aligns the callee parameter count with the `papCreate.arity` attribute and the dialect’s “captures are already-applied arguments” model .

(Your `pass_mlir_generation_theory.md` indicates there is a dedicated `Lambdas.elm` module for “Lambda/closure processing, PAP wrappers” ; this change belongs there.)
- If `papCreate` is created for lambda `L` with `arity = numCaptured + numParams` ,
- then the generated `func.func @L` must have exactly `numCaptured + numParams` parameters.

`generateClosure` stores pending lambdas with:
- `captures = captureTypes`
- `params = closureInfo.params` 

**Required change (if not already done in `Lambdas.elm`):**
When generating the MLIR `func.func` for a pending lambda:
- add block args for captures first (using the capture types),
- then add block args for explicit params.

This aligns the callee parameter count with the `papCreate.arity` attribute and the dialect’s “captures are already-applied arguments” model .

(Your `pass_mlir_generation_theory.md` indicates there is a dedicated `Lambdas.elm` module for “Lambda/closure processing, PAP wrappers” ; this change belongs there.)
- If `papCreate` is created for lambda `L` with `arity = numCaptured + numParams` ,
- then the generated `func.func @L` must have exactly `numCaptured + numParams` parameters.

`generateClosure` stores pending lambdas with:
- `captures = captureTypes`
- `params = closureInfo.params` 

**Required change (if not already done in `Lambdas.elm`):**
When generating the MLIR `func.func` for a pending lambda:
- add block args for captures first (using the capture types),
- then add block args for explicit params.

This aligns the callee parameter count with the `papCreate.arity` attribute and the dialect’s “captures are already-applied arguments” model .

(Your `pass_mlir_generation_theory.md` indicates there is a dedicated `Lambdas.elm` module for “Lambda/closure processing, PAP wrappers” ; this change belongs there.)
- If `papCreate` is created for lambda `L` with `arity = numCaptured + numParams` ,
- then the generated `func.func @L` must have exactly `numCaptured + numParams` parameters.

`generateClosure` stores pending lambdas with:
- `captures = captureTypes`
- `params = closureInfo.params` 

**Required change (if not already done in `Lambdas.elm`):**
When generating the MLIR `func.func` for a pending lambda:
- add block args for captures first (using the capture types),
- then add block args for explicit params.

This aligns the callee parameter count with the `papCreate.arity` attribute and the dialect’s “captures are already-applied arguments” model .

(Your `pass_mlir_generation_theory.md` indicates there is a dedicated `Lambdas.elm` module for “Lambda/closure processing, PAP wrappers” ; this change belongs there.)
- If `papCreate` is created for lambda `L` with `arity = numCaptured + numParams` ,
- then the generated `func.func @L` must have exactly `numCaptured + numParams` parameters.

`generateClosure` stores pending lambdas with:
- `captures = captureTypes`
- `params = closureInfo.params` 

**Required change (if not already done in `Lambdas.elm`):**
When generating the MLIR `func.func` for a pending lambda:
- add block args for captures first (using the capture types),
- then add block args for explicit params.

This aligns the callee parameter count with the `papCreate.arity` attribute and the dialect’s “captures are already-applied arguments” model .

(Your `pass_mlir_generation_theory.md` indicates there is a dedicated `Lambdas.elm` module for “Lambda/closure processing, PAP wrappers” ; this change belongs there.)
---
## 4. Update invariant logic for CGEN_052 (otherwise you’ll keep failing it)

Your invariant description for CGEN_052 currently says:
> Track PAP arities from `eco.papCreate` results; check `remaining_arity = source_arity - num_new_args` 

But per the dialect semantics:
- A PAP created by `papCreate` has remaining `(arity - num_captured)` .

So the test must track **remaining**, not total arity.
> Track PAP arities from `eco.papCreate` results; check `remaining_arity = source_arity - num_new_args` 

But per the dialect semantics:
- A PAP created by `papCreate` has remaining `(arity - num_captured)` .

So the test must track **remaining**, not total arity.
> Track PAP arities from `eco.papCreate` results; check `remaining_arity = source_arity - num_new_args` 

But per the dialect semantics:
- A PAP created by `papCreate` has remaining `(arity - num_captured)` .

So the test must track **remaining**, not total arity.
> Track PAP arities from `eco.papCreate` results; check `remaining_arity = source_arity - num_new_args` 

But per the dialect semantics:
- A PAP created by `papCreate` has remaining `(arity - num_captured)` .

So the test must track **remaining**, not total arity.
### 4.1 Edit `invariant-test-logic.md` CGEN_052 description
Change the CGEN_052 logic to:
- For `eco.papCreate`:
  - `papRemaining = arity - num_captured` (using attrs on the op) 
- For `eco.papExtend` with `k = operand_count - 1` new args:
  - `expected_remaining_arity = sourcePapRemaining`
  - and you can also validate the returned closure’s remaining is `sourcePapRemaining - k` if you model result as a PAP (but the key check is that the attribute on the op equals the “before application” remaining). This matches the `Eco_PapExtendOp` definition .
### 4.2 Update the actual test `PapExtendArityTest.elm`
Not shown in the provided files, but it should be adjusted to use `arity - num_captured` as the “source remaining”.
---
## 5. Remove/repurpose MONO_016 (optional but recommended)

MONO_016 currently says wrapper closures must generate nested calls when callee boundaries are smaller .
Under Option A, after you:
- flatten types in `applySubst` 
- and uncurry lambdas structurally in `Specialize.elm`
Under Option A, after you:
- flatten types in `applySubst` 
- and uncurry lambdas structurally in `Specialize.elm`
…you *should not* have staged call boundaries in Mono IR for normal Elm code (only PAPs).
So you can:
- either delete MONO_016,
- or change it to a stronger Option A invariant:
So you can:
- either delete MONO_016,
- or change it to a stronger Option A invariant:
> No `MonoClosure` has fewer params than `countTotalArity` of its MonoType.

This catches the original root cause directly.
> No `MonoClosure` has fewer params than `countTotalArity` of its MonoType.

This catches the original root cause directly.
---
## Summary: “all code changes needed” checklist
### Monomorphization (core semantic fix)
- `Compiler.Generate.Monomorphize.Specialize`:
  - Add `peelFunctionChain` helper.
  - Modify `TOpt.Function` and `TOpt.TrackedFunction` cases to:
    - peel nested lambdas into one param list
    - specialize a single final body
    - build one `MonoClosure` whose `closureInfo.params` length matches `extractParamTypes monoType` length  .
### Closure wrapping
- `Compiler.Generate.Monomorphize.Closure.ensureCallableTopLevel`:
  - Keep flatten wrapper logic .
  - Fix kernel wrapper params to be derived from `kernelAbiType`, since that is explicitly the stable ABI type .
### MLIR codegen (mechanical but crucial)
- `Compiler.Generate.MLIR.Expr`:
  - Replace all `remaining_arity = Types.functionArity funcType` with `Types.countTotalArity funcType`  .
  - Do not change `papCreate` arity computation; it matches dialect semantics  .
### Lambda function signature generation
- `Compiler.Generate.MLIR.Lambdas` (module exists per docs) :
  - Ensure generated lambda `func.func` parameter list = `captures ++ params`, so CGEN_051 remains true .
### Tests/invariants
- Update CGEN_052 to track “PAP remaining = arity - num_captured” (as per dialect)  .
- Add a monomorphization invariant/test that a `MonoClosure`’s param count matches the flattened function type (Option A’s key structural guarantee).
---

If you share `Compiler/Generate/MLIR/Lambdas.elm` and the invariant test implementations (`PapExtendArityTest.elm`, etc.), I can turn this into a patch-level set of edits (function signatures, exact patterns to match, and how to thread the new “peeled params” through capture analysis without breaking recursion/letrec cases).
