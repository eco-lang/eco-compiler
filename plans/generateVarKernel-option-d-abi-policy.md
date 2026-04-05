# Plan: Option D — Policy-driven ABI in `generateVarKernel`

## Problem

When a kernel function is used as a first-class value (closure/PAP path via `generateVarKernel`),
the registered `func.func` declaration always uses typed MLIR ABI derived from `Types.flattenFunctionType`.
This is wrong for **AllBoxed** kernels (e.g. `List.*`, `Utils.*`), whose C++ ABI is uniformly `uint64_t` / `!eco.value`.
The mismatch causes closure wrappers to spuriously unbox HPointers.

The direct-call path (`generateCallKernel`, line ~2938) already consults `Ctx.kernelBackendAbiPolicy`.
The closure/PAP path does not — that's the bug.

## Goal

Make `generateVarKernel` consult `Ctx.kernelBackendAbiPolicy` when computing the MLIR param/result types
for `registerKernelCall`, so closure and direct-call paths produce identical kernel declarations.
Additionally, update the policy for `Basics.add/sub/mul/pow` to `AllBoxed` (they are number-boxed
polymorphic C++ kernels that inspect HPointers at runtime).

## Steps

### Step 1 — Update `kernelBackendAbiPolicy` for Basics.add/sub/mul/pow

File: `compiler/src/Compiler/Generate/MLIR/Context.elm`, function `kernelBackendAbiPolicy` (lines 121-175).

Add four new cases **before** the catch-all `_ -> ElmDerived`:

```elm
        -- Basics.add/sub/mul/pow: number-boxed polymorphic kernels.
        -- C++ inspects the HPointer tag to dispatch Int vs Float at runtime.
        -- Must be AllBoxed to avoid wrapper unboxing HPointers as raw i64.
        ( "Basics", "add" ) ->
            AllBoxed

        ( "Basics", "sub" ) ->
            AllBoxed

        ( "Basics", "mul" ) ->
            AllBoxed

        ( "Basics", "pow" ) ->
            AllBoxed
```

The rest of `Basics` (trig, fdiv, modBy, etc.) stays `ElmDerived` — those have genuinely typed C++ ABIs.

### Step 2 — Edit site 1: `Just _` branch (lines 706-711)

File: `compiler/src/Compiler/Generate/MLIR/Expr.elm`, lines 706-711.

Replace:
```elm
( paramTypes, resultType ) =
    Types.flattenFunctionType monoType

ctxWithKernel =
    Ctx.registerKernelCall ctx1 kernelName paramTypes resultType
```

With:
```elm
policy : Ctx.KernelBackendAbiPolicy
policy =
    Ctx.kernelBackendAbiPolicy home name

( paramMlirTypes, resultMlirType ) =
    case policy of
        Ctx.AllBoxed ->
            ( List.repeat arity Types.ecoValue, Types.ecoValue )

        Ctx.ElmDerived ->
            Types.flattenFunctionType monoType

ctxWithKernel =
    Ctx.registerKernelCall ctx1 kernelName paramMlirTypes resultMlirType
```

### Step 3 — Edit site 2: `Nothing` branch (lines 785-790)

Same file, lines 785-790. Identical transformation as Step 2.

Replace:
```elm
( paramTypes, resultType ) =
    Types.flattenFunctionType monoType

ctxWithKernel =
    Ctx.registerKernelCall ctx1 kernelName paramTypes resultType
```

With the same policy-driven block.

### Step 4 — Add defensive comment in zero-arity thunk paths

In both the `Just _` (line ~688) and `Nothing` (line ~760) branches, where `arity == 0` thunks
do `resultMlirType = Types.monoTypeToAbi monoType`, add a comment:

```elm
-- NOTE: No AllBoxed kernels with arity 0 exist today. If one is added,
-- this path must consult kernelBackendAbiPolicy and force
-- resultMlirType = Types.ecoValue.
```

No behavioral change — just a breadcrumb for future maintainers.

### Step 5 — No other file changes needed

- `Ctx.kernelBackendAbiPolicy` and `KernelBackendAbiPolicy(..)` are already exported from Context.elm (line 8).
- `Expr.elm` already imports `Compiler.Generate.MLIR.Context as Ctx` and uses `Ctx.kernelBackendAbiPolicy` in the direct-call path (line 2938).
- `registerKernelCall` and `Functions.generateKernelDecl` need no changes — they're data-driven from `ctx.kernelDecls`.

### Step 6 — Build and test

```bash
cmake --build build --target full
```

Verify:
- `CombinatorSpMulTest`, `CombinatorTPipeTest`, `CombinatorListStringTest` pass (these exercise the Basics.add/mul closure path).
- MLIR output for AllBoxed kernels used as values shows `(!eco.value, ...) -> !eco.value` declarations.
- No `registerKernelCall` signature mismatch crashes.

### Step 7 — Inspect MLIR for key kernels

Spot-check generated MLIR for:
- `Elm_Kernel_Basics_add` when used as a value → should be `(!eco.value, !eco.value) -> !eco.value`
- `Elm_Kernel_List_map` when used as a value → should be `(!eco.value, !eco.value) -> !eco.value`
- `Elm_Kernel_Basics_modBy` (ElmDerived, unchanged) → should remain `(i64, i64) -> i64`

## Invariants

- **CGEN_056**: saturated `papExtend` result type must match callee `func.func` result type — satisfied because the declaration now matches the actual C++ ABI.
- **CGEN_057**: all `Elm_Kernel_*` symbols referenced by `eco.papCreate`/`eco.papExtend`/`eco.call` must have matching `is_kernel` declarations — `registerKernelCall` enforces consistency.
- **CGEN_034**: PAPs are boxed closures (`!eco.value`) — unchanged, only the *callee declaration* changes.

## Test coverage notes

- **Existing invariant tests** (CGEN_056, CGEN_057) will catch type-shape regressions and missing declarations in the closure path automatically.
- **E2E combinator tests** (`CombinatorSpMulTest`, `CombinatorTPipeTest`, `CombinatorListStringTest`) validate runtime correctness for `Basics.add/mul` used as closures.
- **Recommended addition**: one targeted codegen test that captures an AllBoxed kernel as a value (e.g. `Utils.append` or `List.map identity` as a closure) and asserts the `func.func` declaration has `!eco.value` params/results. This is not blocking but would provide direct assertion coverage for the Option D wiring.

## Risk assessment

**Low risk.** Two symmetric edits in Expr.elm + four new policy cases in Context.elm. The policy function is already battle-tested in the direct-call path. `registerKernelCall` will crash loudly if any call site disagrees on types, providing a safety net.
