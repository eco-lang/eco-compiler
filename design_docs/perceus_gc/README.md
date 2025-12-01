# Perceus Reference Counting in Roc

This document describes the implementation of the Perceus reference counting algorithm in the Roc compiler. Perceus is a "garbage-free" reference counting system that enables precise, deterministic memory management with support for memory reuse.

## Overview

Roc implements the Perceus algorithm as described in the paper:
- [Perceus: Garbage Free Reference Counting with Reuse](https://www.microsoft.com/en-us/research/uploads/prod/2021/06/perceus-pldi21.pdf)

Additional implementation details are documented in:
- [Reference Counting with Reuse in Roc](https://studenttheses.uu.nl/bitstream/handle/20.500.12932/44634/Reference_Counting_with_Reuse_in_Roc.pdf) (Master's thesis by Jelle Teeuwissen)

## Key Components

The Perceus implementation spans several modules:

```
crates/compiler/mono/src/
├── inc_dec.rs      # RC operation insertion (main Perceus algorithm)
├── borrow.rs       # Borrow signature inference

crates/compiler/gen_llvm/src/llvm/
├── refcounting.rs  # LLVM code generation for RC operations

crates/compiler/builtins/bitcode/src/
├── utils.zig       # Runtime heap operations
```

## Algorithm Phases

### Phase 1: Borrow Signature Inference (`borrow.rs`)

Before inserting reference counting operations, the compiler infers which function parameters can be "borrowed" (passed without ownership transfer) vs "owned" (requiring ownership transfer).

```rust
// borrow.rs - Borrow signature inference

pub(crate) struct BorrowSignatures<'a> {
    pub(crate) procs: MutMap<(Symbol, ProcLayout<'a>), BorrowSignature>,
}

pub(crate) fn infer_borrow_signatures<'a>(
    arena: &'a Bump,
    interner: &impl LayoutInterner<'a>,
    procs: &MutMap<(Symbol, ProcLayout<'a>), Proc<'a>>,
) -> BorrowSignatures<'a>
```

**Key concepts:**

1. **Ownership**: Parameters can be `Owned` (callee takes ownership) or `Borrowed` (callee only borrows)
2. **Default Inference**: Lists and strings default to `Borrowed`, other refcounted types to `Owned`
3. **Fixed-Point Analysis**: The algorithm iterates until signatures stabilize

```rust
fn layout_to_ownership<'a>(
    in_layout: InLayout<'a>,
    interner: &impl LayoutInterner<'a>,
) -> Ownership {
    match interner.get_repr(in_layout) {
        LayoutRepr::Builtin(Builtin::Str) => Ownership::Borrowed,
        LayoutRepr::Builtin(Builtin::List(_)) => Ownership::Borrowed,
        _ => Ownership::Owned,
    }
}
```

### Phase 2: Reference Counting Insertion (`inc_dec.rs`)

The main Perceus algorithm inserts `Inc`, `Dec`, `DecRef`, and `Free` operations into the IR.

```rust
// inc_dec.rs - Main entry point

pub fn insert_inc_dec_operations<'a>(
    arena: &'a Bump,
    layout_interner: &STLayoutInterner<'a>,
    procedures: &mut HashMap<(Symbol, ProcLayout<'a>), Proc<'a>, ...>,
) {
    // Step 1: Infer borrow signatures
    let borrow_signatures = crate::borrow::infer_borrow_signatures(...);

    // Step 2: Insert RC operations for each procedure
    for ((symbol, _layout), proc) in procedures.iter_mut() {
        insert_inc_dec_operations_proc(arena, symbol_rc_types_env, borrow_signatures, proc);
    }
}
```

#### RC Operations

```rust
// From ir.rs - The ModifyRc enum

pub enum ModifyRc {
    /// Increment reference count by N
    Inc(Symbol, u64),

    /// Decrement reference count (recursive - frees children)
    Dec(Symbol),

    /// Decrement without recursing into children
    DecRef(Symbol),

    /// Unconditional deallocation
    Free(Symbol),
}
```

#### Symbol Tracking

The algorithm tracks ownership state for each symbol:

```rust
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Ownership {
    Owned,      // We have ownership - can use without incrementing
    Borrowed,   // Already consumed - must increment before reuse
}
```

#### Statement Processing

The core algorithm processes statements recursively:

```rust
fn insert_refcount_operations_stmt<'v, 'a>(
    arena: &'a Bump,
    environment: &mut RefcountEnvironment<'v>,
    stmt: &Stmt<'a>,
) -> &'a Stmt<'a> {
    match &stmt {
        Stmt::Let(binding, expr, layout, continuation) => {
            // 1. Add binding to environment as Owned
            environment.add_symbol(*binding);

            // 2. Process continuation first (backward analysis)
            let new_stmt = insert_refcount_operations_stmt(arena, environment, continuation);

            // 3. If binding still owned after continuation, insert Dec
            if environment.get_symbol_ownership(binding) == Some(Ownership::Owned) {
                new_stmt = insert_dec_stmt(arena, *binding, new_stmt);
            }

            // 4. Process the expression
            insert_refcount_operations_binding(arena, environment, binding, expr, layout, new_stmt)
        }

        Stmt::Switch { branches, default_branch, ... } => {
            // Clone environment for each branch
            // Process branches independently
            // Reconcile ownership at merge points
        }

        Stmt::Ret(symbol) => {
            // Return value must be owned
            environment.consume_symbol(symbol);
            arena.alloc(Stmt::Ret(*symbol))
        }

        Stmt::Join { id, parameters, body, remainder } => {
            // Fixed-point analysis for join points
            // Handle recursive consumption
        }
        // ...
    }
}
```

#### Expression Processing

Different expressions have different RC requirements:

```rust
fn insert_refcount_operations_binding<'a>(
    arena: &'a Bump,
    environment: &mut RefcountEnvironment,
    binding: &Symbol,
    expr: &Expr<'a>,
    layout: &InLayout<'a>,
    stmt: &'a Stmt<'a>,
) -> &'a Stmt<'a> {
    match expr {
        // Literals don't need RC
        Expr::Literal(_) | Expr::NullPointer | Expr::EmptyArray => {
            new_let!(stmt)
        }

        // Constructors consume their arguments (need Inc if reused)
        Expr::Tag { arguments, .. } | Expr::Struct(arguments) => {
            inc_owned!(arguments.iter().copied(), new_let!(stmt))
        }

        // Field access borrows the structure
        Expr::StructAtIndex { structure, .. } | Expr::UnionAtIndex { structure, .. } => {
            // Borrow the structure (Dec if owned)
            let new_stmt = dec_borrowed!([*structure], stmt);
            // Inc the extracted field if refcounted
            if environment.get_symbol_rc_type(binding) == ReferenceCounted {
                insert_inc_stmt(arena, *binding, 1, new_stmt)
            }
            new_let!(new_stmt)
        }

        // Function calls use borrow signatures
        Expr::Call(Call { arguments, call_type }) => {
            match call_type {
                CallType::ByName { name, ... } => {
                    let borrow_signature = get_borrow_signature(name);
                    // Inc owned arguments, Dec borrowed ones
                }
                // ...
            }
        }
        // ...
    }
}
```

### Low-Level Borrow Signatures

Built-in operations have predefined borrow signatures:

```rust
pub(crate) fn lowlevel_borrow_signature(op: LowLevel) -> &'static [Ownership] {
    use LowLevel::*;

    const OWNED: Ownership = Ownership::Owned;
    const BORROWED: Ownership = Ownership::Borrowed;

    match op {
        // Read-only operations borrow
        ListLenU64 | StrIsEmpty | StrCountUtf8Bytes => &[BORROWED],

        // Destructive updates own
        ListReplaceUnsafe => &[OWNED, IRRELEVANT, IRRELEVANT],
        ListConcat => &[OWNED, OWNED],

        // String operations
        StrConcat => &[OWNED, BORROWED],  // First owned, second borrowed
        StrSplitOn => &[BORROWED, BORROWED],

        // Comparisons borrow
        Eq | NotEq => &[BORROWED, BORROWED],
        // ...
    }
}
```

## LLVM Code Generation (`refcounting.rs`)

The LLVM backend generates actual increment/decrement functions for each layout.

### PointerToRefcount

```rust
pub struct PointerToRefcount<'ctx> {
    value: PointerValue<'ctx>,
}

impl<'ctx> PointerToRefcount<'ctx> {
    // Create from data pointer (refcount is at index -1)
    pub fn from_ptr_to_data<'a, 'env>(
        env: &Env<'a, 'ctx, 'env>,
        data_ptr: PointerValue<'ctx>,
    ) -> Self {
        let refcount_ptr = unsafe {
            builder.new_build_in_bounds_gep(
                env.ptr_int(),
                ptr_as_usize_ptr,
                &[refcount_type.const_int(-1_i64 as u64, false)],
                "get_rc_ptr",
            )
        };
        Self { value: refcount_ptr }
    }

    // Check if refcount is 1 (unique)
    pub fn is_1<'a, 'env>(&self, env: &Env<'a, 'ctx, 'env>) -> IntValue<'ctx> {
        let current = self.get_refcount(env);
        let one = env.context.i64_type().const_int(1_u64, false);
        env.builder.new_build_int_compare(IntPredicate::EQ, current, one, "is_one")
    }
}
```

### Increment Generation

```rust
fn incref_pointer<'ctx>(
    env: &Env<'_, 'ctx, '_>,
    pointer: PointerValue<'ctx>,
    amount: IntValue<'ctx>,
    layout: LayoutRepr<'_>,
) {
    call_void_bitcode_fn(
        env,
        &[pointer.into(), amount.into()],
        roc_builtins::bitcode::UTILS_INCREF_RC_PTR,
    );
}
```

### Decrement Generation

For recursive types, decrement is more complex:

```rust
fn build_rec_union_help<'a, 'ctx>(
    env: &Env<'a, 'ctx, '_>,
    layout_interner: &STLayoutInterner<'a>,
    layout_ids: &mut LayoutIds<'a>,
    mode: Mode,
    union_layout: UnionLayout<'a>,
    fn_val: FunctionValue<'ctx>,
) {
    match mode {
        Mode::Inc => {
            // Inc is cheap - just bump the counter
            refcount_ptr.modify(call_mode, layout, env, layout_interner);
            env.builder.new_build_return(None);
        }

        Mode::Dec => {
            // Check if refcount is 1 (unique)
            builder.new_build_conditional_branch(
                refcount_ptr.is_1(env),
                do_recurse_block,    // Refcount=1: recurse and free
                no_recurse_block,    // Refcount>1: just decrement
            );

            // no_recurse_block: just decrement
            {
                refcount_ptr.modify(call_mode, layout, env, layout_interner);
                builder.new_build_return(None);
            }

            // do_recurse_block: decrement children, then free
            {
                // 1. Load all child pointers FIRST (before freeing parent)
                // 2. Free the parent cell
                // 3. Recursively decrement children (tail call optimized)
            }
        }
    }
}
```

### Tail Call Optimization

The decrement code uses tail calls for recursive types:

```rust
// OPTIMIZATION: Load fields before freeing, then tail-call decrement
for ptr in deferred_rec {
    let call = call_help(env, decrement_fn, mode.to_call_mode(decrement_fn), ptr);
    call.set_tail_call(true);  // Enable tail call optimization
}
```

## Runtime Support (`utils.zig`)

The Zig runtime provides atomic reference counting operations.

### Memory Layout

```
┌─────────────────┬─────────────────┬──────────────────────┐
│  Extra Bytes    │   Refcount      │      Data            │
│  (alignment)    │   (usize)       │                      │
└─────────────────┴─────────────────┴──────────────────────┘
                   ↑                 ↑
                   refcount_ptr      data_ptr (returned)
```

### Refcount Values

```zig
const REFCOUNT_MAX_ISIZE: isize = 0;  // Constant/static data (never freed)

// Normal refcount: starts at 1 when allocated
// Incremented/decremented atomically
```

### Allocation

```zig
pub fn allocateWithRefcount(
    data_bytes: usize,
    element_alignment: u32,
    elements_refcounted: bool,
) [*]u8 {
    const ptr_width = @sizeOf(usize);
    const alignment = @max(ptr_width, element_alignment);
    const extra_bytes = @max(required_space, element_alignment);
    const length = extra_bytes + data_bytes;

    const new_bytes: [*]u8 = alloc(length, alignment);
    const data_ptr = new_bytes + extra_bytes;

    // Initialize refcount to 1
    const refcount_ptr = @ptrCast([*]usize, data_ptr - ptr_width);
    refcount_ptr[0] = 1;

    return data_ptr;
}
```

### Increment

```zig
pub fn increfRcPtrC(ptr_to_refcount: *isize, amount: isize) callconv(.C) void {
    const refcount: isize = ptr_to_refcount.*;

    // Skip if constant (refcount == 0 means static/constant)
    if (!rcConstant(refcount)) {
        // Atomic increment
        _ = @atomicRmw(isize, ptr_to_refcount, .Add, amount, .monotonic);
    }
}
```

### Decrement

```zig
inline fn decref_ptr_to_refcount(
    refcount_ptr: [*]isize,
    element_alignment: u32,
    elements_refcounted: bool,
) void {
    const refcount: isize = refcount_ptr[0];

    if (!rcConstant(refcount)) {
        // Atomic decrement, get previous value
        const last = @atomicRmw(isize, &refcount_ptr[0], .Sub, 1, .monotonic);

        // If was 1, now 0 - free the memory
        if (last == 1) {
            free_ptr_to_refcount(refcount_ptr, alignment, elements_refcounted);
        }
    }
}
```

### Uniqueness Check

```zig
pub fn isUnique(bytes_or_null: ?[*]u8) callconv(.C) bool {
    const bytes = bytes_or_null orelse return true;

    // Clear any tag bits from pointer
    const tag_mask: usize = if (@sizeOf(usize) == 8) 0b111 else 0b11;
    const masked_ptr = @intFromPtr(bytes) & ~tag_mask;

    const isizes: [*]isize = @ptrFromInt(masked_ptr);
    const refcount = (isizes - 1)[0];

    return refcount == 1;
}
```

## Memory Reuse

Perceus enables memory reuse through the `Reset` operation:

```rust
// In ir.rs
Expr::Reset {
    symbol: Symbol,
    update_mode: UpdateModeId,
}
```

When a unique value is deconstructed:
1. Check if refcount is 1 (unique)
2. If unique: decrement children but keep allocation for reuse
3. If not unique: regular decrement

```rust
pub fn build_reset<'a, 'ctx>(
    env: &Env<'a, 'ctx, '_>,
    layout_interner: &STLayoutInterner<'a>,
    layout_ids: &mut LayoutIds<'a>,
    union_layout: UnionLayout<'a>,
) -> FunctionValue<'ctx> {
    // Similar to decrement, but:
    // - If unique: don't free parent, just clear children
    // - Returns the allocation for reuse
}
```

## Join Points and Recursion

Join points (used for tail recursion) require special handling:

```rust
Stmt::Join { id, parameters, body, remainder } => {
    // Fixed-point iteration to determine consumed symbols
    let mut joinpoint_consumption = MutSet::default();

    loop {
        let mut current_body_env = body_env.clone();
        current_body_env.add_joinpoint_consumption(*joinpoint_id, joinpoint_consumption.clone());

        let new_body = insert_refcount_operations_stmt(arena, &mut current_body_env, body);

        // Track which closure symbols were consumed
        let current_consumption = /* symbols that changed from Owned to Borrowed */;

        if joinpoint_consumption == current_consumption {
            break;  // Fixed point reached
        }
        joinpoint_consumption = current_consumption;
    }
}
```

## Data Flow Summary

```
                    ┌─────────────────────┐
                    │   Monomorphized IR  │
                    │   (from mono/ir.rs) │
                    └──────────┬──────────┘
                               │
                               ▼
                    ┌─────────────────────┐
                    │  Borrow Inference   │
                    │   (borrow.rs)       │
                    │                     │
                    │ - Infer signatures  │
                    │ - Fixed-point loop  │
                    └──────────┬──────────┘
                               │
                               ▼
                    ┌─────────────────────┐
                    │   RC Insertion      │
                    │   (inc_dec.rs)      │
                    │                     │
                    │ - Insert Inc/Dec    │
                    │ - Track ownership   │
                    │ - Handle joins      │
                    └──────────┬──────────┘
                               │
                               ▼
                    ┌─────────────────────┐
                    │  IR with RC Ops     │
                    │   (Stmt::Refcounting)│
                    └──────────┬──────────┘
                               │
                               ▼
                    ┌─────────────────────┐
                    │  LLVM Codegen       │
                    │  (refcounting.rs)   │
                    │                     │
                    │ - Generate inc/dec  │
                    │ - Tail call optim   │
                    │ - Layout-specific   │
                    └──────────┬──────────┘
                               │
                               ▼
                    ┌─────────────────────┐
                    │  Runtime Calls      │
                    │  (utils.zig)        │
                    │                     │
                    │ - Atomic ops        │
                    │ - Allocation        │
                    │ - Deallocation      │
                    └─────────────────────┘
```

## Files in This Directory

- `README.md` - This documentation
- `inc_dec.rs` - Extracted RC insertion code with annotations
- `borrow.rs` - Extracted borrow inference code
- `refcounting.rs` - Extracted LLVM codegen for RC operations
- `utils.zig` - Extracted runtime heap operations
