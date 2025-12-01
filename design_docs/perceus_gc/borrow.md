# Borrow Signature Inference - Pseudocode Summary

This document summarizes the data structures and algorithms from `borrow.rs`, which infers borrow signatures for function parameters in the Perceus reference counting system.

## Core Concept

**Borrow signature inference** determines which function parameters should be "borrowed" (read-only) vs "owned" (transfer ownership). Borrowed parameters don't need Inc/Dec operations at call sites, reducing reference counting overhead.

This pass runs before Inc/Dec insertion to inform which arguments need reference count modifications.

## Data Structures

### BorrowSignature - Compact Ownership Representation

```
struct BorrowSignature:
    # Compact bit representation (supports up to 56 parameters)
    # Bits 0-7:  length (number of parameters)
    # Bits 8+:   ownership flags (0 = Borrowed, 1 = Owned)
    data: u64

    function new(length):
        assert length < 56
        return BorrowSignature(length)

    function len() -> usize:
        return data & 0xFF

    function get(index) -> Option<Ownership>:
        if index >= len():
            return None
        mask = 1 << (index + 8)
        if (data & mask) == 0:
            return Borrowed
        else:
            return Owned

    function set(index, ownership) -> modified:
        assert index < len()
        mask = 1 << (index + 8)
        old_value = get(index)

        match ownership:
            Owned:   data |= mask    # Set bit
            Borrowed: data &= ~mask  # Clear bit

        return old_value != ownership

    function iter() -> Iterator<Ownership>:
        for i in 0..len():
            yield get(i)
```

### BorrowSignatures - Collection for All Procedures

```
struct BorrowSignatures:
    # Map from (function name, layout) to its borrow signature
    procs: Map<(Symbol, ProcLayout), BorrowSignature>
```

### State - Analysis State

```
struct State:
    # Function arguments eligible for borrow inference
    args: List<(Layout, Symbol)>

    # Current borrow signature being built
    borrow_signature: BorrowSignature

    # Stack of join points we're inside of
    join_point_stack: List<(JoinPointId, List<Param>)>

    # Join point signatures
    join_points: Map<JoinPointId, BorrowSignature>

    # Whether any modification was made (for fixed-point)
    modified: bool
```

## Main Algorithm: infer_borrow_signatures

```
function infer_borrow_signatures(arena, interner, procs) -> BorrowSignatures:
    # STEP 1: Initialize with default signatures
    # Lists/Strings default to Borrowed, others to Owned
    borrow_signatures = BorrowSignatures {
        procs: {}
    }

    for (key, proc) in procs:
        proc_key = (proc.name, proc.layout)
        signature = BorrowSignature.from_layouts(interner, proc.arg_layouts)
        borrow_signatures.procs[proc_key] = signature

    # Track join points for each procedure
    join_points = [empty_map() for _ in procs]

    # STEP 2: Compute strongly connected components (SCCs)
    # This allows processing in dependency order
    # Functions in same SCC may call each other (mutual recursion)
    call_matrix = construct_reference_matrix(arena, procs)
    sccs = call_matrix.strongly_connected_components_all()

    # STEP 3: Process each SCC with fixed-point iteration
    for group in sccs.groups():
        # Fixed-point: iterate until signatures stabilize
        loop:
            modified = false

            for index in group:
                proc = procs[index]
                key = (proc.name, proc.layout)

                if proc.args.is_empty():
                    continue

                state = State {
                    args: proc.args,
                    borrow_signature: borrow_signatures.procs[key],
                    join_point_stack: [],
                    join_points: join_points[index],
                    modified: false
                }

                # Analyze procedure body
                state.inspect_stmt(interner, borrow_signatures, proc.body)

                # Update signature
                modified |= state.modified
                borrow_signatures.procs[key] = state.borrow_signature
                join_points[index] = state.join_points

            # Fixed point reached - no changes this iteration
            if not modified:
                break

    return borrow_signatures
```

## Default Ownership by Layout

```
function layout_to_ownership(layout, interner) -> Ownership:
    match interner.get_repr(layout):
        # Lists and strings are commonly read-only
        # Default to borrowed to reduce RC overhead
        Builtin(Str):        return Borrowed
        Builtin(List(_)):    return Borrowed

        # Lambda sets: use runtime representation
        LambdaSet(inner):
            return layout_to_ownership(inner.runtime_representation(), interner)

        # Everything else defaults to owned
        _:                   return Owned
```

## Statement Analysis

```
function State.inspect_stmt(interner, borrow_signatures, stmt):
    match stmt:
        # Let binding: analyze expression and continuation
        Let(_, expr, _, continuation):
            self.inspect_expr(borrow_signatures, expr)
            self.inspect_stmt(interner, borrow_signatures, continuation)

        # Switch: analyze all branches
        Switch { branches, default_branch, ... }:
            for (_, _, branch_stmt) in branches:
                self.inspect_stmt(interner, borrow_signatures, branch_stmt)
            self.inspect_stmt(interner, borrow_signatures, default_branch.stmt)

        # Return: value must be owned (transferring to caller)
        Ret(symbol):
            self.mark_owned(symbol)

        # Join point definition
        Join { id, parameters, body, remainder }:
            # Initialize join point signature if first visit
            if id not in self.join_points:
                self.join_points[id] = BorrowSignature.from_layouts(
                    interner, parameters.map(|p| p.layout)
                )

            # Push onto stack and analyze body
            self.join_point_stack.push((id, parameters))
            self.inspect_stmt(interner, borrow_signatures, body)
            self.join_point_stack.pop()

            self.inspect_stmt(interner, borrow_signatures, remainder)

        # Jump to join point
        Jump(id, arguments):
            # Mark arguments as owned if join point requires it
            jp_signature = self.join_points[id]
            for (arg, ownership) in zip(arguments, jp_signature):
                if ownership == Owned:
                    self.mark_owned(arg)

        Crash(_, _):
            pass  # Not relevant for borrow analysis

        Expect { remainder, ... } | Dbg { remainder, ... }:
            # These borrow their arguments, just continue
            self.inspect_stmt(interner, borrow_signatures, remainder)
```

## Expression Analysis

```
function State.inspect_expr(borrow_signatures, expr):
    match expr:
        Call(call):
            self.inspect_call(borrow_signatures, call)

        # Other expressions don't affect borrow inference
        _:
            pass
```

## Call Analysis

```
function State.inspect_call(borrow_signatures, call):
    match call.call_type:
        # Direct call to known function
        ByName { name, arg_layouts, ret_layout, ... }:
            proc_layout = ProcLayout {
                arguments: arg_layouts,
                result: ret_layout
            }

            # Look up callee's borrow signature
            callee_signature = borrow_signatures.procs[(name, proc_layout)]

            # If callee needs ownership, mark our argument as owned too
            for (arg, ownership) in zip(call.arguments, callee_signature):
                if ownership == Owned:
                    self.mark_owned(arg)

        # Low-level built-in operation
        LowLevel { op, ... }:
            # Use predefined signatures for builtins
            builtin_signature = lowlevel_borrow_signature(op)
            for (arg, ownership) in zip(call.arguments, builtin_signature):
                if ownership.is_owned():
                    self.mark_owned(arg)

        # Unknown callees: conservatively assume all args owned
        ByPointer { ... } | Foreign { ... } | HigherOrder(_):
            for arg in call.arguments:
                self.mark_owned(arg)
```

## Marking Ownership

```
function State.mark_owned(symbol):
    # Check if it's a function argument
    for (index, (_, arg_symbol)) in enumerate(self.args):
        if arg_symbol == symbol:
            # Update signature and track modification
            self.modified |= self.borrow_signature.set(index, Owned)
            break

    # Also propagate to enclosing join points
    # If a value flows through a join point, the JP parameter must be owned
    for (jp_id, params) in self.join_point_stack:
        for (index, param) in enumerate(params):
            if param.symbol == symbol:
                self.join_points[jp_id].set(index, Owned)
```

## Call Graph Construction

```
function construct_reference_matrix(arena, procs) -> ReferenceMatrix:
    matrix = ReferenceMatrix.new(procs.len())
    call_info = CallInfo.new(arena)

    for (row, proc) in enumerate(procs.values()):
        call_info.clear()
        call_info.collect_calls_in_stmt(proc.body)

        # For each function we call, mark the edge
        for callee_name in call_info.keys:
            for (col, ((name, _), _)) in enumerate(procs):
                if name == callee_name:
                    matrix.set(row, col, true)

    return matrix

struct CallInfo:
    keys: List<Symbol>  # Functions called

    function collect_calls_in_stmt(stmt):
        stack = [stmt]

        while stack.not_empty():
            stmt = stack.pop()

            match stmt:
                Join { remainder, body, ... }:
                    stack.push(remainder)
                    stack.push(body)

                Let(_, expr, _, continuation):
                    if expr is Call(call):
                        match call.call_type:
                            ByName { name, ... }:
                                self.keys.push(name)
                            HigherOrder(hol):
                                self.keys.push(hol.passed_function.name)
                            _:
                                pass
                    stack.push(continuation)

                Switch { branches, default_branch, ... }:
                    for branch in branches:
                        stack.push(branch.stmt)
                    stack.push(default_branch.stmt)

                Dbg { remainder, ... } | Expect { remainder, ... }:
                    stack.push(remainder)

                Ret(_) | Jump(_, _) | Crash(_, _):
                    pass  # No continuation
```

## Algorithm Flow

```
1. Initialize all signatures with defaults:
   - Str, List → Borrowed
   - Everything else → Owned

2. Build call graph and compute SCCs:
   - Group mutually recursive functions
   - Process in topological order

3. For each SCC, fixed-point iterate:
   a. Analyze each function in group
   b. If callee requires owned argument, mark ours owned
   c. Propagate ownership through join points
   d. Repeat until no changes

4. Result: BorrowSignatures mapping each function to
   its parameter ownership requirements
```

## Example

```
# Source:
foo = \list, idx ->
    x = List.get list idx    # list borrowed
    y = List.first list      # list borrowed
    ret x

bar = \list ->
    z = List.append list 1   # list owned (mutated)
    ret z

# Initial signatures (from defaults):
foo: [Borrowed, Owned]   # List defaults to Borrowed, Int to Owned
bar: [Borrowed]          # List defaults to Borrowed

# After analysis:
# foo calls List.get and List.first, both borrow the list
# No change needed
foo: [Borrowed, Owned]

# bar calls List.append, which requires ownership
# Must mark parameter as Owned
bar: [Owned]             # Changed! List.append needs ownership

# At call sites:
main =
    myList = [1, 2, 3]
    a = foo myList 0      # No Inc needed, foo borrows
    b = bar myList        # Inc needed! bar takes ownership
    ret b
```

## Key Concepts

1. **Default Ownership**: Lists/Strings start as Borrowed, others as Owned
2. **Fixed-Point Iteration**: Handle mutual recursion by iterating until stable
3. **SCC Processing**: Process functions in dependency order
4. **Ownership Propagation**: If callee needs ownership, so do we
5. **Join Point Tracking**: Ownership flows through tail-recursive loops
6. **Conservative Fallback**: Unknown callees assume all args owned
