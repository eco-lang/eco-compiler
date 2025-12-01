// =============================================================================
// EXTRACTED SPECIALIZATION CODE FROM: crates/compiler/mono/src/ir.rs
// =============================================================================
// This file contains the core specialization logic that transforms polymorphic
// functions into monomorphic procedures.

// -----------------------------------------------------------------------------
// Procs: Specialization State Tracking (ir.rs:913)
// -----------------------------------------------------------------------------

pub struct Procs<'a> {
    /// Unspecialized functions (polymorphic, waiting for concrete types)
    pub partial_procs: PartialProcs<'a>,

    /// Ability member aliases for resolution
    ability_member_aliases: AbilityAliases,

    /// Specializations discovered but not yet processed
    pending_specializations: PendingSpecializations<'a>,

    /// Completed specialized procedures
    specialized: Specialized<'a>,

    /// Lambda sets exposed to the host runtime
    host_exposed_lambda_sets: HostExposedLambdaSets<'a>,

    /// Runtime errors encountered during specialization
    pub runtime_errors: BumpMap<Symbol, &'a str>,

    /// Specializations needed from other modules
    pub externals_we_need: BumpMap<ModuleId, ExternalSpecializations<'a>>,

    /// Maps polymorphic symbols to their monomorphic specializations
    symbol_specializations: SymbolSpecializations<'a>,

    /// Stack of functions currently being specialized
    /// Used to detect and handle recursive specialization
    specialization_stack: SpecializationStack<'a>,

    /// Zero-argument thunks imported from other modules
    pub imported_module_thunks: &'a [Symbol],

    /// Zero-argument thunks defined in this module
    pub module_thunks: &'a [Symbol],

    /// Functions exposed to the host
    pub host_exposed_symbols: &'a [Symbol],
}

impl<'a> Procs<'a> {
    /// Check if a symbol is currently being specialized
    /// If so, we need to defer its specialization to avoid infinite recursion
    fn symbol_needs_suspended_specialization(&self, specialization: Symbol) -> bool {
        self.specialization_stack.0.contains(&specialization)
    }

    /// Extract all completed procedures (after specialization is done)
    pub fn get_specialized_procs_without_rc(self) -> (
        MutMap<(Symbol, ProcLayout<'a>), Proc<'a>>,
        HostExposedLambdaSets<'a>,
        ProcsBase<'a>,
    ) {
        // ... implementation
    }
}

// -----------------------------------------------------------------------------
// PartialProc: Unspecialized Function (ir.rs:206)
// -----------------------------------------------------------------------------

#[derive(Clone, Debug)]
pub struct PartialProc<'a> {
    /// The function's type annotation (may contain type variables)
    pub annotation: Variable,

    /// Names of the function parameters
    pub pattern_symbols: &'a [Symbol],

    /// Variables captured from enclosing scope (for closures)
    pub captured_symbols: CapturedSymbols<'a>,

    /// The function body in canonical form
    pub body: roc_can::expr::Expr,

    /// Type variable for the body expression
    pub body_var: Variable,

    /// Whether this function is self-recursive
    pub is_self_recursive: bool,
}

impl<'a> PartialProc<'a> {
    /// Create a PartialProc from a named function definition
    pub fn from_named_function(
        env: &mut Env<'a, '_>,
        annotation: Variable,
        loc_args: std::vec::Vec<(Variable, AnnotatedMark, Loc<roc_can::pattern::Pattern>)>,
        loc_body: Loc<roc_can::expr::Expr>,
        captured_symbols: CapturedSymbols<'a>,
        is_self_recursive: bool,
        ret_var: Variable,
    ) -> PartialProc<'a> {
        // Convert patterns to when-expression if needed
        match patterns_to_when(env, loc_args, ret_var, loc_body) {
            Ok((_, pattern_symbols, body)) => {
                PartialProc {
                    annotation,
                    pattern_symbols: pattern_symbols.into_bump_slice(),
                    captured_symbols,
                    body: body.value,
                    body_var: ret_var,
                    is_self_recursive,
                }
            }
            Err(error) => {
                // Handle pattern conversion error
                // ...
            }
        }
    }
}

// -----------------------------------------------------------------------------
// CapturedSymbols: Closure Captures (ir.rs:287)
// -----------------------------------------------------------------------------

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum CapturedSymbols<'a> {
    #[default]
    None,
    Captured(&'a [(Symbol, Variable)]),
}

impl<'a> CapturedSymbols<'a> {
    fn captures(&self) -> bool {
        match self {
            CapturedSymbols::None => false,
            CapturedSymbols::Captured(_) => true,
        }
    }
}

// -----------------------------------------------------------------------------
// Main Entry Point: specialize_all (ir.rs:3027)
// -----------------------------------------------------------------------------

/// Main entry point for monomorphization.
/// Specializes all functions that are reachable from host-exposed symbols.
pub fn specialize_all<'a>(
    env: &mut Env<'a, '_>,
    mut procs: Procs<'a>,
    externals_others_need: std::vec::Vec<ExternalSpecializations<'a>>,
    specializations_for_host: HostSpecializations<'a>,
    layout_cache: &mut LayoutCache<'a>,
) -> Procs<'a> {
    // Step 1: Switch to "Making" mode - no new pending specializations
    let pending_specializations = std::mem::replace(
        &mut procs.pending_specializations,
        PendingSpecializations::Making(Suspended::new_in(env.arena)),
    );

    // Step 2: Specialize all existing pending specializations
    match pending_specializations {
        PendingSpecializations::Finding(suspended) => {
            specialize_suspended(env, &mut procs, layout_cache, suspended)
        }
        PendingSpecializations::Making(suspended) => {
            debug_assert!(suspended.is_empty());
        }
    }

    // Step 3: Specialize functions other modules need from us
    for externals in externals_others_need {
        specialize_external_specializations(env, &mut procs, layout_cache, externals);
    }

    // Step 4: Specialize host-exposed functions
    specialize_host_specializations(env, &mut procs, layout_cache, specializations_for_host);

    // Step 5: Keep specializing until no new work discovered
    while !procs.pending_specializations.is_empty() {
        let pending_specializations = std::mem::replace(
            &mut procs.pending_specializations,
            PendingSpecializations::Making(Suspended::new_in(env.arena)),
        );

        match pending_specializations {
            PendingSpecializations::Making(suspended) => {
                specialize_suspended(env, &mut procs, layout_cache, suspended);
            }
            PendingSpecializations::Finding(_) => {
                internal_error!("should not have this variant after making specializations")
            }
        }
    }

    procs
}

// -----------------------------------------------------------------------------
// Core Specialization: specialize_variable (ir.rs:4029)
// -----------------------------------------------------------------------------

/// Specialize a function for a specific type variable.
fn specialize_variable<'a>(
    env: &mut Env<'a, '_>,
    procs: &mut Procs<'a>,
    proc_name: LambdaName<'a>,
    layout_cache: &mut LayoutCache<'a>,
    fn_var: Variable,              // The specific type to specialize for
    partial_proc_id: PartialProcId,
) -> Result<SpecializeSuccess<'a>, SpecializeFailure<'a>> {
    // Snapshot typestate for potential rollback
    let snapshot = snapshot_typestate(env.subs, procs, layout_cache);

    // Get the raw function layout from the type variable
    let raw = layout_cache
        .raw_from_var(env.arena, fn_var, env.subs)
        .unwrap_or_else(|err| panic!("TODO handle invalid function {err:?}"));

    // Handle module thunks specially
    let raw = if procs.is_module_thunk(proc_name.name()) {
        match raw {
            RawFunctionLayout::Function(_, lambda_set, _) => {
                RawFunctionLayout::ZeroArgumentThunk(lambda_set.full_layout)
            }
            _ => raw,
        }
    } else {
        raw
    };

    // Make rigid type variables flexible (allows unification)
    let annotation_var = procs.partial_procs.get_id(partial_proc_id).annotation;
    instantiate_rigids(env.subs, annotation_var);

    // Track this specialization on the stack
    procs.push_active_specialization(proc_name.name());

    // Actually build the specialized procedure
    let specialized = specialize_proc_help(
        env, procs, proc_name, layout_cache, fn_var, partial_proc_id
    );

    procs.pop_active_specialization(proc_name.name());

    // Process result
    let result = match specialized {
        Ok(proc) => Ok((proc, raw)),
        Err(error) => Err(SpecializeFailure { attempted_layout: raw }),
    };

    // Rollback typestate changes
    rollback_typestate(env.subs, procs, layout_cache, snapshot);

    result
}

// -----------------------------------------------------------------------------
// Build Specialized Proc: specialize_proc_help (ir.rs:3511)
// -----------------------------------------------------------------------------

/// Build a monomorphic procedure from a PartialProc and specific type.
fn specialize_proc_help<'a>(
    env: &mut Env<'a, '_>,
    procs: &mut Procs<'a>,
    lambda_name: LambdaName<'a>,
    layout_cache: &mut LayoutCache<'a>,
    fn_var: Variable,
    partial_proc_id: PartialProcId,
) -> Result<Proc<'a>, LayoutProblem> {
    let partial_proc = procs.partial_procs.get_id(partial_proc_id);
    let captured_symbols = partial_proc.captured_symbols;

    // Step 1: Unify the annotation with the specific type
    let _unified = env.unify(
        procs.externals_we_need.values_mut(),
        layout_cache,
        partial_proc.annotation,
        fn_var,
    );

    // Step 2: If closure, add ARG_CLOSURE to parameters
    let pattern_symbols = match partial_proc.captured_symbols {
        CapturedSymbols::None => partial_proc.pattern_symbols,
        CapturedSymbols::Captured([]) => partial_proc.pattern_symbols,
        CapturedSymbols::Captured(_) => {
            let mut temp = Vec::from_iter_in(
                partial_proc.pattern_symbols.iter().copied(),
                env.arena
            );
            temp.push(Symbol::ARG_CLOSURE);
            temp.into_bump_slice()
        }
    };

    // Step 3: Build specialized argument list with layouts
    let specialized = build_specialized_proc_from_var(
        env, layout_cache, lambda_name, pattern_symbols, fn_var
    )?;

    // Step 4: Determine recursivity
    let recursivity = if partial_proc.is_self_recursive {
        SelfRecursive::SelfRecursive(JoinPointId(env.unique_symbol()))
    } else {
        SelfRecursive::NotSelfRecursive
    };

    // Step 5: Convert the body from canonical to monomorphic IR
    let body = partial_proc.body.clone();
    let body_var = partial_proc.body_var;
    let mut specialized_body = from_can(env, body_var, body, procs, layout_cache);

    // Step 6: Unpack closure captures (if any)
    let specialized_proc = match specialized {
        SpecializedLayout::FunctionBody { arguments, closure, ret_layout, is_erased } => {
            let mut proc_args = Vec::from_iter_in(arguments.iter().copied(), env.arena);

            // Handle closure unpacking based on representation
            match (closure, captured_symbols) {
                (Some(ClosureDataKind::LambdaSet(closure_layout)), CapturedSymbols::Captured(captured)) => {
                    // Unpack captured variables from closure argument
                    match closure_layout.layout_for_member_with_lambda_name(&layout_cache.interner, lambda_name) {
                        ClosureRepresentation::Union { field_layouts, union_layout, tag_id, .. } => {
                            // Multiple closure variants - extract from union
                            for (index, (symbol, _)) in captured.iter().enumerate() {
                                let expr = Expr::UnionAtIndex {
                                    tag_id,
                                    structure: Symbol::ARG_CLOSURE,
                                    index: index as u64,
                                    union_layout,
                                };
                                let layout = union_layout.layout_at(&mut layout_cache.interner, tag_id, index);
                                specialized_body = Stmt::Let(symbol, expr, layout, env.arena.alloc(specialized_body));
                            }
                        }
                        ClosureRepresentation::AlphabeticOrderStruct(field_layouts) => {
                            // Single closure type - extract from struct
                            for (index, (symbol, layout)) in captured.iter().enumerate() {
                                let expr = Expr::StructAtIndex {
                                    index: index as _,
                                    field_layouts,
                                    structure: Symbol::ARG_CLOSURE,
                                };
                                specialized_body = Stmt::Let(symbol, expr, *layout, env.arena.alloc(specialized_body));
                            }
                        }
                        ClosureRepresentation::UnwrappedCapture(_) => {
                            // Single capture - just substitute
                            let (captured_symbol, _) = captured[0];
                            substitute_in_exprs(env.arena, &mut specialized_body, captured_symbol, Symbol::ARG_CLOSURE);
                        }
                        // ... other cases
                    }
                }
                _ => { /* No closure unpacking needed */ }
            }

            Proc {
                name: lambda_name,
                args: proc_args.into_bump_slice(),
                body: specialized_body,
                closure_data_layout: closure.map(|c| c.full_layout()),
                ret_layout,
                is_self_recursive: recursivity,
                is_erased,
            }
        }
        // ... other specialized layout cases
    };

    Ok(specialized_proc)
}

// -----------------------------------------------------------------------------
// ProcLayout: Specialized Function Signature (ir.rs:4102)
// -----------------------------------------------------------------------------

#[derive(Debug, Copy, Clone, PartialEq, Eq, Hash)]
pub struct ProcLayout<'a> {
    /// Concrete layouts of all arguments
    pub arguments: &'a [InLayout<'a>],
    /// Concrete layout of return type
    pub result: InLayout<'a>,
    /// Niche for optimization (e.g., tag union specialization)
    pub niche: Niche<'a>,
}

impl<'a> ProcLayout<'a> {
    /// Create from raw function layout and lambda name
    fn from_raw_named(
        arena: &'a Bump,
        lambda_name: LambdaName<'a>,
        raw: RawFunctionLayout<'a>,
    ) -> Self {
        match raw {
            RawFunctionLayout::Function(arguments, lambda_set, result) => {
                // Extend arguments with closure data if needed
                let arguments = lambda_set.extend_argument_list_for_named(
                    arena, lambda_name, arguments
                );
                ProcLayout::new(arena, arguments, lambda_name.niche(), result)
            }
            RawFunctionLayout::ErasedFunction(arguments, result) => {
                // Add erased argument if closure has captures
                let arguments = if lambda_name.no_captures() {
                    arguments
                } else {
                    let mut extended = Vec::with_capacity_in(arguments.len() + 1, arena);
                    extended.extend(arguments.iter().chain(&[Layout::ERASED]).copied());
                    extended.into_bump_slice()
                };
                ProcLayout::new(arena, arguments, lambda_name.niche(), result)
            }
            RawFunctionLayout::ZeroArgumentThunk(result) => {
                ProcLayout::new(arena, &[], Niche::NONE, result)
            }
        }
    }
}

// -----------------------------------------------------------------------------
// Helper: Specialize Naked Symbol (ir.rs:4189)
// -----------------------------------------------------------------------------

/// Specialize a symbol that appears without being called.
/// May trigger specialization of a function.
fn specialize_naked_symbol<'a>(
    env: &mut Env<'a, '_>,
    variable: Variable,
    procs: &mut Procs<'a>,
    layout_cache: &mut LayoutCache<'a>,
    assigned: Symbol,
    hole: &'a Stmt<'a>,
    symbol: Symbol,
) -> Stmt<'a> {
    if procs.is_module_thunk(symbol) {
        // Top-level declaration - generates 0-arity thunk call
        call_by_name(
            env, procs, variable, symbol,
            std::vec::Vec::new(), layout_cache,
            assigned, hole,
        )
    } else if env.is_imported_symbol(symbol) {
        // Imported thunk
        call_by_name(
            env, procs, variable, symbol,
            std::vec::Vec::new(), layout_cache,
            assigned, hole,
        )
    } else {
        // Regular symbol - may need specialization
        specialize_symbol(
            env, procs, layout_cache,
            Some(variable), assigned, hole, symbol,
        )
    }
}
