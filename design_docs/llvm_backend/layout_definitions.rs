// =============================================================================
// EXTRACTED LAYOUT DEFINITIONS FROM: crates/compiler/mono/src/layout.rs
// =============================================================================
// Layouts represent the concrete memory representation of types.
// This file contains excerpts for documentation purposes.

// -----------------------------------------------------------------------------
// LayoutRepr: Memory Layout Representation (layout.rs:680)
// -----------------------------------------------------------------------------
// This is the core enum describing how values are stored in memory.

pub enum LayoutRepr<'a> {
    /// Built-in primitive types
    Builtin(Builtin<'a>),

    /// Product type (record, tuple)
    /// Fields are stored contiguously in memory
    Struct(&'a [InLayout<'a>]),

    /// Raw pointer (no reference counting)
    /// Used internally by compiler, not user-facing
    Ptr(InLayout<'a>),

    /// Sum type (tag union)
    /// Different variants have different memory layouts
    Union(UnionLayout<'a>),

    /// Set of possible function implementations
    /// Used when a function value could be one of several lambdas
    LambdaSet(LambdaSet<'a>),

    /// Pointer within a recursive data structure
    /// Points back to the containing recursive type
    RecursivePointer(InLayout<'a>),

    /// Type-erased function pointer
    /// Used when function identity is unknown at compile time
    FunctionPointer(FunctionPointer<'a>),

    /// Fully type-erased value
    Erased(Erased),
}

// -----------------------------------------------------------------------------
// Builtin: Primitive Types (layout.rs)
// -----------------------------------------------------------------------------

pub enum Builtin<'a> {
    /// Signed or unsigned integer of various widths
    Int(IntWidth),

    /// Floating point number
    Float(FloatWidth),

    /// Boolean (1 bit, stored as byte)
    Bool,

    /// Fixed-point decimal (128-bit)
    Decimal,

    /// String (small string optimization)
    /// Memory layout: { ptr, length, capacity } or inline for small strings
    Str,

    /// List (dynamic array)
    /// Memory layout: { ptr, length, capacity }
    /// Element layout stored separately
    List(InLayout<'a>),
}

/// Integer width variants
pub enum IntWidth {
    U8, U16, U32, U64, U128,
    I8, I16, I32, I64, I128,
}

/// Float width variants
pub enum FloatWidth {
    F32, F64,
}

// -----------------------------------------------------------------------------
// UnionLayout: Tag Union Representations (layout.rs:733)
// -----------------------------------------------------------------------------
// Different optimizations are applied based on union structure.

pub enum UnionLayout<'a> {
    /// Standard non-recursive tag union
    /// Example: `Result a e : [Ok a, Err e]`
    ///
    /// Memory: { tag_id: u8/u16, payload: max_variant_size }
    NonRecursive(&'a [&'a [InLayout<'a>]]),

    /// Recursive tag union (general case)
    /// Example: `Expr : [Sym Str, Add Expr Expr]`
    ///
    /// Memory: heap-allocated { tag_id, payload }
    /// The pointer itself is the value
    Recursive(&'a [&'a [InLayout<'a>]]),

    /// Recursive union with single constructor
    /// Example: `RoseTree a : [Tree a (List (RoseTree a))]`
    ///
    /// Optimization: No tag ID needed (always the same)
    /// Memory: heap-allocated payload only
    NonNullableUnwrapped(&'a [InLayout<'a>]),

    /// Recursive union with an empty variant + multiple others
    /// Example: `FingerTree a : [Empty, Single a, More ...]`
    ///
    /// Optimization: Empty variant is NULL pointer
    /// Memory: NULL or heap-allocated { tag_id, payload }
    NullableWrapped {
        /// Index of the tag represented as NULL
        nullable_id: u16,
        /// Layouts of non-null variants
        other_tags: &'a [&'a [InLayout<'a>]],
    },

    /// Recursive union with exactly two variants, one empty
    /// Example: `ConsList a : [Nil, Cons a (ConsList a)]`
    ///
    /// Optimization: Nil = NULL, no tag ID for Cons
    /// Memory: NULL or heap-allocated payload
    NullableUnwrapped {
        /// true if tag 1 is null, false if tag 0 is null
        nullable_id: bool,
        /// Fields of the non-null variant
        other_fields: &'a [InLayout<'a>],
    },
}

// Memory layout examples:
//
// NonRecursive [Ok Int, Err Str]:
//   Stack: { tag: u8, union { ok: i64, err: {ptr, len, cap} } }
//
// Recursive [Leaf Int, Node Tree Tree]:
//   Heap: { tag: u8, union { leaf: i64, node: {ptr, ptr} } }
//   Value is pointer to heap allocation
//
// NullableUnwrapped [Nil, Cons Int ConsList]:
//   NULL = Nil
//   Heap pointer = Cons { value: i64, next: ptr }

// -----------------------------------------------------------------------------
// LambdaSet: Function Value Representation (layout.rs)
// -----------------------------------------------------------------------------
// When a variable could be one of several functions, we track all possibilities.

pub struct LambdaSet<'a> {
    /// All possible function implementations
    pub set: &'a [(Symbol, &'a [InLayout<'a>])],

    /// How to call functions in this set
    pub representation: ClosureRepresentation<'a>,

    /// Layout of the full closure data
    pub full_layout: InLayout<'a>,
}

// Example:
// ```roc
// f = if condition then \x -> x + 1 else \x -> x * 2
// ```
// Lambda set = { closure1, closure2 }
// Both have same signature but different implementations

// -----------------------------------------------------------------------------
// FunctionPointer: Type-Erased Function (layout.rs:695)
// -----------------------------------------------------------------------------

pub struct FunctionPointer<'a> {
    pub args: &'a [InLayout<'a>],
    pub ret: InLayout<'a>,
}

// Used when we can't determine function identity at compile time
// Memory: { function_ptr, maybe_captures_ptr }

// -----------------------------------------------------------------------------
// Layout: Full Layout with Semantic Info
// -----------------------------------------------------------------------------

pub struct Layout<'a> {
    /// The memory representation
    repr: LayoutRepr<'a>,

    /// Semantic information (for debugging/error messages)
    semantic: SemanticRepr<'a>,
}

// -----------------------------------------------------------------------------
// InLayout: Interned Layout Reference
// -----------------------------------------------------------------------------
// All layouts are interned for:
// - Deduplication (same layout = same index)
// - Efficient comparison (just compare indices)
// - Handling recursive types

pub struct InLayout<'a>(u32, std::marker::PhantomData<&'a ()>);

// Pre-defined layouts for common types
impl InLayout<'static> {
    pub const VOID: Self = InLayout(0, PhantomData);
    pub const UNIT: Self = InLayout(1, PhantomData);
    pub const BOOL: Self = InLayout(2, PhantomData);
    pub const U8: Self = InLayout(3, PhantomData);
    pub const U16: Self = InLayout(4, PhantomData);
    pub const U32: Self = InLayout(5, PhantomData);
    pub const U64: Self = InLayout(6, PhantomData);
    pub const U128: Self = InLayout(7, PhantomData);
    pub const I8: Self = InLayout(8, PhantomData);
    pub const I16: Self = InLayout(9, PhantomData);
    pub const I32: Self = InLayout(10, PhantomData);
    pub const I64: Self = InLayout(11, PhantomData);
    pub const I128: Self = InLayout(12, PhantomData);
    pub const F32: Self = InLayout(13, PhantomData);
    pub const F64: Self = InLayout(14, PhantomData);
    pub const DEC: Self = InLayout(15, PhantomData);
    pub const STR: Self = InLayout(16, PhantomData);
}

// -----------------------------------------------------------------------------
// LayoutCache: Layout Computation Cache
// -----------------------------------------------------------------------------
// Caches layout computation from type variables.
// Uses layered caching for snapshot/rollback during specialization.

pub struct LayoutCache<'a> {
    /// Target architecture (affects sizes, alignments)
    pub target: Target,

    /// Layered cache for layouts
    cache: Vec<CacheLayer<LayoutResult<'a>>>,

    /// Layered cache for function layouts
    raw_function_cache: Vec<CacheLayer<RawFunctionLayoutResult<'a>>>,

    /// The layout interner
    pub interner: TLLayoutInterner<'a>,
}

impl<'a> LayoutCache<'a> {
    /// Convert a type variable to a layout
    pub fn from_var(
        &mut self,
        arena: &'a Bump,
        var: Variable,
        subs: &Subs,
    ) -> Result<InLayout<'a>, LayoutProblem> {
        // 1. Look up in cache
        // 2. If not found, compute from type
        // 3. Cache the result
        // 4. Return layout
    }

    /// Convert a function type variable to a raw function layout
    pub fn raw_from_var(
        &mut self,
        arena: &'a Bump,
        var: Variable,
        subs: &Subs,
    ) -> Result<RawFunctionLayout<'a>, LayoutProblem> {
        // Similar to from_var but for function types
    }

    /// Create a snapshot for rollback
    pub fn snapshot(&mut self) -> CacheSnapshot {
        // Push new cache layer
    }

    /// Rollback to a previous snapshot
    pub fn rollback_to(&mut self, snapshot: CacheSnapshot) {
        // Pop cache layer
    }
}

// -----------------------------------------------------------------------------
// RawFunctionLayout: Function Layout Variants
// -----------------------------------------------------------------------------

pub enum RawFunctionLayout<'a> {
    /// Normal function with arguments and possible closures
    Function(
        &'a [InLayout<'a>],   // Argument layouts
        LambdaSet<'a>,        // Possible implementations
        InLayout<'a>,         // Return layout
    ),

    /// Type-erased function (runtime dispatch)
    ErasedFunction(
        &'a [InLayout<'a>],   // Argument layouts
        InLayout<'a>,         // Return layout
    ),

    /// Zero-argument thunk (lazy value)
    ZeroArgumentThunk(InLayout<'a>),
}

// -----------------------------------------------------------------------------
// Target-Specific Layout Information
// -----------------------------------------------------------------------------

impl UnionLayout<'_> {
    /// Whether tag ID is stored in pointer bits (optimization)
    /// Only possible when number of tags < pointer alignment
    pub fn stores_tag_id_in_pointer(&self, target: Target) -> bool {
        match self {
            UnionLayout::Recursive(tags) => {
                tags.len() < target.ptr_width() as usize
            }
            _ => false,
        }
    }

    /// Masks for extracting tag ID from pointer
    pub const POINTER_MASK_32BIT: usize = 0b0000_0111;  // 3 bits
    pub const POINTER_MASK_64BIT: usize = 0b0000_0011;  // 2 bits (conservative)
}

// -----------------------------------------------------------------------------
// Memory Sizes and Alignment
// -----------------------------------------------------------------------------

// Size calculations are target-dependent:
//
// | Type        | 32-bit    | 64-bit    |
// |-------------|-----------|-----------|
// | Pointer     | 4 bytes   | 8 bytes   |
// | Str         | 12 bytes  | 24 bytes  |
// | List        | 12 bytes  | 24 bytes  |
// | I64         | 8 bytes   | 8 bytes   |
// | Bool        | 1 byte    | 1 byte    |
//
// Alignment follows platform ABI rules.
// Structs are padded to alignment of largest field.
