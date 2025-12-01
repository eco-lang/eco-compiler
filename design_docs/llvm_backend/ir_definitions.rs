// =============================================================================
// EXTRACTED IR DEFINITIONS FROM: crates/compiler/mono/src/ir.rs
// =============================================================================
// These are the core data structures that serve as input to the LLVM backend.
// This file contains excerpts for documentation purposes.

// -----------------------------------------------------------------------------
// Proc: A Monomorphic Procedure (ir.rs:304)
// -----------------------------------------------------------------------------
// A fully specialized function ready for code generation.

pub struct Proc<'a> {
    /// The function's unique identifier, including specialization info
    pub name: LambdaName<'a>,

    /// Arguments with their concrete memory layouts
    /// Each argument has a Layout (memory representation) and a Symbol (name)
    pub args: &'a [(InLayout<'a>, Symbol)],

    /// The function body as a statement tree
    pub body: Stmt<'a>,

    /// If this is a closure, the layout of the captured data
    pub closure_data_layout: Option<InLayout<'a>>,

    /// The return type's memory layout
    pub ret_layout: InLayout<'a>,

    /// Whether this function calls itself (enables tail-call optimization)
    pub is_self_recursive: SelfRecursive,

    /// Whether this is a type-erased function
    pub is_erased: bool,
}

// -----------------------------------------------------------------------------
// Stmt: Statement Tree (ir.rs:1510)
// -----------------------------------------------------------------------------
// Statements represent control flow. They form a tree where each node
// contains a continuation (the next statement to execute).

pub enum Stmt<'a> {
    /// Bind an expression to a symbol, then continue
    /// `let symbol = expr in continuation`
    Let(Symbol, Expr<'a>, InLayout<'a>, &'a Stmt<'a>),

    /// Multi-way branch (compiled from pattern matching)
    Switch {
        /// Symbol containing the value to switch on (must be integer-like)
        cond_symbol: Symbol,
        /// Layout of the condition value
        cond_layout: InLayout<'a>,
        /// Branch cases: (value_to_match, branch_info, body)
        branches: &'a [(u64, BranchInfo<'a>, Stmt<'a>)],
        /// Fallback branch if no case matches
        default_branch: (BranchInfo<'a>, &'a Stmt<'a>),
        /// Return type (all branches must return this type)
        ret_layout: InLayout<'a>,
    },

    /// Return a value from the function
    Ret(Symbol),

    /// Reference counting operation, then continue
    Refcounting(ModifyRc, &'a Stmt<'a>),

    /// Assertion with debug information
    Expect {
        condition: Symbol,
        region: Region,
        lookups: &'a [Symbol],
        variables: &'a [LookupType],
        remainder: &'a Stmt<'a>,
    },

    /// Debug print statement
    Dbg {
        source_location: &'a str,
        source: &'a str,
        symbol: Symbol,
        variable: Variable,
        remainder: &'a Stmt<'a>,
    },

    /// Define a join point (target for tail recursion)
    /// `join f <params> = body in remainder`
    Join {
        id: JoinPointId,
        parameters: &'a [Param<'a>],
        body: &'a Stmt<'a>,      // What happens when jumping TO the join point
        remainder: &'a Stmt<'a>, // What happens after DEFINING the join point
    },

    /// Jump to a join point (tail call)
    Jump(JoinPointId, &'a [Symbol]),

    /// Crash/panic with an error message
    Crash(Symbol, CrashTag),
}

// -----------------------------------------------------------------------------
// Expr: Expressions (ir.rs:1868)
// -----------------------------------------------------------------------------
// Expressions compute values. Unlike statements, they don't have continuations.

pub enum Expr<'a> {
    // === Literals ===
    /// Constant value (int, float, string, etc.)
    Literal(Literal<'a>),
    /// Null pointer constant
    NullPointer,

    // === Function Calls ===
    /// Function invocation (direct, indirect, foreign, or builtin)
    Call(Call<'a>),

    // === Data Construction ===
    /// Construct a tag union value
    Tag {
        tag_layout: UnionLayout<'a>,
        tag_id: TagIdIntType,
        arguments: &'a [Symbol],
        /// Optional: reuse an existing allocation
        reuse: Option<ReuseToken>,
    },
    /// Construct a record/tuple
    Struct(&'a [Symbol]),

    // === Data Access ===
    /// Access a field by index from a struct
    StructAtIndex {
        index: u64,
        field_layouts: &'a [InLayout<'a>],
        structure: Symbol,
    },
    /// Get the tag ID from a union value
    GetTagId {
        structure: Symbol,
        union_layout: UnionLayout<'a>,
    },
    /// Access a field from a specific tag variant
    UnionAtIndex {
        structure: Symbol,
        tag_id: TagIdIntType,
        union_layout: UnionLayout<'a>,
        index: u64,
    },
    /// Get a nested pointer (for pattern matching)
    GetElementPointer {
        structure: Symbol,
        union_layout: UnionLayout<'a>,
        indices: &'a [u64],
    },

    // === Arrays ===
    /// Construct a list literal
    Array {
        elem_layout: InLayout<'a>,
        elems: &'a [ListLiteralElement<'a>],
    },
    /// Empty list constant
    EmptyArray,

    // === Type Erasure ===
    /// Create a type-erased value (for higher-order functions)
    ErasedMake {
        value: Option<Symbol>,  // Captured data (None if no captures)
        callee: Symbol,         // Function pointer
    },
    /// Load a field from a type-erased value
    ErasedLoad {
        symbol: Symbol,
        field: ErasedField,
    },

    // === Function Pointers ===
    /// Get a pointer to a function
    FunctionPointer {
        lambda_name: LambdaName<'a>,
    },

    // === Memory Operations ===
    /// Stack allocation
    Alloca {
        element_layout: InLayout<'a>,
        initializer: Option<Symbol>,
    },
    /// Check if value is unique, reset for reuse if so
    Reset {
        symbol: Symbol,
        update_mode: UpdateModeId,
    },
    /// Non-recursive reset (doesn't decrement children)
    ResetRef {
        symbol: Symbol,
        update_mode: UpdateModeId,
    },
}

// -----------------------------------------------------------------------------
// Call: Function Invocation (ir.rs:1677)
// -----------------------------------------------------------------------------

pub struct Call<'a> {
    pub call_type: CallType<'a>,
    pub arguments: &'a [Symbol],
}

pub enum CallType<'a> {
    /// Direct call to a known function
    ByName {
        name: LambdaName<'a>,
        ret_layout: InLayout<'a>,
        arg_layouts: &'a [InLayout<'a>],
        specialization_id: CallSpecId,
    },

    /// Indirect call through a function pointer
    ByPointer {
        pointer: Symbol,
        ret_layout: InLayout<'a>,
        arg_layouts: &'a [InLayout<'a>],
    },

    /// Call to a C foreign function
    Foreign {
        foreign_symbol: ForeignSymbol,
        ret_layout: InLayout<'a>,
    },

    /// Built-in operation (compiled to inline LLVM)
    LowLevel {
        op: LowLevel,
        update_mode: UpdateModeId,
    },

    /// Higher-order builtin (List.map, etc.)
    HigherOrder(&'a HigherOrderLowLevel<'a>),
}

// -----------------------------------------------------------------------------
// ModifyRc: Reference Counting Operations (ir.rs:1612)
// -----------------------------------------------------------------------------
// These are inserted by the Perceus algorithm during inc_dec.rs processing.

pub enum ModifyRc {
    /// Increment reference count by N
    /// Used when a value is used multiple times
    Inc(Symbol, u64),

    /// Decrement reference count
    /// If count reaches zero, recursively free children then deallocate
    Dec(Symbol),

    /// Non-recursive decrement
    /// Only decrements the outer container, not its children
    /// Used when children are already handled (e.g., after copying to new list)
    DecRef(Symbol),

    /// Unconditional deallocation
    /// Used when we know the refcount is 1 (e.g., after unique check)
    Free(Symbol),
}

// -----------------------------------------------------------------------------
// Literal: Constant Values (ir.rs - Literal enum)
// -----------------------------------------------------------------------------

pub enum Literal<'a> {
    Int([u8; 16]),      // 128-bit integer
    U128([u8; 16]),     // Unsigned 128-bit
    Float(f64),
    Decimal([u8; 16]),  // Fixed-point decimal
    Bool(bool),
    Byte(u8),
    Str(&'a str),
}

// -----------------------------------------------------------------------------
// BranchInfo: Pattern Match Metadata (ir.rs:1583)
// -----------------------------------------------------------------------------
// Used in Switch to track what we know about the scrutinee in each branch.

pub enum BranchInfo<'a> {
    /// No additional info
    None,

    /// We know the scrutinee is a specific tag
    Constructor {
        scrutinee: Symbol,
        layout: InLayout<'a>,
        tag_id: TagIdIntType,
    },

    /// We know the scrutinee is a list of specific length
    List {
        scrutinee: Symbol,
        len: u64,
    },

    /// We know whether the scrutinee is unique
    Unique {
        scrutinee: Symbol,
        unique: bool,
    },
}

// -----------------------------------------------------------------------------
// Supporting Types
// -----------------------------------------------------------------------------

/// Unique identifier for a symbol (variable, function, etc.)
pub struct Symbol { /* 64-bit: 32-bit module ID + 32-bit ident ID */ }

/// Interned layout reference
pub struct InLayout<'a> { /* index into layout interner */ }

/// Join point identifier (for tail recursion)
pub struct JoinPointId(Symbol);

/// Parameter in a join point
pub struct Param<'a> {
    pub symbol: Symbol,
    pub layout: InLayout<'a>,
}

/// Token for memory reuse optimization
pub struct ReuseToken {
    pub symbol: Symbol,
    pub update_mode: UpdateModeId,
}

/// Self-recursion status
pub enum SelfRecursive {
    NotSelfRecursive,
    SelfRecursive(JoinPointId),  // Contains the join point for tail calls
}

/// Crash source tag
pub enum CrashTag {
    Roc = 0,   // Compiler-generated crash
    User = 1,  // User-defined crash
}
