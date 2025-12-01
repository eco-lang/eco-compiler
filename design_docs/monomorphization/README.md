# Roc Monomorphization (`roc_mono`)

This document describes the monomorphization process in the Roc compiler, which transforms polymorphic canonical IR into monomorphic procedures ready for code generation.

## Overview

Monomorphization is the process of converting **polymorphic code** (with type variables) into **monomorphic code** (with concrete types). This happens in the `roc_mono` crate and involves:

1. **Type Specialization** - Resolving type variables to concrete layouts
2. **Closure Conversion** - Lifting closures to top-level functions
3. **Pattern Match Compilation** - Converting patterns to decision trees
4. **Reference Counting Insertion** - Adding memory management operations

## Table of Contents

1. [Input and Output](#input-and-output)
2. [Core Data Structures](#core-data-structures)
3. [Specialization Process](#specialization-process)
4. [Closure Conversion](#closure-conversion)
5. [Pattern Match Compilation](#pattern-match-compilation)
6. [Expression Conversion (from_can)](#expression-conversion-from_can)
7. [Source File Reference](#source-file-reference)

---

## Input and Output

### Input: Canonical IR (`roc_can`)

The input comes from the canonicalization phase and contains:

- **Polymorphic expressions** with type variables (`Variable`)
- **Closure definitions** with captured symbols
- **Pattern matching** expressions
- **Type annotations** that may contain type parameters

### Output: Monomorphic IR (`roc_mono`)

The output is fully specialized code:

- **Concrete layouts** for all types (`InLayout`)
- **Top-level procedures** (`Proc`) with closure captures as arguments
- **Decision trees** compiled from pattern matching
- **Reference counting operations** (`ModifyRc`)

---

## Core Data Structures

### Procs - Specialization State

The `Procs` struct tracks all specialization state:

```rust
// From: crates/compiler/mono/src/ir.rs:913
pub struct Procs<'a> {
    /// Unspecialized functions waiting to be specialized
    pub partial_procs: PartialProcs<'a>,

    /// Completed specialized procedures
    specialized: Specialized<'a>,

    /// Specializations discovered but not yet processed
    pending_specializations: PendingSpecializations<'a>,

    /// Lambda sets exposed to the host
    host_exposed_lambda_sets: HostExposedLambdaSets<'a>,

    /// Specializations needed from other modules
    pub externals_we_need: BumpMap<ModuleId, ExternalSpecializations<'a>>,

    /// Maps polymorphic symbols to their specializations
    symbol_specializations: SymbolSpecializations<'a>,

    /// Stack of functions currently being specialized (prevents infinite recursion)
    specialization_stack: SpecializationStack<'a>,

    /// Thunks (zero-argument functions) from this module
    pub module_thunks: &'a [Symbol],

    /// Functions exposed to the host
    pub host_exposed_symbols: &'a [Symbol],
}
```

### PartialProc - Unspecialized Function

A function waiting to be specialized for specific types:

```rust
// From: crates/compiler/mono/src/ir.rs:206
pub struct PartialProc<'a> {
    /// The function's type annotation (polymorphic)
    pub annotation: Variable,

    /// Parameter names
    pub pattern_symbols: &'a [Symbol],

    /// Variables captured from enclosing scope
    pub captured_symbols: CapturedSymbols<'a>,

    /// The function body (still in canonical form)
    pub body: roc_can::expr::Expr,

    /// Type of the body expression
    pub body_var: Variable,

    /// Whether this function calls itself
    pub is_self_recursive: bool,
}
```

### CapturedSymbols - Closure Captures

```rust
// From: crates/compiler/mono/src/ir.rs:287
pub enum CapturedSymbols<'a> {
    None,
    Captured(&'a [(Symbol, Variable)]),
}
```

### ProcLayout - Specialized Function Signature

```rust
// From: crates/compiler/mono/src/ir.rs:4102
pub struct ProcLayout<'a> {
    pub arguments: &'a [InLayout<'a>],  // Concrete argument layouts
    pub result: InLayout<'a>,           // Concrete return layout
    pub niche: Niche<'a>,               // Optimization hint
}
```

---

## Specialization Process

### Entry Point: `specialize_all`

The main entry point that drives all specialization:

```rust
// From: crates/compiler/mono/src/ir.rs:3027
pub fn specialize_all<'a>(
    env: &mut Env<'a, '_>,
    mut procs: Procs<'a>,
    externals_others_need: std::vec::Vec<ExternalSpecializations<'a>>,
    specializations_for_host: HostSpecializations<'a>,
    layout_cache: &mut LayoutCache<'a>,
) -> Procs<'a>
```

**Process:**

```
1. Convert pending_specializations to "Making" mode
   └── Prevents new specializations during this phase

2. Specialize all pending specializations
   └── specialize_suspended(env, procs, layout_cache, suspended)

3. Specialize functions other modules need
   └── for externals in externals_others_need:
           specialize_external_specializations(...)

4. Specialize host-exposed functions
   └── specialize_host_specializations(...)

5. Loop until no new specializations discovered:
   └── while !procs.pending_specializations.is_empty():
           specialize newly discovered functions
```

### Core Specialization: `specialize_variable`

Specializes a function for a specific type:

```rust
// From: crates/compiler/mono/src/ir.rs:4029
fn specialize_variable<'a>(
    env: &mut Env<'a, '_>,
    procs: &mut Procs<'a>,
    proc_name: LambdaName<'a>,
    layout_cache: &mut LayoutCache<'a>,
    fn_var: Variable,           // The specific type to specialize for
    partial_proc_id: PartialProcId,
) -> Result<SpecializeSuccess<'a>, SpecializeFailure<'a>>
```

**Steps:**

1. **Snapshot typestate** - For rollback on failure
2. **Get raw function layout** - From the type variable
3. **Instantiate rigids** - Convert rigid type variables to flexible
4. **Push to specialization stack** - Prevents infinite recursion
5. **Call `specialize_proc_help`** - Do the actual specialization
6. **Pop from stack and rollback** - Restore typestate

### Building Specialized Proc: `specialize_proc_help`

Actually builds the monomorphic procedure:

```rust
// From: crates/compiler/mono/src/ir.rs:3511
fn specialize_proc_help<'a>(
    env: &mut Env<'a, '_>,
    procs: &mut Procs<'a>,
    lambda_name: LambdaName<'a>,
    layout_cache: &mut LayoutCache<'a>,
    fn_var: Variable,
    partial_proc_id: PartialProcId,
) -> Result<Proc<'a>, LayoutProblem>
```

**Steps:**

1. **Unify types** - Unify annotation with specific type variable
2. **Handle closure arguments** - Add `ARG_CLOSURE` if captures exist
3. **Build specialized argument list** - With concrete layouts
4. **Convert body** - `from_can(env, body_var, body, procs, layout_cache)`
5. **Unpack closure fields** - Generate code to extract captured variables

### Handling Recursive Specialization

The `specialization_stack` prevents infinite recursion:

```rust
/// If we need to specialize a function already on the stack,
/// defer until it's popped off.
///
/// Example:
///   foo = \val, b -> if b then "done" else bar val
///   bar = \_ -> foo {} True
///   foo "" False
///
/// During foo : Str -> Str, we need bar : Str -> Str,
/// which needs foo : {} -> Str. But we can't specialize
/// both foo variants simultaneously.
fn symbol_needs_suspended_specialization(&self, symbol: Symbol) -> bool {
    self.specialization_stack.0.contains(&symbol)
}
```

---

## Closure Conversion

### Registration: `register_capturing_closure`

When a closure is encountered, it's registered as a PartialProc:

```rust
// From: crates/compiler/mono/src/ir.rs:6922
fn register_capturing_closure<'a>(
    env: &mut Env<'a, '_>,
    procs: &mut Procs<'a>,
    layout_cache: &mut LayoutCache<'a>,
    closure_name: Symbol,
    closure_data: ClosureData,
)
```

**Process:**

1. **Extract closure data** - Function type, return type, arguments, body
2. **Determine captures** - Which variables from enclosing scope are used
3. **Check lambda set** - Determine if captures need representation
4. **Create PartialProc** - Register for later specialization

### Closure Unpacking in Specialization

When a closure is specialized, captured variables are unpacked:

```rust
// In specialize_proc_help, handling captured symbols:

match closure_layout.layout_for_member_with_lambda_name(...) {
    // Multiple closures possible - use union
    ClosureRepresentation::Union { field_layouts, union_layout, tag_id, .. } => {
        for (index, (symbol, _)) in captured.iter().enumerate() {
            let expr = Expr::UnionAtIndex {
                tag_id,
                structure: Symbol::ARG_CLOSURE,
                index: index as u64,
                union_layout,
            };
            specialized_body = Stmt::Let(symbol, expr, layout, body);
        }
    }

    // Single closure type - use struct
    ClosureRepresentation::AlphabeticOrderStruct(field_layouts) => {
        for (index, (symbol, layout)) in captured.iter().enumerate() {
            let expr = Expr::StructAtIndex {
                index: index as _,
                field_layouts,
                structure: Symbol::ARG_CLOSURE,
            };
            specialized_body = Stmt::Let(symbol, expr, layout, body);
        }
    }

    // Single capture - no wrapping needed
    ClosureRepresentation::UnwrappedCapture(layout) => {
        // Just substitute ARG_CLOSURE for the captured symbol
    }
}
```

### Example: Closure Transformation

**Input (Roc):**
```roc
makeAdder = \n ->
    \x -> x + n

add5 = makeAdder 5
result = add5 10
```

**After Monomorphization:**

```
# Closure becomes top-level function with captures as argument
proc makeAdder_closure(x: I64, closure_data: { n: I64 }) -> I64:
    let n = closure_data.n    # Unpack capture
    let result = x + n
    ret result

# Call site packs captures
proc main() -> I64:
    let n = 5
    let closure_data = { n }
    let result = makeAdder_closure(10, closure_data)
    ret result
```

---

## Pattern Match Compilation

Pattern matching is compiled to efficient decision trees.

### Pattern Types

```rust
// From: crates/compiler/mono/src/ir/pattern.rs:23
pub enum Pattern<'a> {
    Identifier(Symbol),           // x
    Underscore,                   // _
    As(Box<Pattern<'a>>, Symbol), // pattern as x

    // Literals
    IntLiteral([u8; 16], IntWidth),
    FloatLiteral(u64, FloatWidth),
    DecimalLiteral([u8; 16]),
    StrLiteral(Box<str>),
    BitLiteral { value: bool, tag_name, union },
    EnumLiteral { tag_id: u8, tag_name, union },

    // Destructuring
    RecordDestructure(Vec<RecordDestruct>, &[InLayout]),
    TupleDestructure(Vec<TupleDestruct>, &[InLayout]),

    // Tag unions
    NewtypeDestructure { tag_name, arguments },
    AppliedTag { tag_name, tag_id, arguments, layout, union },
    Voided { tag_name },          // Empty tag union (unreachable)

    // Opaque types
    OpaqueUnwrap { opaque, argument },

    // Lists
    List { arity, list_layout, element_layout, elements, opt_rest },
}
```

### Decision Tree Structure

```rust
// From: crates/compiler/mono/src/ir/decision_tree.rs:68
enum DecisionTree<'a> {
    /// We've matched - execute this branch
    Match(Label),

    /// More decisions needed
    Decision {
        /// Path to the value being tested
        path: Vec<PathInstruction>,
        /// Possible tests and their subtrees
        edges: Vec<(GuardedTest<'a>, DecisionTree<'a>)>,
        /// Fallback if no test matches
        default: Option<Box<DecisionTree<'a>>>,
    },
}
```

### Test Types

```rust
// From: crates/compiler/mono/src/ir/decision_tree.rs:101
enum Test<'a> {
    IsCtor { tag_id, ctor_name, union, arguments },  // Tag constructor
    IsInt([u8; 16], IntWidth),                       // Integer literal
    IsFloat(u64, FloatWidth),                        // Float literal
    IsDecimal([u8; 16]),                             // Decimal literal
    IsStr(Box<str>),                                 // String literal
    IsBit(bool),                                     // Boolean
    IsByte { tag_id, num_alts },                     // Byte enum
    IsListLen { bound: ListLenBound, len: u64 },     // List length
}
```

### Decision Tree Compilation

```rust
// From: crates/compiler/mono/src/ir/decision_tree.rs:29
fn compile<'a>(
    interner: &TLLayoutInterner<'a>,
    raw_branches: Vec<(Guard<'a>, Pattern<'a>, u64)>,
) -> DecisionTree<'a>
```

**Algorithm:**

1. **Check for match** - If first branch needs no more tests, done
2. **Pick best path** - Choose which part of pattern to test next
3. **Gather edges** - Group branches by test result
4. **Recurse** - Build subtrees for each edge
5. **Handle fallback** - Remaining branches become default

### Example: Pattern Compilation

**Input:**
```roc
when color is
    Red -> "red"
    Green -> "green"
    Blue -> "blue"
```

**Decision Tree:**
```
Decision {
    path: [],
    edges: [
        (IsCtor { tag_id: 0 }, Match(0)),  # Red
        (IsCtor { tag_id: 1 }, Match(1)),  # Green
        (IsCtor { tag_id: 2 }, Match(2)),  # Blue
    ],
    default: None
}
```

**Generated IR:**
```
Switch {
    cond_symbol: color_tag,
    branches: [
        (0, _, Ret("red")),
        (1, _, Ret("green")),
        (2, _, Ret("blue")),
    ],
    default_branch: (_, Crash("unreachable")),
}
```

---

## Expression Conversion (from_can)

The `from_can` function converts canonical expressions to monomorphic IR:

```rust
// From: crates/compiler/mono/src/ir.rs:7012
pub fn from_can<'a>(
    env: &mut Env<'a, '_>,
    variable: Variable,
    can_expr: roc_can::expr::Expr,
    procs: &mut Procs<'a>,
    layout_cache: &mut LayoutCache<'a>,
) -> Stmt<'a>
```

### Expression Cases

| Canonical Expression | Monomorphic Result |
|---------------------|-------------------|
| `When { branches, cond, ... }` | `from_can_when()` → Decision tree → Switch |
| `If { branches, final_else }` | Nested `cond()` calls → Switch with 2 branches |
| `LetRec(defs, cont)` | Register closures, convert continuation |
| `LetNonRec(def, cont)` | `from_can_let()` → Let binding |
| `Closure(data)` | Register as PartialProc for later |
| `Call(...)` | `call_by_name()` or `call_by_pointer()` |
| `Var(symbol)` | `specialize_naked_symbol()` |
| `Literal(...)` | Direct `Expr::Literal` |

### When Expression Handling

```rust
When { cond_var, expr_var, branches, exhaustive, ... } => {
    // 1. Get symbol for condition
    let cond_symbol = possible_reuse_symbol_or_specialize(...);

    // 2. Compile pattern matching
    let stmt = from_can_when(
        env, cond_var, expr_var,
        cond_symbol, branches, exhaustive,
        layout_cache, procs, None,
    );

    // 3. Wrap with condition assignment
    assign_to_symbol(env, procs, layout_cache, cond_var, loc_cond, cond_symbol, stmt)
}
```

### Let Rec (Recursive Definitions)

```rust
LetRec(defs, cont, _cycle_mark) => {
    // Only functions can be recursive in Roc (strict evaluation)
    for def in defs {
        if let Pattern::Identifier(symbol) = &def.loc_pattern.value {
            match def.loc_expr.value {
                Closure(closure_data) => {
                    // Register closure for later specialization
                    register_capturing_closure(
                        env, procs, layout_cache,
                        symbol, closure_data,
                    );
                }
                _ => unreachable!("recursive value is not a function")
            }
        }
    }
    // Continue with the body
    from_can(env, variable, cont.value, procs, layout_cache)
}
```

---

## Demand-Driven Specialization

Specialization is **demand-driven**: functions are only specialized when called with specific types.

### Flow:

```
1. Host-exposed functions are seeds
   └── specialize_host_specializations()

2. Specializing a function may discover new needs
   └── Call to polymorphic function → queue specialization

3. Loop until fixed point
   └── while pending_specializations not empty:
           specialize all pending

4. External modules may need our functions
   └── externals_we_need tracks cross-module dependencies
```

### Example:

```roc
identity : a -> a
identity = \x -> x

main =
    identity 5        # Triggers identity : Int -> Int
    identity "hello"  # Triggers identity : Str -> Str
```

**Specialization order:**

1. Start with `main` (host-exposed)
2. Discover need for `identity : Int -> Int`
3. Specialize `identity` for `Int`
4. Discover need for `identity : Str -> Str`
5. Specialize `identity` for `Str`
6. No more pending → done

---

## Lambda Sets

Lambda sets track all possible function implementations at a call site:

```rust
// When a function could be one of several:
f = if condition then \x -> x + 1 else \x -> x * 2
f 10  # Lambda set = { closure1, closure2 }
```

**Handling:**

1. **Layout computation** - Lambda set becomes a union of closures
2. **Call site** - May need runtime dispatch or static specialization
3. **Type erasure** - If lambda set can't be resolved statically

---

## Source File Reference

### Core Files

| File | Purpose |
|------|---------|
| `crates/compiler/mono/src/ir.rs` | Main IR definitions and specialization (~8000 lines) |
| `crates/compiler/mono/src/ir/decision_tree.rs` | Pattern match compilation |
| `crates/compiler/mono/src/ir/pattern.rs` | Pattern representation |
| `crates/compiler/mono/src/layout.rs` | Layout computation |
| `crates/compiler/mono/src/borrow.rs` | Borrow signature inference |
| `crates/compiler/mono/src/inc_dec.rs` | Reference counting insertion |

### Key Functions

| Function | Location | Purpose |
|----------|----------|---------|
| `specialize_all` | ir.rs:3027 | Main entry point |
| `specialize_variable` | ir.rs:4029 | Specialize for specific type |
| `specialize_proc_help` | ir.rs:3511 | Build monomorphic procedure |
| `from_can` | ir.rs:7012 | Convert canonical expr to IR |
| `register_capturing_closure` | ir.rs:6922 | Register closure for specialization |
| `compile` | decision_tree.rs:29 | Compile patterns to decision tree |
| `from_can_pattern` | pattern.rs | Convert canonical pattern |

---

## See Also

- [LLVM Backend Documentation](../llvm_backend/README.md) - How mono IR is compiled to LLVM
- [Compiler README](../../crates/compiler/README.md) - Overall compiler architecture
- [Glossary](../../Glossary.md) - Compiler terminology
