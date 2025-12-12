Below is a self‑contained design and implementation plan for:

- Extending `eco.case` and `eco.joinpoint` to carry **mandatory result type information**.
- Normalizing joinpoints to **single‑exit shapes** suitable for `scf.while`.
- Implementing the **Eco → SCF** control‑flow lowering (`EcoControlFlowToSCF`) that plugs into the existing pipeline.

Where I go beyond the existing docs, I’m extrapolating, but I keep it aligned with them.

---

## 0. Context and goals

From the existing design:

- Eco currently lowers control‑flow directly to CF/LLVM:  
  `eco.case/joinpoint/jump → cf.switch/cf.br → LLVM`
- The new proposal is:  
  `eco.case/joinpoint/jump → SCF → CF → LLVM`
- SCF lowering enables loop canonicalization, peeling, specialization, etc., which are particularly useful for recursive/looping Elm code and pattern matching.
- Eco IR represents Elm values primarily as `!eco.value`, plus some primitive types, and `eco.return` already carries the actual MLIR result types as its operands.

The SCF design doc highlights some open issues, notably:

- Result type handling for `scf.if` / `scf.while` (need explicit result types).
- Non‑looping vs looping joinpoints, early exits, and partial coverage.

This design answers those issues by:

1. **Changing `eco.case` and `eco.joinpoint` to carry mandatory result types.**
2. **Adding a joinpoint‑normalization pass** that identifies/normalizes single‑exit loop patterns.
3. **Implementing the Eco→SCF pass** using these invariants.

---

## 1. IR changes: `eco.case` and `eco.joinpoint` with mandatory result types

### 1.1 Current shapes (summary)

From `eco-lowering.md` :

- **`eco.case` – `Eco_CaseOp`**

    - Operands:
        - `scrutinee : AnyType` (usually `!eco.value`)
        - `tags : I64ArrayAttr`
    - Regions:
        - One region per alternative (+ optional default).
        - Each alternative region takes **no block args**.
        - Each region must end in `eco.return` or `eco.jump`.
    - Results: none (control‑only).

- **`eco.joinpoint` / `eco.jump` – `Eco_JoinpointOp`, `Eco_JumpOp`**

    - `eco.joinpoint`:
        - `id : i64`
        - Region 0: `jpRegion` – body; first block’s args are joinpoint parameters.
        - Region 1: `continuation` – code after joinpoint definition.
    - `eco.jump`:
        - `join_point : i64` attribute (refers to `id`).
        - Operands: `args : Variadic<AnyType>` matching joinpoint parameters.
    - Results: none (control‑only); `eco.return` inside regions returns from the function.

### 1.2 New mandatory result types

**Design principle:** The type information we need is *not* the full Elm type, but the **MLIR representation types** of values ultimately returned (`!eco.value`, `i64`, etc.). SCF also only cares about these representation types.

We add a **mandatory attribute** to both ops:

#### `eco.case`

New definition sketch (extrapolated):

```table
Op: eco.case

Operands:
  - scrutinee      : AnyType   (usually !eco.value)
  - tags           : I64ArrayAttr  // existing

Attributes:
  - result_types   : ArrayAttr<Type>  // NEW, mandatory

Regions:
  - alternatives   : One region per tag + optional default.
                    Each region ends in eco.return or eco.jump.

Results:
  - none (control-only)
```

**Invariant:**

- All control‑flow paths from each alternative region that leave the `eco.case` must eventually hit an `eco.return` whose operand types **exactly match** the `result_types` list.

This can be enforced in the `Eco_CaseOp` verifier:

- For each `eco.return` reached from an alternative:
    - Check `returnOp.getOperands().getTypes()` equals `result_types`.
- If a branch exits only via `eco.jump` to some joinpoint that ultimately returns, that joinpoint must also be consistent (but that’s an existing structural requirement).

Typical values of `result_types`:

- `[]` for functions returning unit / no value.
- `[!eco.value]` for normal Elm functions.
- `[i64, !eco.value]` etc. if multi‑valued returns are allowed at MLIR level.

#### `eco.joinpoint`

New definition sketch (extrapolated):

```table
Op: eco.joinpoint

Operands:
  - (none; parameters are block arguments of the jpRegion entry block)

Attributes:
  - id            : i64
  - result_types  : ArrayAttr<Type>  // NEW, mandatory

Regions:
  - jpRegion      : region 0, body
                    entry block args = joinpoint parameters
  - continuation  : region 1, code after the joinpoint definition

Results:
  - none (control-only)
```

**Meaning of `result_types` for joinpoints:**

- The types of the **function‑level values** ultimately returned via `eco.return` reachable from within the joinpoint and its continuation.
- Usually this matches the enclosing function’s return types (e.g. `[!eco.value]` or `[]`).

Verifier for `eco.joinpoint`:

- Walk all `eco.return` reachable from `jpRegion` and `continuation`:
    - Every `eco.return` must have operand types equal to `result_types`.
- Optionally: verify that all `eco.jump` to this joinpoint pass arguments whose types match the joinpoint parameters (existing invariant).

This makes result types **explicit and checked once** in Eco, simplifying the SCF pass.

---

## 2. Joinpoint normalization to single‑exit shapes

Goal: prepare joinpoints so that **some of them** can be cleanly lowered to `scf.while`:

- SCF’s `scf.while` has a single “exit” (condition returns `false`), returning a fixed set of values.
- Eco joinpoints currently may have multiple `eco.return` scattered in the body, including early returns.

We’ll introduce a **Stage‑1 Eco→Eco pass** (building on the existing “Joinpoint legalization” mentioned in eco‑lowering):

> `createJoinpointNormalizationPass()`

### 2.1 Classification of joinpoints

For each `eco.joinpoint` we classify it as:

1. **Looping joinpoint**: there is at least one `eco.jump` targeting this `id` from inside `jpRegion`. (Same detection as in the SCF doc’s pseudo‑code).
2. **Non‑looping joinpoint**: no such `eco.jump` in the body (only in continuation).
3. **SCF‑candidate loop**: a looping joinpoint whose body has a **single exit point**.

We will only SCF‑lower SCF‑candidate loops; others stay on the CF path.

### 2.2 Definition of “single exit point”

For a joinpoint `J`:

- Consider all control‑flow paths starting at the entry block of `jpRegion`.
- An **exit point** is:
    - A terminator `eco.return` reachable from `jpRegion`, or
    - A terminator that jumps to some other joinpoint which ultimately returns (for simplicity, in v1, treat only direct `eco.return` as exits).
- `J` is a **single‑exit** joinpoint if:

  > There is a unique `eco.return` that *post‑dominates* all paths out of `jpRegion`, i.e. every path from the joinpoint’s entry to function exit must go through that one `eco.return`.

Implementation detail (extrapolated):

- In MLIR, run a control‑flow analysis on the region’s CFG:
    - Build a graph of blocks in `jpRegion`.
    - Compute post‑dominators or simpler:
        - Collect all `eco.return` blocks reachable from `jpRegion`.
        - If count > 1, not single‑exit.
        - If exactly 1, check that for each block reachable from the entry, *every* path to function exit goes through that `eco.return` block.

### 2.3 Normalization strategy

Given the complexity of arbitrary multiple exits and early returns, the **initial, implementable plan** is:

1. **Do not try to rewrite arbitrary multi‑exit loops.**
2. **Instead:**
    - If `jpRegion` has:
        - Exactly one `eco.return` reachable from it, and
        - No “unstructured” `eco.return` in inner constructs (e.g. inside nested joinpoints that you aren’t going to SCF‑lower),
        - Then mark it as **SCF‑candidate**.
    - Otherwise, leave it as **CF‑only**.

This matches the SCF doc’s Option C for early exits: “Only lower simple loop patterns to SCF, keep complex ones on CF path.”

You can encode this as an attribute or just as a property the SCF pass recomputes.

#### (Optional future extension – real normalization)

If you later need more coverage, you can:

- Introduce a normalization that rewrites multiple `eco.return`s in `jpRegion` into a single one by:
    - Introducing joinpoint‑local “result variables” (implemented as additional joinpoint parameters or SSA values in the continuation).
    - Rewriting each early `eco.return` into:
        - Assign result values.
        - Jump to a single “exit block” in the continuation that does the real `eco.return`.
- However, this is significantly more complex and can remain future work. For v1, simple detection and exclusion is enough.

---

## 3. Eco→SCF control‑flow lowering (`EcoControlFlowToSCF`)

We now define the main pass that lowers Eco control‑flow to SCF, using the new type and normalization invariants.

### 3.1 Pass placement in the pipeline

The SCF design doc suggests adding a new pass and SCF optimizations before Eco→LLVM, then converting SCF→CF→LLVM.

Updated pipeline fragment (extrapolating from the doc):

```cpp
// Stage 2: Eco → Standard MLIR
pm.addPass(eco::createEcoControlFlowToSCFPass());  // NEW (this design)

// SCF optimizations
pm.addNestedPass<func::FuncOp>(scf::createForLoopCanonicalizationPass());
pm.addNestedPass<func::FuncOp>(scf::createForLoopPeelingPass());
pm.addNestedPass<func::FuncOp>(scf::createForLoopSpecializationPass());

// Stage 3: Eco → LLVM
pm.addPass(eco::createEcoToLLVMPass());            // Heap, calls, etc.
pm.addPass(createConvertSCFToControlFlowPass());   // SCF → CF
pm.addPass(createConvertControlFlowToLLVMPass());  // CF → LLVM
```

(As in the doc’s “Pass Pipeline Modification”, but with the new pass implemented according to this plan.)

### 3.2 SCF type usage: using `result_types`

Because `eco.case` and `eco.joinpoint` now have a mandatory `result_types` attribute:

- SCF ops’ result types are taken **directly** from that attribute.
- You no longer need to infer types from `eco.return` in this pass, only to optionally verify them (using the helper from the doc).

---

## 4. Lowering `eco.case` → SCF

The SCF design doc already describes the general mapping:

- 2 alternatives → `scf.if`.
- >2 alternatives → `scf.index_switch`.

With mandatory `result_types`, we can make this precise.

### 4.1 Prerequisite: `eco.get_tag`

First, ensure there is an `eco.get_tag` op as suggested (extracts the ADT tag from `!eco.value`).

```mlir
%tag = eco.get_tag %scrutinee : !eco.value -> i32  // or index
```

### 4.2 2‑way case → `scf.if`

Given:

```mlir
// Eco
%result_types = [T0, ..., Tn-1] // from attribute
eco.case %scrutinee [tag0, tag1]
         { ... alt0 ... }  // ends in eco.return / eco.jump
         { ... alt1 ... }
```

Lower to:

```mlir
%tag = eco.get_tag %scrutinee : !eco.value -> i32
%cond = arith.cmpi eq, %tag, %c_tag1_i32 : i32  // pick one branch as "then"

%res0, ..., %resN-1 =
  scf.if %cond -> (T0, ..., Tn-1) {
    // Clone body of chosen alternative (e.g. alt1).
    // Replace eco.return %v0, ..., %vn-1
    //   with scf.yield %v0, ..., %vn-1.
  } else {
    // Clone body of the other alternative (alt0).
    // Replace eco.return analogously.
  }
```

Notes:

- Each alternative region’s `eco.return` must already match `(T0, ..., Tn-1)` by the verifier.
- If an alternative ends in `eco.jump` to some joinpoint, the SCF pass either:
    - Leaves that part in Eco/CF form if the joinpoint is non‑SCF, or
    - Handles the joinpoint separately (see the joinpoint section).

### 4.3 Multi‑way case → `scf.index_switch`

Given:

```mlir
%result_types = [T0, ..., Tn-1]
eco.case %scrutinee [tag0, tag1, ..., tagK-1]
         { ... alt0 ... }
         { ... alt1 ... }
         ...
         { ... altK-1 ... }
```

Lower as in the doc:

```mlir
%tag = eco.get_tag %scrutinee : !eco.value -> index
%res0, ..., %resN-1 =
  scf.index_switch %tag -> (T0, ..., Tn-1)
  case 0 {
    // clone alt0, eco.return → scf.yield
  }
  case 1 {
    // clone alt1
  }
  ...
  case K-1 {
    // clone altK-1
  }
  default {
    // If there is a default alternative, clone it.
    // Otherwise, this is unreachable (Elm patterns exhaustive).
    // Might emit eco.crash or scf.yield of "unreachable" values.
  }
```

---

## 5. Lowering `eco.joinpoint` → SCF (`scf.while`)

This is where joinpoint classification and normalization matter.

### 5.1 Loop detection (recap)

Use the detection from the doc (slightly expanded):

```cpp
bool isLoopingJoinpoint(eco::JoinpointOp jp) {
  int64_t id = jp.getId();
  bool hasLoopJump = false;

  jp.getBody().walk([&](eco::JumpOp jump) {
    if (jump.getJoinPointId() == id) {
      hasLoopJump = true;
      return WalkResult::interrupt();
    }
    return WalkResult::advance();
  });

  return hasLoopJump;
}
```

Combine with single‑exit check (from section 2.2) to identify **SCF‑candidate looping joinpoints**.

### 5.2 Canonical pattern to target

We target joinpoints that look roughly like the examples in `control-flow-scf-lowering.md` (loops over lists or counters):

- Parameters of `jpRegion` are loop‑carried values.
- There is a condition that decides whether to “continue” (`eco.jump` back to the joinpoint) or to “exit” (`eco.return`).
- No other `eco.return` in the body.

### 5.3 Mapping to `scf.while`

Given a SCF‑candidate joinpoint:

```mlir
// Canonical Eco sketch
eco.joinpoint %id (%p0: P0, ..., %pk: Pk) {
  // BODY (jpRegion)

  // compute condition %cond
  // if cond:
  //   compute updated params %p0', ..., %pk'
  //   eco.jump %id(%p0', ..., %pk')
  // else:
  //   eco.return %r0, ..., %rn
} continuation {
  // initial jump:
  eco.jump %id(%init_p0, ..., %init_pk)
}
```

With `result_types = [R0, ..., Rn]` on `eco.joinpoint` (matching the `eco.return` operands).

We lower to:

```mlir
// scf.while returns R0..Rn, carries P0..Pk
%r0, ..., %rn =
  scf.while (%p0 = %init_p0, ..., %pk = %init_pk)
            : (P0, ..., Pk) -> (R0, ..., Rn) {
    // "before" region: decide whether to continue

    // Compute condition based on %p0..%pk
    // If we know the structure, we may be able to refactor so that
    // the eco.return is expressed as cond = false and pass result
    // via some explicit values. For v1, we can restrict to cases
    // where the eco.return corresponds to cond=false directly.

    // Simplest pattern (extrapolated):
    // - Extract cond such that:
    //   cond == true  => continue
    //   cond == false => exit with pre-computed results

    %cond = ... : i1

    // For SCF v1, assume results R0..Rn *do not* depend on cond path
    // (or are equal on both paths). If they depend, stick to CF path.

    scf.condition(%cond) %p0, ..., %pk : P0, ..., Pk
  } do {
  ^bb0(%p0_arg: P0, ..., %pk_arg: Pk):
    // body that updates loop-carried values
    %p0_next, ..., %pk_next = ... : P0, ..., Pk
    scf.yield %p0_next, ..., %pk_next : P0, ..., Pk
  }
```

**Important practical restriction (v1, extrapolated):**

To avoid complicated refactoring of `eco.return` into loop‑carried “result” variables, you initially:

- **Only lower joinpoints where:**
    - The loop’s exit values (`R0..Rn`) are equal to some current loop‑carried parameters (e.g., for list loops that keep an accumulator and return it).
    - Or where the base case is recognizable and directly encodable as “cond == false => known result”.

If a joinpoint doesn’t match this simple pattern, the pass *skips SCF lowering* and leaves it to the existing Eco→CF lowering.

### 5.4 Non‑looping joinpoints

As per the SCF doc’s unresolved question 1 and its suggested mitigation:

- **Non‑looping joinpoints are not lowered to SCF.**
- They remain as Eco ops to be lowered directly to CF blocks + `cf.br` (using the existing sketch in `eco-lowering.md`).

This keeps the SCF pass simple and avoids trying to encode “execute once with arguments” in SCF.

---

## 6. Verification and debugging

To keep this robust:

1. **Dialect verifiers:**
    - `eco.case`:
        - Check `result_types` is present.
        - Validate all reachable `eco.return` operands match it.
    - `eco.joinpoint`:
        - Check `result_types` is present.
        - Validate all reachable `eco.return` operands match it.
        - Validate jump argument types vs joinpoint parameters.

2. **SCF pass checks (defensive):**
    - For each op it tries to lower:
        - Recompute region result types with the helper from the doc:
          ```cpp
          SmallVector<Type> getRegionResultTypes(Region &region) { ... }
          ```
        - Assert (in debug mode) that these match `result_types`.
    - For joinpoints:
        - Check loop‑detection + single‑exit conditions before attempting `scf.while` lowering.

3. **Fallback behavior:**
    - If any invariant fails, the SCF pass:
        - Emits an MLIR diagnostic explaining why the op is not SCF‑lowerable.
        - Leaves that op for the CF‑only lowering path.

---

## 7. Summary of concrete implementation steps

1. **IR changes (eco dialect):**
    - Extend `Eco_CaseOp` and `Eco_JoinpointOp` definitions to add a mandatory:
        - `ArrayAttr<Type> result_types`.
    - Implement verifiers enforcing consistency with `eco.return`s.

2. **Frontend changes (Elm IR → Eco MLIR):**
    - When emitting `eco.case`:
        - Set `result_types` to the enclosing function’s return types (as Eco representation types: `!eco.value`, primitives, etc.).
    - When emitting `eco.joinpoint`:
        - Set `result_types` similarly—typically the function’s result types.

3. **Joinpoint normalization pass:**
    - Implement `createJoinpointNormalizationPass()` that:
        - Classifies joinpoints as looping / non‑looping.
        - Checks for single‑exit patterns.
        - (Initially) just records which joinpoints are SCF‑candidates vs CF‑only, based on:
            - Presence of loopback jumps.
            - Unique reachable `eco.return`.
        - More aggressive transformations can be added later if needed.

4. **Eco→SCF lowering pass (`EcoControlFlowToSCF`):**
    - For each `eco.case`:
        - Use `result_types` as the result type list for `scf.if` / `scf.index_switch`.
        - Clone regions, replacing `eco.return` with `scf.yield`.
    - For each SCF‑candidate looping `eco.joinpoint`:
        - Map to `scf.while` when its structure matches the simple loop pattern.
        - Otherwise, skip (CF path).
    - For non‑looping joinpoints and complex cases:
        - Leave them untouched; they’ll be handled by the existing Eco→CF lowering.

5. **Pipeline wiring:**
    - Add `eco::createEcoControlFlowToSCFPass()` to Stage 2 before Eco→LLVM, as in the SCF design doc.
    - Add SCF optimization passes (canonicalization, peeling, specialization).
    - Ensure `EcoToLLVM` no longer tries to lower `eco.case`/`eco.joinpoint` directly once SCF is stable; instead rely on `convertSCFToControlFlow` + `convertControlFlowToLLVM`.

---

This gives you:

- A clear IR contract: `eco.case` and `eco.joinpoint` always know their result types.
- A minimal yet useful subset of joinpoints that can be cleanly mapped to `scf.while`.
- A straightforward Eco→SCF pass that plugs into the existing staged lowering and can be expanded over time as you need more complex loop patterns.

