# Invariants Summary (refreshed 2026-02-25)

This memory contains essential invariants from `design_docs/invariants.csv`. Read this at startup.

## Four Representation Models (REP_001)

The compiler defines **four distinct data representation models**:
1. **ABI representation** - for function calls
2. **SSA representation** - for MLIR operands
3. **Heap representation** - for runtime objects
4. **Logical representation** - for Elm semantics

**Critical rule**: Rules in one model do not imply rules in another unless explicitly stated.

## ABI Rules

**REP_ABI_001**: Only Int, Float, and Char are passed/returned as pass-by-value MLIR types. **All other values including Bool** cross the ABI as `!eco.value`.

## SSA Rules

**REP_SSA_001**: SSA operands use immediate MLIR types (i64, f64, i16, i1) only for Int, Float, Char. All other values are `!eco.value`.

## Heap Rules

**REP_HEAP_001**: Heap field representation is determined solely by layout metadata (RecordLayout, TupleLayout, CtorLayout).

**REP_HEAP_002**: Unboxed fields only when layout bitmap marks them unboxed. GC relies on bitmap.

## Closure Rules

**REP_CLOSURE_001**: Closures capture using SSA rules. Only immediate operands stored unboxed. **Bool stored as !eco.value**.

**FORBID_CLOSURE_001**: Bool must NOT be captured/stored as immediate operand outside SSA control-flow contexts.

## Type Mapping (CGEN_012)

| MonoType | MLIR Type |
|----------|-----------|
| MInt | i64 |
| MFloat | f64 |
| MChar | i16 |
| MBool | **!eco.value** (NOT i1 at boundaries) |
| MString, MList, MTuple, MRecord, MCustom, MFunction | !eco.value |

## Embedded Constants (HEAP_010, REP_CONSTANT_001)

Unit, True, False, Nil, Nothing, EmptyString, EmptyRec are **HPointer values with nonzero constant bits** - never heap allocated.

## Unboxed Bitmap Rules

**CGEN_026**: For eco.construct.*, unboxed_bitmap derived from SSA operand MLIR types: bit set iff operand is i64, f64, or i16.

**CGEN_003**: Closure unboxed bitmaps match SSA operand types after closure-boundary normalization.

## Control Flow (CGEN_010, CGEN_028, CGEN_042-CGEN_054)

**CGEN_010**: eco.case has explicit MLIR result types; every alternative terminates with eco.yield matching those types.

**CGEN_028**: Every eco.case alternative terminates with eco.yield. eco.return forbidden inside alternatives.

**CGEN_042**: Every block must end with a terminator (eco.return, eco.jump, eco.yield, etc.).

## Monomorphization

**MONO_002**: No MVar with CNumber at codegen time - must resolve to MInt or MFloat.

**MONO_006**: RecordLayout/TupleLayout store fieldCount, indices, unboxedBitmap.

**MONO_010**: MonoGraph contains all types including all constructors in ctorLayouts.

## GlobalOpt Invariants

**GOPT_001**: Closure params match stage arity - for every MonoClosure after GlobalOpt, length(params) == length(stageParamTypes(type)). Established by `canonicalizeClosureStaging`, verified by `TestLogic.Generate.MonoFunctionArity` tests (not at runtime).

**GOPT_002**: Returned closure param counts are tracked - for functions returning closures, the returnedClosureParamCounts map entry equals the first-stage parameter count.

**GOPT_003**: All MonoCase branches must have same MonoType as resultType (enforced by GlobalOpt, formerly MONO_018).

## Closure-Specific Invariants (new since 2026-02-19)

**CGEN_CLOSURE_003**: For every closure lambda, FV(body) ⊆ params ∪ captures ∪ siblingMappings keys. Prevents missing captures.

**CGEN_CLOSURE_004**: Every eco.papCreate with captures must have `_fast_evaluator` attribute; zero-capture closures have neither.

**CGEN_CLOSURE_005**: Closure calls with `_dispatch_mode=fast` require `_fast_evaluator` and `_capture_abi` attributes.

**CGEN_CLOSURE_006**: At control-flow merges, closures with differing closure_kind → `_closure_kind=heterogeneous`.

**CGEN_CLOSURE_007**: Every closure call must have `_dispatch_mode` attribute.

**CGEN_CLOSURE_008**: `_dispatch_mode=unknown` indicates missing metadata, should trigger diagnostic.

**ABI_CLONE_001**: After ABI cloning, each closure-typed param in a specialization has at most one capture ABI.

**CLONE_RELATION_001**: Fast clone sig = (capture_types ++ param_types) -> return_type; generic = (Closure* param_types) -> return_type.

**ZERO_CAPTURE_001**: Zero-capture closures don't have `_closure_kind`, `_fast_evaluator`, or `_generic_evaluator` attrs.

## PostSolve Invariants (POST_005-006)

**POST_005**: For every non-negative node id whose pre-PostSolve type is not a bare TVar, PostSolve must not change that type (except VarKernel nodes).

**POST_006**: Post-PostSolve free TVars must be a subset of pre-PostSolve TVars (no new polymorphism introduced).

## GlobalOpt CallInfo Invariants (GOPT_010-016)

**GOPT_010**: After GlobalOpt every MonoCall has a non-placeholder CallInfo.

**GOPT_011-012**: StageCurried calls: stageArities is non-empty list of positive ints, sum equals total params.

**GOPT_013-014**: Partial application arity semantics and isSingleStageSaturated consistency.

**GOPT_015**: FlattenedExternal calls have no staging (empty arities, zero remaining).

**GOPT_016**: ABI wrapper calls invoke callees stage-by-stage per callee's segmentation.

## Monomorphization Invariants (MONO_017-020)

**MONO_017**: SpecId registry reverse mapping matches actual node types.

**MONO_018**: MonoCase branch result types all equal the case resultType.

**MONO_019**: Each lambdaId is unique per MonoGraph.

**MONO_020**: After mono, reachable user-defined local functions have no CEcoValue MVar in MFunction positions.

## CGEN_055-056

**CGEN_055**: ABI wrapper closures for segmentation [s1,s2,...] must have outermost closure with s1 params (not total flat arity).

**CGEN_056**: For saturated eco.papExtend of func.func @f, result MLIR type must equal @f's result type.

## Forbidden Patterns (FORBID_*)

- **FORBID_REP_001**: Don't assume SSA immediate type means unboxed heap field without consulting bitmap
- **FORBID_REP_002**: Don't assume pass-by-value ABI means unboxed heap/closure storage
- **FORBID_HEAP_001**: Don't use address range checks for pointer/constant distinction - use HPointer constant bits
- **FORBID_CF_001**: No implicit fallthrough - all region exits must be explicit terminators
