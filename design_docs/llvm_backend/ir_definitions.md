# IR Definitions - Pseudocode Summary

This document summarizes the data structures and algorithms from `ir_definitions.rs`, which defines the monomorphic intermediate representation used as input to the LLVM backend.

## Core Concept

The IR consists of **Procedures** (functions) containing **Statements** (control flow) and **Expressions** (values). This is the output of monomorphization and input to code generation.

## Data Structures

### Proc - A Monomorphic Procedure

```
struct Proc:
    name: LambdaName                # Unique identifier with specialization info
    args: List<(Layout, Symbol)>    # Arguments with concrete layouts
    body: Stmt                      # Function body as statement tree
    closure_data_layout: Option<Layout>  # Closure captures layout (if any)
    ret_layout: Layout              # Return type layout
    is_self_recursive: SelfRecursive     # Tail-call info
    is_erased: bool                 # Type-erased function flag

enum SelfRecursive:
    NotSelfRecursive
    SelfRecursive(JoinPointId)      # Contains join point for tail calls
```

### Stmt - Statement Tree

Statements represent control flow. Each node contains a continuation (next statement).

```
enum Stmt:
    # Bind expression to symbol, then continue
    # let symbol = expr in continuation
    Let(symbol: Symbol, expr: Expr, layout: Layout, continuation: Stmt)

    # Multi-way branch (compiled from pattern matching)
    Switch:
        cond_symbol: Symbol           # Value to switch on
        cond_layout: Layout           # Layout of condition
        branches: List<(u64, BranchInfo, Stmt)>  # Cases
        default_branch: (BranchInfo, Stmt)       # Fallback
        ret_layout: Layout            # Return type (all branches)

    # Return a value
    Ret(Symbol)

    # Reference counting operation, then continue
    Refcounting(modify_rc: ModifyRc, continuation: Stmt)

    # Debug assertion
    Expect:
        condition: Symbol
        region: Region
        lookups: List<Symbol>
        variables: List<LookupType>
        remainder: Stmt

    # Debug print
    Dbg:
        source_location: String
        source: String
        symbol: Symbol
        variable: Variable
        remainder: Stmt

    # Define a join point (target for tail recursion)
    # join f <params> = body in remainder
    Join:
        id: JoinPointId
        parameters: List<Param>
        body: Stmt                    # What happens when jumping TO join point
        remainder: Stmt               # What happens after DEFINING join point

    # Jump to a join point (tail call)
    Jump(JoinPointId, arguments: List<Symbol>)

    # Crash/panic with error message
    Crash(message: Symbol, crash_tag: CrashTag)
```

### Expr - Expressions

Expressions compute values without continuations.

```
enum Expr:
    # === Literals ===
    Literal(Literal)                  # Int, Float, Bool, Str, etc.
    NullPointer                       # Null constant

    # === Function Calls ===
    Call(Call)                        # Multiple call types

    # === Data Construction ===
    Tag:
        tag_layout: UnionLayout
        tag_id: TagId
        arguments: List<Symbol>
        reuse: Option<ReuseToken>     # Memory reuse hint
    Struct(fields: List<Symbol>)      # Record/tuple literal

    # === Data Access ===
    StructAtIndex:
        index: u64
        field_layouts: List<Layout>
        structure: Symbol
    GetTagId:
        structure: Symbol
        union_layout: UnionLayout
    UnionAtIndex:
        structure: Symbol
        tag_id: TagId
        union_layout: UnionLayout
        index: u64
    GetElementPointer:
        structure: Symbol
        union_layout: UnionLayout
        indices: List<u64>

    # === Arrays ===
    Array:
        elem_layout: Layout
        elems: List<ListLiteralElement>
    EmptyArray

    # === Type Erasure ===
    ErasedMake:
        value: Option<Symbol>         # Captured data (None if no captures)
        callee: Symbol                # Function pointer
    ErasedLoad:
        symbol: Symbol
        field: ErasedField

    # === Function Pointers ===
    FunctionPointer:
        lambda_name: LambdaName

    # === Memory Operations ===
    Alloca:
        element_layout: Layout
        initializer: Option<Symbol>
    Reset:
        symbol: Symbol
        update_mode: UpdateModeId     # Reuse check
    ResetRef:
        symbol: Symbol
        update_mode: UpdateModeId     # Non-recursive reuse
```

### Call - Function Invocation

```
struct Call:
    call_type: CallType
    arguments: List<Symbol>

enum CallType:
    # Direct call to known function
    ByName:
        name: LambdaName
        ret_layout: Layout
        arg_layouts: List<Layout>
        specialization_id: CallSpecId

    # Indirect call via function pointer
    ByPointer:
        pointer: Symbol
        ret_layout: Layout
        arg_layouts: List<Layout>

    # C foreign function call
    Foreign:
        foreign_symbol: ForeignSymbol
        ret_layout: Layout

    # Built-in operation (compiled to inline code)
    LowLevel:
        op: LowLevel
        update_mode: UpdateModeId

    # Higher-order builtins (List.map, etc.)
    HigherOrder(HigherOrderLowLevel)
```

### ModifyRc - Reference Counting Operations

Inserted by the Perceus algorithm:

```
enum ModifyRc:
    # Increment reference count by N
    # Used when a value is used multiple times
    Inc(symbol: Symbol, amount: u64)

    # Decrement reference count
    # If count reaches zero, recursively free children then deallocate
    Dec(symbol: Symbol)

    # Non-recursive decrement
    # Only decrements the outer container, not children
    # Used when children are already handled
    DecRef(symbol: Symbol)

    # Unconditional deallocation
    # Used when we know refcount is 1 (e.g., after unique check)
    Free(symbol: Symbol)
```

### Literal - Constant Values

```
enum Literal:
    Int(bytes: [u8; 16])        # 128-bit integer
    U128(bytes: [u8; 16])       # Unsigned 128-bit
    Float(f64)
    Decimal(bytes: [u8; 16])    # Fixed-point
    Bool(bool)
    Byte(u8)
    Str(string)
```

### BranchInfo - Pattern Match Metadata

```
enum BranchInfo:
    # No additional info
    None

    # We know the scrutinee is a specific tag
    Constructor:
        scrutinee: Symbol
        layout: Layout
        tag_id: TagId

    # We know the scrutinee is a list of specific length
    List:
        scrutinee: Symbol
        len: u64

    # We know whether the scrutinee is unique (for reuse)
    Unique:
        scrutinee: Symbol
        unique: bool
```

### Supporting Types

```
# Unique identifier (64-bit: 32-bit module + 32-bit ident)
struct Symbol { ... }

# Interned layout reference
struct InLayout { index: u32 }

# Join point identifier (for tail recursion)
struct JoinPointId(Symbol)

# Parameter in a join point
struct Param:
    symbol: Symbol
    layout: Layout

# Token for memory reuse optimization
struct ReuseToken:
    symbol: Symbol
    update_mode: UpdateModeId

# Crash source
enum CrashTag:
    Roc = 0     # Compiler-generated crash
    User = 1    # User-defined crash
```

## Statement Tree Example

```
# Roc source:
add = \x, y -> x + y

# Monomorphic IR:
Proc {
    name: add
    args: [(I64, x), (I64, y)]
    body: Let(
        result,
        Call {
            call_type: LowLevel { op: NumAdd },
            arguments: [x, y]
        },
        I64,
        Ret(result)
    )
    ret_layout: I64
}
```

## Switch Example

```
# Roc source:
when color is
    Red -> "red"
    Green -> "green"
    Blue -> "blue"

# Monomorphic IR:
Switch {
    cond_symbol: color_tag
    cond_layout: U8
    branches: [
        (0, Constructor{Red}, Ret("red")),
        (1, Constructor{Green}, Ret("green")),
        (2, Constructor{Blue}, Ret("blue"))
    ]
    default_branch: (None, Crash("unreachable"))
    ret_layout: Str
}
```

## Join Point Example (Tail Recursion)

```
# Roc source:
sum = \list, acc ->
    when list is
        [] -> acc
        [x, ..rest] -> sum rest (acc + x)

# Monomorphic IR:
Proc {
    name: sum
    args: [(List(I64), list), (I64, acc)]
    body: Join {
        id: jp1
        parameters: [(List(I64), list'), (I64, acc')]
        body: Switch {
            cond_symbol: list'_len
            branches: [
                (0, _, Ret(acc')),          # [] -> acc
                (_, _, Let(                  # [x, ..rest] -> ...
                    x, ...,
                    Let(rest, ...,
                        Let(new_acc, NumAdd(acc', x), I64,
                            Jump(jp1, [rest, new_acc])  # Tail call!
                        )
                    )
                ))
            ]
        }
        remainder: Jump(jp1, [list, acc])   # Initial call to join point
    }
}
```

## Key Concepts

1. **Statement Tree**: Control flow as a tree, not a graph
2. **Continuations**: Every statement (except Ret/Crash/Jump) has a next statement
3. **Join Points**: Enable efficient loops/tail recursion without actual recursion
4. **Reference Counting**: Inc/Dec inserted by Perceus algorithm
5. **Reuse Tokens**: Enable memory reuse for unique values
6. **Monomorphic**: All type variables resolved to concrete layouts
