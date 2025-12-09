Below is a pass-design-level outline, grounded in your `Ops.td` definitions and `Heap.hpp` layouts, with some extrapolation where the docs don’t spell out every detail. I’ll flag extrapolated parts.

---

## 0. Runtime layout facts from `Heap.hpp`

From `Heap.hpp`:

- Every heap object starts with an 8‑byte `Header` containing:
  - `tag : TAG_BITS` (which Elm-ish object kind: Int, String, Cons, Custom, Record, Closure, etc.).
  - GC metadata: `color`, `pin`, `epoch`, `age`, `unboxed`, `refcount`, and a `size` field in type-specific units.  
- Logical pointers are `HPointer` (64 bits), with:
  - `ptr : 40` (heap offset),
  - `constant : 4` (embedded constants like Nil/True/False),
  - `padding : 20`.  
- Important object layouts (all 8‑byte aligned):   
  - `ElmInt { Header; i64 value; }`
  - `ElmFloat { Header; f64 value; }`
  - `ElmChar { Header; u16 value; padding; }`
  - `ElmString { Header; u16 chars[]; }` (size = char count)
  - `Tuple2 { Header; Unboxable a,b; }`
  - `Tuple3 { Header; Unboxable a,b,c; }`
  - `Cons { Header; Unboxable head; HPointer tail; }`
  - `Custom { Header; u64 ctor:CTOR_BITS; u64 unboxed:48; Unboxable values[]; }`
  - `Record { Header; u64 unboxed; Unboxable values[]; }`
  - `DynRecord { Header; u64 unboxed; HPointer fieldgroup; HPointer values[]; }`
  - `Closure { Header; n_values:6; max_values:6; unboxed:52; EvalFunction evaluator; Unboxable values[]; }`
  - `Process`, `Task`, `ByteBuffer`, `ElmArray`, and `Forward` forwarding header.

GC‑side sizing uses `getObjectSize` which switches on `hdr->tag` and uses the C++ type sizes plus header/size fields.  

These give you the concrete offsets used when lowering field operations and allocation ops.

---

## 1. Per‑op semantics and LLVM‑oriented lowering sketch

I’ll group ops by category. Everything is based directly on `Ops.td` plus your MLIR research notes.  

### 1.1 Control flow / structure

#### `eco.case` – `Eco_CaseOp`

**Purpose & shape**  

- Pattern match on an ADT’s constructor tag and branch to one of several regions.
- Operands:
  - `scrutinee : AnyType` (usually `!eco.value`).
  - `tags : I64ArrayAttr` – list of constructor tags handled by each region.
- Regions:
  - `alternatives` – 1 region per tag plus optional default.
  - Each region takes no block args; uses `eco.project` inside to access fields.
  - Each region must end in `eco.return` or `eco.jump`.
- Results: none (control‑only op).

**Lowering sketch**

There are two natural strategies:

1. **eco → LLVM directly (one pass)** \
   Extrapolation but consistent with `lean_mlir_research`: turn `eco.case` into an `llvm.switch` on an integer tag.

   - First, **extract tag** from heap object. For:
     - Lists (`Cons`/Nil): distinguish Nil vs Cons by pointer constant or header `tag == Tag_Cons` and a nullable pointer convention.
     - Custom ADTs: load the `ctor` field from `Custom` (after confirming `Header.tag == Tag_Custom`).
   - Compute:
     ```mlir
     %val = ... : !llvm.ptr<...>    // lowered from !eco.value
     %hdr_ptr = llvm.bitcast %val : !llvm.ptr<...> -> !llvm.ptr<Header>
     %tag_i32 = llvm.load %hdr_ptr.field(tag) : i32
     ```
   - Emit `llvm.switch %tag_i32` to one block per `tags[i]`, and an optional default. In each successor, inline the region of the corresponding alternative.

   Upstream dialects: directly LLVM dialect (`llvm.switch`, `llvm.br`); may use `arith` for integer coercions.

2. **eco → `scf`/`cf` → LLVM (more MLIR‑idiomatic)** \
   Recommended if you want to reuse `convert-scf-to-cf` and `convert-cf-to-llvm`.  

   - Introduce `scf.switch` or a tower of `scf.if`/`cf.cond_br` on the tag.
   - Inline the `eco.case` regions as `scf`/`cf` regions.
   - Later:
     - `convert-scf-to-cf` → plain `cf.cond_br`.  
     - `convert-cf-to-llvm` → `llvm.switch`/branches.  

Either way, you may want a prior eco‑only pass that **normalizes scrutinee type** (disambiguate between `Custom`, `Cons`, etc., based on how the Elm IR annotated the ADT).

---

#### `eco.return` – `Eco_ReturnOp`

**Purpose & shape**  

- Terminator that returns zero or more results from an Eco function.
- Operands: `results : Variadic<AnyType>`.
- Results: none; trait: `Terminator`.

**Lowering sketch**

- In the MLIR `func` dialect, `eco.return` inside a `func.func` should eventually become `func.return`.
  - eco→func rewrite: just replace with `func.return` using same operands, once all operand types are legal (e.g. `!eco.value` already mapped to `!llvm.ptr<...>`).
- `convert-func-to-llvm` then turns `func.return` into `llvm.return`.  

Dialects: `func`, `cf` (for structured control flow), `llvm`.

---

#### `eco.joinpoint` / `eco.jump` – `Eco_JoinpointOp`, `Eco_JumpOp`

**Purpose & shape**   

- `eco.joinpoint`:
  - Declares a local joinpoint (loop head) with:
    - Attr `id : i64` – unique joinpoint id (for bookkeeping).
    - Region 0: `jpRegion` – body; first block’s arguments are “joinpoint parameters”.
    - Region 1: `continuation` – code after the joinpoint definition.
- `eco.jump`:
  - Jumps to a joinpoint, terminator.
  - Attr `join_point : i64` – refers to `id`.
  - Operands: `args : Variadic<AnyType>` matching joinpoint parameters.

Semantics match Lean’s joinpoints/hask joinpoints.

**Lowering sketch**

Strategy: lower to regular blocks + branches.

1. **eco → cf/func**

   - Introduce a new basic block for each joinpoint body and for the continuation.
     - The joinpoint’s block arguments become block arguments of that basic block.
   - Replace each `eco.jump` with a `cf.br` to the joinpoint block, passing the args.
   - Replace the `eco.joinpoint` op itself with:
     - A `cf.br` from current location to the continuation block (or inline the continuation region after the joinpoint block).
   - Ensure tail-recursion semantics (no extra stack frame) by making recursion use jumps within same function — which the structure above ensures.

2. **cf/func → llvm**

   - `convert-cf-to-llvm` and `convert-func-to-llvm` will map `cf.br` and block arguments to SSA PHI nodes and branches automatically.

Dialects used: `cf`, `func`, `arith` (only if you need counters), `llvm`.

---

#### `eco.crash` – `Eco_CrashOp`

**Purpose & shape**  

- Terminator that unconditionally crashes/panics.
- Operand: `message : AnyType` (probably `!eco.value` string).
- No results.

**Lowering sketch**

- eco → LLVM dialect:
  - Lower to a call to a runtime function like:
    ```llvm
    declare void @eco_crash(ptr addrspace(1) %msg)
    ```
  - Then `llvm.unreachable` or a call to `@abort` plus `unreachable`.

- If you keep the message as Elm string:
  - Before call, ensure `%msg` is converted from `!eco.value` to `ptr addrspace(1)` (if `!eco.value` already is that, no-op).

Dialects: direct to `llvm`; you might introduce an intermediate `func.call` + `cf.br` in `func` dialect but not necessary.

---

#### `eco.expect` – `Eco_ExpectOp`

**Purpose & shape**  

- Debug assertion: Elm’s `Debug.expect`.
- Operands:
  - `cond : AnyType` – should be reduced boolean (probably unboxed `i1` or boxed Bool).
  - `message : AnyType`.
- Results:
  - `value : AnyType` – pass-through value in IR (so you can write `%x = eco.expect %cond, %msg : T`).

**Lowering sketch**

Extrapolated but typical:

1. Normalize `cond` to `i1`.
   - If `cond` is `!eco.value` Bool, generate comparison against `Const_True` in pointer or inspect header/tag.

2. Emit:

   - eco → `scf.if` or `cf.cond_br`:
     ```mlir
     %ok = arith.extui %cond : i1 -> i1  // if needed
     cf.cond_br %ok, ^ok_block, ^fail_block

     ^ok_block:
       cf.br ^cont(%value)

     ^fail_block:
       // construct message / crash value
       // call @eco_expect_failure(%message)
       cf.br ^unreachable

     ^cont(%value_arg):
       ...
     ```
   - Or go directly to LLVM IR:
     ```llvm
     %ok = ... ; i1
     br i1 %ok, label %cont, label %fail
     fail:
       call void @eco_expect_fail(ptr addrspace(1) %message)
       unreachable
     cont:
       ; value just flows through
     ```

3. After `cf` lowering, `convert-cf-to-llvm` handles the branches.

Dialects: `arith`, `cf` (or `scf`), `llvm`.

---

#### `eco.dbg` – `Eco_DbgOp`

**Purpose & shape**  

- Debug/logging op; side‑effectful, no results.
- Operands: `args : Variadic<AnyType>`.

**Lowering sketch**

- Option A: **Drop in non‑debug builds**: eco‑canonicalization pass erases `eco.dbg`.
- Option B: Lower to a runtime helper:
  - Translate args to some printable representation; call e.g. `@eco_dbg_print(...)`.
  - Use `llvm.call`.

Dialects: typically direct to `llvm` call; or via `func.call` if you’re already using func dialect.

---

### 1.2 ADT construction and projection

#### `eco.construct` – `Eco_ConstructOp`

**Purpose & shape**  

- High-level pure operation: construct an ADT/record/tuple.
- Operands:
  - `fields : Variadic<AnyType>`.
  - Attributes:
    - `constructor : FlatSymbolRefAttr` – `@"Module.Type.Ctor"`.
    - `tag : i64` – constructor tag id (per Elm ADT).
    - `size : i64` – field count.
- Results:
  - `result : AnyType` (usually `!eco.value`).

**Lowering sketch (multi-stage)**

1. **eco high→eco low (still eco dialect)**

   Replace `eco.construct` with:

   - An `eco.allocate_ctor` op:
     ```mlir
     %obj = "eco.allocate_ctor"() {
       tag = <Tag_Custom or Tag_Cons, etc.>, // see below
       size = <#pointer-like fields>,
       scalar_bytes = <extra bytes>
     } : () -> !eco.value
     ```
   - Followed by a series of `llvm.store` or `memref.store` to fill fields, depending on where you first leave eco:
     - For a typical algebraic constructor mapping to `Custom`:
       - Header:
         - `Header.tag = Tag_Custom`
         - `Header.size = size` (field count).
       - After header, we have `u64 ctor` and `u64 unboxed`.
       - Then `Unboxable values[size]`.
     - Field stores:
       - Compute per‑field offset using `Custom` layout from `Heap.hpp`.  

   You can encode this either as inline `llvm.getelementptr` ops in the LLVM dialect, or temporarily through `memref` + `memref.store` and then run `convert-memref-to-llvm`.

2. **eco low→LLVM dialect**

   - **Runtime call strategy** (closer to your research doc):
     - Replace `eco.allocate_ctor` with a call:
       ```mlir
       %obj = llvm.call @eco_alloc_custom(%tag, %size)
         : (i32, i32) -> !llvm.ptr<HeapValue>
       ```
       where `%tag` is the ctor tag (or `Tag_Custom` plus `ctor` field), `%size` is field count. The runtime sets `Header` and `Custom.ctor` / `Header.size` correctly.
     - Then use `llvm.getelementptr` to store `fields` into `values[i]`.

   **Which dialects help?**
   - `arith` for computing indices/offsets.
   - `memref` only if you prefer memrefs to pointers; for GC heap I’d go straight to LLVM pointers.
   - `llvm` dialect for `llvm.call`, `llvm.getelementptr`, `llvm.store`.

*Note*: mapping `tag` attribute from eco.construct to `Custom.ctor` vs `Header.tag` is an extrapolation; the natural choice given `Tag_Custom` in `Header.tag` is:

- `Header.tag = Tag_Custom` (identifies “Custom” object kind).  
- The op’s `tag` attribute → `Custom.ctor` field (16 bits).  

---

#### `eco.project` – `Eco_ProjectOp`

**Purpose & shape**  

- Project a field from a constructor/record by index.
- Operands:
  - `value : AnyType` (`!eco.value`).
  - `index : i64` attribute.
- Results:
  - `field : AnyType`.

No tag checking: wrong index/constructor is UB.

**Lowering sketch**

- eco→LLVM dialect:
  - Lower `value : !eco.value` to `ptr addrspace(1)` (or `ptr<i8>`).
  - Based on the static type of the scrutinee (Elm IR type information; may be carried via attributes), choose the underlying C struct:
    - `Cons`, `Tuple2`, `Tuple3`, `Custom`, `Record`, `DynRecord`, `Closure`, etc.  
  - Use `llvm.bitcast` to the appropriate struct pointer type, then use `llvm.getelementptr` with the right field index:
    ```mlir
    %typed = llvm.bitcast %value : !llvm.ptr<i8> -> !llvm.ptr<Custom>
    %field_ptr = llvm.getelementptr %typed[0, <offset>] : !llvm.ptr<Custom> -> !llvm.ptr<Unboxable>
    %field_val = llvm.load %field_ptr : !llvm.ptr<Unboxable>
    ```
  - Wrap/unbox as needed to return as `!eco.value` or primitive.

Dialects: `llvm`, plus `arith` for index arithmetic.

You may prefer an intermediate eco‑to‑std pass that inserts explicit casts based on static type info to simplify the conversion patterns.

---

#### `eco.string_literal` – `Eco_StringLiteralOp`

**Purpose & shape**  

- Create an Elm string from a literal.
- Operand: `value : StrAttr`.
- Result: `result : AnyType` (`!eco.value`).

**Lowering sketch**

Two possible strategies:

1. **Static read‑only data (recommended):**
   - Emit an LLVM global constant for the UTF‑16 payload plus a global for `ElmString` header.
     - Layout matching `ElmString { Header; u16 chars[]; }`.  
     - `Header.tag = Tag_String`, `Header.size = length`.
   - Have `eco.string_literal` lower to a `llvm.address_of` of that global, cast to `ptr addrspace(1)` / `!eco.value`.

2. **Heap allocation at startup (less ideal):**
   - Lower to a call `@eco_alloc_string_literal(<len>, <data_ptr>)` that copies data into heap.

Dialects: `llvm` for globals and `llvm.mlir.global`.

---

### 1.3 Calls and closures

#### `eco.call` – `Eco_CallOp`

**Purpose & shape**   

- General function/closure application.
- Operands:
  - `args : Variadic<AnyType>`; first may be closure for closure calls.
- Attributes:
  - `function : Optional<FlatSymbolRefAttr>` – direct call target, if any.
  - `musttail : BoolAttr` – must be compiled as a proper tail call.
- Results:
  - `results : Variadic<AnyType>`.

**Lowering sketch**

Two cases:

1. **Direct call (function attr set)**

   eco→func:

   - Replace with `func.call` to `@function`, with operands lowered from `!eco.value` → `ptr addrspace(1)` or unboxed types.

   Tail calls:

   - If `musttail = true`, mark this `func.call` with a custom attribute that will be used during LLVM conversion to emit `musttail` / `tail` calls.

   func→llvm:

   - `convert-func-to-llvm` produces `llvm.call`. Inject `musttail` attribute according to `musttail`.

2. **Closure call (no function attr)**

   - Lower to a runtime helper call, e.g.:
     ```llvm
     declare ptr addrspace(1) @eco_apply_closure(ptr addrspace(1) %closure,
                                                 ptr addrspace(1) %arg0, ...)
     ```
     as illustrated in your map example.  
   - That helper reads the `Closure` header (`evaluator` function ptr, arity, etc.) and dispatches.

Dialects: `func`, `llvm`.

---

#### `eco.papCreate` – `Eco_PapCreateOp`

**Purpose & shape**  

- Create a closure representing a partial application (PAP).
- Operands:
  - `captured : Variadic<AnyType>` – captured values.
- Attributes:
  - `function : FlatSymbolRefAttr` – function being partially applied.
  - `arity : i64` – total arity.
  - `num_captured : i64` – number of captured args.
- Result:
  - `result : AnyType` – closure value (`!eco.value`).

**Lowering sketch**

- eco→LLVM dialect via runtime helper:
  - Lower to `@eco_alloc_closure(function_ptr, num_captures, ...)` where:
    - `function_ptr` is the C function entrypoint for `@function` (maybe looked up from symbol table).
    - `num_captures` sets `Closure.n_values` and `Closure.max_values`.
  - Then store `captured[i]` into `Closure.values[i]`, respecting `Closure.unboxed` bitmap (based on static type info).

Heap layout usage:

- `Closure { Header; n_values; max_values; unboxed; EvalFunction evaluator; Unboxable values[]; }`  

Dialects: `llvm` (calls, GEP, stores). You might represent partial application arity metadata as part of the runtime’s `EvalFunction` protocol.

---

#### `eco.papExtend` – `Eco_PapExtendOp`

**Purpose & shape**  

- Extend an existing closure with more arguments.
- Operands:
  - `closure : AnyType`.
  - `newargs : Variadic<AnyType>`.
- Result:
  - `result : AnyType` – either a new closure or the fully applied result.

**Lowering sketch**

This is almost surely a **runtime operation**; IR lowering just turns it into a call:

- eco→LLVM dialect:
  ```llvm
  declare ptr addrspace(1) @eco_pap_extend(ptr addrspace(1) %closure,
                                           ptr addrspace(1)* %args,
                                           i32 %num_newargs)
  ```
- Implementation given `Closure` layout:
  - If `n_values + num_newargs < arity`:
    - Allocate a new `Closure` with more captured args.
  - If saturated:
    - Call underlying function (like `eco_apply_closure`) and return result.

Dialect: direct `llvm.call`.

---

### 1.4 Allocation and GC

#### `eco.allocate` – `Eco_AllocateOp`

**Purpose & shape**  

- Generic heap allocation with type metadata.
- Operands:
  - `size : AnyType` (should be `i64`).
  - Attributes:
    - `type : FlatSymbolRefAttr` – type descriptor.
    - `needs_root : BoolAttr` – whether to register as root during construction.
- Result:
  - `result : AnyType` (`!eco.value`).

**Lowering sketch**

- eco→LLVM dialect:

  - Compute `size` in bytes or in allocator units (depends on runtime API).
  - Call a generic allocator entrypoint, e.g.:
    ```llvm
    declare ptr addrspace(1) @eco_alloc_raw(i64 %size, ptr %type_info, i1 %needs_root)
    ```
  - `type` attr can be lowered to a pointer to a type descriptor table or a numeric id.
  - The allocator uses `Header.tag` and `Header.size` according to the type.

Dialects: `arith` (size computation), `llvm` (call).

The exact runtime signature is extrapolated, but consistent with your GC notes and `AllocatorCommon.hpp`.  

---

#### `eco.allocate_ctor` – `Eco_AllocateCtorOp`

**Purpose & shape**  

- Low-level allocation for constructor objects.
- Attributes:
  - `tag : i64` – constructor tag.
  - `size : i64` – field count.
  - `scalar_bytes : i64` – extra scalar bytes.
- No operands, 1 result.

**Lowering sketch**

- Direct runtime call:
  ```llvm
  declare ptr addrspace(1) @eco_alloc_ctor(i32 %ctor_tag, i32 %field_count, i32 %scalar_bytes)
  ```
  as sketched in your research doc.  
- Runtime:
  - Allocates `Custom` or similar object with enough space for `values[size]` and `scalar_bytes`.
  - Sets `Header.tag = Tag_Custom`, `Header.size = size`, `Custom.ctor = tag`, `Custom.unboxed` computed from type info.

Dialects: `llvm` only.

---

#### `eco.allocate_string` – `Eco_AllocateStringOp`

**Purpose & shape**  

- Allocate storage for a string of known length.
- Attribute: `length : i64`.
- Result: `!eco.value`.

**Lowering sketch**

- eco→LLVM:
  - Call runtime `@eco_alloc_string(i32 length)` which allocates `ElmString` with `Header.size = length` and `chars[length]`.  
  - Write characters later (from e.g. string literal, IO, or decode).

Dialects: `llvm`.

---

#### `eco.allocate_closure` – `Eco_AllocateClosureOp`

**Purpose & shape**  

- Allocate an empty closure object for a given function and capacity for captures.
- Attributes:
  - `function : FlatSymbolRefAttr`.
  - `num_captures : i64`.
- Result: `!eco.value`.

**Lowering sketch**

- eco→LLVM:
  ```llvm
  declare ptr addrspace(1) @eco_alloc_closure(ptr %func_ptr, i32 %num_captures)
  ```
- Use `Closure` layout to set `n_values = 0`, `max_values = num_captures`, `unboxed` bitmap, and `evaluator` pointer.  

Dialects: `llvm`.

---

#### `eco.safepoint` – `Eco_SafepointOp`

**Purpose & shape**   

- GC safepoint operation. Marks a place where GC may run; `stack_map` attribute describes live `!eco.value` roots at this point (in a higher-level format).
- Operand: `stack_map : StrAttr`.
- No results.

**Lowering sketch (statepoints + stackmaps)**

1. **eco.safepoint → gc.statepoint (LLVM dialect)**

   Use the design in `llvm_stackmap_integration.md`:

   - Replace each `eco.safepoint` with:
     - A call to `@llvm.experimental.gc.statepoint` wrapping the *next* allocation or call, or with a no‑op target if you’re just polling.  
     - Add all live `!eco.value` values to the `"gc-live"` bundle of the statepoint.
   - Immediately after, insert `llvm.experimental.gc.relocate` for each live pointer, and replace their SSA uses after the safepoint with relocated values.  

2. **Stack map integration**

   - LLVM backend will emit `.llvm_stackmaps` section; runtime parses it as in your stack map parser.  
   - GC uses stack maps + `HPointer` encoding to find and update heap pointers, as described in the 40‑bit logical pointer section.  

Dialects: `llvm` with explicit GC strategy (statepoints).

---

### 1.5 Module and global state

#### `eco.global` – `Eco_GlobalOp`

**Purpose & shape**  

- Declare a GC‑managed global variable.
- Attributes:
  - `name : FlatSymbolRefAttr`.

**Lowering sketch**

Two layers:

1. eco→LLVM global:

   - Emit an LLVM global variable, likely of type `ptr addrspace(1)` (logical pointer) or `HPointer`, initialized to a null value or constant.
     ```llvm
     @global_name = global ptr addrspace(1) null
     ```
   - Or a struct representing a GC root slot that runtime registers.

2. Module init:

   - Use pattern from Lean/ECO research: an init function fills globals and marks them persistent.  

Dialects: `llvm` (or `builtin.module` + `llvm.mlir.global` in MLIR dialect).

---

#### `eco.store_global` – `Eco_StoreGlobalOp`

**Purpose & shape**  

- Store to a global variable.
- Operands:
  - `value : AnyType`.
  - Attribute `global : FlatSymbolRefAttr`.

**Lowering sketch**

- eco→LLVM:
  - Compute pointer to the global `@global_name` and `llvm.store` the value (after converting `!eco.value` to correct pointer/integer type).
  - GC root tracking:
    - Optionally call `@eco_gc_add_root(&@global_name)` once, or treat any global of that section as a root when scanning static data.  

Dialects: `llvm`.

---

### 1.6 RC / reuse placeholders (Perceus)

`eco.incref`, `eco.decref`, `eco.decref_shallow`, `eco.free`, `eco.reset`, `eco.reset_ref` are explicitly marked placeholders in `Ops.td` for possible future Perceus/RC integration, not used with tracing GC.  

**Lowering sketch**

- In the current tracing‑GC design, these **should be eliminated before codegen**:
  - An eco‑to‑eco cleanup pass asserts they don’t appear.
- If you ever experiment with Perceus:
  - They would lower to calls that manipulate `Header.refcount` and potentially free objects via `getObjectSize` and tag‑specific destructors.  

Dialects: N/A for now (removed pre‑LLVM).

---

## 2. Which upstream MLIR dialects help, and where

Given your design docs: use `scf`, `std` (i.e. `arith`/`cf`/`func`), and `llvm`.  

- **`func`**: define Eco functions as `func.func` with `!eco.value` and primitive arguments; handle `eco.return`, `eco.call` (direct calls).
- **`cf` / `scf`**:
  - Lower `eco.case` into structured control flow.
  - Lower `eco.joinpoint`/`eco.jump` into blocks and branches.
  - `convert-scf-to-cf` then `convert-cf-to-llvm` handle the rest.  
- **`arith`**:
  - Tag extraction and comparisons.
  - Array index arithmetic for field offsets.
  - Computing `size` in bytes for allocations.
- **`memref`** (optional):
  - If you temporarily model heap cells as memrefs during high-level optimizations; then run `convert-memref-to-llvm`. But for a moving GC + 40‑bit logical pointers, it’s often cleaner to stick to raw pointers and the LLVM dialect.
- **`llvm`**:
  - Final representation of heap pointers (`ptr addrspace(1)`), calls to runtime (`@eco_alloc_*`, `@eco_apply_closure`, `@eco_gc_*`), statepoints, `switch`, `getelementptr`, loads/stores, etc.  

---

## 3. Outline of a full lowering pipeline: `eco` → LLVM IR

Grounded in your research doc’s staged pipeline.  

### Stage 0: Frontend → Eco dialect

Already outlined elsewhere but for completeness:

- Elm source →
- Elm IR → Eco IR (ANF, lambda lifting, joinpoint identification, closure conversion) →
- Eco IR → Eco MLIR dialect ops (`eco.construct`, `eco.case`, `eco.call`, etc.).  

### Stage 1: Eco high-level normalization (Eco→Eco)

Goal: Make GC and codegen‑friendly Eco.

Passes:

1. **Closure normalization**:
   - Introduce `eco.papCreate`, `eco.papExtend`, `eco.call` (direct vs closure).
2. **Joinpoint legalization**:
   - Ensure `eco.jump` targets are structurally correct and in tail position where required.
3. **Construct normalization**:
   - Lower `eco.construct` →
     - `eco.allocate_ctor` + explicit field projections/stores expressed in eco+helper ops.
4. **Debug stripping / shaping**:
   - Optionally remove or mark `eco.dbg`, `eco.expect` for special lowering.

### Stage 2: GC and allocation shaping (Eco→Eco+GC)

Goal: make GC behavior explicit but still in Eco.

Passes:

1. **Safepoint insertion**:
   - Analyze liveness of `!eco.value` values.
   - Insert `eco.safepoint` around allocation sites and user function calls, annotating `stack_map` with a serialized description of live roots.  
2. **Allocation specialization**:
   - Turn generic `eco.allocate` into more precise `eco.allocate_ctor`, `eco.allocate_string`, `eco.allocate_closure` where possible.
3. **Reference‑counting placeholders elimination**:
   - Assert/remove `eco.incref`/`eco.decref` etc.

### Stage 3: Eco→“Std” MLIR (func/cf/scf/arith) + Eco GC ops

Goal: remove Eco control‑flow constructs in favor of MLIR core dialects.

Passes:

1. **Control flow lowering**:
   - `eco.case` → `scf.switch` or nested `scf.if` / `cf.cond_br`.
   - `eco.joinpoint` / `eco.jump` → new basic blocks + `cf.br`.
   - `eco.return` → `func.return`.
   - `eco.crash` / `eco.expect` → CFG with `cf.cond_br`, calls to runtime, `cf.unreachable`.
2. **Type legalization (partial)**:
   - Retain `!eco.value` as a high-level type, but start introducing helper casts to `ptr addrspace(1)` in preparation for LLVM conversion.

Result: module in `func` + `cf`/`scf` + `arith` + Eco heap/GC ops (`eco.allocate_*`, `eco.safepoint`, `eco.call`).

### Stage 4: Eco heap ops → LLVM dialect

Goal: convert heap operations to explicit pointer arithmetic and runtime calls using `Heap.hpp` layouts.   

Passes:

1. **Type mapping**:
   - `!eco.value` → `!llvm.ptr<HeapValue>` or `!llvm.ptr<i8>` / `ptr addrspace(1)` representing `HPointer`.
   - Primitive Elm types (Int, Float, Char, Bool) → LLVM `i64`, `double`, `i16`, `i1`/`i8` as per front-end mapping.

2. **Allocation lowering**:
   - `eco.allocate_ctor` → `llvm.call @eco_alloc_ctor(...)`.
   - `eco.allocate_string` → `llvm.call @eco_alloc_string(...)`.
   - `eco.allocate_closure` → `llvm.call @eco_alloc_closure(...)`.
   - `eco.allocate` → `llvm.call @eco_alloc_raw(...)`.

3. **Data layout‑based field access**:
   - `eco.project` → `llvm.bitcast` to one of the C struct types and `llvm.getelementptr` at correct offsets.
   - `eco.string_literal` → address of global `ElmString` constant.

4. **Global handling**:
   - `eco.global` → `llvm.global` definitions of `ptr addrspace(1)` and/or `HPointer`.
   - `eco.store_global` → `llvm.store`.

5. **Calls**:
   - `eco.call` with `function` attr → `llvm.call` to function symbol; add `musttail`/`tail` as per attr.
   - Closure calls / `eco.papCreate` / `eco.papExtend` → calls into runtime helpers using `Closure` layout.

### Stage 5: Safepoints / stack maps (Eco.safepoint → LLVM statepoints)

Goal: integrate precise GC.

Pass:

- Replace each `eco.safepoint` with a combination of `llvm.experimental.gc.statepoint` and `gc.relocate` following your stackmap integration doc.  

Result: pure LLVM dialect, marked with a GC strategy and statepoints.

### Stage 6: LLVM dialect → LLVM IR → native

- Use MLIR’s `mlir-translate --mlir-to-llvmir` as usual, then `clang` / `llc` to get an executable.  
