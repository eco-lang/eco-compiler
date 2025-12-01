// =============================================================================
// EXTRACTED FROM: crates/compiler/gen_llvm/src/llvm/refcounting.rs
// =============================================================================
// LLVM code generation for reference counting operations.
//
// This module generates specialized inc/dec functions for each layout,
// optimized with tail calls for recursive types.

use inkwell::values::{BasicValueEnum, FunctionValue, IntValue, PointerValue};
use inkwell::{AddressSpace, IntPredicate};
use roc_mono::layout::{
    Builtin, InLayout, LayoutInterner, LayoutRepr, STLayoutInterner, UnionLayout,
};

// =============================================================================
// POINTER TO REFCOUNT
// =============================================================================

/// Represents a pointer to the refcount header (stored before the data)
pub struct PointerToRefcount<'ctx> {
    value: PointerValue<'ctx>,
}

impl<'ctx> PointerToRefcount<'ctx> {
    /// Create from a pointer to the data.
    /// The refcount is stored at index -1 (one usize before the data).
    ///
    /// Memory layout:
    /// ```
    /// ┌─────────────────┬─────────────────┬──────────────────────┐
    /// │  Extra Bytes    │   Refcount      │      Data            │
    /// │  (alignment)    │   (usize)       │                      │
    /// └─────────────────┴─────────────────┴──────────────────────┘
    ///                    ↑                 ↑
    ///                    refcount_ptr      data_ptr
    /// ```
    pub fn from_ptr_to_data<'a, 'env>(
        env: &Env<'a, 'ctx, 'env>,
        data_ptr: PointerValue<'ctx>,
    ) -> Self {
        let builder = env.builder;
        let refcount_type = env.ptr_int();
        let refcount_ptr_type = env.context.ptr_type(AddressSpace::default());

        // Cast data pointer to usize pointer
        let ptr_as_usize_ptr =
            builder.new_build_pointer_cast(data_ptr, refcount_ptr_type, "as_usize_ptr");

        // Index -1 to get refcount location
        let index_intvalue = refcount_type.const_int(-1_i64 as u64, false);
        let refcount_ptr = unsafe {
            builder.new_build_in_bounds_gep(
                env.ptr_int(),
                ptr_as_usize_ptr,
                &[index_intvalue],
                "get_rc_ptr",
            )
        };

        Self { value: refcount_ptr }
    }

    /// Check if refcount is exactly 1 (unique value)
    pub fn is_1<'a, 'env>(&self, env: &Env<'a, 'ctx, 'env>) -> IntValue<'ctx> {
        let current = self.get_refcount(env);
        let one = match env.target.ptr_width() {
            roc_target::PtrWidth::Bytes4 => env.context.i32_type().const_int(1, false),
            roc_target::PtrWidth::Bytes8 => env.context.i64_type().const_int(1, false),
        };

        env.builder
            .new_build_int_compare(IntPredicate::EQ, current, one, "is_one")
    }

    fn get_refcount<'a, 'env>(&self, env: &Env<'a, 'ctx, 'env>) -> IntValue<'ctx> {
        env.builder
            .new_build_load(env.ptr_int(), self.value, "get_refcount")
            .into_int_value()
    }

    pub fn set_refcount<'a, 'env>(&self, env: &Env<'a, 'ctx, 'env>, refcount: IntValue<'ctx>) {
        env.builder.new_build_store(self.value, refcount);
    }

    /// Perform the modify operation (increment or decrement)
    fn modify<'a, 'env>(
        &self,
        mode: CallMode<'ctx>,
        layout: LayoutRepr<'a>,
        env: &Env<'a, 'ctx, 'env>,
        layout_interner: &STLayoutInterner<'a>,
    ) {
        match mode {
            CallMode::Inc(inc_amount) => self.increment(inc_amount, env, layout),
            CallMode::Dec => self.decrement(env, layout_interner, layout),
        }
    }

    fn increment<'a, 'env>(
        &self,
        amount: IntValue<'ctx>,
        env: &Env<'a, 'ctx, 'env>,
        layout: LayoutRepr<'a>,
    ) {
        incref_pointer(env, self.value, amount, layout);
    }

    pub fn decrement<'a, 'env>(
        &self,
        env: &Env<'a, 'ctx, 'env>,
        layout_interner: &STLayoutInterner<'a>,
        layout: LayoutRepr<'a>,
    ) {
        let alignment = layout
            .allocation_alignment_bytes(layout_interner)
            .max(env.target.ptr_width() as u32);

        decref_pointer(env, self.value, alignment, layout);
    }

    pub fn deallocate<'a, 'env>(
        &self,
        env: &Env<'a, 'ctx, 'env>,
        alignment: u32,
        layout: LayoutRepr<'a>,
    ) -> InstructionValue<'ctx> {
        free_pointer(env, self.value, alignment, layout)
    }
}

// =============================================================================
// BITCODE FUNCTION CALLS (TO ZIG RUNTIME)
// =============================================================================

/// Increment refcount by calling Zig runtime
fn incref_pointer<'ctx>(
    env: &Env<'_, 'ctx, '_>,
    pointer: PointerValue<'ctx>,
    amount: IntValue<'ctx>,
    layout: LayoutRepr<'_>,
) {
    debug_assert_not_list(layout);
    call_void_bitcode_fn(
        env,
        &[pointer.into(), amount.into()],
        roc_builtins::bitcode::UTILS_INCREF_RC_PTR,  // increfRcPtrC
    );
}

/// Decrement refcount by calling Zig runtime
fn decref_pointer<'ctx>(
    env: &Env<'_, 'ctx, '_>,
    pointer: PointerValue<'ctx>,
    alignment: u32,
    layout: LayoutRepr<'_>,
) {
    debug_assert_not_list(layout);
    let alignment = env.context.i32_type().const_int(alignment as _, false);
    call_void_bitcode_fn(
        env,
        &[pointer.into(), alignment.into(), /* elements_refcounted */ false.into()],
        roc_builtins::bitcode::UTILS_DECREF_RC_PTR,  // decrefRcPtrC
    );
}

/// Free memory by calling Zig runtime
fn free_pointer<'ctx>(
    env: &Env<'_, 'ctx, '_>,
    pointer: PointerValue<'ctx>,
    alignment: u32,
    layout: LayoutRepr<'_>,
) -> InstructionValue<'ctx> {
    debug_assert_not_list(layout);
    let alignment = env.context.i32_type().const_int(alignment as _, false);
    call_void_bitcode_fn(
        env,
        &[pointer.into(), alignment.into(), /* elements_refcounted */ false.into()],
        roc_builtins::bitcode::UTILS_FREE_RC_PTR,  // freeRcPtrC
    )
}

// =============================================================================
// MODE TYPES
// =============================================================================

/// Whether we're generating an increment or decrement function
#[derive(Clone, Copy)]
pub enum Mode {
    Inc,
    Dec,
}

/// Call-time mode (Inc includes the amount)
#[derive(Clone, Copy)]
enum CallMode<'ctx> {
    Inc(IntValue<'ctx>),
    Dec,
}

impl Mode {
    fn to_call_mode(self, function: FunctionValue<'_>) -> CallMode<'_> {
        match self {
            Mode::Inc => {
                let amount = function.get_nth_param(1).unwrap().into_int_value();
                CallMode::Inc(amount)
            }
            Mode::Dec => CallMode::Dec,
        }
    }
}

// =============================================================================
// LAYOUT-SPECIFIC RC FUNCTION GENERATION
// =============================================================================

/// Generate or retrieve the RC function for a layout
fn modify_refcount_layout_build_function<'a, 'ctx>(
    env: &Env<'a, 'ctx, '_>,
    layout_interner: &STLayoutInterner<'a>,
    layout_ids: &mut LayoutIds<'a>,
    mode: Mode,
    layout: InLayout<'a>,
) -> Option<FunctionValue<'ctx>> {
    use LayoutRepr::*;

    match layout_interner.get_repr(layout) {
        // Builtins: List and Str need RC, others don't
        Builtin(builtin) => {
            modify_refcount_builtin(env, layout_interner, layout_ids, mode, layout, &builtin)
        }

        // Unions: different handling for recursive vs non-recursive
        Union(variant) => {
            use UnionLayout::*;

            match variant {
                NonRecursive(&[]) => None,  // Void type
                NonRecursive(tags) => {
                    Some(modify_refcount_nonrecursive(env, layout_interner, layout_ids, mode, tags))
                }
                _ => {
                    // Recursive unions need special handling
                    Some(build_rec_union(env, layout_interner, layout_ids, mode, variant))
                }
            }
        }

        // Structs: iterate over fields
        Struct(field_layouts) => {
            Some(modify_refcount_struct(env, layout_interner, layout_ids, layout, field_layouts, mode))
        }

        // Recursive pointer: delegate to underlying type
        RecursivePointer(rec_layout) => {
            modify_refcount_layout_build_function(env, layout_interner, layout_ids, mode, rec_layout)
        }

        // Lambda set: use runtime representation
        LambdaSet(lambda_set) => {
            modify_refcount_layout_build_function(
                env, layout_interner, layout_ids, mode,
                lambda_set.runtime_representation()
            )
        }

        // Function pointers: not refcounted
        FunctionPointer(_) => None,

        // Erased: runtime dispatch
        Erased(_) => {
            Some(modify_refcount_erased(env, layout_interner, layout_ids, mode))
        }

        Ptr(_) => None,
    }
}

// =============================================================================
// RECURSIVE UNION HANDLING
// =============================================================================

/// Build increment/decrement for recursive union types.
/// Key optimization: tail-call recursion for tree-like structures.
fn build_rec_union_help<'a, 'ctx>(
    env: &Env<'a, 'ctx, '_>,
    layout_interner: &STLayoutInterner<'a>,
    layout_ids: &mut LayoutIds<'a>,
    mode: Mode,
    union_layout: UnionLayout<'a>,
    fn_val: FunctionValue<'ctx>,
) {
    let tags = union_layout_tags(env.arena, &union_layout);
    let context = &env.context;
    let builder = env.builder;

    // Entry block
    let entry = context.append_basic_block(fn_val, "entry");
    builder.position_at_end(entry);

    let arg_val = fn_val.get_param_iter().next().unwrap();
    let parent = fn_val;

    // Get tag ID and clear any pointer tags
    let current_tag_id = get_tag_id(env, layout_interner, fn_val, &union_layout, arg_val);
    let value_ptr = if union_layout.stores_tag_id_in_pointer(env.target) {
        tag_pointer_clear_tag_id(env, arg_val.into_pointer_value())
    } else {
        arg_val.into_pointer_value()
    };

    let should_recurse_block = context.append_basic_block(parent, "should_recurse");

    // Handle nullable unions (null pointer = empty variant)
    if union_layout.is_nullable() {
        let is_null = builder.new_build_is_null(value_ptr, "is_null");
        let then_block = context.append_basic_block(parent, "then");

        builder.new_build_conditional_branch(is_null, then_block, should_recurse_block);

        builder.position_at_end(then_block);
        builder.new_build_return(None);  // Null = no-op
    } else {
        builder.new_build_unconditional_branch(should_recurse_block);
    }

    builder.position_at_end(should_recurse_block);

    // Get pointer to refcount
    let refcount_ptr = PointerToRefcount::from_ptr_to_data(env, value_ptr);
    let call_mode = mode_to_call_mode(fn_val, mode);
    let layout = LayoutRepr::Union(union_layout);

    match mode {
        Mode::Inc => {
            // INCREMENT IS CHEAP: just bump the counter
            refcount_ptr.modify(call_mode, layout, env, layout_interner);
            builder.new_build_return(None);
        }

        Mode::Dec => {
            // DECREMENT IS COMPLEX: need to check uniqueness
            let do_recurse_block = context.append_basic_block(parent, "do_recurse");
            let no_recurse_block = context.append_basic_block(parent, "no_recurse");

            // Check if refcount == 1 (unique)
            builder.new_build_conditional_branch(
                refcount_ptr.is_1(env),
                do_recurse_block,   // Unique: free after recursing
                no_recurse_block,   // Shared: just decrement
            );

            // NOT UNIQUE: just decrement the counter
            {
                builder.position_at_end(no_recurse_block);
                refcount_ptr.modify(call_mode, layout, env, layout_interner);
                builder.new_build_return(None);
            }

            // UNIQUE: recurse into children, then free
            {
                builder.position_at_end(do_recurse_block);

                build_rec_union_recursive_decrement(
                    env, layout_interner, layout_ids, parent, fn_val,
                    union_layout, tags, value_ptr, current_tag_id,
                    refcount_ptr, do_recurse_block, DecOrReuse::Dec,
                )
            }
        }
    }
}

enum DecOrReuse {
    Dec,    // Decrement and free
    Reuse,  // Decrement children but keep allocation for reuse
}

/// Generate the recursive decrement logic for union fields.
/// CRITICAL OPTIMIZATION: Uses tail calls for recursive fields.
fn build_rec_union_recursive_decrement<'a, 'ctx>(
    env: &Env<'a, 'ctx, '_>,
    layout_interner: &STLayoutInterner<'a>,
    layout_ids: &mut LayoutIds<'a>,
    parent: FunctionValue<'ctx>,
    decrement_fn: FunctionValue<'ctx>,
    union_layout: UnionLayout<'a>,
    tags: UnionLayoutTags<'a>,
    value_ptr: PointerValue<'ctx>,
    current_tag_id: IntValue<'ctx>,
    refcount_ptr: PointerToRefcount<'ctx>,
    match_block: BasicBlock<'ctx>,
    decrement_or_reuse: DecOrReuse,
) {
    let mode = Mode::Dec;
    let call_mode = mode_to_call_mode(decrement_fn, mode);
    let builder = env.builder;

    // Build a switch table for each tag variant
    let mut cases = Vec::with_capacity_in(tags.tags.len(), env.arena);

    for (tag_id, field_layouts) in tags.tags.iter().enumerate() {
        let block = context.append_basic_block(parent, "tag_id_decrement");
        builder.position_at_end(block);

        // Skip if no refcounted fields
        if fields_need_no_refcounting(layout_interner, field_layouts) {
            if let DecOrReuse::Dec = decrement_or_reuse {
                refcount_ptr.modify(call_mode, LayoutRepr::Union(union_layout), env, layout_interner);
            }
            builder.new_build_return(None);
            cases.push((tag_id, block));
            continue;
        }

        // Cast pointer to correct struct type
        let struct_ptr = builder.new_build_pointer_cast(
            value_ptr,
            context.ptr_type(AddressSpace::default()),
            "opaque_to_correct",
        );

        // CRITICAL: Defer RC modifications until AFTER loading all fields
        // This enables tail-call optimization
        let mut deferred_rec = Vec::new_in(env.arena);      // Recursive fields
        let mut deferred_nonrec = Vec::new_in(env.arena);   // Non-recursive fields

        for (i, field_layout) in field_layouts.iter().enumerate() {
            if let LayoutRepr::RecursivePointer(_) = layout_interner.get_repr(*field_layout) {
                // Recursive pointer: load and save for later
                let elem_pointer = builder.new_build_struct_gep(...);
                let ptr_as_i64_ptr = builder.new_build_load(...);
                deferred_rec.push(ptr_as_i64_ptr);
            } else if layout_interner.contains_refcounted(*field_layout) {
                // Non-recursive refcounted: load and save
                let field = load_roc_value(...);
                deferred_nonrec.push((field, field_layout));
            }
        }

        // STEP 1: Free the parent FIRST (before recursing)
        // This is safe because we already loaded all child pointers
        if let DecOrReuse::Dec = decrement_or_reuse {
            refcount_ptr.modify(call_mode, LayoutRepr::Union(union_layout), env, layout_interner);
        }

        // STEP 2: Decrement non-recursive children (inline)
        for (field, field_layout) in deferred_nonrec {
            modify_refcount_layout_help(env, layout_interner, layout_ids, call_mode, field, *field_layout);
        }

        // STEP 3: Decrement recursive children (TAIL CALL)
        // This gives ~2x speedup on linked lists!
        for ptr in deferred_rec {
            let call = call_help(env, decrement_fn, mode.to_call_mode(decrement_fn), ptr);
            call.set_tail_call(true);  // Enable tail call optimization
        }

        builder.new_build_return(None);
        cases.push((tag_id, block));
    }

    // Generate the switch
    builder.position_at_end(match_block);
    let default_block = context.append_basic_block(parent, "switch_default");
    builder.new_build_switch(current_tag_id, default_block, &cases);

    // Default case: just decrement
    builder.position_at_end(default_block);
    if let DecOrReuse::Dec = decrement_or_reuse {
        refcount_ptr.modify(call_mode, LayoutRepr::Union(union_layout), env, layout_interner);
    }
    builder.new_build_return(None);
}

// =============================================================================
// LIST HANDLING
// =============================================================================

/// Generate list increment/decrement.
/// Lists go through Zig runtime for element-level RC.
fn modify_refcount_list_help<'a, 'ctx>(
    env: &Env<'a, 'ctx, '_>,
    layout_interner: &STLayoutInterner<'a>,
    layout_ids: &mut LayoutIds<'a>,
    mode: Mode,
    element_layout: InLayout<'a>,
    fn_val: FunctionValue<'ctx>,
) {
    let builder = env.builder;
    let entry = context.append_basic_block(fn_val, "entry");
    builder.position_at_end(entry);

    let original_wrapper = fn_val.get_param_iter().next().unwrap().into_struct_value();

    match mode {
        Mode::Dec => {
            // Decrement through Zig: handles element RC and deallocation
            let dec_element_fn = build_dec_wrapper(env, layout_interner, layout_ids, element_layout);
            call_void_list_bitcode_fn(
                env,
                &[original_wrapper],
                &[
                    env.alignment_intvalue(layout_interner, element_layout),
                    layout_width(env, layout_interner, element_layout),
                    layout_refcounted(env, layout_interner, element_layout),
                    dec_element_fn.as_global_value().as_pointer_value().into(),
                ],
                bitcode::LIST_DECREF,
            )
        }
        Mode::Inc => {
            let inc_amount = fn_val.get_nth_param(1).unwrap().into_int_value();
            call_void_list_bitcode_fn(
                env,
                &[original_wrapper],
                &[
                    inc_amount.into(),
                    layout_refcounted(env, layout_interner, element_layout),
                ],
                bitcode::LIST_INCREF,
            )
        }
    }

    builder.new_build_return(None);
}

// =============================================================================
// STRING HANDLING
// =============================================================================

/// Generate string increment/decrement.
/// Strings use small-string optimization (SSO).
fn modify_refcount_str_help<'a, 'ctx>(
    env: &Env<'a, 'ctx, '_>,
    layout_interner: &STLayoutInterner<'a>,
    mode: Mode,
    layout: InLayout<'a>,
    fn_val: FunctionValue<'ctx>,
) {
    let builder = env.builder;
    let ctx = env.context;
    let entry = ctx.append_basic_block(fn_val, "entry");
    builder.position_at_end(entry);

    let arg_val = fn_val.get_param_iter().next().unwrap();
    let str_wrapper = /* load string struct */;

    // Read capacity to check for SSO
    let capacity = builder
        .build_extract_value(str_wrapper, Builtin::WRAPPER_CAPACITY, "read_str_capacity")
        .unwrap()
        .into_int_value();

    // SSO: small strings have high bit set in capacity (negative when signed)
    // Only process big, non-empty strings
    let is_big_and_non_empty = builder.new_build_int_compare(
        IntPredicate::SGT,
        capacity,
        env.ptr_int().const_zero(),
        "is_big_str",
    );

    let cont_block = ctx.append_basic_block(parent, "modify_rc_str_cont");
    let modification_block = ctx.append_basic_block(parent, "modify_rc");

    builder.new_build_conditional_branch(is_big_and_non_empty, modification_block, cont_block);

    // Big string: modify refcount
    builder.position_at_end(modification_block);
    let refcount_ptr = PointerToRefcount::from_ptr_to_data(env, str_allocation_ptr(env, arg_val));
    let call_mode = mode_to_call_mode(fn_val, mode);
    refcount_ptr.modify(call_mode, layout_interner.get_repr(layout), env, layout_interner);
    builder.new_build_unconditional_branch(cont_block);

    // Continue/return
    builder.position_at_end(cont_block);
    builder.new_build_return(None);
}

// =============================================================================
// RESET FOR REUSE
// =============================================================================

/// Build a reset function for memory reuse.
/// If value is unique, decrement children but keep allocation.
pub fn build_reset<'a, 'ctx>(
    env: &Env<'a, 'ctx, '_>,
    layout_interner: &STLayoutInterner<'a>,
    layout_ids: &mut LayoutIds<'a>,
    union_layout: UnionLayout<'a>,
) -> FunctionValue<'ctx> {
    // Similar structure to decrement, but:
    // - If unique: don't free parent, just clear children
    // - Returns the allocation pointer for reuse

    // ... implementation uses DecOrReuse::Reuse ...
}

// =============================================================================
// FUNCTION HEADER GENERATION
// =============================================================================

/// Build the function header for inc/dec functions
fn build_header<'ctx>(
    env: &Env<'_, 'ctx, '_>,
    arg_type: BasicTypeEnum<'ctx>,
    mode: Mode,
    fn_name: &str,
) -> FunctionValue<'ctx> {
    match mode {
        // Inc takes value + amount
        Mode::Inc => build_header_help(
            env,
            fn_name,
            env.context.void_type().into(),
            &[arg_type, env.ptr_int().into()],
        ),
        // Dec takes just value
        Mode::Dec => build_header_help(
            env,
            fn_name,
            env.context.void_type().into(),
            &[arg_type],
        ),
    }
}
