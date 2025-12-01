# Monomorphization/Specialization - Pseudocode Summary

This document summarizes the data structures and algorithms from `specialization.rs`, which transforms polymorphic functions into monomorphic procedures.

## Core Concept

**Monomorphization** converts generic code with type variables into specialized code with concrete types. Each unique instantiation of a polymorphic function becomes a separate monomorphic procedure.

## Data Structures

### Procs - Specialization State

```
struct Procs:
    # Unspecialized functions waiting for concrete types
    partial_procs: Map<Symbol, PartialProc>

    # Specializations discovered but not yet processed
    pending_specializations: PendingSpecializations

    # Completed specialized procedures
    specialized: Map<(Symbol, ProcLayout), Proc>

    # Lambda sets exposed to host runtime
    host_exposed_lambda_sets: HostExposedLambdaSets

    # Specializations needed from other modules
    externals_we_need: Map<ModuleId, ExternalSpecializations>

    # Maps polymorphic symbols to their monomorphic specializations
    symbol_specializations: Map<Symbol, List<Specialization>>

    # Stack of functions currently being specialized (prevents infinite recursion)
    specialization_stack: List<Symbol>

    # Thunks (zero-argument functions)
    module_thunks: List<Symbol>
    imported_module_thunks: List<Symbol>

    # Functions exposed to host
    host_exposed_symbols: List<Symbol>

    function symbol_needs_suspended_specialization(symbol) -> bool:
        # If symbol is on the stack, we need to defer specialization
        return symbol in specialization_stack
```

### PartialProc - Unspecialized Function

```
struct PartialProc:
    annotation: Variable              # Polymorphic type annotation
    pattern_symbols: List<Symbol>     # Parameter names
    captured_symbols: CapturedSymbols # Variables from enclosing scope
    body: CanonicalExpr               # Body (still in canonical form)
    body_var: Variable                # Type of body expression
    is_self_recursive: bool           # Calls itself?

enum CapturedSymbols:
    None
    Captured(List<(Symbol, Variable)>)
```

### ProcLayout - Specialized Function Signature

```
struct ProcLayout:
    arguments: List<Layout>   # Concrete argument layouts
    result: Layout            # Concrete return layout
    niche: Niche              # Optimization hint
```

## Main Algorithm: specialize_all

```
function specialize_all(env, procs, externals_others_need, host_specializations, layout_cache):
    # Step 1: Switch to "Making" mode - no new pending specializations during this phase
    pending = procs.pending_specializations
    procs.pending_specializations = Making(empty)

    # Step 2: Specialize all existing pending specializations
    match pending:
        Finding(suspended):
            specialize_suspended(env, procs, layout_cache, suspended)
        Making(suspended):
            assert suspended.is_empty()

    # Step 3: Specialize functions other modules need from us
    for externals in externals_others_need:
        specialize_external_specializations(env, procs, layout_cache, externals)

    # Step 4: Specialize host-exposed functions
    specialize_host_specializations(env, procs, layout_cache, host_specializations)

    # Step 5: Keep specializing until no new work discovered
    while not procs.pending_specializations.is_empty():
        pending = procs.pending_specializations
        procs.pending_specializations = Making(empty)

        match pending:
            Making(suspended):
                specialize_suspended(env, procs, layout_cache, suspended)
            Finding(_):
                error("should not happen after making")

    return procs
```

## Core Specialization: specialize_variable

```
function specialize_variable(env, procs, proc_name, layout_cache, fn_var, partial_proc_id):
    # 1. Snapshot typestate for potential rollback
    snapshot = snapshot_typestate(env.subs, procs, layout_cache)

    # 2. Get raw function layout from type variable
    raw = layout_cache.raw_from_var(env.arena, fn_var, env.subs)

    # 3. Handle module thunks specially
    if procs.is_module_thunk(proc_name.name()):
        match raw:
            Function(_, lambda_set, _):
                raw = ZeroArgumentThunk(lambda_set.full_layout)

    # 4. Make rigid type variables flexible (for unification)
    annotation_var = procs.partial_procs[partial_proc_id].annotation
    instantiate_rigids(env.subs, annotation_var)

    # 5. Track this specialization on stack (prevent infinite recursion)
    procs.push_active_specialization(proc_name.name())

    # 6. Actually build the specialized procedure
    specialized = specialize_proc_help(
        env, procs, proc_name, layout_cache, fn_var, partial_proc_id
    )

    # 7. Pop from stack
    procs.pop_active_specialization(proc_name.name())

    # 8. Process result
    result = match specialized:
        Ok(proc) -> Ok((proc, raw))
        Err(error) -> Err(SpecializeFailure { attempted_layout: raw })

    # 9. Rollback typestate changes
    rollback_typestate(env.subs, procs, layout_cache, snapshot)

    return result
```

## Building Specialized Proc: specialize_proc_help

```
function specialize_proc_help(env, procs, lambda_name, layout_cache, fn_var, partial_proc_id):
    partial_proc = procs.partial_procs[partial_proc_id]
    captured_symbols = partial_proc.captured_symbols

    # Step 1: Unify annotation with specific type
    unify(env, partial_proc.annotation, fn_var)

    # Step 2: If closure, add ARG_CLOSURE to parameters
    pattern_symbols = match partial_proc.captured_symbols:
        None | Captured([]):
            partial_proc.pattern_symbols
        Captured(_):
            partial_proc.pattern_symbols + [ARG_CLOSURE]

    # Step 3: Build specialized argument list with layouts
    specialized = build_specialized_proc_from_var(
        env, layout_cache, lambda_name, pattern_symbols, fn_var
    )

    # Step 4: Determine recursivity
    recursivity = if partial_proc.is_self_recursive:
        SelfRecursive(JoinPointId(unique_symbol()))
    else:
        NotSelfRecursive

    # Step 5: Convert body from canonical to monomorphic IR
    body = partial_proc.body.clone()
    body_var = partial_proc.body_var
    specialized_body = from_can(env, body_var, body, procs, layout_cache)

    # Step 6: Unpack closure captures (if any)
    match (specialized.closure, captured_symbols):
        (Some(LambdaSet(closure_layout)), Captured(captured)):
            closure_rep = closure_layout.layout_for_member(lambda_name)
            match closure_rep:
                # Multiple closure variants - extract from union
                Union { field_layouts, union_layout, tag_id }:
                    for (index, (symbol, _)) in enumerate(captured):
                        expr = UnionAtIndex {
                            tag_id: tag_id,
                            structure: ARG_CLOSURE,
                            index: index,
                            union_layout: union_layout
                        }
                        layout = union_layout.layout_at(tag_id, index)
                        specialized_body = Let(symbol, expr, layout, specialized_body)

                # Single closure type - extract from struct
                AlphabeticOrderStruct(field_layouts):
                    for (index, (symbol, layout)) in enumerate(captured):
                        expr = StructAtIndex {
                            index: index,
                            field_layouts: field_layouts,
                            structure: ARG_CLOSURE
                        }
                        specialized_body = Let(symbol, expr, layout, specialized_body)

                # Single capture - no wrapping
                UnwrappedCapture(layout):
                    (captured_symbol, _) = captured[0]
                    substitute_in_exprs(specialized_body, captured_symbol, ARG_CLOSURE)

        _:
            pass  # No closure unpacking needed

    return Proc {
        name: lambda_name,
        args: specialized.arguments,
        body: specialized_body,
        closure_data_layout: specialized.closure?.full_layout(),
        ret_layout: specialized.ret_layout,
        is_self_recursive: recursivity,
        is_erased: specialized.is_erased
    }
```

## Handling Recursive Specialization

```
# Problem: Mutually recursive functions can cause infinite specialization loops
#
# Example:
#   foo = \val, b -> if b then "done" else bar val
#   bar = \_ -> foo {} True
#   foo "" False
#
# When specializing foo : Str -> Str:
#   - We need bar : Str -> Str
#   - Which needs foo : {} -> Str
#   - But we're already specializing foo!
#
# Solution: Track functions on the stack and defer when needed

function specialize_suspended(env, procs, layout_cache, suspended):
    for (symbol, fn_var, partial_proc_id) in suspended:
        if procs.symbol_needs_suspended_specialization(symbol):
            # Defer this specialization - it depends on itself
            procs.pending_specializations.add(symbol, fn_var, partial_proc_id)
        else:
            # Safe to specialize now
            result = specialize_variable(env, procs, symbol, layout_cache, fn_var, partial_proc_id)
            match result:
                Ok((proc, raw)):
                    proc_layout = ProcLayout.from_raw_named(symbol, raw)
                    procs.specialized[(symbol, proc_layout)] = proc
                Err(failure):
                    # Handle specialization failure
                    pass
```

## Demand-Driven Specialization Flow

```
# Specialization is demand-driven: functions only specialized when called with specific types

1. Host-exposed functions are seeds
   └── specialize_host_specializations()

2. Specializing a function may discover new needs
   └── Call to polymorphic function → queue specialization
       └── call_by_name(env, procs, var, symbol, args, layout_cache, ...)
           └── procs.pending_specializations.add(symbol, fn_var, ...)

3. Loop until fixed point
   └── while pending_specializations not empty:
           specialize all pending
           (new specializations may be discovered)

4. External modules may need our functions
   └── externals_we_need tracks cross-module dependencies
```

## Closure Transformation Example

```
# Input (Roc):
makeAdder = \n ->
    \x -> x + n

add5 = makeAdder 5
result = add5 10

# After Monomorphization:

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

## Specialization Example

```
# Polymorphic function:
identity : a -> a
identity = \x -> x

# Usage:
main =
    identity 5        # Triggers identity : Int -> Int
    identity "hello"  # Triggers identity : Str -> Str

# Specialization order:
1. Start with main (host-exposed)
2. Discover need for identity : Int -> Int
3. Specialize identity for Int → generates identity_I64
4. Discover need for identity : Str -> Str
5. Specialize identity for Str → generates identity_Str
6. No more pending → done

# Generated procedures:
proc identity_I64(x: I64) -> I64:
    ret x

proc identity_Str(x: Str) -> Str:
    ret x
```

## Key Concepts

1. **Demand-Driven**: Only specialize what's actually called
2. **Fixed-Point**: Keep specializing until no new work discovered
3. **Recursion Handling**: Stack tracks active specializations to prevent loops
4. **Closure Conversion**: Closures become functions with capture argument
5. **Typestate Snapshot/Rollback**: For backtracking on failure
6. **Cross-Module**: Track what other modules need from us
