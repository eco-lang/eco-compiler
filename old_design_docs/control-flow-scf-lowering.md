Below is a consolidated design / implementation plan that incorporates both the original SCF design doc and the clarifications you raised in the “critical questions.” I’ll flag where I’m extrapolating beyond what’s explicitly written, but it all stays consistent with the existing docs.

---

## 0. Goals and context

Current situation:

- Today: `eco.case/joinpoint/jump → cf` (via `createControlFlowLoweringPass`) → LLVM  .
- Proposed: introduce an intermediate SCF layer:

  ```
  eco.case/joinpoint/jump → SCF dialect → CF → LLVM
  ```

  via a new `EcoControlFlowToSCF` pass, SCF optimizations, then `convertSCFToControlFlow` and `convertControlFlowToLLVM`  .

Main design challenges called out by the doc:

- Non‑looping joinpoints; early exits inside joinpoints; explicit result types for `scf.if`/`scf.while`; incremental vs big‑bang integration; and pattern prioritization  .

This design resolves those and adds a precise implementation story.

---

## 1. IR changes

### 1.1 `eco.case` – mandatory result types (extrapolated)

Today, `eco.case`:

- Has `scrutinee : AnyType`, `tags : I64ArrayAttr`, regions for alternatives, each ending in `eco.return` or `eco.jump`, and no explicit result types .
- Type handling for SCF is currently proposed via analysis of `eco.return` inside regions  .

**Change (extrapolated):**

Add a **mandatory** `result_types` attribute:

- Signature sketch:

  ```table
  Op: eco.case

  Operands:
    - scrutinee  : AnyType
    - tags       : I64ArrayAttr

  Attributes:
    - result_types : ArrayAttr  // array of TypeAttr (see 6. Type attribute representation)

  Regions:
    - alternatives: one region per tag (+ optional default), each ending in eco.return or eco.jump

  Results:
    - none (control-only)
  ```

Semantics:

- `result_types` is the list of **MLIR representation types** returned from this case (e.g. `[!eco.value]`, `[]`, `[i64, !eco.value]`), matching the operand types of `eco.return` reachable from each alternative region.
- Verifier:

    - Walk each alternative region; for every reachable `eco.return`, assert that `returnOp.getOperands().getTypes()` equals the types in `result_types`.
    - If a branch reaches some joinpoint that then returns, type consistency is checked on the joinpoint side (see next section).

This is a realization of the “add explicit result type annotation to eco.case/joinpoint” mitigation mentioned in the risk table  .

### 1.2 `eco.joinpoint` – mandatory result types (extrapolated)

Today, `eco.joinpoint`:

- Attributes: `id : i64`.
- Regions:
    - `jpRegion` – body; entry block arguments are joinpoint parameters.
    - `continuation` – code after the joinpoint definition.
- Results: none; `eco.return` inside regions returns from the function .

**Change (extrapolated):**

Add mandatory `result_types`:

```table
Op: eco.joinpoint

Attributes:
  - id           : I64Attr
  - result_types : ArrayAttr  // array of TypeAttr

Regions:
  - jpRegion     : body (loop or join block)
  - continuation : post-joinpoint code

Results:
  - none (control-only)
```

Semantics:

- `result_types` is the list of *function‑level* values ultimately returned via `eco.return` reachable from this joinpoint and its continuation; typically the enclosing function’s return types (`[!eco.value]`, `[]`, etc.).
- Verifier:

    - Walk `jpRegion` and `continuation` and assert every reachable `eco.return` has operand types equal to `result_types`.
    - Ensure every `eco.jump` to this joinpoint passes arguments whose types match the joinpoint entry block’s parameter types (existing invariant ).

These attributes give the SCF pass the explicit result type information it needs, rather than re‑inferring it repeatedly (though we can still keep the `getRegionResultTypes` helper as a debug check ).

### 1.3 `eco.get_tag` op (doc‑driven)

The SCF plan already lists as the first implementation step:

> 1. Add `eco.get_tag` op – Extract constructor tag (currently done inline in CaseOpLowering) .

**Design:**

```mlir
%tag = eco.get_tag %scrutinee : !eco.value -> i32   // or -> index
```

- It encapsulates the header/tag / constructor‐id extraction logic currently inlined in `eco.case` lowering to LLVM .
- This op will be used by both:
    - Eco→SCF case lowering (`scf.if`/`scf.index_switch`)  .
    - Eco→LLVM heap/layout lowering (instead of duplicating tag extraction logic).

---

## 2. Joinpoint normalization pass (Eco→Eco, extrapolated)

Doc already envisions a “joinpoint legalization” pass in Stage 1 Eco→Eco . Here we refine it into:

> `createJoinpointNormalizationPass()`

### 2.1 Classification

For each `eco.joinpoint`:

1. **Looping vs non‑looping** (doc pattern):

    - Use the loop detection algorithm already sketched:

      ```cpp
      bool isLoopingJoinpoint(JoinpointOp op) {
        int64_t jpId = op.getId();
        bool hasLoopingJump = false;
        op.getBody().walk([&](JumpOp jump) {
          if (jump.getTarget() == jpId) {
            hasLoopingJump = true;
            return WalkResult::interrupt();
          }
          return WalkResult::advance();
        });
        return hasLoopingJump;
      }
      ```

    - If `hasLoopingJump` is false → **non‑looping** joinpoint; won’t map to `scf.while` per doc’s strategy .

2. **Single‑exit vs multi‑exit** (extrapolated):

    - Traverse the CFG of `jpRegion` and collect all reachable `eco.return` blocks.
    - If >1 distinct `eco.return` blocks are reachable, mark as **multi‑exit**.
    - If exactly one reachable `eco.return`, and every path from the joinpoint entry to function exit passes through that block (post‑dominator check), mark as **single‑exit**.

3. **SCF‑candidate**:

    - A joinpoint is SCF‑candidate if:
        - It is looping (has a self‑jump).
        - It is single‑exit as above.
        - Its `continuation` region satisfies the shape below (2.2).

Non‑SCF‑candidates will stay on the CF path (doc mitigation for complex patterns and non‑looping joinpoints  ).

### 2.2 Continuation normalization (extrapolated but consistent)

We impose a simple structural invariant on the continuation region of SCF‑candidate joinpoints:

- The entry block of `continuation` must:
    - Start with exactly **one** `eco.jump` to the current joinpoint id.
    - After that jump, contain straight‑line code (no branches) that uses only:
        - Function arguments,
        - Values returned from the joinpoint (after lowering),
        - Other values defined in that straight‑line segment.

Any joinpoint whose continuation doesn’t match this shape (e.g. multiple jumps, complex branching before the first jump) is **not SCF‑candidate** and remains CF‑only.

Purpose:

- The first `eco.jump` provides the initial loop state values for `scf.while`.
- The remaining continuation code will be inlined **after** the `scf.while` as post‑loop code that consumes the loop’s result.

---

## 3. Eco→SCF pass: `EcoControlFlowToSCF`

The SCF doc suggests a new pass:

- `eco::createEcoControlFlowToSCFPass()` that lowers `eco.case` to `scf.if`/`scf.index_switch` and `eco.joinpoint/jump` to `scf.while` .

### 3.1 Pipeline placement

Integrate as per the doc’s “Pass Pipeline Modification” , refined to keep a CF fallback:

```cpp
// Stage 2: Eco → Standard MLIR
pm.addPass(eco::createJoinpointNormalizationPass());   // NEW (extrapolated)
pm.addPass(eco::createEcoControlFlowToSCFPass());      // NEW

// (still in Stage 2)
pm.addPass(eco::createControlFlowLoweringPass());      // existing Eco→CF for remaining eco.case/joinpoint/jump

// SCF optimizations
pm.addNestedPass<func::FuncOp>(scf::createForLoopCanonicalizationPass());
pm.addNestedPass<func::FuncOp>(scf::createForLoopPeelingPass());
pm.addNestedPass<func::FuncOp>(scf::createForLoopSpecializationPass());

// Stage 3: Eco → LLVM
pm.addPass(eco::createEcoToLLVMPass());                // heap, calls, etc.
pm.addPass(createConvertSCFToControlFlowPass());
pm.addPass(createConvertControlFlowToLLVMPass());
```

Key guarantee:

- After `createControlFlowLoweringPass()`, **no** `eco.case`/`eco.joinpoint`/`eco.jump` remain; everything is SCF or CF, matching eco‑lowering’s Stage 3 description .
- `EcoToLLVMPass` in Stage 3 therefore does not need to handle Eco control‑flow ops, consistent with the SCF doc’s intention “EcoToLLVM no longer handles case/joinpoint” .

A CLI flag (as suggested by the doc ) can enable/disable SCF lowering:

- If disabled: skip `EcoControlFlowToSCF`, run only `createControlFlowLoweringPass()` (current behavior).
- If enabled: run both passes as above.

### 3.2 `eco.case` → SCF (generic “pure return” pattern)

Use the mapping strategy and examples from the doc  , with the additional constraint that **all** alternatives must exit via `eco.return`.

**Preconditions for this pattern (extrapolated):**

- `eco.case` has `result_types` attribute.
- For each alternative region:
    - All exits from that region, modulo nested joinpoints that are not SCF‑candidate, must reach some `eco.return` with operand types matching `result_types`.
    - No branch in that region ends in `eco.jump` to an outer joinpoint (those are handled by joinpoint patterns, see 3.3).

**Lowering (2‑way):**

```mlir
// eco
eco.case %scrutinee [tag0, tag1] { alt0 } { alt1 }
  attributes { result_types = [T0, ..., Tn-1] }

// SCF (sketch)
%tag  = eco.get_tag %scrutinee : !eco.value -> i32
%cond = arith.cmpi eq, %tag, %c_tag1_i32 : i32

%res0, ..., %resN-1 =
  scf.if %cond -> (T0, ..., Tn-1) {
    // clone alt1 body
    // eco.return → scf.yield
  } else {
    // clone alt0 body
    // eco.return → scf.yield
  }
```

**Lowering (multi-way):**

As in the doc’s `scf.index_switch` example  , but with results `(T0..Tn-1)` from `result_types`:

```mlir
%tag = eco.get_tag %color : !eco.value -> index
%res0, ..., %resN-1 =
  scf.index_switch %tag -> (T0, ..., Tn-1)
  case 0 { ... eco.return → scf.yield ... }
  ...
  default { eco.crash ... }  // or clone default region
```

**Cases with `eco.jump` alternatives:**

- If any alternative region ends in `eco.jump` to an outer joinpoint, this generic pattern **does not apply**.
- Those `eco.case` ops are either:
    - Consumed via the composite joinpoint+case pattern (3.3) when they form a loop body, or
    - Left for the CF‑only path (lowered by `createControlFlowLoweringPass()`).

### 3.3 `eco.joinpoint` → `scf.while`

The doc already sketches mapping looping joinpoints to `scf.while`  and notes the challenge of non‑looping joinpoints and early exits  .

We now fix the semantics issues and refine which patterns we support.

#### 3.3.1 Loop detection and eligibility (doc‑driven + extrapolation)

- Use `isLoopingJoinpoint` from the doc .
- Use the joinpoint normalization pass (Section 2) to:
    - Require single‑exit joinpoints for SCF lowering.
    - Require normalized continuation.

Only such joinpoints are SCF‑candidate.

#### 3.3.2 `scf.while` result semantics: P vs R (extrapolated)

`scf.while` returns its **loop‑carried state**, i.e. the values passed through `scf.condition` in the last iteration. In some examples, the doc shows `scf.while` returning a simpler result (e.g. `i64` fold) , but the actual semantics are that the result is exactly the yield/condition tuple.

To align Eco joinpoints with this:

- Let P be the types of joinpoint parameters (loop‑carried state).
- Let R be the joinpoint’s `result_types` (Elm‑visible function results).
- In general R is a **projection** of P or of some extension of P (for fold: P=`(!eco.value, i64)`, R=`(i64)`).

**Lowering strategy (extrapolated):**

1. Ensure P includes R:

    - If R is already a subset of P (e.g. R is the accumulator in `(list, acc)`), nothing to do.
    - Otherwise, normalize joinpoint parameters so they carry `(S0..Sk, R0..Rn)`; R components initialized appropriately.

2. Construct `scf.while`:

    - Initial values `(P0..Pk)` taken from the first `eco.jump` in continuation.
    - Condition region:
        - Encodes the loop exit decision (base case).
        - Calls `scf.condition(%cond) P0..Pk`.
    - Body region:
        - Encodes the loop body.
        - `scf.yield` new `(P0..Pk)`.

3. After the loop:

    - `scf.while` returns `(P0_final..Pk_final)`.
    - Project out R from P:

      ```mlir
      %p0_final, ..., %pk_final = scf.while (...)
 
      // R is some projection/projection+computation of %p*_final,
      // often just picking some of the components.
      %r0 = <extract from P_final>
      ...
      %rn = <extract from P_final>
      ```

    - These `%r*` replace the logical “results of the joinpoint” in the surrounding code (especially in the continuation’s post‑loop code).

This resolves the “R ≠ P” mismatch (your Q1) without restricting to R==P.

#### 3.3.3 Composite pattern: joinpoint + case with jump

The doc shows the “complex pattern” of `eco.case` inside `eco.joinpoint` and suggests lowering the case first, then joinpoint  . However, in the presence of alternatives that end in `eco.jump`, generic case→SCF would fail.

For canonical loops (e.g. list recursion):

```mlir
eco.joinpoint 0(%val: !eco.value) {
  eco.case %val [0, 1] {
    eco.return %result : !eco.value            // exit path
  }, {
    %next = eco.project %val[1] : !eco.value
    eco.jump 0(%next : !eco.value)            // loop path
  }
} continuation {
  eco.jump 0(%list : !eco.value)
}
```

**Design decision (extrapolated):**

- Implement a **joinpoint‑first composite pattern**:

    - Pattern matches joinpoints whose `jpRegion` is structurally:

        - A top‑level `eco.case` on the loop variable,
        - One alternative that performs `eco.return` of the joinpoint’s result_types (exit case),
        - One or more alternatives that compute new loop state and `eco.jump` back to the same joinpoint (loop cases).

    - The pattern consumes both the `eco.joinpoint` and its internal `eco.case` and emits a single `scf.while` plus projections, as in 3.3.2.

- This pattern runs **before** the generic case→SCF rewrite in the pattern set (higher benefit).

- If the pattern doesn’t match (e.g. more complex nesting or multiple returns), we fall back to:

    - Generic `eco.case → scf.if/index_switch` where possible;
    - Or CF lowering for non‑SCF‑friendly patterns.

This is slightly different from the doc’s “lower case first, then detect loop structure” example , but achieves the same end result and avoids case→SCF having to understand `eco.jump` alternatives.

#### 3.3.4 Non‑looping joinpoints

- Non‑looping joinpoints (no self‑jump) are never lowered to SCF.
- They are left as Eco ops for `createControlFlowLoweringPass()` to lower to CF blocks and `cf.br` , in line with the doc’s suggestion to keep non‑looping joinpoints on the CF path .

---

## 4. Nested patterns and lowering order

There are two main nested cases in the doc:

- Case inside joinpoint (loop body with pattern match)  .
- Joinpoint inside case (loop only in one branch) .

**Overall strategy (extrapolated, compatible with doc):**

1. **Joinpoint‑first for loop patterns where case has a jump:**

    - For SCF‑candidate joinpoints whose `jpRegion` is top‑level `eco.case` with `return` vs `jump back`:
        - Apply the composite joinpoint+case→`scf.while` pattern (3.3.3).
        - This effectively lowers both the joinpoint and the case at once.

2. **Inside‑out for other cases:**

    - After joinpoint patterns have run:
        - Apply generic case→SCF (`scf.if` / `scf.index_switch`) to any remaining `eco.case` whose alternatives all lead to `eco.return` (no `eco.jump`).
        - This addresses cases both inside and outside of joinpoints.

3. **Joinpoint‑inside‑case (doc’s 3b) :**

    - For:

      ```mlir
      eco.case %outer [0, 1] {
        eco.joinpoint 0(...) { ... }  // nested loop in branch
        eco.return
      }, {
        eco.return
      }
      ```

    - The doc recommends processing “inside‑out – lower inner joinpoints first, then outer case” .
    - We follow that:
        - First, apply joinpoint patterns (potentially generating `scf.while`) inside each branch.
        - Once there are no `eco.joinpoint` left in the case regions, the case→SCF pattern is free to run.

---

## 5. Type attribute representation (`result_types`)

As discussed, we need:

```text
result_types : ArrayAttr<Type>
```

MLIR doesn’t have a built‑in `TypeArrayAttr`; the idiom is:

- Use `ArrayAttr` whose elements are `TypeAttr`.
- Check this in the op verifier.

**TableGen sketch (extrapolated):**

```tablegen
def Eco_CaseOp : Op<"case", [/*traits*/]> {
  let arguments = (ins
    AnyType:$scrutinee,
    I64ArrayAttr:$tags,
    ArrayAttr:$resultTypes   // Array of TypeAttr; checked in verifier
  );
  // ...
}

def Eco_JoinpointOp : Op<"joinpoint", [/*traits*/]> {
  let arguments = (ins
    I64Attr:$id,
    ArrayAttr:$resultTypes   // Array of TypeAttr
  );
  // ...
}
```

**Verifier (extrapolated):**

```cpp
LogicalResult Eco_CaseOp::verify() {
  auto array = getResultTypes(); // ArrayAttr
  for (Attribute attr : array) {
    if (!attr.isa<TypeAttr>())
      return emitOpError() << "result_types must be array of TypeAttr";
  }
  // Convert to SmallVector<Type> and check all eco.return ops.
  ...
}
```

Same for `Eco_JoinpointOp`.

---

## 6. Frontend and bootstrap strategy

Docs assume a frontend that translates Elm IR → Eco IR → Eco MLIR ops (`eco.construct`, `eco.case`, `eco.joinpoint`, etc.)  .

**When that frontend exists:**

- It must:
    - Fill `result_types` for `eco.case` and `eco.joinpoint` from known function result types and representation types (`!eco.value`, `i64`, etc.).
    - Satisfy the verifier invariants outlined in Section 1.

**For current work / tests (extrapolated):**

- You can unblock SCF implementation before the frontend is complete by:

    1. Allowing `result_types` to be initially empty in tests or IR.
    2. Implementing a small Eco→Eco pass:

       ```cpp
       // Pseudocode:
       for (eco.case / eco.joinpoint op):
         if (!hasResultTypesAttr()):
           auto inferred = getRegionResultTypes(op.getRegions()...)
           setResultTypesAttr(inferred)
       ```

       using the helper from the SCF doc .

    3. Once `result_types` is filled, run the verifiers and SCF lowering as normal.

- Later, when the frontend is in place, you can:
    - Make `result_types` truly mandatory at parse/emit time.
    - Keep the inference pass only for debug verification (recompute from `eco.return` and assert equality).

---

## 7. Fallback coexistence and EcoToLLVM behavior

Docs:

- `createControlFlowLoweringPass()` already lowers Eco control flow (case/joinpoint/jump/return) to CF  .
- `EcoToLLVMPass` handles heap ops, constants, calls, etc., and runs alongside `convertSCFToControlFlow` and `convertControlFlowToLLVM` .

**Design decisions (extrapolated but aligned):**

- **After `EcoControlFlowToSCF`:**

    - Some `eco.case`/`eco.joinpoint` are converted to SCF.
    - SCF‑incompatible ones remain as Eco ops.

- **`createControlFlowLoweringPass()` then runs:**

    - It lowers any remaining `eco.case`/`eco.joinpoint`/`eco.jump` to CF directly (as today).
    - It ignores SCF ops, which are handled later by `convertSCFToControlFlowPass()`.

- **By entry to Stage 3 (EcoToLLVM):**

    - The module contains:
        - `func`, `cf`, `scf`, `arith`, Eco heap/GC ops (`eco.allocate_*`, `eco.safepoint`, `eco.call`) .
        - **No** remaining Eco control‑flow ops.

- `EcoToLLVMPass` therefore does **not** need to be modified to understand Eco control‑flow ops in the SCF configuration; they are gone by then.

If an Eco control‑flow op still exists when entering Stage 3:

- Treat this as an **error** (failed lowering) – the SCF/CF passes should have been able to handle it.
- This catches cases where the SCF pass leaves an Eco op, but EC→CF pass is disabled or misconfigured.

---

## 8. Summary of required work items

Putting it all together:

1. **IR & dialect:**
    - Add `result_types : ArrayAttr` (array of `TypeAttr`) to `eco.case` and `eco.joinpoint`.
    - Update verifiers to assert type consistency with `eco.return`.
    - Add `eco.get_tag` op and hook it into existing LLVM lowering logic.

2. **Normalization:**
    - Implement `createJoinpointNormalizationPass()`:
        - Detect looping vs non‑looping joinpoints (reuse algorithm from SCF doc ).
        - Mark single‑exit joinpoints and normalized continuations as SCF‑candidates.
        - Others remain CF‑only.

3. **SCF lowering:**
    - Implement `EcoControlFlowToSCF`:
        - Generic pure‑return `eco.case` → `scf.if` / `scf.index_switch`.
        - Composite `eco.joinpoint` + `eco.case` (with `eco.jump` alt) → `scf.while` + projection of results.
        - SCF‑candidate joinpoints: construct `scf.while` with loop‑carried state P (including R), then extract R after the loop.
    - Ensure pattern application order:
        - Joinpoint+case composite patterns applied first.
        - Then generic case→SCF patterns.
        - Joinpoint‑inside‑case lowered inside‑out as per doc .

4. **Pipeline integration:**
    - Stage 2:
        - `createJoinpointNormalizationPass()`
        - `createEcoControlFlowToSCFPass()`
        - `createControlFlowLoweringPass()` (fallback CF lowering)
    - SCF optimizations: `scf::createForLoopCanonicalizationPass()`, `createForLoopPeelingPass()`, `createForLoopSpecializationPass()` .
    - Stage 3:
        - `createEcoToLLVMPass()`
        - `createConvertSCFToControlFlowPass()`
        - `createConvertControlFlowToLLVMPass()` (plus existing func/arith→LLVM passes as in llvm‑optimization‑ideas ).

5. **Frontend / bootstrap:**
    - In tests: optionally add a simple Eco‑to‑Eco pass that infers and populates `result_types` from `eco.return` if not already present (using the helper from the SCF doc ).
    - In the real Elm→Eco frontend: emit `result_types` directly from type information.

This plan directly addresses the three “must‑resolve” blockers you listed:

1. `scf.while` result semantics – by treating results as a projection of loop‑carried state and projecting after the loop.
2. `eco.jump` in case alternatives – by splitting into generic pure‑return cases vs composite joinpoint+case patterns, with the latter lowered jointly to `scf.while`.
3. `eco.get_tag` – by making it an explicit prerequisite op, already suggested as step 1 in the SCF design doc .

