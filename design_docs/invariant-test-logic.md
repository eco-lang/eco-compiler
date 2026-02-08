# Invariant Test Logic

This document describes the test logic for each invariant defined in `invariants.csv`.
The invariants.csv file is the definitive source of truth for invariant definitions.

---

## Representation Model Invariants (REP_*)

--
name: Four distinct representation models
phase: cross-phase
invariants: REP_001
ir: All IR representations
logic: Document and verify that ABI, SSA, Heap, and Logical representations are treated independently:
  * ABI: function call boundaries
  * SSA: MLIR operands
  * Heap: runtime object fields
  * Logical: Elm semantics
  Assert no code assumes rules from one model apply to another without explicit invariant reference.
inputs: Code review and cross-phase tests
oracle: Representation decisions are always justified by the correct model's invariants.
--
--
name: ABI boundary uses only Int, Float, Char as primitives
phase: cross-phase
invariants: REP_ABI_001
ir: Function signatures at call boundaries
logic: For all function call boundaries (kernel and compiled):
  * Assert only Int (i64), Float (f64), and Char (i16) are passed/returned as primitive MLIR types.
  * Assert Bool and all other Elm values cross as !eco.value.
inputs: MLIR function signatures and call sites
oracle: No Bool (i1) or other non-{Int,Float,Char} primitives at ABI boundaries.
--
--
name: ABI and heap representations are independent
phase: cross-phase
invariants: REP_ABI_002
ir: ABI signatures vs heap layouts
logic: Verify that ABI representation does not imply heap field representation:
  * A value passed as i64 at ABI may be stored boxed or unboxed in heap fields.
  * Layout metadata (not ABI) determines heap storage.
inputs: Programs with mixed representations
oracle: No code path assumes ABI type implies heap layout.
--
--
name: SSA operand types for primitives
phase: cross-phase
invariants: REP_SSA_001
ir: MLIR SSA operands
logic: Assert SSA operands use immediate types (i64, f64, i16, i1) only for Int, Float, Char values:
  * All other Elm values are !eco.value in SSA.
  * SSA representation is independent of heap layout and ABI.
inputs: Generated MLIR modules
oracle: Only Int/Float/Char have immediate SSA types; all others are !eco.value.
--
--
name: Heap layout determined by layout metadata
phase: runtime heap
invariants: REP_HEAP_001
ir: Heap objects and layout structures
logic: Verify heap field representation is determined solely by RecordLayout, TupleLayout, CtorLayout:
  * Layout metadata is produced during monomorphization.
  * Heap layout is independent of ABI and SSA representation.
inputs: Monomorphized layouts and runtime heap objects
oracle: Heap layouts match metadata; no implicit assumptions from other representations.
--
--
name: Heap unboxing determined by bitmap
phase: runtime heap
invariants: REP_HEAP_002
ir: Heap objects with unboxed fields
logic: For heap objects with unboxed fields:
  * Unboxing occurs only when layout bitmap marks the slot as unboxed.
  * GC and debug logic rely exclusively on unboxed bitmap or HPointer constant bits.
inputs: Runtime heap tests with mixed boxed/unboxed fields
oracle: Bitmap is the sole source of truth for field boxing status.
--
--
name: Projection from heap yields correct SSA types
phase: cross-phase
invariants: REP_BOUNDARY_001
ir: eco.project ops
logic: For projection from heap objects into SSA:
  * If heap layout bitmap indicates unboxed field → produce immediate MLIR operand.
  * Otherwise → produce !eco.value.
inputs: MLIR with projection ops
oracle: Projection result types match heap layout bitmap.
--
--
name: Construction sets bitmaps from SSA types
phase: cross-phase
invariants: REP_BOUNDARY_002
ir: eco.construct ops
logic: For construction of heap objects from SSA values:
  * Unboxed bitmaps are set based solely on SSA operand MLIR types (i64, f64, i16).
  * Runtime layout must match the bitmap exactly.
inputs: MLIR construct ops and runtime layouts
oracle: Bitmap matches SSA operand types; runtime layout is consistent.
--
--
name: Closure capture follows SSA rules with Bool normalization
phase: cross-phase
invariants: REP_CLOSURE_001
ir: Closure capture and PAP ops
logic: Closure objects capture values using SSA representation rules:
  * Only immediate operands (i64, f64, i16) are stored in unboxed fields.
  * Bool (i1) and all other values are stored as !eco.value.
  * Unboxed bitmaps must exactly match captured operand MLIR types after normalization.
inputs: MLIR with eco.papCreate and closure capture
oracle: No i1 in closure capture; bitmaps match normalized SSA types.
--
--
name: Closure application preserves captured representation
phase: cross-phase
invariants: REP_CLOSURE_002
ir: eco.papExtend ops
logic: Verify captured value representation is preserved across partial application:
  * Captured unboxed fields remain unboxed.
  * Captured boxed values remain !eco.value.
  * Bitmap merging is performed by runtime.
inputs: MLIR with partial applications
oracle: No representation change during closure extension.
--
--
name: Well-known constants are embedded HPointers
phase: runtime heap
invariants: REP_CONSTANT_001
ir: Unit, True, False, Nil, Nothing, EmptyString, EmptyRec
logic: Verify these constants:
  * Are represented as HPointer values with nonzero constant bits.
  * Are never heap allocated.
  * GC and debug logic treat them as non-heap.
inputs: Runtime constant handling
oracle: Constants are embedded; no heap allocation for them.
--
--
name: eco.value may be heap pointer or embedded constant
phase: cross-phase
invariants: REP_CONSTANT_002
ir: !eco.value SSA values
logic: Verify codegen, GC, and runtime rely on HPointer constant bits (not pointer range checks) to distinguish heap pointers from embedded constants.
inputs: Runtime pointer classification
oracle: HPointer constant bits are the sole discriminator.
--

---

## Canonicalization Phase (CANON_*)

--
name: Global names are fully qualified
phase: canonicalization
invariants: CANON_001
ir: Canonical AST
logic: For every non-local variable reference (VarForeign, VarKernel, VarCtor, VarOperator, top-level Var), assert its `home` is an `IO.Canonical` referring to a defined module; assert local variables are always `VarLocal` and never carry `home`.
inputs: Canonicalized modules (from source and synthetic Canonical ASTs)
oracle: Environment lookup using `home` must succeed; any global without `home` or any local with `home` fails.
--
--
name: Expression IDs are unique and non-negative
phase: canonicalization
invariants: CANON_002
ir: Canonical AST
logic: Walk all expressions and patterns, collect `ExprInfo.id` values into a map; assert all IDs are >= 0 and no duplicates exist. Also assert that constructors that bypass ID allocation (if any) only produce negative placeholder IDs.
inputs: Canonicalized modules
oracle: No missing or duplicate non-negative IDs; all construction sites observed to call `Ids.allocId` in instrumentation builds.
--
--
name: No duplicate top-level declarations
phase: canonicalization
invariants: CANON_003
ir: Source module -> Canonicalization errors
logic: Generate modules with intentional duplicate value, type, ctor, binop, and export names; run canonicalization and assert it produces `DuplicateDecl`, `DuplicateType`, `DuplicateCtor`, `DuplicateBinop`, or `ExportDuplicate` errors as appropriate. Also generate nested scopes with shadowing to ensure `Shadowing` errors are emitted and correctly localized.
inputs: Source IR modules
oracle: Specific error constructors occur for each duplicate scenario; no module with duplicates canonicalizes successfully.
--
--
name: Imports resolve to valid interfaces
phase: canonicalization
invariants: CANON_004
ir: Source module -> Canonicalization errors
logic: Build interface maps with/without specific modules and exposed symbols. Run `Foreign.createInitialEnv` and canonicalization; verify that:
  * Valid imports resolve and populate the environment.
  * Missing modules yield `ImportNotFound`.
  * Missing exposed values/types/ctors/operators yield `ImportExposingNotFound`.
  * Ambiguous imports between multiple modules produce the corresponding `Ambiguous*` errors.
inputs: Source IR modules plus synthetic interface maps
oracle: Every import reference either resolves uniquely or yields the exact expected error kind.
--
--
name: Dependency SCCs detect recursion correctly
phase: canonicalization
invariants: CANON_005
ir: Canonical module dependency graph
logic: For a variety of modules, build the value dependency graph, run `Graph.stronglyConnComp`, and:
  * Verify SCC grouping matches direct dependencies (unit tests).
  * Create non-terminating recursive definitions and mutually recursive groups; assert canonicalization reports `RecursiveDecl` or `RecursiveLet`.
  * Create legal recursion (e.g. functions using themselves in arguments) and assert they are grouped but not rejected.
inputs: Source IR modules compiled to Canonical
oracle: SCC partitions are deterministic and error classification between legal recursion and non-terminating cycles is correct.
--
--
name: Cached type info for special vars and patterns
phase: canonicalization
invariants: CANON_006
ir: Canonical AST
logic: For nodes VarForeign, VarCtor, VarDebug, VarOperator, and Binop, and patterns PCtor / PatternCtorArg:
  * Assert their cached `Can.Annotation` / `Can.Type` fields are present and consistent with the canonical type environment.
  * Randomly pick such nodes, recompute types via interface lookup, and compare with cached types.
inputs: Canonical AST from real and synthetic modules
oracle: No mismatch between cached types and environment-derived types; missing caches fail the test.
--

---

## Type Checking Phase (TYPE_*)

--
name: Constraints cover all reachable declarations
phase: type checking
invariants: TYPE_001
ir: Canonical module -> Constraint tree
logic: Traverse canonical declarations, effects, expressions, and patterns; mark reachable nodes. After constraint generation (erased and typed), traverse the constraint tree and mark nodes back. Assert every reachable node has corresponding constraints.
inputs: Canonical modules (large plus synthetic edge cases)
oracle: No reachable AST node is missing from constraints; dead/unreachable parts may be exempt by design and documented.
--
--
name: Unification failures become type errors
phase: type checking
invariants: TYPE_002
ir: Constraints -> Solver result
logic: Craft constraints with known conflicting types (e.g., unify Int and String). Run solver and:
  * Assert union-find still satisfies consistency invariants (no inconsistent parents).
  * Assert a `Type.Error` is produced and the final result surfaces as `BadTypes`.
  * Assert there is no path where inconsistencies are silently dropped.
inputs: Synthetic constraint trees and real bad-typed source programs
oracle: Every unification failure corresponds to a recorded error and a failing solve; no inconsistent environment accepted.
--
--
name: NodeTypes map covers all non-negative IDs
phase: type checking
invariants: TYPE_003
ir: NodeTypes / ExprTypes map
logic: After `Solve.runWithIds`, compute the set of all expression/pattern IDs >= 0 that were recorded via NodeIds during constraint generation. Assert:
  * Each such ID exists in NodeTypes with a canonical type.
  * Negative placeholder IDs are absent.
inputs: Type-checked modules with varied size and nested patterns
oracle: Bijective mapping between collected IDs and NodeTypes keys for non-negative IDs.
--
--
name: Occurs check forbids infinite types
phase: type checking
invariants: TYPE_004
ir: Solver unification
logic: Force scenarios where a type variable must unify with a structure containing itself (e.g., `a ~ List a` or recursive record types). Assert `Compiler.Type.Occurs` triggers and the solver records a type error. Verify that no infinite type is present in NodeTypes or final schemes.
inputs: Synthetic constraints and ill-typed source programs
oracle: Infinite-type attempts always yield a type error; inspector utilities never see cyclic type structures.
--
--
name: Rank-based let-polymorphism is enforced
phase: type checking
invariants: TYPE_005
ir: Solver state (ranks and generalization)
logic: Construct nested lets that should or should not generalize (e.g., classic ML rank examples, value restriction style cases). Inspect rank pools:
  * Ensure only variables at the correct rank are quantified.
  * Younger variables are frozen or promoted according to rules.
  * Unsound polymorphism across scopes does not appear in inferred schemes.
inputs: Source IR with polymorphic lets; synthetic solver setups
oracle: Resulting type schemes match expected rank-based polymorphism; attempts to exploit unsound generalization fail.
--
--
name: Annotations are enforced, not ignored
phase: type checking
invariants: TYPE_006
ir: Constraints with annotations
logic: For expressions with explicit annotations:
  * Generate matching and intentionally mismatched annotations.
  * Ensure constraints require equality between annotated and inferred types.
  * Any mismatch must produce a Type.Error (BadTypes) and not be silently coerced.
inputs: Annotated source IR programs
oracle: All valid annotations succeed; all intentional mismatches are rejected with precise error location.
--

---

## Nitpick Phase (NITPICK_*)

--
name: Case expressions are exhaustive
phase: nitpick
invariants: NITPICK_001
ir: Canonical case expressions
logic: After Nitpick phase:
  * Assert all possible values of scrutinee type are covered by at least one pattern.
  * Generate cases with missing patterns; verify `InexhaustivePatterns` errors are reported.
  * Downstream phases can assume case expressions always match exactly one alternative.
inputs: Canonical modules with case expressions
oracle: Missing patterns are reported; exhaustive cases pass.
--

---

## Post-Solve Phase (POST_*)

--
name: Group B expressions get structural types
phase: post-solve
invariants: POST_001
ir: PostSolve NodeTypes
logic: Identify Group B expressions (lists, tuples, records, units, lambdas) whose pre-PostSolve solver types include unconstrained synthetic variables. After PostSolve:
  * Assert those entries are replaced with concrete `Can.Type` structures.
  * Reconstruct the type structurally from subexpression types and compare to PostSolve's result.
inputs: TypedCanonical + pre-/post-PostSolve NodeTypes snapshots + syntheticExprIds from constraint generation
oracle: No Group B expression retains an unconstrained synthetic var; recomputed structural type matches PostSolve's.
tests: compiler/tests/Compiler/Type/PostSolve/PostSolveGroupBStructuralTypesTest.elm
--
--
name: Kernel function types inferred from usage
phase: post-solve
invariants: POST_002
ir: KernelTypeEnv
logic: Build modules with kernel alias definitions referencing `VarKernel` and various usage forms (calls, ctors, binops, case branches). Run PostSolve and:
  * Verify the seeding from aliases.
  * Trace first-usage-wins scheme-to-type unification and confirm the resulting `KernelTypeEnv` matches the observed usage patterns.
inputs: Canonical modules with kernels; synthetic kernel-heavy modules
oracle: Each (home, name) kernel pair has a consistent canonical function type; conflicting usages surface as bugs, not silent merges.
--
--
name: No unconstrained synthetic variables remain after PostSolve
phase: post-solve
invariants: POST_003
ir: Fixed NodeTypes
logic: Scan NodeTypes for non-kernel expressions after PostSolve:
  * Assert all types contain no unconstrained synthetic vars.
  * For any placeholder kind that remain by design (kernel-related), assert they're limited to kernel expressions.
  * Use syntheticExprIds from constraint generation to identify which TVars were solver-allocated placeholders.
inputs: PostSolve NodeTypes maps from many modules + syntheticExprIds from constraint generation
oracle: NodeTypes is fully concrete for non-kernel expressions; any remaining synthetic variables are flagged as a violation.
tests: compiler/tests/Compiler/Type/PostSolve/PostSolveNoSyntheticHolesTest.elm
--
--
name: PostSolve is deterministic for Group B and kernels
phase: post-solve
invariants: POST_004
ir: NodeTypes + KernelTypeEnv
logic: Given the same canonical module and initial solver-produced NodeTypes:
  * Run PostSolve multiple times and on different machines/build variants.
  * Assert the resulting fixed NodeTypes and KernelTypeEnv are byte-for-byte identical (or structurally equal).
inputs: Saved canonical + pre-PostSolve NodeTypes; replay tests
oracle: No nondeterminism in PostSolve outputs; hashed summaries remain stable across runs.
--
--
name: PostSolve does not rewrite solver-structured node types
phase: post-solve
invariants: POST_005
ir: Solver NodeTypes (pre-PostSolve) vs PostSolve NodeTypes (post-PostSolve)
logic:
  * Run Solve.runWithIds to obtain nodeTypesPre.
  * Run PostSolve.postSolve to obtain nodeTypesPost.
  * Traverse the canonical module to classify node ids (VarKernel, Accessor, other).
  * For each node id >= 0 that is not VarKernel:
      - if nodeTypesPre[id] is NOT a bare TVar, assert nodeTypesPost[id] is alpha-equivalent to nodeTypesPre[id].
inputs: Canonical module + (annotations, nodeTypesPre) + nodeTypesPost
oracle: PostSolve only fills placeholder TVars; it never changes already-structured solver types.
tests: compiler/tests/Compiler/Type/PostSolve/PostSolveNonRegressionInvariantsTest.elm
--
--
name: PostSolve does not introduce new free type variables
phase: post-solve
invariants: POST_006
ir: Solver NodeTypes (pre-PostSolve) vs PostSolve NodeTypes (post-PostSolve)
logic:
  * Using the same nodeTypesPre/nodeTypesPost:
  * For each node id >= 0 that is neither VarKernel nor Accessor:
      - compute freeVars(preType) and freeVars(postType)
      - assert freeVars(postType) ⊆ freeVars(preType)
inputs: Canonical module + nodeTypesPre + nodeTypesPost
oracle: PostSolve cannot make a node more polymorphic than what the solver inferred.
tests: compiler/tests/Compiler/Type/PostSolve/PostSolveNonRegressionInvariantsTest.elm
--

---

## Typed Optimization Phase (TOPT_*)

--
name: TypedOptimized expressions always carry types
phase: typed optimization
invariants: TOPT_001
ir: TypedOptimized.Expr
logic: For each `TypedOptimized.Expr` variant:
  * Assert the last constructor argument is a `Can.Type`.
  * Implement `typeOf` via pattern-match, and test that for all expressions (after optimization), `typeOf` returns that last field.
inputs: TypedOptimized modules (from varied sources)
oracle: No expression constructor missing a trailing type; `typeOf` is total and returns the stored type.
--
--
name: Pattern matches compile to exhaustive decision trees
phase: typed optimization
invariants: TOPT_002
ir: TypedOptimized.Decider trees
logic: Compare source pattern matches to generated `Decider` trees:
  * Assert no nested patterns remain in the IR; all operate via flat bindings and destructor paths.
  * Run an independent exhaustiveness checker on the decider trees and compare with earlier pattern check results.
inputs: TypedCanonical + TypedOptimized; pattern-rich programs
oracle: Trees are structurally pattern-free, exhaustive, and behavior-equivalent to original matches.
--
--
name: Top-level annotations preserved in local graph
phase: typed optimization
invariants: TOPT_003
ir: TOpt.LocalGraphData
logic: For each top-level definition:
  * Compare its type scheme from type checking with the corresponding entry in `Annotations` inside `LocalGraphData`.
  * Assert every top-level name present in the module exists in the Annotations dict with identical scheme.
inputs: TypedOptimized modules
oracle: No missing or altered top-level schemes; later passes never need to re-run inference.
--
--
name: Typed optimization is type preserving
phase: typed optimization
invariants: TOPT_004
ir: TypedCanonical.Expr vs TypedOptimized.Expr types
logic: For transformations (inlining, DCE, case-to-decision-tree, etc.):
  * For each optimized expression, derive its expected type from the input TypedCanonical or NodeTypes.
  * Check that the stored `Can.Type` on TOpt.Expr matches that expected type via simple local rules (function arg/result, call result, etc.).
inputs: Pairs of TypedCanonical and TypedOptimized IR
oracle: Types attached to optimized expressions are always equal (alpha-equivalent) to the inferred types.
--
--
name: Function expressions encode full function type
phase: typed optimization
invariants: TOPT_005
ir: TypedOptimized function expressions
logic: For every function expression in TypedOptimized:
  * Extract its parameter `(Name, Can.Type)` list and result `Can.Type`.
  * Compute the corresponding curried TLambda chain.
  * Assert that the expression's own attached `Can.Type` equals that TLambda type.
inputs: TypedOptimized modules with varied arities and partial applications
oracle: Function types are internally consistent; arity and parameter/result types always match the TLambda-encoded type.
--

---

## Monomorphization Phase (MONO_*)

--
name: MonoType encodes fully elaborated runtime shapes
phase: monomorphization
invariants: MONO_001
ir: MonoType
logic: Inspect MonoTypes in the monomorphized IR:
  * Confirm that source-level types are represented as `MInt`, `MFloat`, `MList`, `MTuple`, `MRecord`, `MCustom`, or `MFunction`.
  * Confirm the only remaining generic vars are `MVar` with an attached `Constraint` (`CEcoValue` or `CNumber`, etc.).
inputs: Monomorphized graphs from typed modules
oracle: No other kind of partially inferred or unspecialized type representation survives at this phase.
--
--
name: No CNumber MVar at MLIR codegen entry
phase: monomorphization
invariants: MONO_002
ir: MonoType just before MLIR codegen
logic: At the boundary to MLIR generation, traverse all reachable MonoTypes and assert:
  * No `MVar` has a `CNumber` constraint.
  * Any such occurrence is reported as a compiler bug in tests.
inputs: Monomorphized graphs (including stress-randomized ones)
oracle: All numeric polymorphism is fully resolved; remaining MVars are non-numeric only.
--
--
name: CEcoValue MVars do not affect layout
phase: monomorphization
invariants: MONO_003
ir: MonoType, layout structures
logic: For every `MVar` with `CEcoValue`:
  * Check that its usage appears only in positions that do not impact layout/calling convention (e.g., ECO-only metadata).
  * Assert that record/tuple/ctor layouts and MLIR signatures are identical under any substitution of concrete source types for those vars.
inputs: Monomorphized graphs and corresponding layouts/signatures
oracle: Changing CEcoValue type arguments does not change runtime layout or calling convention; tests via differential substitution.
--
--
name: All functions are callable MonoNodes
phase: monomorphization
invariants: MONO_004
ir: MonoGraph nodes
logic: For each `MonoNode` whose `MonoType` is a function:
  * Assert the node variant is either `MonoTailFunc` or `MonoDefine` whose expression is `MonoClosure`.
  * Assert there are no function-typed nodes lacking an implementation or with incompatible constructors.
inputs: Monomorphized graphs
oracle: Every function type corresponds to an actually callable implementation; no orphan function types.
--
--
name: Specialization registry is complete and consistent
phase: monomorphization
invariants: MONO_005
ir: SpecializationRegistry + MonoGraph
logic: For each entry in `SpecializationRegistry` (keyed by Global + MonoType + LambdaId):
  * Assert it maps to a unique `SpecId`.
  * Assert each `SpecId` used in `MonoVarGlobal` refers to an existing `MonoNode`.
  * Assert there are no registry entries that are never referenced.
inputs: Monomorphized graphs with heavy polymorphism
oracle: 1-1 mapping between specializations and nodes; no missing or orphan specs.
--
--
name: Record and tuple layouts capture shape completely
phase: monomorphization
invariants: MONO_006
ir: RecordLayout, TupleLayout
logic: For every record/tuple type:
  * Inspect the associated layout's `fieldCount`, `indices`, and `unboxedBitmap`.
  * Reconstruct the logical field order and unboxing decisions from source types and compare.
inputs: Monomorphized graphs and layouts
oracle: Layout metadata matches the exact logical record/tuple structure; indices and unboxing flags are correct.
--
--
name: Record access matches layout metadata
phase: monomorphization
invariants: MONO_007
ir: MonoRecordAccess / MonoRecordUpdate
logic: For each record field access/update:
  * Use the record value's MonoType to find its `RecordLayout`.
  * Verify the field index and `isUnboxed` flag used in the IR matches the layout's metadata.
inputs: Monomorphized graphs
oracle: No mismatch between record access operations and layout definitions.
--
--
name: Primitive numeric types are fixed in calls
phase: monomorphization
invariants: MONO_008
ir: Function call specializations
logic: At each specialized function call:
  * Unify the canonical function type with monomorphic argument MonoTypes.
  * Assert all primitive numeric types are concretely `MInt` or `MFloat`.
  * If a mismatch is detected, classify as a monomorphization bug and treat as test failure.
inputs: Monomorphized graphs with numeric polymorphism
oracle: No unresolved or inconsistent numeric type at call sites.
--
--
name: Debug kernel calls remain polymorphic with CEcoValue
phase: monomorphization
invariants: MONO_009
ir: MonoType for Debug calls
logic: Identify polymorphic Debug kernel calls:
  * Check that monomorphization applies an empty substitution to keep type variables as `MVar`.
  * Assert those MVars always carry `CEcoValue` constraint and do not show up in layout-influencing positions.
inputs: Programs using Debug.* with polymorphic arguments
oracle: Debug calls retain polymorphic MonoTypes; only CEcoValue constraints appear.
--
--
name: MonoGraph is type complete
phase: monomorphization
invariants: MONO_010
ir: MonoGraph
logic: Traverse the entire MonoGraph:
  * Assert every referenced MonoType is present and fully elaborated (no dangling references).
  * Ensure ctorLayouts for custom types include all constructors and their types.
inputs: Large monomorphized graphs
oracle: There are no missing type definitions; MonoGraph fully describes program types and constructors.
--
--
name: MonoGraph is closed and hygienic
phase: monomorphization
invariants: MONO_011
ir: MonoGraph
logic: For each local/global variable and specialization:
  * Check every `MonoVarLocal` resolves to a binder in its lexical region:
      - Parameters of the enclosing closure or tail function
      - Destruct bindings (MonoDestruct)
      - Local value definitions (MonoLet), treating any contiguous chain of
        nested MonoLets as a single mutually visible scope.
      - Forward references within such a MonoLet chain are allowed.
  * Check every `MonoVarGlobal` and `SpecId` refer to existing MonoNodes.
  * Detect unreachable `SpecId`s and ensure they're either optimized away or flagged.
inputs: Monomorphized graphs including randomized stress graphs
oracle: No dangling references, no undefined globals, no unreachable specs in the registry.
note: Typed optimization and monomorphization encode `let rec` groups as nested
  `MonoLet` expressions. At Mono level, scoping for such chains is *mutual*, not
  sequential: all definitions in a contiguous `MonoLet` chain are considered in
  scope for each other's bodies and for the chain's final body. MONO_011 enforces
  that every `MonoVarLocal` is backed by some binder in this sense, rather than
  enforcing source-level sequential-let rules.
--
--
name: Function arity matches parameters and closure info
phase: monomorphization
invariants: MONO_012
ir: MonoNodes with function types
logic: For each function/closure node:
  * Compare the function MonoType's arity with the parameter list length and closure bindings.
  * Verify each call site's argument count matches the function's MonoType (allowing partial application where supported).
inputs: Monomorphized graphs with varied arities and partial applications
oracle: All call sites are well-formed w.r.t. MonoType; no over/under-application.
--
--
name: Constructor layouts define consistent custom types
phase: monomorphization
invariants: MONO_013
ir: CtorLayout and custom nodes
logic: For each custom type and each constructor:
  * Verify `CtorLayout` field count and ordering match the constructor definition.
  * Assert `unboxedBitmap` matches which fields are unboxed primitives.
  * Check all construction and pattern matching nodes adhere to the same layout.
inputs: Monomorphized graphs with many custom types
oracle: No discrepancy between constructor use sites and their layouts.
--
--
name: Structurally equivalent layouts are canonical
phase: monomorphization
invariants: MONO_014
ir: RecordLayout / TupleLayout
logic: Search for record/tuple types that are structurally equivalent (same fields and unboxing decisions):
  * Check they either share the same layout identifier or produce layouts whose `indices` and `unboxedBitmap` are identical.
inputs: Monomorphized graphs with many similar record/tuple types
oracle: No spurious duplication of equivalent layouts; layout metadata is canonicalized.
--
--
name: Accessor extension variables are unified with full record type
phase: monomorphization
invariants: MONO_015
ir: Accessor function specializations
logic: When an accessor like `.name` with canonical type `{ ext | name : T } -> T` is passed as a first-class function:
  * Assert the extension variable `ext` is unified with the full record type from the call site.
  * Verify specialization receives the complete record layout, not just explicitly named fields.
inputs: Programs passing accessors as first-class functions
oracle: Accessor specializations have complete record layouts; no partial layouts.
--
--
--
name: Registry type matches node type
phase: monomorphization
invariants: MONO_017
ir: MonoGraph (nodes + registry)
logic: For each entry in registry.reverseMapping:
  * Get (specId -> (global, regMonoType, maybeLambda))
  * Look up node at graph.nodes[specId]
  * If node not found: violation (orphan registry entry)
  * Otherwise: assert regMonoType == nodeType(node)
  * nodeType extracts the MonoType from any MonoNode variant
inputs: Monomorphized graphs
oracle: Every registry entry's MonoType matches the corresponding node's type.
tests: compiler/tests/Compiler/Generate/Monomorphize/RegistryNodeTypeConsistencyTest.elm
--
--
name: MonoCase branches match case result type
phase: monomorphization
invariants: MONO_018
ir: MonoCase expressions
logic: For every MonoCase _ _ decider jumps resultType:
  * For each (idx, branchExpr) in jumps:
      Assert Mono.typeOf branchExpr == resultType
  * Walk the decider tree:
      For each Leaf (Inline expr): Assert Mono.typeOf expr == resultType
      For each Leaf (Jump idx): No check needed (checked via jumps)
  * Recursively check all sub-expressions in the MonoGraph
inputs: Monomorphized graphs
oracle: MonoCase resultType agrees with the types of all branch expressions.
tests: compiler/tests/TestLogic/Monomorphize/MonoCaseBranchResultTypeTest.elm
--
--
name: Lambda IDs are unique within graph
phase: monomorphization
invariants: MONO_019
ir: MonoGraph (all MonoClosure and MonoTailFunc nodes)
logic: Collect all lambdaId values from:
  * closureInfo.lambdaId in MonoClosure expressions
  * Any lambdaId in related structures
Assert the collected set has no duplicates.
inputs: Monomorphized graphs with many closures
oracle: Every closure/function has a unique lambdaId.
tests: compiler/tests/TestLogic/Monomorphize/LambdaIdUniquenessTest.elm
--

---

## Global Optimization Phase (GOPT_*)

--
name: Closure params match stage arity
phase: global optimization
invariants: GOPT_001
ir: MonoClosure after GlobalOpt
logic: For every MonoClosure with MFunction type after GlobalOpt:
  * Compute stageArity = length of outermost MFunction param list
  * Assert length(closureInfo.params) == stageArity
  * Established by canonicalizeClosureStaging in GlobalOpt
inputs: GlobalOpt output graphs
oracle: All closures have param counts matching their stage arity.
tests: compiler/tests/TestLogic/GlobalOpt/ClosureStageArityTest.elm
--
--
name: Returned closure param counts tracked
phase: global optimization
invariants: GOPT_002
ir: MonoGraph.returnedClosureParamCounts
logic: For every function that returns a closure:
  * The returnedClosureParamCounts map entry equals the first-stage parameter count
  * Computed by computeReturnedClosureParamCount after ABI normalization
inputs: GlobalOpt output graphs
oracle: Map is complete for all closure-returning functions.
tests: NOT YET IMPLEMENTED
--
--
name: Case/if branches have compatible staging
phase: global optimization
invariants: GOPT_003
ir: MonoCase, MonoIf after normalizeCaseIfAbi
logic: For every MonoCase and MonoIf returning function types after GlobalOpt:
  * All branch result types have identical staging signatures
  * Non-conforming branches were wrapped via buildAbiWrapperGO
  * This extends MONO_018 (type equality) to include staging equality
inputs: GlobalOpt output with function-returning cases
oracle: All branches unify to a common staging; no ABI mismatches.
tests: compiler/tests/TestLogic/GlobalOpt/CaseBranchStagingTest.elm
--
--
name: No placeholder CallInfo after GlobalOpt
phase: global optimization
invariants: GOPT_010
ir: MonoCall expressions
logic: Walk all MonoCall expressions in the optimized graph:
  * Assert callInfo does not equal defaultCallInfo
  * defaultCallInfo has stageArities=[] and initialRemaining=0
  * Every call site must have a computed CallInfo reflecting staging decisions
inputs: GlobalOpt output graphs
oracle: Every MonoCall has computed CallInfo; no placeholders remain.
tests: compiler/tests/TestLogic/GlobalOpt/CallInfoCompleteTest.elm
--
--
name: StageCurried stageArities is non-empty and positive
phase: global optimization
invariants: GOPT_011
ir: CallInfo in MonoCall
logic: For every MonoCall with callModel == StageCurried:
  * Assert stageArities is non-empty
  * Assert all elements in stageArities are positive integers
inputs: GlobalOpt output graphs
oracle: StageCurried calls always have valid stage arities.
tests: compiler/tests/TestLogic/GlobalOpt/CallInfoCompleteTest.elm
--
--
name: stageArities sum equals flattened arity
phase: global optimization
invariants: GOPT_012
ir: CallInfo in MonoCall
logic: For every MonoCall with StageCurried callModel:
  * Compute sum = List.sum callInfo.stageArities
  * Compute flattenedArity = total params in flattened MFunction type
  * Assert sum == flattenedArity
inputs: GlobalOpt output graphs with various function arities
oracle: Stage groupings cover exactly all function parameters.
tests: compiler/tests/TestLogic/GlobalOpt/CallInfoCompleteTest.elm
--
--
name: PAP remaining-arity semantics
phase: global optimization
invariants: GOPT_013
ir: CallInfo in MonoCall for partial applications
logic: For StageCurried calls creating/extending PAPs:
  * Assert callInfo.initialRemaining == List.sum callInfo.remainingStageArities
  * remainingStageArities contains arities of unsatisfied stages
  * Example: stageArities=[2,3], argCount=2 -> remainingStageArities=[3], initialRemaining=3
inputs: GlobalOpt graphs with partial applications
oracle: initialRemaining correctly reflects unsatisfied stages.
tests: compiler/tests/TestLogic/GlobalOpt/CallInfoCompleteTest.elm
--
--
name: isSingleStageSaturated semantics
phase: global optimization
invariants: GOPT_014
ir: CallInfo in MonoCall
logic: Assert callInfo.isSingleStageSaturated is true iff:
  * This call does not create/extend a PAP for the current stage
  * Equivalently: argCount >= stageArities[0]
inputs: GlobalOpt graphs with various call patterns
oracle: Flag correctly identifies single-stage saturation.
tests: compiler/tests/TestLogic/GlobalOpt/CallInfoCompleteTest.elm
--
--
name: FlattenedExternal has no staged currying
phase: global optimization
invariants: GOPT_015
ir: CallInfo in MonoCall for kernel/extern calls
logic: For every MonoCall with callModel == FlattenedExternal:
  * Assert stageArities == []
  * Assert remainingStageArities == []
  * Assert initialRemaining == 0
  * MLIR treats such calls as flat ABI calls
inputs: GlobalOpt graphs with kernel calls
oracle: Kernel calls have empty stage information.
tests: compiler/tests/TestLogic/GlobalOpt/CallInfoCompleteTest.elm
--
--
name: ABI wrapper nested calls respect segmentation
phase: global optimization
invariants: GOPT_016
ir: Wrapper closures created by buildAbiWrapperGO/buildNestedCallsGO
logic: When ABI normalization creates wrapper closures that call functions with multi-stage types:
  * Get the callee's segmentation via Mono.segmentLengths (Mono.typeOf callee)
  * For each segment length m in the segmentation:
    - A MonoCall passes exactly m arguments to the current callee
    - The result of that call becomes the callee for the next stage
  * No MonoCall in a wrapper chain passes more arguments than its stage accepts
  * Example: For callee with segmentation [2,3] called with params [a,b,c,d,e]:
    - First call: callee(a,b) -> intermediate with segment [3]
    - Second call: intermediate(c,d,e) -> result
inputs: N/A (verified by construction)
oracle: Wrapper nested calls match callee segmentation exactly; no over-application at any stage.
verification: structural (by construction in buildNestedCallsGO; indirectly verified via CallInfo invariants GOPT_010-015)
--

---

## MLIR Codegen Phase (CGEN_*)

--
name: Boxing only between primitives and eco.value
phase: MLIR codegen
invariants: CGEN_001
ir: Generated MLIR for boxing/unboxing
logic: Inspect MLIR for boxing/unboxing operations:
  * Assert they only convert between primitive MLIR types (i64, f64, i16) and `!eco.value`.
  * Any conversion between mismatched primitives (e.g., i64 <-> f64) is reported as a monomorphization bug for test purposes.
inputs: MLIR from a variety of programs, especially numeric ones
oracle: All boxing/unboxing edges are primitive <-> eco.value; no primitive <-> different-primitive patches.
--
--
name: Partial applications routed through closure generation
phase: MLIR codegen
invariants: CGEN_002
ir: Generated calls in MLIR
logic: For each call where the result MonoType is still a function:
  * Assert `generateCall` routes it to closure generation and emits `eco.papExtend` instead of a direct call.
  * Verify the resulting MLIR function type matches the expected partially applied type.
inputs: Programs with many partial applications
oracle: No direct calls producing function-typed results; all partials go through closure machinery.
--
--
name: Closure ops compute unboxed bitmaps from SSA types
phase: MLIR codegen
invariants: CGEN_003
ir: eco.papCreate, eco.papExtend ops
logic: For closure partial application and application ops:
  * Compute unboxed bitmaps solely from SSA operand MLIR types after closure-boundary normalization.
  * Only unboxable primitives (i64, f64, i16) are marked unboxed.
  * Bool (i1) and all other operands must be treated as !eco.value.
  * Assert `_operand_types`, `unboxed_bitmap`, and `newargs_unboxed_bitmap` exactly match SSA operand types and layout.
inputs: Monomorphized programs using closures
oracle: Bitmaps match SSA types; no i1 in closure captures; attributes consistent with runtime expectations.
tests: compiler/tests/Compiler/Generate/CodeGen/UnboxedBitmapTest.elm
--
--
name: Destruct paths follow destructor MonoType
phase: MLIR codegen
invariants: CGEN_004
ir: MLIR destruct and eco.project usage
logic: For each destruct operation:
  * Confirm `generateDestruct` and `generateMonoPath` use the destructor's MonoType to determine the path target MLIR type.
  * Assert they do not use the body result type in that computation.
inputs: Programs with complex destructuring
oracle: Destruct results have their natural type; no unintended unboxing or type mismatch.
tests: NOT YET IMPLEMENTED
--
--
name: Heap projection respects layout bitmap
phase: MLIR codegen
invariants: CGEN_005
ir: generateMonoPath and eco.project ops
logic: For generateMonoPath projecting heap fields into SSA operands:
  * If the heap layout bitmap marks the field unboxed -> result is immediate SSA operand.
  * Otherwise -> result is !eco.value.
inputs: MLIR with record/tuple/custom field projections
oracle: eco.project results match heap layout bitmap; no incorrect unboxing.
--
--
name: Let bindings preserve representation
phase: MLIR codegen
invariants: CGEN_006
ir: MLIR let bindings / SSA values
logic: Inspect MLIR generated for `generateLet`:
  * Check that SSA values bound to let names have the same MLIR type as the defining expression.
  * Confirm no spurious `eco.construct` wrapping is introduced solely by let binding.
inputs: MLIR from programs with nested lets and various boxed/unboxed values
oracle: Let-bindings are representation-transparent; type and representation are identical pre/post binding.
--
--
name: Argument boxing only adjusts eco.value vs unboxed
phase: MLIR codegen
invariants: CGEN_007
ir: MLIR calls and boxing helpers
logic: For calls where `boxToMatchSignature` / `boxToMatchSignatureTyped` are invoked:
  * Compare actual SSA operand types with `monoTypeToMlir` of expected MonoTypes.
  * Ensure the only adjustments are between boxed (`!eco.value`) and corresponding unboxed primitives.
  * No primitive kind changes (i64 <-> f64) are introduced.
inputs: MLIR with mixed boxed/unboxed call arguments
oracle: Adjustments are limited to boxing; primitive kinds stay identical.
--
--
name: _operand_types exactly match SSA operand types
phase: MLIR codegen
invariants: CGEN_008
ir: eco.construct / eco.project / eco.call / eco.return ops
logic: For each of these ops:
  * Capture the SSA operand types.
  * Compare with `_operand_types` attribute list.
  * Assert exact one-to-one type equality and order.
inputs: Generated MLIR modules
oracle: No divergence between operand types and recorded attributes.
tests: compiler/tests/Compiler/Generate/CodeGen/OperandTypesAttrTest.elm
--
--
name: Boolean constants use !eco.value except in control-flow
phase: MLIR codegen
invariants: CGEN_009
ir: MLIR boolean values
logic: Boolean constants:
  * May appear as i1 immediate SSA operands only in control-flow contexts (case scrutinees).
  * Are otherwise represented as !eco.value constants at ABI, heap, and closure boundaries.
inputs: MLIR with boolean operations and constants
oracle: i1 only in control-flow; !eco.value elsewhere for Bool.
--
--
name: eco.case is SSA value-producing with eco.yield
phase: MLIR codegen
invariants: CGEN_010
ir: eco.case ops
logic: For each `eco.case`:
  * Verify it has explicit MLIR result types on the op itself (not via result_types/caseResultTypes attribute).
  * Verify every alternative region terminates with `eco.yield`.
  * Verify each `eco.yield` operand arity and types exactly match the eco.case result types.
inputs: MLIR for pattern matches and cases
oracle: All eco.case ops produce SSA values; all alternatives end with eco.yield matching result types.
tests: compiler/tests/Compiler/Generate/CodeGen/CaseTerminationTest.elm
--
--
name: All eco.call targets exist as func.func
phase: MLIR codegen
invariants: CGEN_011
ir: MLIR functions and eco.call ops
logic: Use the UndefinedFunction pass or equivalent:
  * Collect all `eco.call` targets.
  * Ensure for each target there is a `func.func` definition or declaration with matching signature.
inputs: Generated MLIR modules
oracle: No undefined function symbols; mismatches are caught and fail tests.
--
--
name: monoTypeToMlir primitive mapping is correct
phase: MLIR codegen
invariants: CGEN_012
ir: MonoType -> MLIR type mapping
logic: For each MonoType:
  * Check that `MInt -> i64`, `MFloat -> f64`, `MChar -> i16`.
  * Assert all other MonoTypes (including MBool, MVar, compound types) map to `!eco.value`.
inputs: Synthetic MonoTypes and integrated MLIR outputs
oracle: Mapping table is complete and consistent; no primitive maps to wrong MLIR type.
--
--
name: CEcoValue MVars always lower to eco.value
phase: MLIR codegen
invariants: CGEN_013
ir: MonoType containing MVar(CEcoValue) -> MLIR types
logic: Identify all MonoType components that are `MVar` with `CEcoValue`:
  * Confirm that their MLIR type is always `!eco.value` in every use.
inputs: MLIR modules derived from CEcoValue-heavy code
oracle: No influence of CEcoValue type vars on MLIR primitive types or layouts; always eco.value.
--
--
name: MLIR uses only MonoGraph ctorLayouts for unions
phase: MLIR codegen
invariants: CGEN_014
ir: MLIR for constructors / pattern matches + MonoGraph.ctorLayouts
logic: For union constructors and matches:
  * Verify codegen uses `MonoGraph.ctorLayouts` for tag, size, and unboxed layout.
  * Ensure no access to GlobalTypeEnv for union metadata during MLIR codegen (enforced via test-only stubbing).
inputs: MLIR and MonoGraph snapshots
oracle: All constructor metadata is sourced from MonoGraph; GlobalTypeEnv reads for unions are absent or unused.
--
--
name: MChar maps to i16
phase: MLIR codegen
invariants: CGEN_015
ir: Char values in MLIR
logic: Assert monoTypeToMlir maps MChar to i16 (Eco_Char), not i32:
  * All codegen char constants and ops must use i16.
inputs: MLIR with char operations
oracle: No i32 for char values; all use i16.
tests: compiler/tests/Compiler/Generate/CodeGen/CharTypeMappingTest.elm
--
--
name: List construction uses eco.construct.list
phase: MLIR codegen
invariants: CGEN_016
ir: List construction ops
logic: List values are constructed:
  * With eco.construct.list for Cons cells.
  * With eco.constant Nil for empty lists.
  * Never with eco.construct.custom.
inputs: MLIR with list operations
oracle: No eco.construct.custom for lists.
tests: compiler/tests/Compiler/Generate/CodeGen/ListConstructionTest.elm
--
--
name: Tuple construction uses dedicated ops
phase: MLIR codegen
invariants: CGEN_017
ir: Tuple construction ops
logic: Tuples are constructed:
  * With eco.construct.tuple2 for 2-tuples.
  * With eco.construct.tuple3 for 3-tuples.
  * Never with eco.construct.custom.
inputs: MLIR with tuple operations
oracle: No eco.construct.custom for tuples.
tests: compiler/tests/Compiler/Generate/CodeGen/TupleConstructionTest.elm
--
--
name: Record construction uses eco.construct.record or eco.constant
phase: MLIR codegen
invariants: CGEN_018
ir: Record construction ops
logic: Records are constructed:
  * With eco.construct.record when field_count is nonzero.
  * With eco.constant EmptyRec for empty records (never heap allocated).
inputs: MLIR with record operations
oracle: Empty records are constants; non-empty use eco.construct.record.
tests: compiler/tests/Compiler/Generate/CodeGen/RecordConstructionTest.elm
--
--
name: Well-known singletons use eco.constant
phase: MLIR codegen
invariants: CGEN_019
ir: Unit, True, False, Nil, Nothing, EmptyString, EmptyRec
logic: These values are always created via eco.constant:
  * Never via eco.construct or allocation.
inputs: MLIR with singleton values
oracle: All singletons are eco.constant.
tests: compiler/tests/Compiler/Generate/CodeGen/SingletonConstantsTest.elm
--
--
name: eco.construct.custom matches CtorLayout
phase: MLIR codegen
invariants: CGEN_020
ir: eco.construct.custom ops
logic: eco.construct.custom is used only for user-defined custom ADTs:
  * Its tag, size, and unboxed_bitmap attributes match CtorLayout from MonoGraph.ctorLayouts.
  * Operand count matches layout.
inputs: MLIR with custom type construction
oracle: Attributes match layout; no mismatched construction.
tests: compiler/tests/Compiler/Generate/CodeGen/CustomConstructionTest.elm
--
--
name: List destructuring uses dedicated projection ops
phase: MLIR codegen
invariants: CGEN_021
ir: List projection ops
logic: List destructuring uses:
  * eco.project.list_head and eco.project.list_tail only.
  * Never eco.project.custom or tuple or record projection ops.
inputs: MLIR with list destructuring
oracle: Only list-specific projection ops for lists.
tests: compiler/tests/Compiler/Generate/CodeGen/ListProjectionTest.elm
--
--
name: Tuple destructuring uses dedicated projection ops
phase: MLIR codegen
invariants: CGEN_022
ir: Tuple projection ops
logic: Tuple destructuring uses:
  * eco.project.tuple2 or eco.project.tuple3 with field index in range.
  * Never eco.project.custom or eco.project.record.
inputs: MLIR with tuple destructuring
oracle: Only tuple-specific projection ops for tuples.
tests: compiler/tests/Compiler/Generate/CodeGen/TupleProjectionTest.elm
--
--
name: Record field access uses eco.project.record
phase: MLIR codegen
invariants: CGEN_023
ir: Record projection ops
logic: Record field access uses:
  * eco.project.record with field_index in range.
  * Never eco.project.custom.
inputs: MLIR with record field access
oracle: Only record projection ops for records.
tests: compiler/tests/Compiler/Generate/CodeGen/RecordProjectionTest.elm
--
--
name: Custom ADT field access uses eco.project.custom
phase: MLIR codegen
invariants: CGEN_024
ir: Custom projection ops
logic: Custom ADT field access uses:
  * eco.project.custom with field_index in range.
  * No other projection op is used for custom ADT fields.
inputs: MLIR with custom type destructuring
oracle: Only eco.project.custom for custom types.
tests: compiler/tests/Compiler/Generate/CodeGen/CustomProjectionTest.elm
--
--
name: All construct ops produce !eco.value
phase: MLIR codegen
invariants: CGEN_025
ir: eco.construct.* ops
logic: All eco.construct.* operations produce !eco.value results:
  * Regardless of whether any fields are stored unboxed.
inputs: MLIR with construction ops
oracle: Result type is always !eco.value.
tests: compiler/tests/Compiler/Generate/CodeGen/ConstructResultTypeTest.elm
--
--
name: Container construct unboxed_bitmap matches SSA types
phase: MLIR codegen
invariants: CGEN_026
ir: eco.construct.tuple2, eco.construct.tuple3, eco.construct.record, eco.construct.custom
logic: For these ops, the unboxed_bitmap is derived solely from SSA operand MLIR types:
  * A bit is set iff the operand MLIR type is i64, f64, or i16.
inputs: MLIR with container construction
oracle: Bitmap bits match operand types exactly.
tests: compiler/tests/Compiler/Generate/CodeGen/UnboxedBitmapTest.elm
--
--
name: List construct head_unboxed matches SSA type
phase: MLIR codegen
invariants: CGEN_027
ir: eco.construct.list ops
logic: For eco.construct.list:
  * head_unboxed is true iff the SSA head operand MLIR type is i64, f64, or i16.
inputs: MLIR with list construction
oracle: head_unboxed matches head operand type.
tests: compiler/tests/Compiler/Generate/CodeGen/UnboxedBitmapTest.elm
--
--
name: eco.case alternatives terminate with eco.yield
phase: MLIR codegen
invariants: CGEN_028
ir: eco.case ops
logic: Every eco.case alternative region:
  * Terminates with eco.yield only.
  * eco.return, eco.jump, eco.crash, and eco.unreachable are forbidden inside eco.case alternatives.
  * No alternative falls through past the end of a region.
inputs: MLIR with case expressions
oracle: All alternatives terminate with eco.yield; no other terminators allowed.
tests: compiler/tests/Compiler/Generate/CodeGen/CaseTerminationTest.elm
--
--
name: eco.case tags array length matches alternatives
phase: MLIR codegen
invariants: CGEN_029
ir: eco.case ops
logic: eco.case tags array length equals the number of alternative regions.
inputs: MLIR with case expressions
oracle: Tag count matches alternative count.
tests: compiler/tests/Compiler/Generate/CodeGen/CaseTagsCountTest.elm
--
--
name: eco.jump targets valid joinpoints
phase: MLIR codegen
invariants: CGEN_030
ir: eco.jump and eco.joinpoint ops
logic: eco.jump target refers to:
  * A lexically enclosing eco.joinpoint with matching id.
  * Jump argument types match the joinpoint block argument types.
inputs: MLIR with joinpoints
oracle: All jumps target valid joinpoints with matching types.
tests: compiler/tests/Compiler/Generate/CodeGen/JumpTargetTest.elm
--
--
name: Joinpoint IDs are unique within func.func
phase: MLIR codegen
invariants: CGEN_031
ir: eco.joinpoint ops
logic: Within a single func.func:
  * Each eco.joinpoint id is unique.
  * No duplicate IDs that could cause ambiguity during lowering.
inputs: MLIR with multiple joinpoints
oracle: All joinpoint IDs are unique within their function.
tests: compiler/tests/Compiler/Generate/CodeGen/JoinpointUniqueIdTest.elm
--
--
name: _operand_types required when operands present
phase: MLIR codegen
invariants: CGEN_032
ir: Ops with operands
logic: _operand_types is required and must match SSA operand types:
  * When an op has one or more operands.
  * May be omitted for zero-operand ops.
inputs: MLIR ops
oracle: _operand_types present and correct when operands exist.
tests: compiler/tests/Compiler/Generate/CodeGen/OperandTypesAttrTest.elm
--
--
name: eco.papCreate has valid arity and captures
phase: MLIR codegen
invariants: CGEN_033
ir: eco.papCreate ops
logic: eco.papCreate requires:
  * arity > 0
  * num_captured equals the number of captured operands
  * num_captured < arity
inputs: MLIR with closure creation
oracle: Arity and capture constraints satisfied.
tests: compiler/tests/Compiler/Generate/CodeGen/PapCreateArityTest.elm
--
--
name: eco.papExtend produces !eco.value result
phase: MLIR codegen
invariants: CGEN_034
ir: eco.papExtend ops
logic: MLIR codegen emits eco.papExtend with !eco.value result type:
  * Produces immediate results only by inserting eco.unbox after papExtend when expected result type is immediate.
inputs: MLIR with closure application
oracle: papExtend always returns !eco.value; unboxing is explicit.
tests: compiler/tests/Compiler/Generate/CodeGen/PapExtendResultTest.elm
--
--
name: eco.papCreate arity matches function parameter count
phase: MLIR codegen
invariants: CGEN_051
ir: eco.papCreate ops
logic: eco.papCreate arity attribute must equal the number of parameters of the referenced function:
  * Build a map from function symbol names to their parameter counts.
  * For each eco.papCreate, look up the function and verify arity matches param count.
  * External kernel functions without definitions are skipped.
inputs: MLIR with closure creation
oracle: papCreate arity equals referenced function parameter count.
tests: compiler/tests/Compiler/Generate/CodeGen/PapArityConsistencyTest.elm
--
--
name: eco.papExtend remaining_arity matches source PAP remaining
phase: MLIR codegen
invariants: CGEN_052
ir: eco.papExtend ops
logic: eco.papExtend remaining_arity must equal the source PAP's remaining arity (before application):
  * Track a map papRemaining from result SSA value → remaining:
    - For eco.papCreate: papRemaining = arity - num_captured (from op attrs).
    - For eco.papExtend: if result still a PAP, papRemaining = remaining_arity - num_new_args.
  * For each eco.papExtend %closure(%args...) { remaining_arity = R }:
    - Look up sourceRemaining = papRemaining[%closure].
    - Require R == sourceRemaining (the source's remaining before this application).
  * Verify: remaining_arity >= num_new_args (no over-application).
inputs: MLIR with closure application
oracle: remaining_arity equals source PAP's remaining; no over-application.
tests: compiler/tests/Compiler/Generate/CodeGen/PapExtendArityTest.elm
--
--
name: eco.yield only in eco.case alternatives
phase: MLIR codegen
invariants: CGEN_053
ir: eco.yield ops
logic: eco.yield may only appear as the terminator of an eco.case alternative region:
  * eco.yield is forbidden in function bodies.
  * eco.yield is forbidden in joinpoint bodies.
  * eco.yield is forbidden in SCF regions.
  * If eco.yield appears outside an eco.case alternative, it is a codegen bug.
inputs: MLIR with eco.yield ops
oracle: All eco.yield ops are inside eco.case alternative regions.
tests: compiler/tests/Compiler/Generate/CodeGen/CaseTerminationTest.elm
--
--
name: eco.return forbidden in eco.case alternatives
phase: MLIR codegen
invariants: CGEN_054
ir: eco.case alternative regions
logic: eco.return is forbidden inside eco.case alternative regions:
  * eco.yield is the only legal case-alternative terminator.
  * This prevents accidental non-local exits from within a value-producing case.
  * eco.return appearing in a case alternative is a codegen bug.
inputs: MLIR with case expressions
oracle: No eco.return ops inside eco.case alternatives.
tests: compiler/tests/Compiler/Generate/CodeGen/CaseTerminationTest.elm
--
--
name: Single eco.type_table per module
phase: MLIR codegen
invariants: CGEN_035
ir: Module structure
logic: Each module has at most one eco.type_table op at module scope.
inputs: MLIR modules
oracle: No duplicate type tables.
tests: compiler/tests/Compiler/Generate/CodeGen/TypeTableUniquenessTest.elm
--
--
name: eco.dbg type IDs reference valid type table entries
phase: MLIR codegen
invariants: CGEN_036
ir: eco.dbg ops
logic: When eco.dbg carries arg_type_ids:
  * Each referenced type id must refer to a valid entry in the module eco.type_table.
inputs: MLIR with debug info
oracle: All type IDs are valid.
tests: compiler/tests/Compiler/Generate/CodeGen/DbgTypeIdsTest.elm
--
--
name: eco.case scrutinee type matches case_kind
phase: MLIR codegen
invariants: CGEN_037, CGEN_043
ir: eco.case ops
logic: Scrutinee representation and case_kind agree:
  * case_kind="bool" requires i1 scrutinee.
  * case_kind="int" requires i64 scrutinee.
  * case_kind="chr" requires i16 (ECO char) scrutinee.
  * case_kind="ctor" requires !eco.value scrutinee.
  * case_kind="str" requires !eco.value scrutinee.
inputs: MLIR with various case kinds
oracle: Scrutinee type matches case_kind.
tests: compiler/tests/Compiler/Generate/CodeGen/CaseScrutineeTypeTest.elm, compiler/tests/Compiler/Generate/CodeGen/CaseKindScrutineeTest.elm
--
--
name: Kernel calls use consistent types across module
phase: MLIR codegen
invariants: CGEN_038
ir: Calls to kernel functions
logic: All calls to the same kernel function name:
  * Use exactly the same MLIR argument and result types across the whole module.
  * Any mismatch is a codegen bug.
inputs: MLIR with kernel calls
oracle: Kernel call types are consistent.
tests: compiler/tests/Compiler/Generate/CodeGen/KernelAbiConsistencyTest.elm
--
--
name: MLIR codegen does not emit allocation ops directly
phase: MLIR codegen
invariants: CGEN_039
ir: MLIR from codegen
logic: MLIR codegen does not emit:
  * eco.allocate, eco.allocate_ctor, eco.allocate_string, eco.allocate_closure.
  * These allocation ops are introduced only by later lowering from eco.construct and related ops.
inputs: MLIR before lowering
oracle: No allocation ops in codegen output.
tests: compiler/tests/Compiler/Generate/CodeGen/NoAllocateOpsTest.elm
--
--
name: _operand_types attribute list matches SSA operand count and types
phase: MLIR codegen
invariants: CGEN_040
ir: Ops with _operand_types
logic: For any operation with _operand_types:
  * Attribute list length equals SSA operand count.
  * Each declared type exactly matches the corresponding SSA operand type (same order).
inputs: MLIR ops
oracle: Perfect correspondence between attribute and SSA types.
tests: compiler/tests/Compiler/Generate/CodeGen/OperandTypeConsistencyTest.elm
--
--
name: Symbol definitions are unique within module
phase: MLIR codegen
invariants: CGEN_041
ir: Module symbol definitions
logic: Within a module:
  * No two func.func operations may have the same sym_name.
  * No two symbol-bearing ops may define the same symbol.
inputs: MLIR modules
oracle: All symbol definitions are unique.
tests: compiler/tests/Compiler/Generate/CodeGen/SymbolUniquenessTest.elm
--
--
name: All blocks end with terminators
phase: MLIR codegen
invariants: CGEN_042
ir: MLIR blocks
logic: Every block in every region:
  * Must end with a terminator operation (eco.return, eco.jump, eco.crash, eco.unreachable, eco.yield, scf.yield, cf.br, cf.cond_br, etc.).
  * Note: eco.case is NOT a terminator; it is a value-producing expression.
  * Each eco.case alternative region must be properly terminated with eco.yield with no fallthrough.
inputs: MLIR from codegen
oracle: All blocks are properly terminated.
tests: compiler/tests/Compiler/Generate/CodeGen/BlockTerminatorTest.elm
--
--
name: eco.call targets exist and are non-stub
phase: MLIR codegen
invariants: CGEN_044
ir: eco.call and func.func ops
logic: Every eco.call callee must:
  * Resolve to an existing func.func symbol in the module (definition or declaration).
  * Not target placeholder/stub implementations when a non-stub implementation is present.
inputs: MLIR with calls
oracle: All calls target valid, non-stub functions.
tests: compiler/tests/Compiler/Generate/CodeGen/CallTargetValidityTest.elm
--
--
name: eco.case is NOT a block terminator (value-producing)
phase: MLIR codegen
invariants: CGEN_045
ir: eco.case ops
logic: eco.case is NOT a block terminator:
  * eco.case may appear mid-block as a value-producing expression op.
  * Its result SSA values may be used by subsequent operations in the same block.
  * eco.case produces values, it does not terminate control flow.
inputs: MLIR with case expressions
oracle: eco.case ops produce SSA values and may be followed by other operations.
--
--
name: eco.case produces results via eco.yield
phase: MLIR codegen
invariants: CGEN_046
ir: eco.case ops
logic: For every eco.case:
  * It always produces its results via eco.yield in exactly one selected alternative.
  * Control continues in the enclosing block after the eco.case operation.
  * eco.case has no implicit control-flow exits.
inputs: MLIR with case expressions
oracle: eco.case always produces values; control flows to next op in block.
--
--
name: Decider regions must end with eco.yield
phase: MLIR codegen
invariants: CGEN_047
ir: eco.case alternative regions
logic: Every decider region that becomes an eco.case alternative:
  * Has a non-empty op list whose last op is eco.yield.
  * Codegen never manufactures dummy eco.return terminators to "patch" unterminated decider regions.
  * Hitting a non-eco.yield tail in a case alternative is a codegen bug.
inputs: MLIR with nested cases
oracle: All alternative regions end with eco.yield.
tests: compiler/tests/Compiler/Generate/CodeGen/CaseTerminationTest.elm
--
--
name: EcoControlFlowToSCF matches value-producing eco.case
phase: MLIR codegen
invariants: CGEN_048
ir: eco.case lowering
logic: The EcoControlFlowToSCF pass:
  * Matches value-producing eco.case regardless of its position in a block.
  * Rewrites it to scf.if or scf.index_switch by translating eco.yield terminators to scf.yield.
  * Replaces the original eco.case results with the SCF op results.
inputs: MLIR during lowering
oracle: Pass correctly converts eco.case to SCF ops with eco.yield -> scf.yield translation.
--
--
name: PAP bitmaps limited to 52 bits
phase: MLIR codegen
invariants: CGEN_049
ir: eco.papCreate and eco.papExtend ops
logic: For PAP ops:
  * unboxed_bitmap attributes are limited to 52 bits.
  * Total captures plus arity must not exceed 52.
  * Number of set bits in unboxed_bitmap equals count of immediate MLIR operand typed operands.
inputs: MLIR with closures
oracle: Bitmap constraints satisfied; bits match operand types.
tests: compiler/tests/Compiler/Generate/CodeGen/UnboxedBitmapTest.elm
--
--
name: Lambda functions use typed signatures
phase: MLIR codegen
invariants: CGEN_050
ir: Lambda function signatures
logic: Lambda functions:
  * Use typed signatures where capture parameters have actual MonoType mapped to MLIR types.
  * Return types match the body expression type rather than always using eco.value.
  * No internal boxing or unboxing is needed for immediate captures and returns.
inputs: MLIR with lambdas
oracle: Lambda signatures are typed; no unnecessary boxing.
--

---

## Runtime Heap Phase (HEAP_*)

--
name: Heap objects start with 8-byte header and tag
phase: runtime heap
invariants: HEAP_001
ir: In-memory heap objects
logic: Allocate various heap objects and inspect raw memory:
  * Confirm first 8 bytes are `Header`.
  * Confirm low TAG_BITS represent a valid `Tag` kind.
inputs: Runtime tests with instrumentation or memory dumps
oracle: All heap objects start with a valid header encoding a known tag.
--
--
name: Heap objects are 8-byte aligned
phase: runtime heap
invariants: HEAP_002
ir: Allocated heap object addresses
logic: For many allocations:
  * Assert `address % 8 == 0`.
  * Confirm `getObjectSize` returns sizes rounded up to multiples of 8.
inputs: Runtime allocation tests
oracle: Every object is 8-byte aligned; no odd alignments seen.
--
--
name: Tag is sole discriminator for heap layout
phase: runtime heap
invariants: HEAP_003
ir: GC tracing and size computation
logic: Instrument `getObjectSize` and tracing routines:
  * Confirm they always switch on `Header.tag` and never on other metadata to decide layout.
  * Fuzz with objects of different tags and ensure correct behavior.
inputs: Runtime tests across all object kinds
oracle: Tag fully determines layout handling; no hidden layout side channels.
--
--
name: Adding a heap type requires full GC updates
phase: runtime heap
invariants: HEAP_004
ir: Tag enum, heap structs, GC code
logic: Meta-test:
  * Introduce a synthetic new Tag in a feature branch and enforce that tests fail unless `Tag` enum, C++ struct, `getObjectSize`, `scanObject`, and `markChildren` are updated.
  * Maintain a checklist-based or static-analysis-based test ensuring each Tag kind has corresponding GC handlers.
inputs: Build-time tests and CI rules
oracle: It is impossible to add a Tag without updating all required GC logic.
--
--
name: No old-to-young pointers in heap
phase: runtime heap
invariants: HEAP_005
ir: Heap graph during GC
logic: Construct long-lived data and new allocations:
  * During GC, scan for pointers from old generation to nursery.
  * Assert none exist; if any found, test fails.
inputs: Generational heap runtime tests
oracle: Heap graph never has old->young edges, matching Elm immutability assumptions.
--
--
name: Forwarding pointers are GC-only
phase: runtime heap
invariants: HEAP_006
ir: Tag_Forward objects
logic: While GC is running:
  * Validate objects with `Tag_Forward` appear only during collection.
  * Immediately after GC, verify no live object has `Tag_Forward`.
inputs: GC instrumentation tests
oracle: Forwarding pointers never escape into mutator-visible execution; tag is transient.
--
--
name: Each heap region has a single owning thread
phase: runtime heap
invariants: HEAP_007
ir: ThreadLocalHeap regions
logic: In multi-threaded tests:
  * Track heap regions and their `ThreadLocalHeap` owners.
  * Assert no cross-thread heap pointers are created.
  * Confirm each mutator only runs GC on its own heap.
inputs: Concurrency tests with multiple threads allocating
oracle: Ownership is exclusive; no cross-thread heap references or GC operations.
--
--
name: HPointer is a 40-bit offset from heap_base
phase: runtime heap
invariants: HEAP_008
ir: HPointer representation
logic: For HPointer values:
  * Verify `ptr` field is within 40-bit range and encodes an offset from `heap_base`.
  * Confirm conversions to/from raw pointers use helpers and produce consistent results.
inputs: Runtime tests involving pointer conversions
oracle: Logical pointers are never raw addresses; offset and base compute the actual location.
--
--
name: HPointer is the only heap reference type
phase: runtime heap
invariants: HEAP_009
ir: C++ and runtime APIs
logic: Static and dynamic analysis:
  * Ensure all heap references are typed as `HPointer` or `uint64_t`-encoded HPointer.
  * Enforce use of `fromPointer` / `toPointer` or Allocator helpers to convert; prohibit treating them as `void*`.
inputs: Codebase checks and runtime assertions
oracle: No direct raw pointer arithmetic or casts for heap values; HPointer is canonical.
--
--
name: Common constants are non-zero tagged HPointers
phase: runtime heap
invariants: HEAP_010
ir: HPointer constants
logic: Inspect `Unit`, `EmptyRec`, `True`, `False`, `Nil`, `Nothing`, `EmptyString`:
  * Confirm they are represented as HPointer values with `constant != 0`.
  * Assert they are never heap-allocated and not traced by GC.
inputs: Runtime tests and constant table inspection
oracle: All listed constants are embedded, nonzero-tag HPointer constants.
--
--
name: Allocation may move all nursery objects
phase: runtime heap
invariants: HEAP_011
ir: Allocation behavior and object movement
logic: During stress tests:
  * Trigger minor GCs via `ThreadLocalHeap::allocate` or `Allocator::allocate`.
  * Track object addresses before and after allocation; verify many nursery objects move.
  * Ensure code never relies on object addresses remaining stable across allocation.
inputs: GC-heavy runtime tests
oracle: Minor GCs are allowed at any allocation point and may move all nursery objects.
--
--
name: isInHeap's bounds check is heap_base + heap_reserved
phase: runtime heap
invariants: HEAP_012
ir: isInHeap implementation
logic: Unit-test `isInHeap`:
  * Construct pointers exactly at `heap_base`, `heap_base + heap_reserved - 1`, and just outside.
  * Confirm behavior matches an O(1) bounds check over that range.
inputs: Synthetic pointers in runtime tests
oracle: Any pointer in the unified heap address range is treated as a potential heap object.
--
--
name: Tag must match object struct at allocation
phase: runtime heap
invariants: HEAP_013
ir: Allocation and object layout
logic: For each allocation:
  * Check that the Tag passed to `Allocator::allocate` matches the struct written at that address.
  * GC's `getObjectSize` and tracing for that tag must successfully interpret the memory.
inputs: Tagged allocations across all heap object types
oracle: No mismatch between header.tag and in-memory structure; mismatches cause explicit failures.
--
--
name: Embedded constants are non-heap and not traced
phase: runtime heap
invariants: HEAP_014
ir: HPointer.constant handling
logic: For HPointer values with `constant != 0`:
  * Assert allocator and resolver treat them as non-heap.
  * Confirm GC and debug printing never attempt to trace or resolve them as heap addresses.
inputs: Runtime tests involving embedded constants
oracle: Embedded constants behave as value-like handles, not heap objects.
--
--
name: Header tag and struct layout match runtime type
phase: runtime heap
invariants: HEAP_015
ir: Heap layout by type
logic: For each runtime type (Tuple, Cons, Record, Custom, etc.):
  * Allocate values and inspect Tag and in-memory struct layout.
  * Assert no value of List/Tuple/Record is represented using `Custom` struct.
  * Tag and physical layout must always match the declared type.
inputs: Runtime allocation tests for each type category
oracle: TypeLayout invariant holds; no mixing of representations.
--
--
name: Runtime exports use HPointer-encoded uint64_t
phase: runtime heap
invariants: HEAP_016
ir: eco_alloc_* and heap APIs
logic: For all `eco_alloc_*` and heap functions:
  * Check they return `uint64_t` where `constant == 0` for heap objects.
  * Functions receiving heap objects must take `uint64_t` and use `Allocator::resolve` internally.
inputs: Runtime API tests
oracle: No function leaks raw pointers; all heap values use the HPointer encoding.
--
--
name: No null pointers in Elm heap
phase: runtime heap
invariants: HEAP_017
ir: Pointer values
logic: Throughout runtime:
  * Assert allocations never return `null`; treat any such result as out-of-memory.
  * Treat `HPointer{ptr == 0, constant == 0}` as a valid heap offset 0, not null.
inputs: Runtime stress tests, including low-memory simulations
oracle: Null pointer never used as a value; special HPointer(0,0) is treated as a real address.
--
--
name: Elm values are acyclic at runtime
phase: runtime heap
invariants: HEAP_018
ir: Value graphs
logic: For arbitrary Elm values:
  * Traverse the object graph following references; verify traversal always terminates without cycle detection.
  * Attempt to construct cyclic values via recursive lets; ensure language semantics disallow them at compile time.
inputs: Runtime tests over complex nested structures
oracle: Traversals terminate without cycle handling; no cycles observable in runtime graphs.
--
--
name: Unboxed bitmap correctly marks primitive slots
phase: runtime heap
invariants: HEAP_019
ir: Heap container objects and GC
logic: For `Custom`, `Cons`, `Record` objects:
  * Verify `header.unboxed` bits correctly identify which slots are unboxed primitives.
  * GC tracing must skip unboxed slots and follow only boxed HPointers.
  * Debug printing must distinguish unboxed primitives from pointers.
inputs: Runtime allocations with mixed boxed/unboxed fields
oracle: Bitmap and actual contents match; GC and utilities behave correctly.
--

---

## Bytes Fusion Reification Phase (BFUSE_*)

--
name: Reification is all-or-nothing
phase: bytes fusion
invariants: BFUSE_001
ir: Fused kernels
logic: A fused kernel is emitted only when the entire encoder or decoder structure can be statically resolved:
  * Otherwise the interpreter path is used.
inputs: Programs with encoders/decoders
oracle: Partial fusion never occurs.
--
--
name: Dynamic encoders/decoders rejected from fusion
phase: bytes fusion
invariants: BFUSE_002
ir: Fusion decisions
logic: Any encoder or decoder whose structure depends on runtime values causes fallback to interpreter.
inputs: Programs with dynamic encoding
oracle: Runtime-dependent structures are not fused.
--
--
name: Let-bound encoders/decoders must be fully resolvable
phase: bytes fusion
invariants: BFUSE_003
ir: Let bindings with encoders
logic: Let-bound encoders and decoders are reified only if fully resolvable at compile time:
  * Partially resolvable let bindings cause the entire fusion to be rejected.
inputs: Programs with let-bound encoders
oracle: Partial resolution causes fallback.
--
--
name: Reification preserves operation order
phase: bytes fusion
invariants: BFUSE_004
ir: Fused kernel operation sequence
logic: The sequence of encode or decode steps in the fused kernel matches the order specified in the source program.
inputs: Multi-step encoders/decoders
oracle: Order is preserved exactly.
--
--
name: Reification inspects only static structure
phase: bytes fusion
invariants: BFUSE_005
ir: Fusion analysis
logic: Reification inspects structure only, never runtime values:
  * Fusion decisions are based solely on static shape of encoder/decoder AST.
inputs: Programs with encoders
oracle: No runtime value inspection in fusion decisions.
--

---

## Bytes Fusion Ops Phase (BFOPS_*)

Note: See invariants.csv for the full list of BFOPS invariants (BFOPS_001 through BFOPS_038).
These cover cursor state, SSA threading, encoder/decoder bounds checking, lowering, and ABI rules.

---

## Cross-Phase Invariants (XPHASE_*)

--
name: Layout consistency across MonoGraph, MLIR, and runtime
phase: cross-phase (monomorphization -> MLIR -> runtime)
invariants: XPHASE_001
ir: RecordLayout, TupleLayout, CtorLayout, eco.construct attrs, C++ structs
logic: For records/tuples/custom types:
  * Compare `RecordLayout` / `TupleLayout` / `CtorLayout` to eco.construct's `tag`, `size`, and `unboxed_bitmap`.
  * Check generated MLIR objects match the C++ `Custom` and `Record` struct layouts at runtime via allocation/inspection.
inputs: MonoGraph, generated MLIR, running heap
oracle: Exact agreement on field counts, ordering, sizes, and unboxing between all three layers.
--
--
name: eco.value pointers obey runtime heap invariants
phase: cross-phase (codegen -> runtime)
invariants: XPHASE_002
ir: MLIR `!eco.value`, HPointer-based heap
logic: For all boxed values from MLIR:
  * Ensure they are valid HPointer-based heap objects (8-byte aligned, header first, valid tag).
  * Confirm MLIR never produces boxed values that violate heap invariants (misaligned or missing header).
inputs: End-to-end programs with heavy boxing/unboxing and GC
oracle: Every eco.value corresponds to a well-formed heap object; heap and IR representations remain consistent.
--
--
name: CallInfo flows unchanged to MLIR
phase: cross-phase (GlobalOpt -> MLIR codegen)
invariants: XPHASE_010
ir: MonoGraph from GlobalOpt to MLIR codegen
logic: Structural verification by code inspection:
  * MLIR codegen only pattern-matches on MonoCall
  * It never constructs MonoCall expressions
  * It never uses defaultCallInfo
  * Therefore CallInfo values from GlobalOpt pass through unchanged
inputs: Code review
oracle: No MonoCall construction or defaultCallInfo usage in MLIR codegen.
verification: structural (code inspection)
--
--
name: Types preserved except MFunction canonicalization
phase: cross-phase (Monomorphization -> GlobalOpt)
invariants: XPHASE_011
ir: MonoTypes before/after GlobalOpt
logic: Compare MonoTypes before and after GlobalOpt:
  * MFunction types may be canonicalized (nested -> flat per GOPT_001)
  * No other type changes allowed
  * No type information lost
inputs: Monomorphized graphs before/after GlobalOpt
oracle: Type mutations are limited to documented canonicalization.
tests: compiler/tests/TestLogic/CrossPhase/TypeConsistencyTest.elm
--

---

## Forbidden Invariants (FORBID_*)

These invariants specify what NOT to do. Each defines an assumption that must NOT be made.

--
name: No SSA-to-heap-layout assumption
phase: cross-phase
invariants: FORBID_REP_001
logic: No phase may assume that an SSA operand of immediate MLIR operand type corresponds to an unboxed field in any heap object unless an explicit layout bitmap is consulted.
--
--
name: No ABI-to-heap-layout assumption
phase: cross-phase
invariants: FORBID_REP_002
logic: No phase may assume that a value passed as a pass-by-value MLIR type at an ABI boundary is stored as an unboxed field in heap objects or closures.
--
--
name: No SSA-ABI assumption
phase: cross-phase
invariants: FORBID_REP_003
logic: No phase may assume that SSA operand representation implies ABI calling convention or vice versa except where explicitly specified by REP_ABI invariants.
--
--
name: No pointer range checks for constants
phase: runtime heap
invariants: FORBID_HEAP_001
logic: No code may distinguish heap pointers from constants using address range checks or null tests; only HPointer constant bits and header tags may be used.
--
--
name: No HPointer arithmetic except via helpers
phase: runtime heap
invariants: FORBID_HEAP_002
logic: No code may perform arithmetic on HPointer values except via allocator helpers or runtime APIs.
--
--
name: Bool must be !eco.value in heap and closures
phase: cross-phase
invariants: FORBID_CLOSURE_001
logic: No phase may assume that Bool values are captured, stored, or passed as immediate operands outside SSA control-flow contexts; Bool must be represented as !eco.value in heap and closures.
--
--
name: Closure layout from SSA types only
phase: cross-phase
invariants: FORBID_CLOSURE_002
logic: No phase may infer closure capture layout from MonoType or source type alone; layout must be derived from SSA operand MLIR types and recorded bitmaps.
--
--
name: No Tag-only layout assumption
phase: runtime heap
invariants: FORBID_LAYOUT_001
logic: No code may assume a heap object's field layout based solely on its Tag without consulting the corresponding layout metadata.
--
--
name: No implicit layout sharing
phase: monomorphization
invariants: FORBID_LAYOUT_002
logic: No phase may assume that two structurally equal source types share layout unless their RecordLayout or TupleLayout identifiers are equal or explicitly canonicalized.
--
--
name: No boxing removal without proof
phase: typed optimization
invariants: FORBID_OPT_001
logic: No optimization may remove boxing or unboxing operations unless representation equivalence is proven under the active representation model.
--
--
name: No direct heap access in generated code
phase: cross-phase
invariants: FORBID_OPT_002
logic: No generated code may access heap object internals directly except inside designated runtime helpers.
--
--
name: No implicit control-flow fallthrough
phase: MLIR codegen
invariants: FORBID_CF_001
logic: No control-flow construct may assume implicit fallthrough:
  * All region exits must be explicit terminators.
  * All eco.case alternatives must explicitly terminate with eco.yield.
  * Relying on fallthrough behavior is forbidden.
--
--
name: Debug code uses same tracing as GC
phase: runtime heap
invariants: FORBID_DBG_001
logic: Debug and inspection code must not assume access to raw heap layouts and must use the same tracing logic as GC.
--
--
name: No unstated representation assumptions
phase: cross-phase
invariants: FORBID_META_001
logic: No phase may rely on representation properties that are not explicitly stated in a REP_* invariant.
--
