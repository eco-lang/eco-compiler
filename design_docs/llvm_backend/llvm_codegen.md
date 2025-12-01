# LLVM Code Generation - Pseudocode Summary

This document summarizes the data structures and algorithms from `llvm_codegen.rs`, which translates monomorphized IR to LLVM IR.

## Data Structures

### Env - Code Generation Environment

```
struct Env:
    arena: ArenaAllocator           # Temporary allocations
    context: LLVMContext            # Owns all LLVM objects
    builder: LLVMBuilder            # Creates instructions
    module: LLVMModule              # Module being built
    target: Target                  # Target architecture (32/64-bit)
    interns: SymbolTable            # Symbol interning
    exposed_to_host: Set<Symbol>    # Functions for host FFI

    function ptr_int():
        if target.ptr_width == 4 bytes:
            return i32_type
        else:
            return i64_type
```

### Scope - Symbol Table During Compilation

```
struct Scope:
    symbols: Map<Symbol, (Layout, LLVMValue)>  # Variable bindings
    top_level_thunks: Map<Symbol, (ProcLayout, FunctionValue)>
    join_points: Map<JoinPointId, (BasicBlock, List<JoinPointArg>)>

    function insert(symbol, layout, value):
        symbols[symbol] = (layout, value)

    function load_symbol(symbol):
        return symbols[symbol].value

    function insert_join_point(id, block, args):
        join_points[id] = (block, args)
```

### JoinPointArg - Tail Recursion Parameter Passing

```
enum JoinPointArg:
    Alloca(PointerValue)    # Large values: pass by reference (stack slot)
    Phi(PhiValue)           # Small values: pass via phi node
```

## Main Algorithm: build_procedures

```
function build_procedures(env, layout_interner, procedures, entry_point):
    # 1. Run alias analysis for specialization info
    mod_solutions = alias_analysis.spec_program(procedures)

    # 2. Generate function signatures (headers only)
    for (symbol, proc_layout), proc in procedures:
        build_proc_header(env, symbol, proc_layout)

    # 3. Compile each procedure body
    for (symbol, proc_layout), proc in procedures:
        build_proc(env, mod_solutions, symbol, proc_layout, proc)

    # 4. Generate host-exposed function wrappers
    for (symbol, top_level) in glue_layouts.getters:
        expose_function_to_host(env, symbol, top_level)
```

## Statement Compilation: build_exp_stmt

```
function build_exp_stmt(env, scope, parent_function, stmt):
    match stmt:

        # Let binding: evaluate expression, bind, continue
        case Let(symbol, expr, layout, continuation):
            value = build_exp_expr(env, scope, parent_function, layout, expr)
            scope.insert(symbol, layout, value)
            result = build_exp_stmt(env, scope, parent_function, continuation)
            scope.remove(symbol)
            return result

        # Return: load value and return
        case Ret(symbol):
            (value, layout) = scope.load_symbol_and_layout(symbol)
            build_return(env, layout, value, parent_function)
            return dummy_value  # Unreachable after return

        # Switch: compile pattern match to LLVM switch + phi
        case Switch(cond_symbol, branches, default_branch, ret_layout):
            cond_val = scope.load_symbol(cond_symbol)
            ret_type = layout_to_llvm_type(ret_layout)

            # Create basic blocks
            branch_blocks = []
            for (tag_id, _, _) in branches:
                block = append_basic_block(parent_function, "branch")
                branch_blocks.append((tag_id, block))
            default_block = append_basic_block(parent_function, "default")
            merge_block = append_basic_block(parent_function, "merge")

            # Build switch instruction
            build_switch(cond_val, default_block, branch_blocks)

            # Compile each branch
            incoming_values = []
            for (branch_stmt, block) in zip(branches, branch_blocks):
                position_at_end(block)
                result = build_exp_stmt(env, scope, parent_function, branch_stmt)
                incoming_values.append((result, block))
                build_branch(merge_block)

            # Compile default branch
            position_at_end(default_block)
            default_result = build_exp_stmt(env, scope, parent_function, default_branch)
            incoming_values.append((default_result, default_block))
            build_branch(merge_block)

            # Merge results with phi node
            position_at_end(merge_block)
            phi = build_phi(ret_type, "switch_result")
            for (val, block) in incoming_values:
                phi.add_incoming(val, block)
            return phi

        # Join point: create labeled block for tail recursion
        case Join(id, parameters, body, remainder):
            join_block = append_basic_block(parent_function, "joinpoint")

            # Create phi nodes or allocas for parameters
            join_args = []
            position_at_end(join_block)
            for param in parameters:
                param_type = layout_to_llvm_type(param.layout)
                if is_passed_by_reference(param.layout):
                    alloca = create_entry_block_alloca(param_type)
                    join_args.append(Alloca(alloca))
                else:
                    phi = build_phi(param_type, "join_arg")
                    join_args.append(Phi(phi))

            scope.insert_join_point(id, join_block, join_args)

            # Compile remainder first (may jump to join point)
            remainder_result = build_exp_stmt(env, scope, parent_function, remainder)

            # Now compile join point body
            position_at_end(join_block)
            for (param, arg) in zip(parameters, join_args):
                value = match arg:
                    Phi(phi) -> phi.as_value()
                    Alloca(ptr) -> build_load(ptr)
                scope.insert(param.symbol, param.layout, value)
            return build_exp_stmt(env, scope, parent_function, body)

        # Jump: tail call to join point
        case Jump(join_point_id, arguments):
            (target_block, join_args) = scope.get_join_point(join_point_id)
            current_block = get_current_block()

            # Pass arguments to join point
            for (symbol, arg) in zip(arguments, join_args):
                value = scope.load_symbol(symbol)
                match arg:
                    Phi(phi):
                        phi.add_incoming(value, current_block)
                    Alloca(ptr):
                        build_store(ptr, value)

            # Branch to join point (this IS the tail call!)
            build_branch(target_block)
            return dummy_value

        # Reference counting operations
        case Refcounting(modify_rc, continuation):
            match modify_rc:
                Inc(symbol, amount):
                    value = scope.load_symbol(symbol)
                    increment_refcount(value, amount)
                Dec(symbol):
                    (value, layout) = scope.load_symbol_and_layout(symbol)
                    decrement_refcount(value, layout)
                DecRef(symbol):
                    value = scope.load_symbol(symbol)
                    call_decref_nonrecursive(value)
                Free(symbol):
                    value = scope.load_symbol(symbol)
                    deallocate(value)
            return build_exp_stmt(env, scope, parent_function, continuation)

        # Crash/panic
        case Crash(symbol, crash_tag):
            msg = scope.load_symbol(symbol)
            call_roc_panic(msg, crash_tag)
            return dummy_value
```

## Expression Compilation: build_exp_expr

```
function build_exp_expr(env, scope, parent_function, layout, expr):
    match expr:

        # Literals
        case Literal(lit):
            return build_literal(env, layout, lit)

        case NullPointer:
            return const_null(layout_to_llvm_type(layout))

        # Function calls
        case Call(call):
            return build_exp_call(env, scope, parent_function, layout, call)

        # Struct construction
        case Struct(fields):
            field_values = [scope.load_symbol(sym) for sym in fields]
            return build_struct(field_values)

        # Tag union construction
        case Tag(tag_layout, tag_id, arguments, reuse):
            reuse_ptr = reuse?.symbol |> scope.load_symbol
            return build_tag(env, scope, tag_layout, tag_id, arguments, reuse_ptr)

        # Field access
        case StructAtIndex(index, field_layouts, structure):
            struct_val = scope.load_symbol(structure)
            struct_type = struct_type_from_layouts(field_layouts)
            field_ptr = build_struct_gep(struct_type, struct_val, index)
            return build_load(field_ptr)

        # Tag ID extraction
        case GetTagId(structure, union_layout):
            union_val = scope.load_symbol(structure)
            return extract_tag_id(union_layout, union_val)

        # Union field access
        case UnionAtIndex(structure, tag_id, union_layout, index):
            union_val = scope.load_symbol(structure)
            return extract_union_field(union_layout, tag_id, index, union_val)

        # Array construction
        case Array(elem_layout, elems):
            list_ptr = allocate_list(elem_layout, len(elems))
            for (i, elem) in enumerate(elems):
                val = match elem:
                    Literal(lit) -> build_literal(elem_layout, lit)
                    Symbol(sym) -> scope.load_symbol(sym)
                store_list_element(list_ptr, i, val)
            return list_ptr

        case EmptyArray:
            return empty_polymorphic_list()

        # Memory reuse check (Perceus optimization)
        case Reset(symbol, update_mode):
            (ptr, layout) = scope.load_symbol_and_layout(symbol)
            rc_ptr = get_refcount_ptr(ptr)
            is_unique = rc_ptr.is_one()
            return build_reset_check(ptr, layout, is_unique)
```

## Call Compilation: build_exp_call

```
function build_exp_call(env, scope, parent_function, ret_layout, call):
    match call.call_type:

        # Direct call to known function
        case ByName(name, specialization_id):
            args = [scope.load_symbol(s) for s in call.arguments]
            func_spec = get_specialization(specialization_id)
            fn_val = get_specialized_function(name, func_spec)
            call_result = build_call(fn_val, args)
            call_result.set_calling_convention(FAST_CALL_CONV)
            return call_result

        # Indirect call through function pointer
        case ByPointer(pointer, arg_layouts, ret_layout):
            fn_ptr = scope.load_symbol(pointer)
            args = [scope.load_symbol(s) for s in call.arguments]
            fn_type = build_function_type(arg_layouts, ret_layout)
            return build_indirect_call(fn_type, fn_ptr, args)

        # Built-in operation (compiled inline)
        case LowLevel(op, update_mode):
            return run_low_level(env, scope, ret_layout, op, call.arguments, update_mode)

        # Foreign function call (C ABI)
        case Foreign(foreign_symbol, ret_layout):
            args = [scope.load_symbol(s) for s in call.arguments]
            return build_foreign_call(foreign_symbol, args, ret_layout)

        # Higher-order builtins (List.map, etc.)
        case HigherOrder(ho):
            return run_higher_order_low_level(env, scope, parent_function, ho)
```

## Layout to LLVM Type Conversion

```
function layout_to_llvm_type(env, layout):
    match layout:
        Builtin(Int(width)):
            return width_to_int_type(width)  # i8, i16, i32, i64, i128

        Builtin(Float(width)):
            return width_to_float_type(width)  # f32, f64

        Builtin(Bool):
            return i1_type

        Builtin(Str):
            return struct_type { ptr, i64, i64 }  # ptr, len, capacity

        Builtin(List(_)):
            return struct_type { ptr, i64, i64 }  # ptr, len, capacity

        Struct(fields):
            field_types = [layout_to_llvm_type(f) for f in fields]
            return struct_type(field_types)

        Union(union_layout):
            return struct_type_from_union_layout(union_layout)

        Ptr(_) | RecursivePointer(_) | FunctionPointer(_):
            return ptr_type

        LambdaSet(lambda_set):
            return layout_to_llvm_type(lambda_set.full_layout)

        Erased(_):
            return erased_type()  # { ptr, ptr } - value and callee
```

## Helper Functions

```
function create_entry_block_alloca(ty, name):
    # Create alloca in function entry block for stack allocation
    entry = get_entry_block()
    temp_builder = create_builder()
    temp_builder.position_at_start(entry)
    return temp_builder.build_alloca(ty, name)

function build_return(env, layout, value, parent_function):
    if returns_by_pointer(layout):
        # Large value: store through return pointer (first param)
        return_ptr = parent_function.get_first_param()
        build_store(return_ptr, value)
        build_return_void()
    else:
        # Small value: return in register
        build_return(value)

# Calling conventions
FAST_CALL_CONV = 8   # LLVM fast calling convention (enables tail calls)
C_CALL_CONV = 0      # C calling convention (for FFI)
```

## Key Concepts

1. **Statement Tree**: IR uses a tree structure where each statement contains its continuation
2. **Join Points**: Enable efficient tail recursion via phi nodes and branches
3. **Scope Management**: Variables are bound/unbound as we traverse the tree
4. **Large Value Returns**: Values > register size returned via pointer parameter
5. **Reference Counting**: Inc/Dec operations generated inline for each statement
