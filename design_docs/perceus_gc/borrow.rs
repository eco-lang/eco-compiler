// =============================================================================
// EXTRACTED FROM: crates/compiler/mono/src/borrow.rs
// =============================================================================
// Borrow signature inference for Perceus reference counting.
//
// This pass determines which function parameters should be "borrowed" (read-only)
// vs "owned" (transferred ownership). Borrowed parameters don't need Inc/Dec
// at call sites.

use bumpalo::{collections::Vec, Bump};
use roc_collections::{MutMap, ReferenceMatrix};
use roc_module::symbol::Symbol;

use crate::{
    inc_dec::Ownership,
    ir::{Call, CallType, Expr, JoinPointId, Param, Proc, ProcLayout, Stmt},
    layout::{Builtin, InLayout, LayoutInterner, LayoutRepr, Niche},
};

// =============================================================================
// BORROW SIGNATURE
// =============================================================================

/// Compact representation of borrow signature (up to 56 parameters)
/// Bit 0-7: length, Bits 8+: ownership flags (0=borrowed, 1=owned)
#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) struct BorrowSignature(u64);

impl BorrowSignature {
    fn new(len: usize) -> Self {
        assert!(len < 64 - 8);
        Self(len as _)
    }

    /// Create default signature from layouts
    /// Lists and strings default to Borrowed, others to Owned
    fn from_layouts<'a>(
        interner: &impl LayoutInterner<'a>,
        layouts: impl ExactSizeIterator<Item = &'a InLayout<'a>>,
    ) -> Self {
        let mut signature = BorrowSignature::new(layouts.len());

        for (i, layout) in layouts.enumerate() {
            signature.set(i, layout_to_ownership(*layout, interner));
        }

        signature
    }

    fn len(&self) -> usize {
        (self.0 & 0xFF) as usize
    }

    fn get(&self, index: usize) -> Option<&Ownership> {
        if index >= self.len() {
            return None;
        }

        match self.0 & (1 << (index + 8)) {
            0 => Some(&Ownership::Borrowed),
            _ => Some(&Ownership::Owned),
        }
    }

    fn set(&mut self, index: usize, ownership: Ownership) -> bool {
        assert!(index < self.len());

        let modified = self.get(index) != Some(&ownership);
        let mask = 1 << (index + 8);

        match ownership {
            Ownership::Owned => self.0 |= mask,
            Ownership::Borrowed => self.0 &= !mask,
        }

        modified
    }

    pub fn iter(&self) -> impl Iterator<Item = Ownership> + '_ {
        let mut i = 0;
        std::iter::from_fn(move || {
            let value = self.get(i)?;
            i += 1;
            Some(*value)
        })
    }
}

// =============================================================================
// BORROW SIGNATURES COLLECTION
// =============================================================================

pub(crate) struct BorrowSignatures<'a> {
    pub(crate) procs: MutMap<(Symbol, ProcLayout<'a>), BorrowSignature>,
}

// =============================================================================
// MAIN ENTRY POINT
// =============================================================================

/// Infer borrow signatures for all procedures.
/// Uses fixed-point iteration over strongly connected components.
pub(crate) fn infer_borrow_signatures<'a>(
    arena: &'a Bump,
    interner: &impl LayoutInterner<'a>,
    procs: &MutMap<(Symbol, ProcLayout<'a>), Proc<'a>>,
) -> BorrowSignatures<'a> {
    // STEP 1: Initialize with default signatures
    let mut borrow_signatures: BorrowSignatures = BorrowSignatures {
        procs: procs
            .iter()
            .map(|(_key, proc)| {
                let key = (proc.name.name(), proc.proc_layout(arena));
                let signature = BorrowSignature::from_layouts(interner, key.1.arguments.iter());
                (key, signature)
            })
            .collect(),
    };

    // Join points for each procedure
    let mut join_points: Vec<_> = std::iter::repeat_with(MutMap::default)
        .take(procs.len())
        .collect_in(arena);

    // STEP 2: Compute strongly connected components
    // This allows processing in dependency order
    let matrix = construct_reference_matrix(arena, procs);
    let sccs = matrix.strongly_connected_components_all();

    let mut join_point_stack = Vec::new_in(arena);
    let mut proc_join_points = MutMap::default();

    // STEP 3: Process each SCC with fixed-point iteration
    for (group, _) in sccs.groups() {
        // Fixed-point: keep iterating until signatures stabilize
        loop {
            let mut modified = false;

            for index in group.iter_ones() {
                let (_, proc) = procs.iter().nth(index).unwrap();
                let key = (proc.name.name(), proc.proc_layout(arena));

                if proc.args.is_empty() {
                    continue;
                }

                std::mem::swap(&mut proc_join_points, &mut join_points[index]);

                let mut state = State {
                    args: proc.args,
                    borrow_signature: *borrow_signatures.procs.get(&key).unwrap(),
                    join_point_stack,
                    join_points: proc_join_points,
                    modified: false,
                };

                // Analyze the procedure body
                state.inspect_stmt(interner, &mut borrow_signatures, &proc.body);

                // Check if signature changed
                modified |= state.modified;

                // Update signature
                borrow_signatures.procs.insert(key, state.borrow_signature);

                proc_join_points = state.join_points;
                std::mem::swap(&mut proc_join_points, &mut join_points[index]);

                join_point_stack = state.join_point_stack;
                join_point_stack.clear();
            }

            // Fixed point reached
            if !modified {
                break;
            }
        }
    }

    borrow_signatures
}

// =============================================================================
// DEFAULT OWNERSHIP BY LAYOUT
// =============================================================================

/// Determine default ownership for a layout.
/// Lists and Strings default to Borrowed (read-only),
/// other refcounted types default to Owned.
fn layout_to_ownership<'a>(
    in_layout: InLayout<'a>,
    interner: &impl LayoutInterner<'a>,
) -> Ownership {
    match interner.get_repr(in_layout) {
        // Lists and strings are commonly read-only, so default to borrowed
        LayoutRepr::Builtin(Builtin::Str) => Ownership::Borrowed,
        LayoutRepr::Builtin(Builtin::List(_)) => Ownership::Borrowed,

        // Lambda sets: use the runtime representation
        LayoutRepr::LambdaSet(inner) => {
            layout_to_ownership(inner.runtime_representation(), interner)
        }

        // Everything else defaults to owned
        _ => Ownership::Owned,
    }
}

// =============================================================================
// ANALYSIS STATE
// =============================================================================

struct State<'state, 'arena> {
    /// Function arguments eligible for borrow inference
    args: &'state [(InLayout<'arena>, Symbol)],

    /// Current borrow signature being built
    borrow_signature: BorrowSignature,

    /// Stack of join points we're inside of
    join_point_stack: Vec<'arena, (JoinPointId, &'state [Param<'arena>])>,

    /// Join point signatures
    join_points: MutMap<JoinPointId, BorrowSignature>,

    /// Whether any modification was made
    modified: bool,
}

impl<'state, 'a> State<'state, 'a> {
    /// Mark a symbol as Owned (cannot be borrowed)
    /// This happens when a symbol is:
    /// - Returned from the function
    /// - Passed to a function that requires ownership
    /// - Used destructively
    fn mark_owned(&mut self, symbol: Symbol) {
        // Check if it's a function argument
        if let Some(index) = self.args.iter().position(|(_, s)| *s == symbol) {
            self.modified |= self.borrow_signature.set(index, Ownership::Owned);
        }

        // Also propagate to enclosing join points
        for (id, params) in &self.join_point_stack {
            if let Some(index) = params.iter().position(|p| p.symbol == symbol) {
                self.join_points
                    .get_mut(id)
                    .unwrap()
                    .set(index, Ownership::Owned);
            }
        }
    }

    /// Analyze a statement for ownership requirements
    fn inspect_stmt(
        &mut self,
        interner: &impl LayoutInterner<'a>,
        borrow_signatures: &mut BorrowSignatures<'a>,
        stmt: &Stmt<'a>,
    ) {
        match stmt {
            Stmt::Let(_, expr, _, stmt) => {
                self.inspect_expr(borrow_signatures, expr);
                self.inspect_stmt(interner, borrow_signatures, stmt);
            }

            Stmt::Switch { branches, default_branch, .. } => {
                for (_, _, stmt) in branches.iter() {
                    self.inspect_stmt(interner, borrow_signatures, stmt);
                }
                self.inspect_stmt(interner, borrow_signatures, default_branch.1);
            }

            Stmt::Ret(s) => {
                // Returning a value requires ownership
                self.mark_owned(*s);
            }

            Stmt::Join { id, parameters, body, remainder } => {
                // Initialize join point signature if first visit
                self.join_points.entry(*id).or_insert_with(|| {
                    BorrowSignature::from_layouts(interner, parameters.iter().map(|p| &p.layout))
                });

                // Push onto stack and analyze body
                self.join_point_stack.push((*id, parameters));
                self.inspect_stmt(interner, borrow_signatures, body);
                self.join_point_stack.pop();

                self.inspect_stmt(interner, borrow_signatures, remainder);
            }

            Stmt::Jump(id, arguments) => {
                // Mark arguments as owned if join point requires it
                let borrow_signature = self.join_points.get(id).unwrap();
                for (argument, ownership) in arguments.iter().zip(borrow_signature.iter()) {
                    if let Ownership::Owned = ownership {
                        self.mark_owned(*argument);
                    }
                }
            }

            Stmt::Crash(_, _) => { /* Not relevant */ }

            Stmt::Expect { remainder, .. } | Stmt::Dbg { remainder, .. } => {
                // These borrow their arguments
                self.inspect_stmt(interner, borrow_signatures, remainder);
            }

            Stmt::Refcounting(_, _) => unreachable!("not inserted yet"),
        }
    }

    /// Analyze an expression for ownership requirements
    fn inspect_expr(&mut self, borrow_signatures: &mut BorrowSignatures<'a>, expr: &Expr<'a>) {
        if let Expr::Call(call) = expr {
            self.inspect_call(borrow_signatures, call)
        }
    }

    /// Analyze a function call
    fn inspect_call(&mut self, borrow_signatures: &mut BorrowSignatures<'a>, call: &Call<'a>) {
        let Call { call_type, arguments } = call;

        match call_type {
            CallType::ByName { name, arg_layouts, ret_layout, .. } => {
                let proc_layout = ProcLayout {
                    arguments: arg_layouts,
                    result: *ret_layout,
                    niche: Niche::NONE,
                };

                // Look up callee's borrow signature
                let borrow_signature = borrow_signatures
                    .procs
                    .get(&(name.name(), proc_layout))
                    .unwrap();

                // If callee needs ownership, mark argument as owned
                for (argument, ownership) in arguments.iter().zip(borrow_signature.iter()) {
                    if let Ownership::Owned = ownership {
                        self.mark_owned(*argument);
                    }
                }
            }

            CallType::LowLevel { op, .. } => {
                // Use predefined signatures for builtins
                let borrow_signature = crate::inc_dec::lowlevel_borrow_signature(*op);
                for (argument, ownership) in arguments.iter().zip(borrow_signature) {
                    if ownership.is_owned() {
                        self.mark_owned(*argument);
                    }
                }
            }

            // Unknown callees: assume all args owned
            CallType::ByPointer { .. } | CallType::Foreign { .. } | CallType::HigherOrder(_) => {
                for argument in arguments.iter() {
                    self.mark_owned(*argument)
                }
            }
        }
    }
}

// =============================================================================
// CALL GRAPH CONSTRUCTION
// =============================================================================

/// Build a matrix of which procedures call which others.
/// Used for SCC computation.
fn construct_reference_matrix<'a>(
    arena: &'a Bump,
    procs: &MutMap<(Symbol, ProcLayout<'a>), Proc<'a>>,
) -> ReferenceMatrix {
    let mut matrix = ReferenceMatrix::new(procs.len());

    let mut call_info = CallInfo::new(arena);

    for (row, proc) in procs.values().enumerate() {
        call_info.clear();
        call_info.stmt(arena, &proc.body);

        for key in call_info.keys.iter() {
            for (col, (k, _)) in procs.keys().enumerate() {
                if k == key {
                    matrix.set_row_col(row, col, true);
                }
            }
        }
    }

    matrix
}

struct CallInfo<'a> {
    keys: Vec<'a, Symbol>,
}

impl<'a> CallInfo<'a> {
    fn new(arena: &'a Bump) -> Self {
        CallInfo { keys: Vec::new_in(arena) }
    }

    fn clear(&mut self) {
        self.keys.clear()
    }

    fn call(&mut self, call: &crate::ir::Call<'a>) {
        match call.call_type {
            CallType::ByName { name, .. } => {
                self.keys.push(name.name());
            }
            CallType::HigherOrder(ref hol) => {
                self.keys.push(hol.passed_function.name.name());
            }
            _ => {}
        }
    }

    fn stmt(&mut self, arena: &'a Bump, stmt: &Stmt<'a>) {
        let mut stack = bumpalo::vec![in arena; stmt];

        while let Some(stmt) = stack.pop() {
            match stmt {
                Stmt::Join { remainder, body, .. } => {
                    stack.push(remainder);
                    stack.push(body);
                }
                Stmt::Let(_, expr, _, cont) => {
                    if let Expr::Call(call) = expr {
                        self.call(call);
                    }
                    stack.push(cont);
                }
                Stmt::Switch { branches, default_branch, .. } => {
                    stack.extend(branches.iter().map(|b| &b.2));
                    stack.push(default_branch.1);
                }
                Stmt::Dbg { remainder, .. } | Stmt::Expect { remainder, .. } => {
                    stack.push(remainder);
                }
                Stmt::Ret(_) | Stmt::Jump(_, _) | Stmt::Crash(..) => {}
                Stmt::Refcounting(_, _) => unreachable!(),
            }
        }
    }
}
