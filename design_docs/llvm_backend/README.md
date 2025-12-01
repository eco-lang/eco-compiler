# Roc LLVM Backend (`roc_gen_llvm`)

This document describes the LLVM code generation backend for the Roc compiler.

## Overview

The `roc_gen_llvm` crate translates **monomorphized IR** from `roc_mono` into LLVM IR using the [Inkwell](https://github.com/TheDan64/inkwell) library (Rust bindings for LLVM). The output is LLVM bitcode that can be optimized and compiled to native machine code.

## Table of Contents

1. [Input Representation](#input-representation)
2. [Translation Process](#translation-process)
3. [Intermediate Layers](#intermediate-layers)
4. [Key Data Structures](#key-data-structures)
5. [Code Flow](#code-flow)
6. [Source File Reference](#source-file-reference)

---

## Input Representation

The LLVM backend does **not** receive an AST. Instead, it receives a **monomorphized intermediate representation (IR)** from `roc_mono`. This IR has already been:

- Type-specialized (all polymorphism resolved)
- Closure-converted (closures lifted to top-level functions)
- Pattern-match compiled (converted to decision trees)
- Reference counting operations inserted

### Core Input Structures

The input consists of `Proc` (procedures) containing `Stmt` (statements) and `Expr` (expressions):

#### `Proc` - A Monomorphic Procedure

```rust
// From: crates/compiler/mono/src/ir.rs:304
pub struct Proc<'a> {
    pub name: LambdaName<'a>,                    // Function identifier
    pub args: &'a [(InLayout<'a>, Symbol)],      // Arguments with concrete layouts
    pub body: Stmt<'a>,                          // Function body
    pub closure_data_layout: Option<InLayout<'a>>, // Closure environment layout
    pub ret_layout: InLayout<'a>,                // Return type layout
    pub is_self_recursive: SelfRecursive,        // Tail-recursion info
    pub is_erased: bool,                         // Type-erased function flag
}
```

#### `Stmt` - Statement Tree

Statements form a tree structure representing control flow:

```rust
// From: crates/compiler/mono/src/ir.rs:1510
pub enum Stmt<'a> {
    // Sequential binding: let symbol = expr in continuation
    Let(Symbol, Expr<'a>, InLayout<'a>, &'a Stmt<'a>),

    // Pattern matching compiled to switch
    Switch {
        cond_symbol: Symbol,
        cond_layout: InLayout<'a>,
        branches: &'a [(u64, BranchInfo<'a>, Stmt<'a>)],
        default_branch: (BranchInfo<'a>, &'a Stmt<'a>),
        ret_layout: InLayout<'a>,
    },

    // Return a value
    Ret(Symbol),

    // Reference counting operations
    Refcounting(ModifyRc, &'a Stmt<'a>),

    // Assertions with debug info
    Expect { condition, region, lookups, variables, remainder },

    // Debug output
    Dbg { source_location, source, symbol, variable, remainder },

    // Join point definition (for loops/tail recursion)
    Join { id, parameters, body, remainder },

    // Jump to join point
    Jump(JoinPointId, &'a [Symbol]),

    // Panic/crash
    Crash(Symbol, CrashTag),
}
```

#### `Expr` - Expressions

Expressions represent leaf values and operations:

```rust
// From: crates/compiler/mono/src/ir.rs:1868
pub enum Expr<'a> {
    // Constants
    Literal(Literal<'a>),         // Int, Float, Bool, Str, etc.
    NullPointer,

    // Function calls
    Call(Call<'a>),               // Multiple call types (see below)

    // Data construction
    Tag { tag_layout, tag_id, arguments, reuse },  // Union constructor
    Struct(&'a [Symbol]),                          // Record/tuple literal

    // Data access
    StructAtIndex { index, field_layouts, structure },  // Field access
    GetTagId { structure, union_layout },               // Extract tag ID
    UnionAtIndex { structure, tag_id, union_layout, index }, // Union field
    GetElementPointer { structure, union_layout, indices },

    // Arrays
    Array { elem_layout, elems },
    EmptyArray,

    // Type erasure
    ErasedMake { value, callee },   // Create erased value
    ErasedLoad { symbol, field },   // Load from erased value

    // Function pointers
    FunctionPointer { lambda_name },

    // Memory operations
    Alloca { element_layout, initializer },
    Reset { symbol, update_mode },       // Reuse check
    ResetRef { symbol, update_mode },    // Non-recursive reuse
}
```

#### `Call` - Function Invocation

```rust
// From: crates/compiler/mono/src/ir.rs:1678
pub struct Call<'a> {
    pub call_type: CallType<'a>,
    pub arguments: &'a [Symbol],
}

pub enum CallType<'a> {
    // Direct call to known function
    ByName {
        name: LambdaName<'a>,
        ret_layout: InLayout<'a>,
        arg_layouts: &'a [InLayout<'a>],
        specialization_id: CallSpecId,
    },

    // Indirect call via function pointer
    ByPointer {
        pointer: Symbol,
        ret_layout: InLayout<'a>,
        arg_layouts: &'a [InLayout<'a>],
    },

    // C FFI call
    Foreign { foreign_symbol, ret_layout },

    // Built-in operation
    LowLevel { op: LowLevel, update_mode },

    // Higher-order builtins (List.map, etc.)
    HigherOrder(&'a HigherOrderLowLevel<'a>),
}
```

#### `ModifyRc` - Reference Counting Operations

```rust
// From: crates/compiler/mono/src/ir.rs:1612
pub enum ModifyRc {
    Inc(Symbol, u64),   // Increment refcount by N
    Dec(Symbol),        // Decrement (recursive free if zero)
    DecRef(Symbol),     // Non-recursive decrement
    Free(Symbol),       // Unconditional deallocation
}
```

---

## Layout System

`Layout` represents the **concrete memory representation** of types. Unlike the type system, layouts are fully monomorphic.

```rust
// From: crates/compiler/mono/src/layout.rs:680
pub enum LayoutRepr<'a> {
    Builtin(Builtin<'a>),              // Primitives: Int, Float, Bool, Str, List
    Struct(&'a [InLayout<'a>]),        // Product types (records, tuples)
    Ptr(InLayout<'a>),                 // Non-RC pointer
    Union(UnionLayout<'a>),            // Sum types (tag unions)
    LambdaSet(LambdaSet<'a>),          // Function value representation
    RecursivePointer(InLayout<'a>),    // Pointer in recursive structure
    FunctionPointer(FunctionPointer<'a>), // Type-erased function pointer
    Erased(Erased),                    // Type-erased value
}

pub enum UnionLayout<'a> {
    NonRecursive(&'a [&'a [InLayout<'a>]]),  // Standard tagged union
    Recursive(&'a [&'a [InLayout<'a>]]),     // Recursive type
    NonNullableUnwrapped(&'a [InLayout<'a>]), // Single constructor, unwrapped
    NullableWrapped { nullable_id, other_tags }, // Empty = NULL optimization
    NullableUnwrapped { nullable_id, other_fields }, // Two constructors, one NULL
}
```

---

## Translation Process

### Entry Point

The main entry point is `build_procedures`:

```rust
// From: crates/compiler/gen_llvm/src/llvm/build.rs:5359
pub fn build_procedures<'a>(
    env: &Env<'a, '_, '_>,
    layout_interner: &STLayoutInterner<'a>,
    opt_level: OptLevel,
    procedures: MutMap<(Symbol, ProcLayout<'a>), roc_mono::ir::Proc<'a>>,
    host_exposed_lambda_sets: HostExposedLambdaSets<'a>,
    entry_point: EntryPoint<'a>,
    debug_output_file: Option<&Path>,
    glue_layouts: &GlueLayouts<'a>,
)
```

### High-Level Pipeline

```
MutMap<(Symbol, ProcLayout), Proc>
    │
    ├── roc_alias_analysis::spec_program()
    │   └── Performs alias analysis → FuncSpecSolutions
    │
    ├── build_proc_headers()
    │   └── Generate LLVM function signatures
    │
    └── For each Proc:
        └── build_proc()
            └── build_exp_stmt(body)
                └── Recursively compile statement tree
```

### Statement Compilation: `build_exp_stmt`

```rust
// From: crates/compiler/gen_llvm/src/llvm/build.rs:3049
pub(crate) fn build_exp_stmt<'a, 'ctx>(
    env: &Env<'a, 'ctx, '_>,
    layout_interner: &STLayoutInterner<'a>,
    layout_ids: &mut LayoutIds<'a>,
    func_spec_solutions: &FuncSpecSolutions,
    scope: &mut Scope<'a, 'ctx>,
    parent: FunctionValue<'ctx>,
    stmt: &roc_mono::ir::Stmt<'a>,
) -> BasicValueEnum<'ctx>
```

Translation for each statement type:

| Statement | LLVM Translation |
|-----------|------------------|
| `Let(sym, expr, layout, cont)` | Compile expr, insert into scope, compile continuation |
| `Switch { branches, ... }` | Multiple basic blocks + phi nodes for merge |
| `Ret(symbol)` | Load from scope + return instruction |
| `Refcounting(Inc/Dec, cont)` | Call refcount functions, compile continuation |
| `Join { id, params, body, remainder }` | Create basic block as jump target |
| `Jump(id, args)` | Branch to join point block |
| `Crash(symbol, tag)` | Call panic function |

### Expression Compilation: `build_exp_expr`

```rust
// From: crates/compiler/gen_llvm/src/llvm/build.rs:1558
pub(crate) fn build_exp_expr<'a, 'ctx>(
    env: &Env<'a, 'ctx, '_>,
    layout_interner: &STLayoutInterner<'a>,
    layout_ids: &mut LayoutIds<'a>,
    func_spec_solutions: &FuncSpecSolutions,
    scope: &mut Scope<'a, 'ctx>,
    parent: FunctionValue<'ctx>,
    layout: InLayout<'a>,
    expr: &roc_mono::ir::Expr<'a>,
) -> BasicValueEnum<'ctx>
```

Translation for each expression type:

| Expression | LLVM Translation |
|------------|------------------|
| `Literal(Int)` | `const_int()` |
| `Literal(Str)` | Global string or inline small string |
| `Call(ByName{...})` | Direct function call |
| `Call(ByPointer{...})` | Indirect call via function pointer |
| `Call(LowLevel{...})` | Inline LLVM instructions or intrinsics |
| `Tag { ... }` | Allocate + store tag ID + payload |
| `Struct(fields)` | Pack values into LLVM struct |
| `StructAtIndex` | GEP (getelementptr) + load |
| `GetTagId` | Extract tag from union |
| `Array { elems }` | Allocate list + store elements |

---

## Intermediate Layers

There are several intermediate representations between the mono IR and raw LLVM:

### 1. Scope - Symbol Table

Maps Roc symbols to LLVM values during compilation:

```rust
// From: crates/compiler/gen_llvm/src/llvm/scope.rs:13
pub(crate) struct Scope<'a, 'ctx> {
    symbols: ImMap<Symbol, (InLayout<'a>, BasicValueEnum<'ctx>)>,
    top_level_thunks: ImMap<Symbol, (ProcLayout<'a>, FunctionValue<'ctx>)>,
    join_points: ImMap<JoinPointId, (BasicBlock<'ctx>, Vec<JoinPointArg<'ctx>>)>,
}
```

### 2. Env - Compilation Environment

Global state during code generation:

```rust
// From: crates/compiler/gen_llvm/src/llvm/build.rs:733
pub struct Env<'a, 'ctx, 'env> {
    pub arena: &'a Bump,                    // Arena allocator
    pub context: &'ctx Context,             // LLVM context
    pub builder: &'env Builder<'ctx>,       // LLVM IR builder
    pub dibuilder: &'env DebugInfoBuilder<'ctx>, // Debug info
    pub compile_unit: &'env DICompileUnit<'ctx>,
    pub module: &'ctx Module<'ctx>,         // LLVM module
    pub interns: Interns,                   // Symbol interning
    pub target: Target,                     // Compilation target
    pub mode: LlvmBackendMode,              // Binary/Test/etc.
    pub exposed_to_host: MutSet<Symbol>,    // Host-exposed functions
}
```

### 3. Layout Interner

Caches and canonicalizes layouts:

```rust
// From: crates/compiler/mono/src/layout.rs:116
pub struct LayoutCache<'a> {
    pub target: Target,
    cache: std::vec::Vec<CacheLayer<LayoutResult<'a>>>,
    raw_function_cache: std::vec::Vec<CacheLayer<RawFunctionLayoutResult<'a>>>,
    pub interner: TLLayoutInterner<'a>,
}
```

### 4. FuncSpecSolutions - Alias Analysis Results

Contains specialization information from Morphic analysis:

```rust
// Used to determine:
// - Which function specialization to call
// - Update modes (InPlace vs Immutable)
// - Borrow vs owned parameters
```

---

## Key Data Structures

### Layout to LLVM Type Translation

```rust
basic_type_from_layout(env, layout_interner, layout_repr) -> BasicTypeEnum
```

| Layout | LLVM Type |
|--------|-----------|
| `Builtin(Int(I64))` | `i64` |
| `Builtin(Float(F64))` | `double` |
| `Builtin(Bool)` | `i1` |
| `Builtin(Str)` | `{ ptr, i64, i64 }` (ptr, len, capacity) |
| `Builtin(List(elem))` | `{ ptr, i64, i64 }` |
| `Struct([...])` | LLVM struct with field types |
| `Union(...)` | LLVM struct `{ tag_type, payload }` |

### Calling Conventions

```rust
const FAST_CALL_CONV: u32 = 8;  // LLVM fast calling convention
const C_CALL_CONV: u32 = 0;     // C calling convention (for FFI)
```

### Return Value Handling

Large values are returned via pointer:

```rust
pub enum RocReturn {
    ByValue(BasicType),    // Return in register
    ByPointer(InLayout),   // Caller allocates, callee fills
}
```

---

## Code Flow

### Complete Translation Example

```
Roc Source:
    add : Int, Int -> Int
    add = \x, y -> x + y

After Monomorphization (mono IR):
    Proc {
        name: add,
        args: [(I64, x), (I64, y)],
        body: Let(result,
                  Call {
                      call_type: LowLevel { op: NumAdd },
                      arguments: [x, y]
                  },
                  I64,
                  Ret(result))
        ret_layout: I64,
    }

LLVM IR Output:
    define fastcc i64 @add(i64 %x, i64 %y) {
    entry:
        %result = add i64 %x, %y
        ret i64 %result
    }
```

### Switch Compilation

```
mono IR:
    Switch {
        cond_symbol: tag_id,
        branches: [(0, _, branch0), (1, _, branch1)],
        default_branch: (_, default),
    }

LLVM IR:
    switch i8 %tag_id, label %default [
        i8 0, label %branch0
        i8 1, label %branch1
    ]

    branch0:
        ; ... compile branch0 body ...
        br label %merge

    branch1:
        ; ... compile branch1 body ...
        br label %merge

    default:
        ; ... compile default body ...
        br label %merge

    merge:
        %result = phi i64 [%r0, %branch0], [%r1, %branch1], [%rd, %default]
```

### Join Point Compilation (Tail Recursion)

```
mono IR:
    Join {
        id: jp1,
        parameters: [(I64, acc)],
        body: ...,           // Loop body
        remainder: ...,      // After loop
    }

    Jump(jp1, [new_acc])     // Tail call

LLVM IR:
    ; remainder code first
    br label %joinpoint

    joinpoint:
        %acc = phi i64 [%init, %entry], [%new_acc, %loop_body]
        ; loop body
        br label %joinpoint   ; tail call becomes branch
```

---

## Source File Reference

### Core Files

| File | Purpose |
|------|---------|
| `crates/compiler/gen_llvm/src/llvm/build.rs` | Main code generation (~6500 lines) |
| `crates/compiler/gen_llvm/src/llvm/scope.rs` | Symbol → LLVM value mapping |
| `crates/compiler/gen_llvm/src/llvm/convert.rs` | Layout → LLVM type conversion |
| `crates/compiler/gen_llvm/src/llvm/refcounting.rs` | Reference counting codegen |
| `crates/compiler/gen_llvm/src/llvm/lowlevel.rs` | Built-in operations |

### Input IR Files

| File | Purpose |
|------|---------|
| `crates/compiler/mono/src/ir.rs` | IR definitions (Proc, Stmt, Expr) |
| `crates/compiler/mono/src/layout.rs` | Layout system |

### Key Functions

| Function | Location | Purpose |
|----------|----------|---------|
| `build_procedures` | build.rs:5359 | Main entry point |
| `build_exp_stmt` | build.rs:3049 | Statement compilation |
| `build_exp_expr` | build.rs:1558 | Expression compilation |
| `build_exp_call` | build.rs:1405 | Call compilation |
| `build_exp_literal` | build.rs:1270 | Literal compilation |
| `basic_type_from_layout` | convert.rs | Layout → LLVM type |

---

## See Also

- [Compiler README](../../crates/compiler/README.md) - Overall compiler architecture
- [Compiler DESIGN.md](../../crates/compiler/DESIGN.md) - Detailed design document
- [Glossary](../../Glossary.md) - Compiler terminology
