// =============================================================================
// EXTRACTED FROM: crates/compiler/mono/src/inc_dec.rs
// =============================================================================
// This is the main Perceus reference counting insertion pass.
//
// Implementation based on:
// - Perceus: Garbage Free Reference Counting with Reuse
//   https://www.microsoft.com/en-us/research/uploads/prod/2021/06/perceus-pldi21.pdf
// - Master's thesis by Jelle Teeuwissen:
//   https://studenttheses.uu.nl/bitstream/handle/20.500.12932/44634/Reference_Counting_with_Reuse_in_Roc.pdf

use std::{collections::HashMap, hash::BuildHasherDefault};
use bumpalo::collections::{CollectIn, Vec};
use bumpalo::Bump;
use roc_collections::{all::WyHash, MutMap, MutSet};
use roc_module::low_level::LowLevel;
use roc_module::symbol::Symbol;

use crate::ir::{
    BranchInfo, Call, CallType, Expr, HigherOrderLowLevel, JoinPointId, ListLiteralElement,
    ModifyRc, Param, Proc, ProcLayout, Stmt,
};
use crate::layout::{InLayout, LayoutInterner, Niche, STLayoutInterner};

// =============================================================================
// MAIN ENTRY POINT
// =============================================================================

/// Insert reference count operations for all procedures.
/// This is the main entry point for the Perceus algorithm.
pub fn insert_inc_dec_operations<'a>(
    arena: &'a Bump,
    layout_interner: &STLayoutInterner<'a>,
    procedures: &mut HashMap<(Symbol, ProcLayout<'a>), Proc<'a>, BuildHasherDefault<WyHash>>,
) {
    // STEP 1: Infer borrow signatures for all procedures
    // This determines which parameters are "owned" vs "borrowed"
    let borrow_signatures =
        crate::borrow::infer_borrow_signatures(arena, layout_interner, procedures);
    let borrow_signatures = arena.alloc(borrow_signatures);

    // STEP 2: Insert RC operations for each procedure
    // Note: Skip low-level wrapper functions (they get inlined)
    for ((symbol, _layout), proc) in procedures.iter_mut() {
        if matches!(
            LowLevelWrapperType::from_symbol(*symbol),
            LowLevelWrapperType::NotALowLevelWrapper
        ) {
            let symbol_rc_types_env = SymbolRcTypesEnv::from_layout_interner(layout_interner);
            insert_inc_dec_operations_proc(arena, symbol_rc_types_env, borrow_signatures, proc);
        }
    }
}

// =============================================================================
// RC TYPE TRACKING
// =============================================================================

/// Whether a symbol's type requires reference counting
#[derive(Copy, Clone)]
enum VarRcType {
    ReferenceCounted,
    NotReferenceCounted,
}

/// Tracks which symbols are reference counted vs not
#[derive(Clone, Default)]
struct SymbolRcTypes {
    reference_counted: MutSet<Symbol>,
    not_reference_counted: MutSet<Symbol>,
}

impl SymbolRcTypes {
    fn insert(&mut self, symbol: Symbol, var_rc_type: VarRcType) {
        match var_rc_type {
            VarRcType::ReferenceCounted => {
                self.reference_counted.insert(symbol);
            }
            VarRcType::NotReferenceCounted => {
                self.not_reference_counted.insert(symbol);
            }
        }
    }

    fn get(&self, symbol: &Symbol) -> Option<VarRcType> {
        if self.reference_counted.contains(symbol) {
            Some(VarRcType::ReferenceCounted)
        } else if self.not_reference_counted.contains(symbol) {
            Some(VarRcType::NotReferenceCounted)
        } else {
            None
        }
    }
}

// =============================================================================
// OWNERSHIP TRACKING
// =============================================================================

/// Ownership state of a symbol during RC analysis
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Ownership {
    /// We own this value - can use without incrementing
    Owned,
    /// Already consumed - must increment before reuse
    Borrowed,
}

impl Ownership {
    pub(crate) fn is_owned(&self) -> bool {
        matches!(self, Ownership::Owned)
    }

    pub(crate) fn is_borrowed(&self) -> bool {
        matches!(self, Ownership::Borrowed)
    }
}

// =============================================================================
// ENVIRONMENT
// =============================================================================

/// The environment for the reference counting pass.
/// Tracks ownership state and join point information.
#[derive(Clone)]
struct RefcountEnvironment<'v> {
    /// Which symbols are reference counted
    symbols_rc_types: &'v SymbolRcTypes,

    /// Current ownership state of each symbol
    /// Koka-style: everything not owned is borrowed
    symbols_ownership: MutMap<Symbol, Ownership>,

    /// Join point consumption tracking (for recursive tail calls)
    jointpoint_closures: MutMap<JoinPointId, JoinPointConsumption>,

    /// Inferred borrow signatures of roc functions
    borrow_signatures: &'v crate::borrow::BorrowSignatures<'v>,
}

impl<'v> RefcountEnvironment<'v> {
    /// Consume a symbol (transfer ownership)
    /// Returns the previous ownership state
    fn consume_symbol(&mut self, symbol: &Symbol) -> Option<Ownership> {
        if !self.symbols_ownership.contains_key(symbol) {
            return None;
        }
        Some(self.consume_rc_symbol(*symbol))
    }

    /// Consume a refcounted symbol - set to borrowed
    fn consume_rc_symbol(&mut self, symbol: Symbol) -> Ownership {
        // Set to borrowed (consumed), return previous state
        match self.symbols_ownership.insert(symbol, Ownership::Borrowed) {
            Some(ownership) => ownership,
            None => internal_error!("Expected symbol {symbol:?} to be in environment"),
        }
    }

    /// Add a new symbol (initially owned)
    fn add_symbol(&mut self, symbol: Symbol) {
        self.add_symbol_with(symbol, Ownership::Owned)
    }

    fn add_symbol_with(&mut self, symbol: Symbol, ownership: Ownership) {
        match self.get_symbol_rc_type(&symbol) {
            VarRcType::ReferenceCounted => {
                self.symbols_ownership.insert(symbol, ownership);
            }
            VarRcType::NotReferenceCounted => {
                // Non-RC symbols don't need tracking
            }
        }
    }
}

// =============================================================================
// PROCEDURE PROCESSING
// =============================================================================

/// Insert RC operations for a single procedure
fn insert_inc_dec_operations_proc<'a>(
    arena: &'a Bump,
    mut symbol_rc_types_env: SymbolRcTypesEnv<'a, '_>,
    borrow_signatures: &'a crate::borrow::BorrowSignatures<'a>,
    proc: &mut Proc<'a>,
) {
    // Collect RC types for all symbols in this procedure
    symbol_rc_types_env.insert_symbols_rc_type_proc(proc);

    let mut environment = RefcountEnvironment {
        symbols_rc_types: &symbol_rc_types_env.symbols_rc_type,
        symbols_ownership: MutMap::default(),
        jointpoint_closures: MutMap::default(),
        borrow_signatures,
    };

    // Add arguments with their inferred ownership (from borrow signatures)
    let borrow_signature = borrow_signatures
        .procs
        .get(&(proc.name.name(), proc.proc_layout(arena)))
        .unwrap();
    for ((_, symbol), ownership) in proc.args.iter().zip(borrow_signature.iter()) {
        environment.add_symbol_with(*symbol, ownership);
    }

    // Process the body
    let new_body = insert_refcount_operations_stmt(arena, &mut environment, &proc.body);

    // Insert Dec for unused parameters (still marked as owned)
    let rc_proc_symbols = proc
        .args
        .iter()
        .map(|(_layout, symbol)| symbol)
        .filter(|symbol| environment.symbols_ownership.contains_key(symbol))
        .copied()
        .collect_in::<Vec<_>>(arena);
    let newer_body =
        consume_and_insert_dec_stmts(arena, &mut environment, rc_proc_symbols, new_body);

    proc.body = newer_body.clone();
}

// =============================================================================
// STATEMENT PROCESSING (CORE ALGORITHM)
// =============================================================================

/// Process a statement, inserting RC operations as needed.
/// This is the heart of the Perceus algorithm.
fn insert_refcount_operations_stmt<'v, 'a>(
    arena: &'a Bump,
    environment: &mut RefcountEnvironment<'v>,
    stmt: &Stmt<'a>,
) -> &'a Stmt<'a> {
    match &stmt {
        // ---------------------------------------------------------------------
        // LET BINDING
        // ---------------------------------------------------------------------
        Stmt::Let(_, _, _, _) => {
            // Collect all consecutive let bindings
            // (Avoids stack overflow for long chains)
            let mut triples = vec![];
            let mut current_stmt = stmt;
            while let Stmt::Let(binding, expr, layout, next_stmt) = current_stmt {
                triples.push((binding, expr, layout));
                current_stmt = next_stmt
            }

            // Add all bindings to environment first
            for (binding, _, _) in triples.iter() {
                environment.add_symbol(**binding);
            }

            // Process in reverse order (backward analysis)
            triples
                .into_iter()
                .rev()
                .fold(
                    insert_refcount_operations_stmt(arena, environment, current_stmt),
                    |new_stmt, (binding, expr, layout)| {
                        // If binding still owned (unused), insert Dec
                        let new_stmt_without_unused = match environment
                            .get_symbol_ownership(binding)
                        {
                            Some(Ownership::Owned) => insert_dec_stmt(arena, *binding, new_stmt),
                            _ => new_stmt,
                        };

                        // Remove from environment (out of scope)
                        environment.remove_symbol(*binding);

                        // Process the expression
                        insert_refcount_operations_binding(
                            arena, environment, binding, expr, layout, new_stmt_without_unused,
                        )
                    },
                )
        }

        // ---------------------------------------------------------------------
        // SWITCH (PATTERN MATCHING)
        // ---------------------------------------------------------------------
        Stmt::Switch {
            cond_symbol,
            cond_layout,
            branches,
            default_branch,
            ret_layout,
        } => {
            // Process each branch with cloned environment
            let new_branches = branches
                .iter()
                .map(|(label, info, branch)| {
                    let mut branch_env = environment.clone();
                    let new_branch = insert_refcount_operations_stmt(arena, &mut branch_env, branch);
                    (*label, info.clone(), new_branch, branch_env)
                })
                .collect_in::<Vec<_>>(arena);

            let new_default_branch = {
                let (info, branch) = default_branch;
                let mut branch_env = environment.clone();
                let new_branch = insert_refcount_operations_stmt(arena, &mut branch_env, branch);
                (info.clone(), new_branch, branch_env)
            };

            // Reconcile: find symbols consumed in any branch
            // These must be consumed in ALL branches for consistency
            let consume_symbols = /* ... calculate from branch environments ... */;

            // Insert Dec for symbols not consumed in specific branches
            let newer_branches = /* ... insert Dec stmts where needed ... */;

            // Update current environment
            for consume_symbol in consume_symbols.iter() {
                environment.consume_symbol(consume_symbol);
            }

            arena.alloc(Stmt::Switch {
                cond_symbol: *cond_symbol,
                cond_layout: *cond_layout,
                branches: newer_branches,
                default_branch: newer_default_branch,
                ret_layout: *ret_layout,
            })
        }

        // ---------------------------------------------------------------------
        // RETURN
        // ---------------------------------------------------------------------
        Stmt::Ret(s) => {
            // Return value must be owned
            let ownership = environment.consume_symbol(s);
            debug_assert!(matches!(ownership, None | Some(Ownership::Owned)));
            arena.alloc(Stmt::Ret(*s))
        }

        // ---------------------------------------------------------------------
        // JOIN POINT (for tail recursion)
        // ---------------------------------------------------------------------
        Stmt::Join {
            id: joinpoint_id,
            parameters,
            body,
            remainder,
        } => {
            // Fixed-point iteration to determine consumed symbols
            // Needed because join points can be called recursively
            let mut joinpoint_consumption = MutSet::default();

            let (new_body, mut new_body_environment) = loop {
                let mut current_body_env = body_env.clone();

                current_body_env.add_joinpoint_consumption(*joinpoint_id, joinpoint_consumption.clone());
                let new_body = insert_refcount_operations_stmt(arena, &mut current_body_env, body);
                current_body_env.remove_joinpoint_consumption(*joinpoint_id);

                // Check which symbols were consumed
                let current_consumption = current_body_env
                    .symbols_ownership
                    .iter()
                    .filter_map(|(symbol, ownership)| {
                        ownership.is_borrowed().then_some(*symbol)
                    })
                    .collect::<MutSet<_>>();

                // Fixed point reached?
                if joinpoint_consumption == current_consumption {
                    break (new_body, current_body_env);
                }
                joinpoint_consumption = current_consumption;
            };

            // Process remainder with join point consumption info
            environment.add_joinpoint_consumption(*joinpoint_id, joinpoint_consumption);
            let new_remainder = insert_refcount_operations_stmt(arena, environment, remainder);
            environment.remove_joinpoint_consumption(*joinpoint_id);

            arena.alloc(Stmt::Join {
                id: *joinpoint_id,
                parameters,
                body: newer_body,
                remainder: new_remainder,
            })
        }

        // ---------------------------------------------------------------------
        // JUMP (to join point)
        // ---------------------------------------------------------------------
        Stmt::Jump(joinpoint_id, arguments) => {
            // Consume symbols that the join point needs
            let consumed_symbols = environment.get_joinpoint_consumption(*joinpoint_id);
            for consumed_symbol in consumed_symbols.clone().iter() {
                environment.consume_symbol(consumed_symbol);
            }

            let new_jump = arena.alloc(Stmt::Jump(*joinpoint_id, arguments));

            // Insert Inc for arguments that need to stay alive
            consume_and_insert_inc_stmts(
                arena,
                environment,
                environment.owned_usages(arguments.iter().copied()),
                new_jump,
            )
        }

        // ---------------------------------------------------------------------
        // CRASH
        // ---------------------------------------------------------------------
        Stmt::Crash(symbol, crash_tag) => {
            // Make sure crash message stays alive
            let new_crash = arena.alloc(Stmt::Crash(*symbol, *crash_tag));
            consume_and_insert_inc_stmts(
                arena,
                environment,
                environment.owned_usages([*symbol]),
                new_crash,
            )
        }

        // Should not exist yet
        Stmt::Refcounting(_, _) => unreachable!("refcounting should not be in the AST yet"),
        // ...
    }
}

// =============================================================================
// EXPRESSION PROCESSING
// =============================================================================

/// Process an expression in a let binding
fn insert_refcount_operations_binding<'a>(
    arena: &'a Bump,
    environment: &mut RefcountEnvironment,
    binding: &Symbol,
    expr: &Expr<'a>,
    layout: &InLayout<'a>,
    stmt: &'a Stmt<'a>,
) -> &'a Stmt<'a> {
    // Helper macros for common patterns
    macro_rules! dec_borrowed {
        ($symbols:expr, $stmt:expr) => {
            consume_and_insert_dec_stmts(arena, environment, environment.borrowed_usages($symbols), stmt)
        };
    }

    macro_rules! new_let {
        ($stmt:expr) => {
            arena.alloc(Stmt::Let(*binding, expr.clone(), *layout, $stmt))
        };
    }

    macro_rules! inc_owned {
        ($symbols:expr, $stmt:expr) => {
            consume_and_insert_inc_stmts(arena, environment, environment.owned_usages($symbols), $stmt)
        };
    }

    match expr {
        // -----------------------------------------------------------------
        // LITERALS: No RC needed
        // -----------------------------------------------------------------
        Expr::Literal(_) | Expr::NullPointer | Expr::FunctionPointer { .. } | Expr::EmptyArray => {
            new_let!(stmt)
        }

        // -----------------------------------------------------------------
        // CONSTRUCTORS: Consume arguments (need Inc if reused)
        // -----------------------------------------------------------------
        Expr::Tag { arguments, .. } | Expr::Struct(arguments) => {
            let new_let = new_let!(stmt);
            inc_owned!(arguments.iter().copied(), new_let)
        }

        // -----------------------------------------------------------------
        // FIELD ACCESS: Borrow structure, Inc extracted field
        // -----------------------------------------------------------------
        Expr::GetTagId { structure, .. }
        | Expr::StructAtIndex { structure, .. }
        | Expr::UnionAtIndex { structure, .. }
        | Expr::GetElementPointer { structure, .. } => {
            // Structure is borrowed (Dec if currently owned)
            let new_stmt = dec_borrowed!([*structure], stmt);

            // Extracted field needs Inc if refcounted
            let newer_stmt = if matches!(
                environment.get_symbol_rc_type(binding),
                VarRcType::ReferenceCounted
            ) {
                match expr {
                    Expr::StructAtIndex { .. }
                    | Expr::UnionAtIndex { .. }
                    | Expr::GetElementPointer { .. } => {
                        insert_inc_stmt(arena, *binding, 1, new_stmt)
                    }
                    Expr::GetTagId { .. } => new_stmt, // Tag ID is not RC'd
                    _ => unreachable!(),
                }
            } else {
                new_stmt
            };

            new_let!(newer_stmt)
        }

        // -----------------------------------------------------------------
        // ARRAY CREATION: Inc all elements
        // -----------------------------------------------------------------
        Expr::Array { elems, .. } => {
            let new_let = new_let!(stmt);
            inc_owned!(
                elems.iter().filter_map(|element| match element {
                    ListLiteralElement::Literal(_) => None,
                    ListLiteralElement::Symbol(symbol) => Some(*symbol),
                }),
                new_let
            )
        }

        // -----------------------------------------------------------------
        // FUNCTION CALLS: Use borrow signatures
        // -----------------------------------------------------------------
        Expr::Call(Call { arguments, call_type }) => {
            match call_type {
                CallType::ByName { name, arg_layouts, ret_layout, .. } => {
                    // Look up the borrow signature
                    let proc_layout = ProcLayout {
                        arguments: arg_layouts,
                        result: ret_layout,
                        niche: Niche::NONE,
                    };
                    let borrow_signature = environment
                        .borrow_signatures
                        .procs
                        .get(&(name.name(), proc_layout))
                        .unwrap();

                    // Separate owned vs borrowed arguments
                    let owned_arguments = arguments
                        .iter()
                        .zip(borrow_signature.iter())
                        .filter_map(|(symbol, ownership)| ownership.is_owned().then_some(*symbol));
                    let borrowed_arguments = arguments
                        .iter()
                        .zip(borrow_signature.iter())
                        .filter_map(|(symbol, ownership)| ownership.is_borrowed().then_some(*symbol));

                    let new_stmt = dec_borrowed!(borrowed_arguments, stmt);
                    let new_let = new_let!(new_stmt);
                    inc_owned!(owned_arguments, new_let)
                }

                CallType::ByPointer { .. } => {
                    // Unknown function - assume all args owned
                    let new_let = new_let!(stmt);
                    inc_owned!(arguments.iter().copied(), new_let)
                }

                CallType::Foreign { .. } => {
                    // Foreign functions - assume borrowed
                    let new_stmt = dec_borrowed!(arguments.iter().copied(), stmt);
                    new_let!(new_stmt)
                }

                CallType::LowLevel { op: operator, .. } => {
                    // Use predefined borrow signatures for builtins
                    let borrow_signature = lowlevel_borrow_signature(operator);
                    // ... apply signature ...
                }

                CallType::HigherOrder(_) => {
                    // Higher-order: function owns captured environment
                    // ... special handling ...
                }
            }
        }

        _ => new_let!(stmt)
    }
}

// =============================================================================
// HELPER FUNCTIONS
// =============================================================================

/// Insert Inc statement
fn insert_inc_stmt<'a>(
    arena: &'a Bump,
    symbol: Symbol,
    count: u64,
    continuation: &'a Stmt<'a>,
) -> &'a Stmt<'a> {
    match count {
        0 => continuation,
        positive_count => arena.alloc(Stmt::Refcounting(
            ModifyRc::Inc(symbol, positive_count),
            continuation,
        )),
    }
}

/// Insert Dec statement
fn insert_dec_stmt<'a>(
    arena: &'a Bump,
    symbol: Symbol,
    continuation: &'a Stmt<'a>,
) -> &'a Stmt<'a> {
    arena.alloc(Stmt::Refcounting(ModifyRc::Dec(symbol), continuation))
}

// =============================================================================
// LOW-LEVEL BORROW SIGNATURES
// =============================================================================

/// Predefined borrow signatures for built-in operations
pub(crate) fn lowlevel_borrow_signature(op: LowLevel) -> &'static [Ownership] {
    use LowLevel::*;

    const OWNED: Ownership = Ownership::Owned;
    const BORROWED: Ownership = Ownership::Borrowed;
    const IRRELEVANT: Ownership = Ownership::Owned; // Non-RC types

    match op {
        // Read-only: borrow
        ListLenU64 | ListLenUsize | StrIsEmpty | StrCountUtf8Bytes | ListGetCapacity => &[BORROWED],

        // Capacity allocation: no RC args
        ListWithCapacity | StrWithCapacity => &[IRRELEVANT],

        // Destructive update: own
        ListReplaceUnsafe => &[OWNED, IRRELEVANT, IRRELEVANT],
        ListGetUnsafe | StrGetUnsafe => &[BORROWED, IRRELEVANT],

        // Concatenation
        ListConcat => &[OWNED, OWNED],
        StrConcat => &[OWNED, BORROWED], // Left owned (modified), right borrowed

        // Comparisons: borrow both
        Eq | NotEq => &[BORROWED, BORROWED],

        // Numeric ops: not RC'd
        NumAdd | NumSub | NumMul | NumDiv | NumCompare => &[IRRELEVANT, IRRELEVANT],

        // ... many more ...
        _ => &[OWNED], // Default: own everything
    }
}
