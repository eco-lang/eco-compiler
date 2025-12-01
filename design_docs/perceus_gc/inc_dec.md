# Perceus Inc/Dec Insertion - Pseudocode Summary

This document summarizes the data structures and algorithms from `inc_dec.rs`, which inserts reference counting operations (Inc/Dec) into the monomorphic IR.

## Core Concept

**Perceus** is a reference counting algorithm that automatically inserts increment and decrement operations to manage memory. The key insight is tracking **ownership** - whether a value is "owned" (can be consumed without incrementing) or "borrowed" (must be incremented before reuse).

Based on:
- Perceus: Garbage Free Reference Counting with Reuse (Microsoft Research, 2021)
- Master's thesis by Jelle Teeuwissen: Reference Counting with Reuse in Roc

## Data Structures

### Ownership - Value State

```
enum Ownership:
    Owned      # We own this value - can use without incrementing
    Borrowed   # Already consumed - must increment before reuse
```

### VarRcType - Reference Counting Classification

```
enum VarRcType:
    ReferenceCounted     # Heap-allocated, needs RC tracking
    NotReferenceCounted  # Stack value (Int, Bool, etc.), no RC needed
```

### SymbolRcTypes - Type Classification Tracking

```
struct SymbolRcTypes:
    reference_counted: Set<Symbol>      # Symbols that need RC
    not_reference_counted: Set<Symbol>  # Symbols that don't need RC

    function insert(symbol, rc_type):
        match rc_type:
            ReferenceCounted: reference_counted.add(symbol)
            NotReferenceCounted: not_reference_counted.add(symbol)

    function get(symbol) -> Option<VarRcType>:
        if symbol in reference_counted: return ReferenceCounted
        if symbol in not_reference_counted: return NotReferenceCounted
        return None
```

### RefcountEnvironment - Analysis State

```
struct RefcountEnvironment:
    # Which symbols are reference counted
    symbols_rc_types: SymbolRcTypes

    # Current ownership state of each symbol
    # Key insight: everything not owned is borrowed
    symbols_ownership: Map<Symbol, Ownership>

    # Join point consumption tracking (for recursive tail calls)
    jointpoint_closures: Map<JoinPointId, Set<Symbol>>

    # Inferred borrow signatures of all functions
    borrow_signatures: BorrowSignatures

    # Consume a symbol (transfer ownership)
    # Returns previous state, sets to Borrowed
    function consume_symbol(symbol) -> Option<Ownership>:
        if symbol not in symbols_ownership:
            return None
        old_ownership = symbols_ownership[symbol]
        symbols_ownership[symbol] = Borrowed
        return old_ownership

    # Add new symbol (initially Owned)
    function add_symbol(symbol):
        if get_symbol_rc_type(symbol) == ReferenceCounted:
            symbols_ownership[symbol] = Owned

    # Add symbol with specific ownership
    function add_symbol_with(symbol, ownership):
        if get_symbol_rc_type(symbol) == ReferenceCounted:
            symbols_ownership[symbol] = ownership
```

## Main Algorithm: insert_inc_dec_operations

```
function insert_inc_dec_operations(arena, layout_interner, procedures):
    # STEP 1: Infer borrow signatures for all procedures
    # Determines which parameters are "owned" vs "borrowed"
    borrow_signatures = infer_borrow_signatures(arena, layout_interner, procedures)

    # STEP 2: Insert RC operations for each procedure
    for (symbol, layout), proc in procedures:
        # Skip low-level wrappers (they get inlined)
        if not is_lowlevel_wrapper(symbol):
            symbol_rc_types = collect_rc_types_for_proc(proc)
            insert_inc_dec_operations_proc(arena, symbol_rc_types, borrow_signatures, proc)
```

## Procedure Processing: insert_inc_dec_operations_proc

```
function insert_inc_dec_operations_proc(arena, symbol_rc_types_env, borrow_signatures, proc):
    # Collect RC types for all symbols
    symbol_rc_types_env.insert_symbols_rc_type_proc(proc)

    # Create environment
    environment = RefcountEnvironment {
        symbols_rc_types: symbol_rc_types_env.symbols_rc_type,
        symbols_ownership: empty_map(),
        jointpoint_closures: empty_map(),
        borrow_signatures: borrow_signatures
    }

    # Add arguments with their inferred ownership
    borrow_signature = borrow_signatures.get_proc(proc.name, proc.layout)
    for (layout, symbol), ownership in zip(proc.args, borrow_signature):
        environment.add_symbol_with(symbol, ownership)

    # Process the body
    new_body = insert_refcount_operations_stmt(arena, environment, proc.body)

    # Insert Dec for unused parameters (still marked as Owned)
    unused_params = [s for (_, s) in proc.args
                     if s in environment.symbols_ownership
                     and environment.symbols_ownership[s] == Owned]
    proc.body = insert_dec_for_symbols(arena, environment, unused_params, new_body)
```

## Statement Processing (Core Algorithm)

```
function insert_refcount_operations_stmt(arena, environment, stmt):
    match stmt:

        # =====================================================================
        # LET BINDING
        # =====================================================================
        Let(binding, expr, layout, continuation):
            # Collect consecutive lets to avoid stack overflow
            triples = collect_consecutive_lets(stmt)

            # Add all bindings to environment (initially Owned)
            for (binding, _, _) in triples:
                environment.add_symbol(binding)

            # Process in REVERSE order (backward analysis)
            result = insert_refcount_operations_stmt(arena, environment, final_continuation)

            for (binding, expr, layout) in reversed(triples):
                # If binding still Owned (unused), insert Dec
                if environment.get_ownership(binding) == Owned:
                    result = insert_dec_stmt(arena, binding, result)

                # Remove from environment (out of scope)
                environment.remove_symbol(binding)

                # Process expression
                result = insert_refcount_operations_binding(
                    arena, environment, binding, expr, layout, result
                )

            return result

        # =====================================================================
        # SWITCH (Pattern Matching)
        # =====================================================================
        Switch(cond_symbol, cond_layout, branches, default_branch, ret_layout):
            # Process each branch with CLONED environment
            branch_results = []
            for (label, info, branch) in branches:
                branch_env = environment.clone()
                new_branch = insert_refcount_operations_stmt(arena, branch_env, branch)
                branch_results.append((label, info, new_branch, branch_env))

            default_env = environment.clone()
            new_default = insert_refcount_operations_stmt(arena, default_env, default_branch)

            # RECONCILIATION: Find symbols consumed in ANY branch
            # These must be consumed in ALL branches for consistency
            consumed_symbols = find_symbols_consumed_in_any_branch(branch_envs)

            # Insert Dec for symbols not consumed in specific branches
            # This ensures consistent behavior regardless of which branch taken
            for result in branch_results:
                for symbol in consumed_symbols:
                    if not consumed_in_this_branch(result.env, symbol):
                        result.stmt = insert_dec_stmt(arena, symbol, result.stmt)

            # Update current environment
            for symbol in consumed_symbols:
                environment.consume_symbol(symbol)

            return Switch(cond_symbol, cond_layout, new_branches, new_default, ret_layout)

        # =====================================================================
        # RETURN
        # =====================================================================
        Ret(symbol):
            # Return value must be Owned (we're transferring to caller)
            ownership = environment.consume_symbol(symbol)
            assert ownership == None or ownership == Owned
            return Ret(symbol)

        # =====================================================================
        # JOIN POINT (Tail Recursion)
        # =====================================================================
        Join(joinpoint_id, parameters, body, remainder):
            # Fixed-point iteration to determine consumed symbols
            # Needed because join points can be called recursively
            joinpoint_consumption = empty_set()

            loop:
                body_env = create_body_environment_with_params(parameters)
                body_env.add_joinpoint_consumption(joinpoint_id, joinpoint_consumption)

                new_body = insert_refcount_operations_stmt(arena, body_env, body)

                # Check which symbols were consumed
                current_consumption = {s for (s, o) in body_env.symbols_ownership
                                        if o == Borrowed}

                # Fixed point reached?
                if joinpoint_consumption == current_consumption:
                    break
                joinpoint_consumption = current_consumption

            # Process remainder with join point consumption info
            environment.add_joinpoint_consumption(joinpoint_id, joinpoint_consumption)
            new_remainder = insert_refcount_operations_stmt(arena, environment, remainder)
            environment.remove_joinpoint_consumption(joinpoint_id)

            return Join(joinpoint_id, parameters, new_body, new_remainder)

        # =====================================================================
        # JUMP (to join point)
        # =====================================================================
        Jump(joinpoint_id, arguments):
            # Consume symbols that the join point needs
            consumed = environment.get_joinpoint_consumption(joinpoint_id)
            for symbol in consumed:
                environment.consume_symbol(symbol)

            # Insert Inc for arguments that need to stay alive
            new_jump = Jump(joinpoint_id, arguments)
            return insert_inc_for_owned_usages(arena, environment, arguments, new_jump)

        # =====================================================================
        # CRASH
        # =====================================================================
        Crash(symbol, crash_tag):
            new_crash = Crash(symbol, crash_tag)
            return insert_inc_for_owned_usages(arena, environment, [symbol], new_crash)
```

## Expression Processing

```
function insert_refcount_operations_binding(arena, env, binding, expr, layout, stmt):

    match expr:

        # =====================================================================
        # LITERALS: No RC needed
        # =====================================================================
        Literal(_) | NullPointer | FunctionPointer | EmptyArray:
            return Let(binding, expr, layout, stmt)

        # =====================================================================
        # CONSTRUCTORS: Consume arguments (Inc if reused)
        # =====================================================================
        Tag { arguments, ... } | Struct(arguments):
            new_let = Let(binding, expr, layout, stmt)
            # Inc any owned arguments that are being used
            return insert_inc_for_owned_usages(arena, env, arguments, new_let)

        # =====================================================================
        # FIELD ACCESS: Borrow structure, Inc extracted field
        # =====================================================================
        StructAtIndex { structure, ... }
        | UnionAtIndex { structure, ... }
        | GetElementPointer { structure, ... }:
            # Structure is borrowed - Dec if currently Owned
            new_stmt = insert_dec_for_borrowed(arena, env, [structure], stmt)

            # Extracted field needs Inc if it's refcounted
            if env.get_symbol_rc_type(binding) == ReferenceCounted:
                new_stmt = insert_inc_stmt(arena, binding, 1, new_stmt)

            return Let(binding, expr, layout, new_stmt)

        GetTagId { structure, ... }:
            # Tag ID is not reference counted, just borrow structure
            new_stmt = insert_dec_for_borrowed(arena, env, [structure], stmt)
            return Let(binding, expr, layout, new_stmt)

        # =====================================================================
        # ARRAY CREATION: Inc all elements
        # =====================================================================
        Array { elems, ... }:
            new_let = Let(binding, expr, layout, stmt)
            symbols = [s for elem in elems if elem is Symbol(s)]
            return insert_inc_for_owned_usages(arena, env, symbols, new_let)

        # =====================================================================
        # FUNCTION CALLS: Use borrow signatures
        # =====================================================================
        Call { arguments, call_type: ByName { name, arg_layouts, ret_layout } }:
            # Look up the borrow signature
            borrow_signature = env.borrow_signatures.get_proc(name, arg_layouts, ret_layout)

            # Separate owned vs borrowed arguments
            owned_args = [arg for (arg, sig) in zip(arguments, borrow_signature)
                          if sig == Owned]
            borrowed_args = [arg for (arg, sig) in zip(arguments, borrow_signature)
                             if sig == Borrowed]

            # Dec borrowed arguments if currently Owned
            new_stmt = insert_dec_for_borrowed(arena, env, borrowed_args, stmt)
            new_let = Let(binding, expr, layout, new_stmt)
            # Inc owned arguments
            return insert_inc_for_owned_usages(arena, env, owned_args, new_let)

        Call { arguments, call_type: ByPointer { ... } }:
            # Unknown function - assume all args owned
            new_let = Let(binding, expr, layout, stmt)
            return insert_inc_for_owned_usages(arena, env, arguments, new_let)

        Call { arguments, call_type: Foreign { ... } }:
            # Foreign functions - assume borrowed (Dec any owned)
            new_stmt = insert_dec_for_borrowed(arena, env, arguments, stmt)
            return Let(binding, expr, layout, new_stmt)

        Call { arguments, call_type: LowLevel { op } }:
            # Use predefined borrow signatures for builtins
            borrow_signature = lowlevel_borrow_signature(op)
            # ... apply signature like ByName ...
```

## Helper Functions

```
function insert_inc_stmt(arena, symbol, count, continuation):
    if count == 0:
        return continuation
    return Refcounting(Inc(symbol, count), continuation)

function insert_dec_stmt(arena, symbol, continuation):
    return Refcounting(Dec(symbol), continuation)

function insert_inc_for_owned_usages(arena, env, symbols, stmt):
    result = stmt
    for symbol in symbols:
        ownership = env.consume_symbol(symbol)
        if ownership == Owned:
            result = insert_inc_stmt(arena, symbol, 1, result)
    return result

function insert_dec_for_borrowed(arena, env, symbols, stmt):
    result = stmt
    for symbol in symbols:
        ownership = env.consume_symbol(symbol)
        if ownership == Owned:
            result = insert_dec_stmt(arena, symbol, result)
    return result
```

## Low-Level Borrow Signatures

```
const OWNED = Ownership::Owned
const BORROWED = Ownership::Borrowed
const IRRELEVANT = Ownership::Owned  # Non-RC types don't matter

function lowlevel_borrow_signature(op):
    match op:
        # Read-only operations: borrow
        ListLenU64 | ListLenUsize | StrIsEmpty | StrCountUtf8Bytes:
            return [BORROWED]

        # Capacity allocation: no RC args
        ListWithCapacity | StrWithCapacity:
            return [IRRELEVANT]

        # Destructive update: own the container
        ListReplaceUnsafe:
            return [OWNED, IRRELEVANT, IRRELEVANT]

        # Index access: borrow container
        ListGetUnsafe | StrGetUnsafe:
            return [BORROWED, IRRELEVANT]

        # Concatenation
        ListConcat:
            return [OWNED, OWNED]
        StrConcat:
            return [OWNED, BORROWED]  # Left modified, right read-only

        # Comparisons: borrow both
        Eq | NotEq:
            return [BORROWED, BORROWED]

        # Numeric ops: not reference counted
        NumAdd | NumSub | NumMul | NumDiv | NumCompare:
            return [IRRELEVANT, IRRELEVANT]

        # Default: own everything
        _:
            return [OWNED]
```

## Perceus Algorithm Example

```
# Input:
let list = [1, 2, 3]
let x = List.get list 0      # Borrow list
let y = List.first list      # Borrow list
let z = List.append list 4   # Own list (modifies)
ret z

# After RC insertion:
let list = [1, 2, 3]           # list: Owned
let x = List.get list 0        # list borrowed, still Owned
let y = List.first list        # list borrowed, still Owned
Inc(list)                      # Need copy for append since borrowed later... wait
let z = List.append list 4     # list consumed, now Borrowed
# Dec(list) not needed - consumed by append
ret z                          # z transferred to caller

# Simpler example:
let a = "hello"                # a: Owned
let b = a                      # Direct use
let c = a                      # Second use of a
ret c

# After RC insertion:
let a = "hello"                # a: Owned
Inc(a)                         # a used twice, need extra ref
let b = a                      # Consumes one ref
let c = a                      # Consumes one ref
Dec(b)                         # b unused
ret c
```

## Key Concepts

1. **Backward Analysis**: Process statements in reverse to know future uses
2. **Ownership Tracking**: Values are either Owned or Borrowed
3. **Consume on Use**: Using a value transfers ownership (Owned → Borrowed)
4. **Inc Before Reuse**: If value already Borrowed, Inc to get new ownership
5. **Dec Unused**: If value still Owned at end of scope, Dec to release
6. **Branch Reconciliation**: All branches must consume same symbols
7. **Join Point Fixed-Point**: Iteratively determine consumed symbols for recursion
8. **Borrow Signatures**: Functions declare which args they own vs borrow
