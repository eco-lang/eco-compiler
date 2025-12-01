// =============================================================================
// EXTRACTED LLVM CODE GENERATION FROM: crates/compiler/gen_llvm/src/llvm/build.rs
// =============================================================================
// This file shows how mono IR is translated to LLVM IR.
// Contains excerpts and summaries for documentation purposes.

use inkwell::builder::Builder;
use inkwell::context::Context;
use inkwell::module::Module;
use inkwell::values::{BasicValueEnum, FunctionValue, IntValue, PointerValue};
use inkwell::basic_block::BasicBlock;

// -----------------------------------------------------------------------------
// Env: Code Generation Environment (build.rs:733)
// -----------------------------------------------------------------------------
// Global state during LLVM code generation.

pub struct Env<'a, 'ctx, 'env> {
    /// Arena allocator for temporary allocations
    pub arena: &'a Bump,

    /// LLVM context (owns all LLVM objects)
    pub context: &'ctx Context,

    /// LLVM IR builder (creates instructions)
    pub builder: &'env Builder<'ctx>,

    /// Debug info builder
    pub dibuilder: &'env DebugInfoBuilder<'ctx>,

    /// Debug compile unit
    pub compile_unit: &'env DICompileUnit<'ctx>,

    /// LLVM module being built
    pub module: &'ctx Module<'ctx>,

    /// Symbol interning tables
    pub interns: Interns,

    /// Target architecture
    pub target: Target,

    /// Build mode (binary, test, etc.)
    pub mode: LlvmBackendMode,

    /// Functions exposed to host
    pub exposed_to_host: MutSet<Symbol>,
}

impl<'a, 'ctx, 'env> Env<'a, 'ctx, 'env> {
    /// Get the integer type representing a pointer
    pub fn ptr_int(&self) -> IntType<'ctx> {
        match self.target.ptr_width() {
            PtrWidth::Bytes4 => self.context.i32_type(),
            PtrWidth::Bytes8 => self.context.i64_type(),
        }
    }

    /// Call an LLVM intrinsic function
    pub fn call_intrinsic(
        &self,
        intrinsic_name: &'static str,
        args: &[BasicValueEnum<'ctx>],
    ) -> BasicValueEnum<'ctx> {
        let fn_val = self.module.get_function(intrinsic_name).unwrap();
        let call = self.builder.new_build_call(fn_val, args, "call");
        call.try_as_basic_value().left().unwrap()
    }
}

// -----------------------------------------------------------------------------
// Scope: Symbol to LLVM Value Mapping (scope.rs:13)
// -----------------------------------------------------------------------------
// Tracks bindings during code generation.

pub struct Scope<'a, 'ctx> {
    /// Symbol -> (Layout, LLVM Value) mapping
    symbols: ImMap<Symbol, (InLayout<'a>, BasicValueEnum<'ctx>)>,

    /// Top-level thunks for lazy values
    top_level_thunks: ImMap<Symbol, (ProcLayout<'a>, FunctionValue<'ctx>)>,

    /// Join points for tail recursion
    join_points: ImMap<JoinPointId, (BasicBlock<'ctx>, Vec<JoinPointArg<'ctx>>)>,
}

impl<'a, 'ctx> Scope<'a, 'ctx> {
    /// Insert a binding
    pub fn insert(&mut self, symbol: Symbol, layout: InLayout<'a>, value: BasicValueEnum<'ctx>) {
        self.symbols.insert(symbol, (layout, value));
    }

    /// Load a symbol's value
    pub fn load_symbol(&self, symbol: &Symbol) -> BasicValueEnum<'ctx> {
        self.symbols.get(symbol).map(|(_, v)| *v).unwrap()
    }

    /// Load symbol with its layout
    pub fn load_symbol_and_layout(&self, symbol: &Symbol) -> (BasicValueEnum<'ctx>, InLayout<'a>) {
        self.symbols.get(symbol).map(|(l, v)| (*v, *l)).unwrap()
    }

    /// Register a join point for tail recursion
    pub fn insert_join_point(
        &mut self,
        id: JoinPointId,
        block: BasicBlock<'ctx>,
        args: Vec<JoinPointArg<'ctx>>,
    ) {
        self.join_points.insert(id, (block, args));
    }
}

// Join point arguments can be phi nodes or stack allocations
pub enum JoinPointArg<'ctx> {
    Alloca(PointerValue<'ctx>),  // Passed by reference
    Phi(PhiValue<'ctx>),         // Passed by value (phi node)
}

// -----------------------------------------------------------------------------
// Entry Point: build_procedures (build.rs:5359)
// -----------------------------------------------------------------------------
// Main entry point for LLVM code generation.

pub fn build_procedures<'a>(
    env: &Env<'a, '_, '_>,
    layout_interner: &STLayoutInterner<'a>,
    opt_level: OptLevel,
    procedures: MutMap<(Symbol, ProcLayout<'a>), Proc<'a>>,
    host_exposed_lambda_sets: HostExposedLambdaSets<'a>,
    entry_point: EntryPoint<'a>,
    debug_output_file: Option<&Path>,
    glue_layouts: &GlueLayouts<'a>,
) {
    // 1. Run alias analysis to get specialization info
    let mod_solutions = roc_alias_analysis::spec_program(
        env.arena,
        layout_interner,
        opt_level,
        entry_point,
        procedures.iter(),
        host_exposed_lambda_sets,
    );

    // 2. Build procedure headers (function signatures)
    build_proc_headers(env, layout_interner, &procedures);

    // 3. Compile each procedure body
    for ((symbol, proc_layout), proc) in procedures {
        build_proc(
            env,
            layout_interner,
            &mod_solutions,
            symbol,
            proc_layout,
            proc,
        );
    }

    // 4. Generate glue code for host-exposed functions
    for (symbol, top_level) in glue_layouts.getters.iter() {
        expose_function_to_host(env, layout_interner, symbol, top_level);
    }
}

// -----------------------------------------------------------------------------
// Statement Compilation: build_exp_stmt (build.rs:3049)
// -----------------------------------------------------------------------------
// Compiles a statement tree to LLVM IR.

pub fn build_exp_stmt<'a, 'ctx>(
    env: &Env<'a, 'ctx, '_>,
    layout_interner: &STLayoutInterner<'a>,
    layout_ids: &mut LayoutIds<'a>,
    func_spec_solutions: &FuncSpecSolutions,
    scope: &mut Scope<'a, 'ctx>,
    parent: FunctionValue<'ctx>,
    stmt: &Stmt<'a>,
) -> BasicValueEnum<'ctx> {
    use Stmt::*;

    match stmt {
        // -----------------------------------------------------------------
        // Let binding: evaluate expression, bind to symbol, continue
        // -----------------------------------------------------------------
        Let(symbol, expr, layout, continuation) => {
            // Compile the expression
            let val = build_exp_expr(
                env, layout_interner, layout_ids,
                func_spec_solutions, scope, parent, *layout, expr,
            );

            // Bind symbol to value
            scope.insert(*symbol, *layout, val);

            // Compile continuation
            let result = build_exp_stmt(
                env, layout_interner, layout_ids,
                func_spec_solutions, scope, parent, continuation,
            );

            // Clean up binding
            scope.remove(symbol);
            result
        }

        // -----------------------------------------------------------------
        // Return: load value and generate return instruction
        // -----------------------------------------------------------------
        Ret(symbol) => {
            let (value, layout) = scope.load_symbol_and_layout(symbol);

            // Handle by-pointer return for large values
            build_return(
                env, layout_interner,
                layout_interner.get_repr(layout),
                value, parent,
            );

            // Return dummy value (return doesn't continue)
            env.context.i8_type().const_zero().into()
        }

        // -----------------------------------------------------------------
        // Switch: compile pattern match to LLVM switch + phi
        // -----------------------------------------------------------------
        Switch { cond_symbol, cond_layout, branches, default_branch, ret_layout } => {
            let ret_type = basic_type_from_layout(env, layout_interner, *ret_layout);

            // Load condition value
            let cond_val = scope.load_symbol(cond_symbol);

            // Create basic blocks for each branch
            let mut branch_blocks = Vec::new();
            for (tag_id, _, _) in branches.iter() {
                let block = env.context.append_basic_block(parent, "branch");
                branch_blocks.push((*tag_id, block));
            }
            let default_block = env.context.append_basic_block(parent, "default");
            let merge_block = env.context.append_basic_block(parent, "merge");

            // Build LLVM switch instruction
            let switch = env.builder.build_switch(
                cond_val.into_int_value(),
                default_block,
                &branch_blocks,
            );

            // Compile each branch
            let mut incoming_values = Vec::new();
            for ((_, _, branch_stmt), (_, block)) in branches.iter().zip(&branch_blocks) {
                env.builder.position_at_end(*block);
                let result = build_exp_stmt(
                    env, layout_interner, layout_ids,
                    func_spec_solutions, scope, parent, branch_stmt,
                );
                incoming_values.push((result, *block));
                env.builder.build_unconditional_branch(merge_block);
            }

            // Compile default branch
            env.builder.position_at_end(default_block);
            let default_result = build_exp_stmt(
                env, layout_interner, layout_ids,
                func_spec_solutions, scope, parent, default_branch.1,
            );
            incoming_values.push((default_result, default_block));
            env.builder.build_unconditional_branch(merge_block);

            // Build phi node to merge results
            env.builder.position_at_end(merge_block);
            let phi = env.builder.build_phi(ret_type, "switch_result");
            for (val, block) in &incoming_values {
                phi.add_incoming(&[(&val, *block)]);
            }

            phi.as_basic_value()
        }

        // -----------------------------------------------------------------
        // Join point: create a block that can be jumped to (tail recursion)
        // -----------------------------------------------------------------
        Join { id, parameters, body, remainder } => {
            // Create the join point block
            let join_block = env.context.append_basic_block(parent, "joinpoint");

            // Create phi nodes for parameters
            let mut join_args = Vec::new();
            env.builder.position_at_end(join_block);
            for param in parameters.iter() {
                let basic_type = basic_type_from_layout(
                    env, layout_interner, param.layout
                );
                if layout_interner.is_passed_by_reference(param.layout) {
                    // Large values: use alloca
                    let alloca = create_entry_block_alloca(env, basic_type, "join_arg");
                    join_args.push(JoinPointArg::Alloca(alloca));
                } else {
                    // Small values: use phi node
                    let phi = env.builder.build_phi(basic_type, "join_arg");
                    join_args.push(JoinPointArg::Phi(phi));
                }
            }

            // Register join point
            scope.insert_join_point(*id, join_block, join_args);

            // Compile remainder (code before join point)
            // ... returns to entry, may jump to join point

            // Position in join block and compile body
            env.builder.position_at_end(join_block);
            // Bind parameters from phi nodes
            for (param, arg) in parameters.iter().zip(&join_args) {
                let val = match arg {
                    JoinPointArg::Phi(phi) => phi.as_basic_value(),
                    JoinPointArg::Alloca(ptr) => env.builder.build_load(*ptr, ""),
                };
                scope.insert(param.symbol, param.layout, val);
            }
            build_exp_stmt(
                env, layout_interner, layout_ids,
                func_spec_solutions, scope, parent, body,
            )
        }

        // -----------------------------------------------------------------
        // Jump: tail call to a join point
        // -----------------------------------------------------------------
        Jump(join_point_id, arguments) => {
            let (target_block, join_args) = scope.get_join_point(*join_point_id).unwrap();

            // Pass arguments to join point
            let current_block = env.builder.get_insert_block().unwrap();
            for (symbol, arg) in arguments.iter().zip(join_args) {
                let value = scope.load_symbol(symbol);
                match arg {
                    JoinPointArg::Phi(phi) => {
                        phi.add_incoming(&[(&value, current_block)]);
                    }
                    JoinPointArg::Alloca(ptr) => {
                        env.builder.build_store(*ptr, value);
                    }
                }
            }

            // Branch to join point (this is the tail call!)
            env.builder.build_unconditional_branch(*target_block);

            env.context.i8_type().const_zero().into()
        }

        // -----------------------------------------------------------------
        // Reference counting operations
        // -----------------------------------------------------------------
        Refcounting(modify_rc, continuation) => {
            match modify_rc {
                ModifyRc::Inc(symbol, amount) => {
                    let value = scope.load_symbol(symbol);
                    increment_refcount_layout(env, layout_interner, value, *amount);
                }
                ModifyRc::Dec(symbol) => {
                    let (value, layout) = scope.load_symbol_and_layout(symbol);
                    decrement_refcount_layout(env, layout_interner, layout, value);
                }
                ModifyRc::DecRef(symbol) => {
                    let value = scope.load_symbol(symbol);
                    // Non-recursive decrement (just the container)
                    call_void_list_bitcode_fn(env, &[value], bitcode::LIST_DECREF);
                }
                ModifyRc::Free(symbol) => {
                    let value = scope.load_symbol(symbol);
                    let rc_ptr = PointerToRefcount::from_ptr_to_data(env, value);
                    rc_ptr.deallocate(env);
                }
            }

            // Compile continuation
            build_exp_stmt(
                env, layout_interner, layout_ids,
                func_spec_solutions, scope, parent, continuation,
            )
        }

        // -----------------------------------------------------------------
        // Crash/panic
        // -----------------------------------------------------------------
        Crash(symbol, crash_tag) => {
            let msg = scope.load_symbol(symbol);
            call_roc_panic(env, msg, *crash_tag);
            env.context.i8_type().const_zero().into()
        }

        // Expect and Dbg omitted for brevity...
    }
}

// -----------------------------------------------------------------------------
// Expression Compilation: build_exp_expr (build.rs:1558)
// -----------------------------------------------------------------------------
// Compiles an expression to an LLVM value.

pub fn build_exp_expr<'a, 'ctx>(
    env: &Env<'a, 'ctx, '_>,
    layout_interner: &STLayoutInterner<'a>,
    layout_ids: &mut LayoutIds<'a>,
    func_spec_solutions: &FuncSpecSolutions,
    scope: &mut Scope<'a, 'ctx>,
    parent: FunctionValue<'ctx>,
    layout: InLayout<'a>,
    expr: &Expr<'a>,
) -> BasicValueEnum<'ctx> {
    use Expr::*;

    match expr {
        // -----------------------------------------------------------------
        // Literals
        // -----------------------------------------------------------------
        Literal(literal) => build_exp_literal(env, layout_interner, layout, literal),

        NullPointer => {
            let basic_type = basic_type_from_layout(env, layout_interner, layout);
            basic_type.into_pointer_type().const_zero().into()
        }

        // -----------------------------------------------------------------
        // Function calls
        // -----------------------------------------------------------------
        Call(call) => build_exp_call(
            env, layout_interner, layout_ids,
            func_spec_solutions, scope, parent, layout, call,
        ),

        // -----------------------------------------------------------------
        // Struct construction
        // -----------------------------------------------------------------
        Struct(fields) => {
            // Load all field values
            let field_values: Vec<_> = fields.iter()
                .map(|sym| scope.load_symbol(sym))
                .collect();

            // Build LLVM struct
            RocStruct::build(env, layout_interner, layout, &field_values).into()
        }

        // -----------------------------------------------------------------
        // Tag union construction
        // -----------------------------------------------------------------
        Tag { tag_layout, tag_id, arguments, reuse } => {
            let reuse_ptr = reuse.map(|r| scope.load_symbol(&r.symbol).into_pointer_value());

            build_tag(
                env, layout_interner, scope,
                tag_layout, *tag_id, arguments,
                reuse_ptr, parent,
            )
        }

        // -----------------------------------------------------------------
        // Field access
        // -----------------------------------------------------------------
        StructAtIndex { index, field_layouts, structure } => {
            let struct_val = scope.load_symbol(structure);
            let struct_type = struct_type_from_layouts(env, layout_interner, field_layouts);

            // GEP to get field pointer, then load
            let field_ptr = env.builder.build_struct_gep(
                struct_type,
                struct_val.into_pointer_value(),
                *index as u32,
                "field_ptr",
            );
            env.builder.build_load(field_ptr, "field_value")
        }

        // -----------------------------------------------------------------
        // Tag ID extraction
        // -----------------------------------------------------------------
        GetTagId { structure, union_layout } => {
            let union_val = scope.load_symbol(structure);
            extract_tag_id(env, layout_interner, *union_layout, union_val)
        }

        // -----------------------------------------------------------------
        // Union field access
        // -----------------------------------------------------------------
        UnionAtIndex { structure, tag_id, union_layout, index } => {
            let union_val = scope.load_symbol(structure);
            extract_union_field(
                env, layout_interner,
                *union_layout, *tag_id, *index, union_val,
            )
        }

        // -----------------------------------------------------------------
        // Array construction
        // -----------------------------------------------------------------
        Array { elem_layout, elems } => {
            // Allocate list
            let list_ptr = allocate_list(env, layout_interner, *elem_layout, elems.len());

            // Store elements
            for (i, elem) in elems.iter().enumerate() {
                let val = match elem {
                    ListLiteralElement::Literal(lit) => {
                        build_exp_literal(env, layout_interner, *elem_layout, lit)
                    }
                    ListLiteralElement::Symbol(sym) => scope.load_symbol(sym),
                };
                store_list_element(env, layout_interner, list_ptr, i, val);
            }

            list_ptr.into()
        }

        EmptyArray => empty_polymorphic_list(env).into(),

        // -----------------------------------------------------------------
        // Type erasure
        // -----------------------------------------------------------------
        ErasedMake { value, callee } => {
            let value_ptr = value.map(|s| scope.load_symbol(&s).into_pointer_value());
            let callee_ptr = scope.load_symbol(callee).into_pointer_value();
            erased::build(env, value_ptr, callee_ptr).into()
        }

        ErasedLoad { symbol, field } => {
            let erased_val = scope.load_symbol(symbol).into_struct_value();
            let wanted_type = basic_type_from_layout(env, layout_interner, layout);
            erased::load(env, erased_val, *field, wanted_type).into()
        }

        // -----------------------------------------------------------------
        // Function pointers
        // -----------------------------------------------------------------
        FunctionPointer { lambda_name } => {
            fn_ptr::build(env, *lambda_name).into()
        }

        // -----------------------------------------------------------------
        // Reset for reuse (Perceus optimization)
        // -----------------------------------------------------------------
        Reset { symbol, update_mode } => {
            let (ptr, layout) = scope.load_symbol_and_layout(symbol);
            let ptr = ptr.into_pointer_value();

            // Check if unique
            let rc_ptr = PointerToRefcount::from_ptr_to_data(env, ptr);
            let is_unique = rc_ptr.is_1(env);

            // If unique: decrement children, return pointer for reuse
            // If not unique: decrement whole thing, return NULL
            build_reset_check(env, layout_interner, ptr, layout, is_unique)
        }

        // Alloca and ResetRef omitted for brevity...
    }
}

// -----------------------------------------------------------------------------
// Call Compilation: build_exp_call (build.rs:1405)
// -----------------------------------------------------------------------------

pub fn build_exp_call<'a, 'ctx>(
    env: &Env<'a, 'ctx, '_>,
    layout_interner: &STLayoutInterner<'a>,
    layout_ids: &mut LayoutIds<'a>,
    func_spec_solutions: &FuncSpecSolutions,
    scope: &mut Scope<'a, 'ctx>,
    parent: FunctionValue<'ctx>,
    ret_layout: InLayout<'a>,
    call: &Call<'a>,
) -> BasicValueEnum<'ctx> {
    match &call.call_type {
        // Direct call to known function
        CallType::ByName { name, specialization_id, .. } => {
            // Load argument values
            let args: Vec<_> = call.arguments.iter()
                .map(|s| scope.load_symbol(s))
                .collect();

            // Get function specialization from alias analysis
            let func_spec = func_spec_solutions.get_specialization(*specialization_id);

            // Lookup or generate the specialized function
            let fn_val = get_specialized_function(env, *name, func_spec);

            // Build the call
            let call = env.builder.build_call(fn_val, &args, "call");
            call.set_call_convention(FAST_CALL_CONV);
            call.try_as_basic_value().left().unwrap()
        }

        // Indirect call through function pointer
        CallType::ByPointer { pointer, arg_layouts, ret_layout } => {
            let fn_ptr = scope.load_symbol(pointer).into_pointer_value();

            // Load arguments
            let args: Vec<_> = call.arguments.iter()
                .map(|s| scope.load_symbol(s))
                .collect();

            // Build function type
            let fn_type = build_function_type(env, layout_interner, arg_layouts, ret_layout);

            // Build indirect call
            let call = env.builder.build_indirect_call(fn_type, fn_ptr, &args, "call");
            call.try_as_basic_value().left().unwrap()
        }

        // Built-in operation
        CallType::LowLevel { op, update_mode } => {
            run_low_level(
                env, layout_interner, scope,
                parent, ret_layout, *op, call.arguments, *update_mode,
            )
        }

        // Foreign function call
        CallType::Foreign { foreign_symbol, ret_layout } => {
            let args: Vec<_> = call.arguments.iter()
                .map(|s| scope.load_symbol(s))
                .collect();

            build_foreign_call(env, *foreign_symbol, &args, *ret_layout)
        }

        // Higher-order operations (List.map, etc.)
        CallType::HigherOrder(ho) => {
            run_higher_order_low_level(
                env, layout_interner, layout_ids,
                func_spec_solutions, scope, parent, ho,
            )
        }
    }
}

// -----------------------------------------------------------------------------
// Layout to LLVM Type Conversion
// -----------------------------------------------------------------------------

pub fn basic_type_from_layout<'ctx>(
    env: &Env<'_, 'ctx, '_>,
    layout_interner: &STLayoutInterner<'_>,
    layout: LayoutRepr<'_>,
) -> BasicTypeEnum<'ctx> {
    match layout {
        LayoutRepr::Builtin(Builtin::Int(width)) => match width {
            IntWidth::I8 | IntWidth::U8 => env.context.i8_type().into(),
            IntWidth::I16 | IntWidth::U16 => env.context.i16_type().into(),
            IntWidth::I32 | IntWidth::U32 => env.context.i32_type().into(),
            IntWidth::I64 | IntWidth::U64 => env.context.i64_type().into(),
            IntWidth::I128 | IntWidth::U128 => env.context.i128_type().into(),
        },

        LayoutRepr::Builtin(Builtin::Float(width)) => match width {
            FloatWidth::F32 => env.context.f32_type().into(),
            FloatWidth::F64 => env.context.f64_type().into(),
        },

        LayoutRepr::Builtin(Builtin::Bool) => env.context.bool_type().into(),

        LayoutRepr::Builtin(Builtin::Str) => zig_str_type(env).into(),

        LayoutRepr::Builtin(Builtin::List(_)) => zig_list_type(env).into(),

        LayoutRepr::Struct(fields) => {
            let field_types: Vec<_> = fields.iter()
                .map(|f| basic_type_from_layout(env, layout_interner, *f))
                .collect();
            env.context.struct_type(&field_types, false).into()
        }

        LayoutRepr::Union(union_layout) => {
            struct_type_from_union_layout(env, layout_interner, union_layout).into()
        }

        LayoutRepr::Ptr(_) |
        LayoutRepr::RecursivePointer(_) |
        LayoutRepr::FunctionPointer(_) => env.context.ptr_type(AddressSpace::default()).into(),

        LayoutRepr::LambdaSet(lambda_set) => {
            // Lambda sets compile to their closure data representation
            basic_type_from_layout(env, layout_interner, lambda_set.full_layout)
        }

        LayoutRepr::Erased(_) => erased::erased_type(env).into(),
    }
}

// -----------------------------------------------------------------------------
// Calling Conventions
// -----------------------------------------------------------------------------

/// LLVM fast calling convention (callee cleans up, enables tail calls)
pub const FAST_CALL_CONV: u32 = 8;

/// C calling convention (for FFI)
pub const C_CALL_CONV: u32 = 0;

// -----------------------------------------------------------------------------
// Helper Functions
// -----------------------------------------------------------------------------

/// Create an alloca in the entry block (for stack allocation)
fn create_entry_block_alloca<'ctx>(
    env: &Env<'_, 'ctx, '_>,
    ty: BasicTypeEnum<'ctx>,
    name: &str,
) -> PointerValue<'ctx> {
    let builder = env.context.create_builder();
    let entry = env.builder.get_insert_block().unwrap()
        .get_parent().unwrap()
        .get_first_basic_block().unwrap();

    match entry.get_first_instruction() {
        Some(instr) => builder.position_before(&instr),
        None => builder.position_at_end(entry),
    }

    builder.build_alloca(ty, name)
}

/// Build a return, handling by-pointer returns for large values
fn build_return<'ctx>(
    env: &Env<'_, 'ctx, '_>,
    layout_interner: &STLayoutInterner<'_>,
    layout: LayoutRepr<'_>,
    value: BasicValueEnum<'ctx>,
    parent: FunctionValue<'ctx>,
) {
    if returns_by_pointer(layout_interner, layout) {
        // Large value: store through return pointer (first param)
        let return_ptr = parent.get_first_param().unwrap().into_pointer_value();
        env.builder.build_store(return_ptr, value);
        env.builder.build_return(None);
    } else {
        // Small value: return in register
        env.builder.build_return(Some(&value));
    }
}
