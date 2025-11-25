# Lean MLIR Research

Research on Lean4's MLIR-based compilation backend for ECO reference implementation.

## Repository Information

- **Main Lean4 repo**: https://github.com/leanprover/lean4
- **MLIR implementation fork**: https://github.com/bollu/lean4
- **Branch analyzed**: `2021-cgo-artifact`
- **Author**: Siddharth Bhat (bollu)
- **Status**: Experimental research implementation (2021-2022)
- **Last significant activity**: August 2022
- **Key commit**: 907c9c6fb3 - "pilfer my tests from developing MLIR backend into lean test suite"

## How to Access

```bash
# Clone the repository
git clone git@github.com:bollu/lean4.git
cd lean4

# Checkout the MLIR branch
git checkout 2021-cgo-artifact

# Key file to examine
cat src/Lean/Compiler/IR/EmitMLIR.lean
```

## Overview

This is a complete MLIR code generator for Lean 4's intermediate representation (IR). The implementation demonstrates how to compile a functional programming language with:
- Algebraic data types (ADTs)
- Closures and partial application
- Tail call optimization
- Reference counting memory management
- Join points (for efficient local control flow)

The code generator is written in **Lean itself** (approximately 1500 lines) and emits a custom MLIR dialect called `lz` (likely "Lean Z" or similar).

## Dialect Structure

### Dialect Name: `lz` (Lean IR Dialect)

The dialect is NOT defined in TableGen or C++. Instead, operations are emitted as **custom string representations** that would need to be parsed by a corresponding MLIR dialect implementation (which may exist in a separate repository or as compiled C++ code).

### Core Type: `!lz.value`

The fundamental type representing all Lean heap objects:

```mlir
!lz.value   // Opaque pointer to heap-allocated Lean object
```

All boxed values (ADTs, closures, large integers, strings) use this type. Primitive types (i32, i8, f64, i1) are used for unboxed scalar values.

### Type Mapping

From `toCType` function (lines 131-145):

| Lean IR Type | MLIR Type | Notes |
|--------------|-----------|-------|
| `IRType.float` | `f64` | Unboxed floating point |
| `IRType.uint8` | `i8` | Unboxed byte |
| `IRType.uint16` | `i16` | Unboxed short |
| `IRType.uint32` | `i32` | Unboxed 32-bit integer |
| `IRType.uint64` | `i32` | Also i32 (size hack) |
| `IRType.usize` | `i32` | Platform size as i32 |
| `IRType.object` | `!lz.value` | Boxed heap object |
| `IRType.tobject` | `!lz.value` | Tagged object |
| `IRType.irrelevant` | `!lz.value` | Erased proof terms |

## Operations Defined

The dialect defines operations in several categories:

### 1. Memory Management Operations

Reference counting operations (Lean uses RC, not GC):

```mlir
// Increment reference count
"lz.inc"(%x) {value=1, checkref=true} : (!lz.value) -> ()

// Increment by N
"lz.inc"(%x) {value=N, checkref=false} : (!lz.value) -> ()

// Decrement reference count
"lz.dec"(%x) {value=1, ref=true} : (!lz.value) -> ()
```

Key insight: The `checkref` attribute determines whether to check if the object is actually heap-allocated before incrementing (scalars don't need RC).

### 2. Constructor Operations

```mlir
// Construct algebraic data type
%z = "lz.construct"(%y1, %y2, ...) {
  dataconstructor = @"<index>",
  size = <n>
} : (!lz.value, !lz.value, ...) -> (!lz.value)
```

This is the high-level representation. The lowering expands this to:
1. Allocate constructor with `lean_alloc_ctor(tag, size, scalar_size)`
2. Set each field with `lean_ctor_set(obj, index, value)`

### 3. Projection Operations

```mlir
// Extract field from constructor
%z = "lz.project"(%x) {value=<index>}
  : (!lz.value) -> (!lz.value)
```

Lowers to `lean_ctor_get(obj, index)`.

### 4. Function Call Operations

The most interesting aspect - three types of calls:

#### Full Application (Direct Call)
```mlir
%ret = "lz.call"(%arg1, %arg2) {
  value = @function_name,
  musttail = "true"  // or "false"
} : (!lz.value, !lz.value) -> (!lz.value)
```

The `musttail` attribute is critical - it marks tail calls that MUST be compiled to jumps, not calls. This preserves Lean's tail recursion semantics.

#### Partial Application (Closure Creation)
```mlir
%closure = "lz.pap"(%captured1, %captured2) {
  value = @function_name,
  arity = <total_arity>
} : (!lz.value, !lz.value) -> (!lz.value)
```

Creates a partial application (PAP) - a closure that captures some arguments but needs more to complete the call. The `arity` field indicates total function arity.

#### Closure Application Extension
```mlir
%newclosure = "lz.papExtend"(%closure, %newarg1, %newarg2)
  : (!lz.value, !lz.value, !lz.value) -> (!lz.value)
```

Extends an existing closure with more arguments. This is how currying works in Lean.

### 5. Control Flow Operations

#### Pattern Matching on Objects
```mlir
"lz.caseRet"(%scrutinee)(
  { /* case 0 body */ },
  { /* case 1 body */ },
  { /* default case */ }
) {
  alt0 = <tag0>,
  alt1 = <tag1>,
  alt2 = @default
} : (!lz.value) -> ()
```

Pattern matching on ADT constructors. Each alternative is a region with its own code.

#### Pattern Matching on Integers
```mlir
"lz.caseIntRet"(%scrutinee)(
  { /* value 0 body */ },
  { /* value 1 body */ },
  { /* default */ }
) {
  alt0 = 0,
  alt1 = 1,
  alt2 = @default
} : (i8) -> ()
```

Note: Often the scrutinee is an `i1` (boolean) from a comparison, making this effectively an if-then-else.

#### Join Points (Local Labels)
```mlir
"lz.joinpoint"()(
  {
    ^entry(%param1: !lz.value, %param2: i32):
      // join point body
      "lz.return"(%result) : (!lz.value) -> ()
  },
  {
    // continuation after join point
  }
) {value = <join_point_id>} : () -> ()
```

Join points are Lean's optimization for local control flow - they're like labels/gotos but with proper SSA form. Critical for efficient compilation.

#### Jumps to Join Points
```mlir
"lz.jump"(%arg1, %arg2) {value = <join_point_id>}
  : (!lz.value, i32) -> ()
```

### 6. Boxing/Unboxing Operations

Converting between unboxed and boxed representations:

```mlir
// Box a primitive
%boxed = call @lean_box_uint32(%unboxed)
  : (i32) -> (!lz.value)

// Unbox to primitive
%unboxed = call @lean_unbox_uint32(%boxed)
  : (!lz.value) -> (i32)
```

Similar operations exist for: `uint8`, `uint16`, `uint64`, `usize`, `float`.

### 7. Literal Operations

```mlir
// Small integer (< 2^32)
%n = "lz.int"() {value=<n>} : () -> (!lz.value)

// Large integer (arbitrary precision)
%big = "lz.largeint"() {value="<bignum_string>"}
  : () -> (!lz.value)

// String literal
%s = "lz.string"() {value="hello world"}
  : () -> (!lz.value)
```

### 8. Return Operations

```mlir
"lz.return"(%value) : (!lz.value) -> ()
```

### 9. Global Variable Operations

```mlir
// Load from global
%val = "ptr.loadglobal"() {value = @global_name}
  : () -> (!lz.value)

// Store to global
"ptr.storeglobal"(%val) {value = @global_name}
  : (!lz.value) -> ()

// Declare global
"ptr.global"() {value = @global_name, type = !lz.value}
  : () -> ()
```

### 10. Miscellaneous Operations

```mlir
// String literal operation
%s = "ptr.string"() {value="text"}
  : () -> (!lz.value)

// Unreachable code
"ptr.unreachable"() : () -> ()

// Boolean not (for i1)
%notval = "ptr.not"(%val) : (i1) -> i8
```

## Lowering Pipeline

### Stage 1: Lean IR → MLIR `lz` Dialect

This is what `EmitMLIR.lean` does:

1. **Normalize IR**: Ensure no gaps in variable indices (`normalizeIds`)
2. **Build type map**: Track types of all variables
3. **Emit preamble**: Forward declare runtime functions
4. **Emit functions**:
   - Convert each Lean IR function declaration to `func @name`
   - Convert function body (FnBody) to MLIR operations
   - Handle special cases (tail calls, closures, join points)
5. **Emit initialization**: Module initialization code

### Stage 2: `lz` Dialect → LLVM Dialect (Hypothetical)

Not implemented in this file, but would need:

1. **Lower high-level ops**:
   - `lz.construct` → alloc + field sets
   - `lz.project` → field get
   - `lz.call` → function call (with musttail attribute)

2. **Lower control flow**:
   - `lz.caseRet` → switch statement or if-then-else
   - `lz.joinpoint` → labels and branches
   - `lz.jump` → branch instruction

3. **Lower memory operations**:
   - `lz.inc`, `lz.dec` → calls to RC runtime
   - `ptr.loadglobal`, `ptr.storeglobal` → LLVM global operations

### Stage 3: LLVM Dialect → LLVM IR → Native Code

Standard MLIR → LLVM pipeline.

## Compilation Process Overview

```
Lean Source Code
    ↓
Lean Frontend (type checking, elaboration)
    ↓
Lean IR (lambda lifted, CPS-ish with join points)
    ↓
EmitMLIR.lean (this file)
    ↓
MLIR lz Dialect (textual form)
    ↓
MLIR Parser (C++, not in this repo)
    ↓
MLIR lz Dialect (in-memory IR)
    ↓
Lowering Passes (C++, not in this repo)
    ↓
LLVM Dialect
    ↓
LLVM IR
    ↓
Native Code
```

## Key Implementation Patterns

### 1. Representing Heap Objects

Everything is `!lz.value` - an opaque pointer type. This matches Lean's runtime where all heap objects have a uniform header:

```c
// From Lean's C runtime
typedef struct {
    uint32_t m_rc;        // Reference count
    uint16_t m_tag;       // Constructor tag or object type
    uint16_t m_other;     // Size or other metadata
    // Followed by fields
} lean_object;
```

### 2. Reference Counting Discipline

The IR explicitly includes `inc` and `dec` operations. The Lean compiler frontend computes where these should go based on:
- Variable liveness analysis
- Borrowing analysis (avoid inc/dec for borrowed references)
- Persistent values (no RC needed)

This is visible in the FnBody constructors:
```lean
| inc (x : VarId) (n : Nat) (checkRef : Bool) (persistent : Bool) (b : FnBody)
| dec (x : VarId) (n : Nat) (checkRef : Bool) (persistent : Bool) (b : FnBody)
```

### 3. Tail Call Optimization

Critical for functional languages. The implementation:

1. Detects tail calls in `isTailCall` (line 1003)
2. Marks them with `musttail="true"` attribute
3. Uses `lz.return` immediately after call

This ensures LLVM backend generates a jump, not call+return.

### 4. Closure Representation

Three-phase approach:

1. **Full closure creation** (`lz.pap`):
   - Allocates closure object
   - Stores function pointer and captured arguments
   - Stores remaining arity

2. **Closure extension** (`lz.papExtend`):
   - Takes existing closure
   - Adds more arguments
   - May trigger call if arity satisfied

3. **Closure application** (`lz.call` where function is variable):
   - Extract function pointer from closure
   - Pass closure + new arguments

### 5. Pattern Matching Compilation

Two strategies:

**For ADTs** (lines 1075-1099):
- Generate `lz.caseRet` with one region per constructor
- Extract tag from object
- Jump to appropriate region
- Each region can project fields from the scrutinee

**For integers/booleans** (lines 1109-1132):
- Generate `lz.caseIntRet`
- Often the scrutinee is an `i1` from comparison
- In practice becomes if-then-else

### 6. Join Points (Efficient Local Control Flow)

Lean's key optimization for loops and local control flow (lines 1164-1180):

```lean
// Join point declaration
jdecl <id> [params] {
  // body of join point
} in {
  // continuation
}
```

Compiles to:

```mlir
"lz.joinpoint"()({
  ^entry(%param: !lz.value):
    // body
}, {
  // continuation
}) {value=<id>}
```

This is more efficient than closures because:
- No heap allocation
- Can be inlined or converted to labels
- Parameters in SSA form
- Can be called multiple times (like a label)

### 7. Handling Irrelevant Values

Lean erases proof terms at runtime. They become `%irrelevant`:

```mlir
%c0_irr = std.constant 0 : i32
%irrelevant = call @lean_box(%c0_irr) : (i32) -> (!lz.value)
```

Then `%irrelevant` can be used wherever an erased value is needed.

### 8. Object Reuse Optimization

Lean tries to reuse constructor allocations when RC=1:

```mlir
// From emitReset (lines 640-656)
%excl = call @lean_is_exclusive(%x) : (!lz.value) -> (i1)
%z = scf.if %excl -> (!lz.value) {
  call @lean_ctor_release(%x, ...) // Release fields
  scf.yield %x  // Reuse allocation
} else {
  call @lean_dec_ref(%x)  // Decrement RC
  %new = call @lean_box(...) // New allocation
  scf.yield %new
}
```

This is a key optimization for functional languages - reuse allocations when possible.

## Functional Programming Patterns

### 1. Algebraic Data Types

Represented as tagged unions:

```lean
-- Lean definition
inductive List (α : Type)
| nil : List α
| cons : α → List α → List α
```

Compiles to constructors with tags:

```mlir
// nil (tag 0)
%nil = "lz.construct"() {dataconstructor=@"0", size=0}
  : () -> (!lz.value)

// cons (tag 1)
%cons = "lz.construct"(%head, %tail) {
  dataconstructor=@"1",
  size=2
} : (!lz.value, !lz.value) -> (!lz.value)
```

### 2. Higher-Order Functions

Functions are first-class values:

```mlir
// Create closure (partial application)
%map = "lz.pap"(%f) {value=@map_impl, arity=2}
  : (!lz.value) -> (!lz.value)

// Apply closure
%result = "lz.call"(%map, %list) {value=..., musttail="false"}
  : (!lz.value, !lz.value) -> (!lz.value)
```

### 3. Immutability

No write barriers needed - objects never mutated after construction. The only mutation is RC updates, which are internal to runtime.

### 4. Tail Recursion

Explicitly marked and preserved:

```mlir
func @factorial_impl(%n: i32, %acc: !lz.value) -> !lz.value {
  // ... recursive case ...
  %next_acc = "lz.call"(%mul, %n, %acc) {...}
  %result = "lz.call"(%factorial_impl, %n_minus_1, %next_acc) {
    value=@factorial_impl,
    musttail="true"  // ← MUST be tail call
  } : (i32, !lz.value, !lz.value) -> (!lz.value)
  "lz.return"(%result) : (!lz.value) -> ()
}
```

### 5. Currying and Partial Application

Built into the type system:

```lean
-- Lean function
def add (x y : Nat) : Nat := x + y

-- Can be partially applied
def add5 := add 5  -- Closure capturing 5
```

Compiles to:

```mlir
%add5 = "lz.pap"(%five) {value=@add, arity=2}
  : (!lz.value) -> (!lz.value)
```

### 6. Pattern Matching

Compiles to efficient switches:

```lean
match list with
| List.nil => 0
| List.cons x xs => 1 + length xs
```

Becomes:

```mlir
"lz.caseRet"(%list)(
  { // nil case
    %zero = "lz.int"() {value=0} : () -> (!lz.value)
    "lz.return"(%zero) : (!lz.value) -> ()
  },
  { // cons case
    %x = "lz.project"(%list) {value=0} : (!lz.value) -> (!lz.value)
    %xs = "lz.project"(%list) {value=1} : (!lz.value) -> (!lz.value)
    %len_xs = "lz.call"(%length, %xs) {...}
    %one = "lz.int"() {value=1} : () -> (!lz.value)
    %result = "lz.call"(%add, %one, %len_xs) {...}
    "lz.return"(%result) : (!lz.value) -> ()
  }
) {alt0=0, alt1=1} : (!lz.value) -> ()
```

## Runtime Integration

### Memory Management

Reference counting, not garbage collection:

| MLIR Operation | Runtime Function | Purpose |
|----------------|------------------|---------|
| `lz.inc` | `lean_inc`, `lean_inc_n`, `lean_inc_ref` | Increment RC |
| `lz.dec` | `lean_dec`, `lean_dec_n`, `lean_dec_ref` | Decrement RC, maybe free |
| `lz.construct` | `lean_alloc_ctor` | Allocate constructor |
| - | `lean_ctor_set` | Set constructor field |
| `lz.project` | `lean_ctor_get` | Get constructor field |
| - | `lean_is_exclusive` | Check if RC=1 (can reuse) |
| - | `lean_is_scalar` | Check if tagged scalar (not heap) |

### Calling Convention

Functions in Lean IR take:
- Regular parameters (passed in registers/stack)
- Return `!lz.value` or primitive type

Closures are heap objects with:
- Function pointer
- Array of captured arguments
- Remaining arity

### Module Initialization

Each module has an initialization function:

```mlir
func private @_init_<module_name>(%in: !lz.value) -> !lz.value {
  // Initialize imported modules
  %result1 = call @_init_<import1>(%in) : (!lz.value) -> !lz.value
  %result2 = call @_init_<import2>(%in) : (!lz.value) -> !lz.value

  // Initialize globals
  %global1 = call @_init_global1() : () -> !lz.value
  "ptr.storeglobal"(%global1) {value=@global1} : (!lz.value) -> ()
  call @lean_mark_persistent(%global1) : (!lz.value) -> ()

  // Return success
  %ok = call @lean_io_result_mk_ok(%unit) : (!lz.value) -> !lz.value
  return %ok : !lz.value
}
```

Key point: Initialization happens in dependency order, and persistent values are marked (no RC needed).

## Patterns Applicable to ECO

### 1. Dialect Design Patterns

**✓ Use opaque value type**:
- Lean uses `!lz.value` for all heap objects
- ECO should use `!eco.value` similarly
- Enables uniform representation of ADTs, closures, etc.

**✓ Separate boxed and unboxed types**:
- Primitives (i32, f64) are unboxed when possible
- Explicit boxing/unboxing operations
- Reduces allocation pressure

**✓ High-level operations in dialect**:
- Don't lower to `alloc` + `store` immediately
- Keep operations like `lz.construct` at dialect level
- Enables better optimization before lowering

### 2. ADT Compilation Patterns

**✓ Constructor representation**:
```mlir
%obj = "eco.construct"(%field1, %field2) {
  constructor = @"ModuleName.TypeName.CtorName",
  tag = <n>,
  size = 2
} : (!eco.value, !eco.value) -> (!eco.value)
```

**✓ Pattern matching**:
```mlir
"eco.case"(%scrutinee)(
  { // tag 0 alternative },
  { // tag 1 alternative },
  { // default }
) {tags = [0, 1]} : (!eco.value) -> ()
```

**✓ Field projection**:
```mlir
%field = "eco.project"(%obj) {index = 0}
  : (!eco.value) -> (!eco.value)
```

### 3. Closure Compilation Patterns

**✓ Three-phase closure handling**:

1. **Partial application** (closure creation):
```mlir
%closure = "eco.papCreate"(%captured...) {
  function = @func_name,
  arity = <total>,
  num_captured = <n>
} : (...) -> (!eco.value)
```

2. **Closure extension** (more arguments):
```mlir
%extended = "eco.papExtend"(%closure, %newargs...)
  : (!eco.value, ...) -> (!eco.value)
```

3. **Closure invocation** (check arity, call or return closure):
Handled by runtime or explicit lowering.

### 4. Tail Call Optimization

**✓ Explicit tail call marking**:
```mlir
%result = "eco.call"(%func, %args...) {
  musttail = true,  // ← Required for correctness
  function = @name
} : (...) -> (...)
```

**✓ Tail call discipline**:
- Mark ALL tail recursive calls
- Validate during IR construction
- Error if tail call impossible (wrong calling convention, etc.)

### 5. Control Flow Patterns

**✓ Join points for local loops**:
```mlir
"eco.joinpoint"()({
  ^jp(%param: !eco.value):
    // loop body
    "eco.jump"(%next_value) {join_point = ...}
}, {
  // continuation after loop
}) {id = <unique_id>}
```

More efficient than:
- Recursive calls (no stack frames)
- Closures (no allocation)

### 6. GC Integration Patterns (ECO-specific)

Lean uses reference counting, ECO uses tracing GC. Differences:

**Lean MLIR** (RC):
```mlir
"lz.inc"(%x) {value=1, checkref=true}
"lz.dec"(%x) {value=1, ref=true}
```

**ECO MLIR** (GC):
```mlir
// No explicit inc/dec
// Instead: safepoints for GC
"eco.safepoint"() {stack_map = ...} : () -> ()

// And: root tracking
%obj = "eco.allocate"(%size) {
  type = @TypeName,
  needs_root = true  // In root set during construction
} : (i64) -> (!eco.value)
```

### 7. Memory Allocation Patterns

**✓ Allocation operations**:
```mlir
// Constructor allocation
%obj = "eco.allocate_ctor"() {
  tag = <n>,
  size = 2,
  scalar_bytes = 0
} : () -> (!eco.value)

// String allocation
%str = "eco.allocate_string"() {
  length = <n>
} : () -> (!eco.value)

// Closure allocation
%closure = "eco.allocate_closure"() {
  function = @func,
  num_captures = 3
} : () -> (!eco.value)
```

**✓ Always attach type information**:
- Enables GC to scan objects correctly
- Helps optimization passes
- Required for stack maps

### 8. Module and Global Patterns

**✓ Global initialization**:
```mlir
// Declare global
"eco.global"() {name = @global_name, type = !eco.value}
  : () -> ()

// Initialize in module init function
func @_init_module() {
  %val = call @compute_initial_value() : () -> !eco.value
  "eco.store_global"(%val) {global = @global_name}
  // For ECO: possibly register as GC root
}
```

### 9. Lowering Strategy

**✓ Multi-stage lowering**:

```
ECO High-Level Dialect
  ↓ (lower constructs)
ECO Mid-Level Dialect (with GC operations explicit)
  ↓ (lower to LLVM constructs)
LLVM Dialect
  ↓ (MLIR → LLVM)
LLVM IR
```

Don't try to lower everything at once. Keep high-level semantics as long as possible.

### 10. Testing Strategy

**✓ Test each IR construct**:
- Lean repo has `tests/backendramp/` with minimal examples
- Test: simple constructors, pattern matching, recursion, closures
- Ensure each can round-trip through MLIR

**✓ Test properties**:
- Factorial (tail recursion)
- map/filter (higher-order functions)
- Tree traversal (nested ADTs)
- Mutual recursion
- Case analysis with many branches

## Differences from ECO's Needs

### 1. Memory Management

**Lean**: Reference counting
- Explicit `inc`/`dec` in IR
- Objects freed immediately when RC=0
- Can optimize away RC for local variables

**ECO**: Tracing garbage collection
- Need safepoints for GC
- Need stack maps for roots
- No explicit free operations
- Write barriers NOT needed (Elm immutability!)

### 2. Object Mutability

**Lean**: Optimistic in-place update
- Check RC=1, mutate if exclusive
- Enables "functional but in-place" style

**ECO**: Strict immutability
- Never mutate after construction
- Simpler semantics
- No write barriers needed for generational GC

### 3. Calling Convention

**Lean**: Reference-counted objects passed by value
- Caller/callee need to manage RC
- Borrowed parameters (no RC change)

**ECO**: GC-managed objects
- Just pass pointers
- GC finds roots via stack maps
- Simpler calling convention

### 4. Compilation Model

**Lean**: Separate compilation + C FFI
- Each module → object file
- Link with runtime (written in C)
- Call external C functions easily

**ECO**: Whole-program compilation (initially)
- Can see entire program
- Enables aggressive optimization
- Harder to interop with C

### 5. Types System

**Lean**: Dependent types, proof-relevant
- Complex type system
- Proof erasure at compile time
- `irrelevant` values in IR

**ECO**: Elm's simple types
- No dependent types
- No erasure needed
- Simpler IR

## Recommendations for ECO

Based on Lean's MLIR approach, ECO should:

### 1. Define `eco` MLIR Dialect

**Core operations**:
- `eco.construct`: Create ADT
- `eco.project`: Extract field
- `eco.case`: Pattern match
- `eco.call`, `eco.papCreate`, `eco.papExtend`: Functions
- `eco.joinpoint`, `eco.jump`: Local control flow
- `eco.allocate_*`: Various allocations
- `eco.safepoint`: GC safepoints
- `eco.return`: Function return

**Core type**:
- `!eco.value`: All heap objects

**Attributes**:
- Attach LLVM function attributes (musttail, etc.)
- Type information for GC
- Debug information

### 2. Implement Multi-Stage Lowering

**Stage 1: Elm → ECO IR**
- ANF transformation
- Lambda lifting
- Join point identification
- Closure conversion

**Stage 2: ECO IR → ECO MLIR Dialect**
- Direct translation (like EmitMLIR.lean)
- Emit high-level operations
- Maintain type information

**Stage 3: ECO Dialect → ECO Dialect + GC**
- Insert safepoints
- Generate stack maps
- Lower allocations to calls

**Stage 4: ECO Dialect → LLVM Dialect**
- Lower `eco.construct` → `alloc` + `store`
- Lower `eco.call` → `llvm.call`
- Lower `eco.case` → `switch` or branches
- Lower join points → labels + branches

**Stage 5: LLVM Dialect → LLVM IR → Native**
- Standard MLIR machinery

### 3. Adopt Successful Patterns

**From Lean**:
- ✓ Use opaque value type for objects
- ✓ High-level operations in dialect
- ✓ Join points for efficient loops
- ✓ Explicit tail call marking
- ✓ Three-phase closure handling
- ✓ Separate boxed/unboxed types

**Different from Lean**:
- ✗ Don't use reference counting
- ✓ Add GC safepoints and stack maps
- ✓ Simpler (no dependent types)
- ✓ Leverage immutability (no write barriers)

### 4. Testing and Validation

**Start with minimal examples**:
```elm
-- Test 1: Simple ADT
type Maybe a = Nothing | Just a

-- Test 2: Tail recursion
factorial n = factHelper n 1

-- Test 3: Higher-order functions
map f list = case list of ...

-- Test 4: Nested patterns
depth tree = case tree of ...
```

**Validate each stage**:
- Pretty-print each IR level
- Roundtrip tests
- Execution tests
- Performance benchmarks

### 5. Leverage MLIR Infrastructure

**Use existing dialects**:
- `scf` (structured control flow) for conditionals
- `std` (standard) for constants, arithmetic
- `llvm` for low-level operations

**Use existing passes**:
- Inlining
- Common subexpression elimination
- Dead code elimination
- SROA (Scalar Replacement of Aggregates)

**Create custom passes**:
- GC safepoint insertion
- Stack map generation
- Closure optimization
- Join point optimization

### 6. Runtime Integration

**Define C API for GC**:
```c
// Allocate object (may trigger GC)
eco_value* eco_alloc_ctor(uint32_t tag, uint32_t size);

// Allocate closure
eco_value* eco_alloc_closure(void* func_ptr, uint32_t num_captures);

// Trigger GC explicitly (for testing)
void eco_gc_collect();

// Register root
void eco_gc_add_root(eco_value** root_location);
```

**Stack map format**:
```yaml
function: @factorial
offset: 42  # Instruction offset
roots:
  - location: stack[-8]   # 8 bytes below FP
    type: eco.value
  - location: register:rax
    type: eco.value
```

### 7. Optimization Opportunities

**ECO-specific**:
- No RC overhead (faster than Lean!)
- Aggressive inlining (whole program)
- Closure elimination (escape analysis)
- Unboxing (more than Lean, due to purity)

**Inherited from MLIR**:
- Constant folding
- Loop optimizations
- Vectorization (if applicable)

### 8. Debugging Support

**Emit debug info**:
- Source locations in MLIR
- DWARF debug info in object file
- Pretty stack traces (use libbacktrace)

**Provide tools**:
- MLIR pretty printer
- GC statistics (like eco-runtime)
- Heap profiler

## Example: Compiling `map` Function

Let's trace through a complete example.

### Elm Source

```elm
map : (a -> b) -> List a -> List b
map f list =
    case list of
        [] -> []
        x :: xs -> f x :: map f xs
```

### After ANF + Lambda Lifting

```
map f list =
  case list of
    [] -> []
    (::) x xs ->
      let fx = f x
      let rest = map f xs
      (::) fx rest
```

### ECO IR (Hypothetical)

```
fn @map(f: !eco.value, list: !eco.value) -> !eco.value {
  case list {
    tag(0): // []
      %nil = construct [] {}
      return %nil

    tag(1): // (::)
      %x = project list, 0
      %xs = project list, 1
      %fx = call f(%x)
      %rest = call @map(f, %xs) [tailcall]
      %result = construct (::) {%fx, %rest}
      return %result
  }
}
```

### ECO MLIR Dialect (Emitted)

```mlir
func @map(%f: !eco.value, %list: !eco.value) -> !eco.value {
  "eco.case"(%list)(
    {  // [] case (tag 0)
      %nil = "eco.construct"() {
        constructor = @"List.[]",
        tag = 0,
        size = 0
      } : () -> (!eco.value)
      "eco.return"(%nil) : (!eco.value) -> ()
    },
    {  // (::) case (tag 1)
      %x = "eco.project"(%list) {field = 0}
        : (!eco.value) -> (!eco.value)
      %xs = "eco.project"(%list) {field = 1}
        : (!eco.value) -> (!eco.value)

      // Apply f to x
      %fx = "eco.call"(%f, %x) {musttail = false}
        : (!eco.value, !eco.value) -> (!eco.value)

      // Recursive call (tail call)
      %rest = "eco.call"(%map, %f, %xs) {
        function = @map,
        musttail = true
      } : (!eco.value, !eco.value, !eco.value) -> (!eco.value)

      // Construct result
      %result = "eco.construct"(%fx, %rest) {
        constructor = @"List.::",
        tag = 1,
        size = 2
      } : (!eco.value, !eco.value) -> (!eco.value)

      "eco.return"(%result) : (!eco.value) -> ()
    }
  ) {tags = [0, 1]} : (!eco.value) -> ()
}
```

### After Lowering to LLVM Dialect

```mlir
llvm.func @map(%f: !llvm.ptr<i8>, %list: !llvm.ptr<i8>)
    -> !llvm.ptr<i8> {
  // Extract tag from list
  %tag_ptr = llvm.getelementptr %list[0, 0]
    : (!llvm.ptr<i8>) -> !llvm.ptr<i32>
  %tag = llvm.load %tag_ptr : !llvm.ptr<i32>

  // Switch on tag
  llvm.switch %tag, ^default [
    0: ^case_nil,
    1: ^case_cons
  ]

^case_nil:
  // Allocate nil
  %nil = llvm.call @eco_alloc_ctor(%c0, %c0)
    : (i32, i32) -> !llvm.ptr<i8>
  llvm.return %nil : !llvm.ptr<i8>

^case_cons:
  // GC safepoint (may allocate)
  llvm.call @eco_gc_safepoint() : () -> ()

  // Project fields
  %x_ptr = llvm.getelementptr %list[0, 2] // fields start at offset 2
  %x = llvm.load %x_ptr : !llvm.ptr<ptr<i8>>
  %xs_ptr = llvm.getelementptr %list[0, 3]
  %xs = llvm.load %xs_ptr : !llvm.ptr<ptr<i8>>

  // Call closure f
  %fx = llvm.call @eco_apply_closure(%f, %x)
    : (!llvm.ptr<i8>, !llvm.ptr<i8>) -> !llvm.ptr<i8>

  // Tail call (musttail)
  %rest = llvm.call tail @map(%f, %xs)
    : (!llvm.ptr<i8>, !llvm.ptr<i8>) -> !llvm.ptr<i8>

  // Allocate cons
  %cons = llvm.call @eco_alloc_ctor(%c1, %c2)
    : (i32, i32) -> !llvm.ptr<i8>
  %field0_ptr = llvm.getelementptr %cons[0, 2]
  llvm.store %fx, %field0_ptr
  %field1_ptr = llvm.getelementptr %cons[0, 3]
  llvm.store %rest, %field1_ptr

  llvm.return %cons : !llvm.ptr<i8>

^default:
  llvm.unreachable
}
```

## Conclusion

Lean's MLIR implementation provides an excellent reference for compiling functional languages through MLIR. Key takeaways for ECO:

1. **Use a custom dialect** with high-level operations
2. **Multi-stage lowering** preserves semantics and enables optimization
3. **Explicit tail call marking** is essential for functional languages
4. **Join points** are more efficient than closures for local control flow
5. **Opaque value type** simplifies representation of ADTs and closures
6. **GC integration** (ECO-specific) requires safepoints and stack maps

The Lean implementation is ~1500 lines of well-structured code that demonstrates all these patterns. It's a valuable reference for ECO's MLIR backend development.

## lz Dialect C++ Implementation (Master Branch)

### Repository Information

- **lz Repository**: git@github.com:bollu/lz.git
- **Branch**: `master` (contains the C++ dialect implementation)
- **Alternative branch**: `2021-cgo-artifact` (contains Lean4 fork with EmitMLIR.lean)
- **Project name**: Core-MLIR
- **Status**: Research implementation for functional language compilation

### Key Finding: Complete C++ Dialect Implementation

The `lz` repository on the **master branch** contains a complete C++ implementation of the `lz` MLIR dialect, along with several other dialects for functional language compilation. This is a comprehensive MLIR-based compiler infrastructure.

### Architecture Overview

```
Lean4 Compiler (2021-cgo-artifact branch)
    │
    │ EmitMLIR.lean generates textual MLIR
    ▼
┌─────────────────────────────────────────────────────────────┐
│  lz Repository (master branch) - "Core-MLIR"                │
│                                                             │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │ Hask Dialect│  │ lambdapure  │  │   Pointer   │         │
│  │   (lz.*)    │  │   Dialect   │  │   Dialect   │         │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘         │
│         │                │                │                 │
│         └────────────────┼────────────────┘                 │
│                          │                                  │
│                          ▼                                  │
│                   ┌─────────────┐                           │
│                   │  hask-opt   │  (MLIR optimizer tool)    │
│                   └──────┬──────┘                           │
│                          │                                  │
│         ┌────────────────┼────────────────┐                 │
│         │                │                │                 │
│         ▼                ▼                ▼                 │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │ --lean-lower│  │ --ptr-lower │  │   SCF/Std   │         │
│  └─────────────┘  └─────────────┘  └─────────────┘         │
│                          │                                  │
│                          ▼                                  │
│                   ┌─────────────┐                           │
│                   │ LLVM Dialect│                           │
│                   └──────┬──────┘                           │
└──────────────────────────┼──────────────────────────────────┘
                           │
                           ▼
                    ┌─────────────┐
                    │   LLVM IR   │
                    └─────────────┘
```

### Dialects Implemented

#### 1. Hask Dialect (`lz.*` operations)

The primary dialect for functional language compilation. Located in:
- `include/Hask/HaskDialect.h`, `HaskDialect.td`
- `include/Hask/HaskOps.h` (783 lines)
- `lib/Hask/HaskOps.cpp` (1244 lines)
- `lib/Hask/HaskDialect.cpp`

**Complete Operation List:**

| Operation | Description | C++ Class |
|-----------|-------------|-----------|
| `lz.return` | Return from function | `HaskReturnOp` |
| `lz.ap` | Lazy application (creates thunk) | `ApOp` |
| `lz.apEager` | Eager application (direct call) | `ApEagerOp` |
| `lz.case` | Pattern match on ADT constructors | `CaseOp` |
| `lz.caseint` | Pattern match on integers | `CaseIntOp` |
| `lz.caseRet` | Case with implicit return | `HaskCaseRetOp` |
| `lz.caseIntRet` | Integer case with implicit return | `HaskCaseIntRetOp` |
| `lz.construct` | Create ADT constructor | `HaskConstructOp` |
| `lz.project` | Extract field from constructor | `ProjectionOp` |
| `lz.pap` | Partial application (closure) | `PapOp` |
| `lz.papExtend` | Extend closure with more args | `PapExtendOp` |
| `lz.lambda` | Lambda abstraction | `HaskLambdaOp` |
| `lz.force` | Force evaluation of thunk | `ForceOp` |
| `lz.thunkify` | Wrap value in thunk | `ThunkifyOp` |
| `lz.tagget` | Get constructor tag | `TagGetOp` |
| `lz.int` | Integer constant | `HaskIntegerConstOp` |
| `lz.largeint` | Large integer constant | `HaskLargeIntegerConstOp` |
| `lz.string` | String constant | `HaskStringConstOp` |
| `lz.inc` | Increment reference count | `IncOp` |
| `lz.dec` | Decrement reference count | `DecOp` |
| `lz.joinpoint` | Join point declaration | `HaskJoinPointOp` |
| `lz.jump` | Jump to join point | `HaskJumpOp` |
| `lz.call` | Direct function call | `HaskCallOp` |
| `lz.erasedvalue` | Erased proof term | `ErasedValueOp` |
| `lz.reset` | Reset for destructive update | `ResetOp` |
| `lz.reuseconstruct` | Reuse allocation | `ReuseConstructorOp` |

**Types:**
- `ValueType` (`!lz.value`) - Boxed heap value
- `ThunkType` (`!lz.thunk<T>`) - Lazy thunk wrapping type T

#### 2. lambdapure Dialect

Alternative functional dialect, located in:
- `include/lambdapure/Dialect.h`, `Ops.td`
- `lib/lambdapure/Dialect.cpp`

Operations (mostly commented out in current code):
- `lambdapure.IntegerConst`, `lambdapure.AppOp`, `lambdapure.PapOp`
- `lambdapure.CallOp`, `lambdapure.ReturnOp`, `lambdapure.ConstructorOp`
- `lambdapure.ProjectionOp`, `lambdapure.CaseOp`, `lambdapure.ResetOp`
- `lambdapure.IncOp`, `lambdapure.DecOp`, `lambdapure.BoxOp`, `lambdapure.UnboxOp`

#### 3. Pointer Dialect (`ptr.*`)

Low-level pointer operations, located in:
- `include/Pointer/PointerDialect.h`, `PointerDialect.td`
- `include/Pointer/PointerOps.h`, `PointerOps.td`
- `lib/Pointer/PointerDialect.cpp`, `PointerOps.cpp`

#### 4. GRIN Dialect

Graph Reduction Intermediate Notation, located in:
- `include/GRIN/GRINDialect.h`, `GRINDialect.td`
- `include/GRIN/GRINOps.h`, `GRINOps.td`
- `lib/GRIN/GRINDialect.cpp`, `GRINOps.cpp`

#### 5. Unification Dialect

Type unification operations, located in:
- `include/Unification/UnificationDialect.h`, `UnificationDialect.td`
- `include/Unification/UnificationOps.h`, `UnificationOps.td`
- `lib/Unification/UnificationDialect.cpp`, `UnificationOps.cpp`

#### 6. Rgn Dialect

Region-based memory management, located in:
- `include/RgnDialect.h`
- `lib/RgnDialect.cpp`
- `hask-opt/RgnDialect.cpp`, `RgnToStd.cpp`, `RgnCSEPass.cpp`

### Key Implementation Files

| File | Lines | Purpose |
|------|-------|---------|
| `include/Hask/HaskOps.h` | 783 | All Hask operation class definitions |
| `lib/Hask/HaskOps.cpp` | 1244 | Operation implementations (parse, print, build) |
| `lib/Hask/HaskDialect.cpp` | ~200 | Dialect registration and type definitions |
| `lib/Hask/LeanLowering.cpp` | ~800 | Lowering Hask dialect to LLVM |
| `lib/Hask/LeanRgnLowering.cpp` | ~500 | Region-based lowering |
| `hask-opt/hask-opt.cpp` | ~300 | Main optimizer tool |
| `hask-opt/LeanPipeline.cpp` | ~200 | Compilation pipeline |

### Lowering Passes

The repository includes several lowering passes:

1. **`--lean-lower`**: Lowers `lz.*` operations to lower-level constructs
2. **`--ptr-lower`**: Lowers pointer operations
3. **`--convert-scf-to-std`**: Standard MLIR pass for control flow
4. **`--lz-lambdapure-to-lean`**: Converts lambdapure to Hask dialect
5. **`--lz-lambdapure-reference-rewriter`**: Optimizes reference counting
6. **`--lz-lambdapure-destructive-updates`**: Enables in-place updates

### Usage Example

From the test scripts:
```bash
# Compile Lean to MLIR
lean -m "$f.mlir" "$f"

# Run through hask-opt with lowering passes
hask-opt "$f.mlir" --convert-scf-to-std --lean-lower --ptr-lower | \
  mlir-translate --mlir-to-llvmir -o "$f.ll"

# Compile LLVM IR to executable
clang "$f.ll" -o "$f.out"
```

### Code Example: HaskConstructOp Implementation

From `lib/Hask/HaskOps.cpp`:

```cpp
void HaskConstructOp::build(mlir::OpBuilder &builder,
                            mlir::OperationState &state,
                            StringRef constructorName,
                            ValueRange args) {
  state.addAttribute(
      HaskConstructOp::getDataConstructorAttrKey(),
      FlatSymbolRefAttr::get(builder.getContext(), constructorName));
  state.addOperands(args);
  // return type
  state.addTypes(ValueType::get(builder.getContext()));
};
```

### Implications for ECO

This implementation provides a complete reference for ECO's MLIR dialect:

**What to adopt:**
1. **Operation structure**: The pattern of `Op<...>` classes with `parse`, `print`, `build` methods
2. **Type system**: `ValueType` for boxed values, separate types for thunks
3. **Pattern matching**: `CaseOp` with regions for each alternative
4. **Closures**: Three-phase handling (`pap`, `papExtend`, application)
5. **Join points**: `HaskJoinPointOp` and `HaskJumpOp` for efficient loops
6. **Lowering passes**: Staged lowering to LLVM dialect

**What to change for ECO:**
1. **Remove RC operations**: `lz.inc`/`lz.dec` not needed with tracing GC
2. **Add GC operations**: Safepoints, stack maps, allocation barriers
3. **Simplify types**: Elm doesn't need `ThunkType` (strict evaluation)
4. **Add Elm-specific ops**: Records, update syntax, ports

## Further Research

To deepen understanding:

1. **Study lowering passes**: Examine `LeanLowering.cpp` in detail for patterns

2. **Examine generated code**: Compile Lean programs and inspect MLIR output

3. **Performance analysis**: Compare Lean MLIR vs. Lean C backend

4. **GC integration examples**: Look for other MLIR projects with GC (Mojo, Flang, Julia MLIR)

5. **Build the project**: Try building `hask-opt` to experiment with the dialect

## References

- **Lean 4 Main Repository**: https://github.com/leanprover/lean4
- **MLIR Fork by bollu (lean4)**: https://github.com/bollu/lean4 (branch: 2021-cgo-artifact)
- **lz Repository (C++ dialect)**: https://github.com/bollu/lz (branch: master)
- **Author**: Siddharth Bhat (@bollu) - known for MLIR work, compiler research
- **Key Files**:
  - `src/Lean/Compiler/IR/EmitMLIR.lean` (1509 lines) - MLIR emission
  - `include/Hask/HaskOps.h` (783 lines) - C++ dialect definition
  - `lib/Hask/HaskOps.cpp` (1244 lines) - C++ dialect implementation
- **CGO 2021**: Associated with "Code Generation and Optimization" conference
- **MLIR Documentation**: https://mlir.llvm.org/
- **Lean IR Documentation**: https://github.com/leanprover/lean4/blob/master/src/library/compiler/ir.cpp

This research provides a comprehensive foundation for ECO's MLIR dialect design. The lz repository demonstrates a complete, working implementation of an MLIR dialect for functional language compilation, including all the key patterns needed for ADTs, closures, pattern matching, and optimization.
