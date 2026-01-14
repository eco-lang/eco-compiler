### Canonicalization phase

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
logic: Walk all expressions and patterns, collect `ExprInfo.id` values into a map; assert all IDs are ≥ 0 and no duplicates exist. Also assert that constructors that bypass ID allocation (if any) only produce negative placeholder IDs.
inputs: Canonicalized modules
oracle: No missing or duplicate non-negative IDs; all construction sites observed to call `Ids.allocId` in instrumentation builds.
--
--
name: No duplicate top-level declarations
phase: canonicalization
invariants: CANON_003
ir: Source module → Canonicalization errors
logic: Generate modules with intentional duplicate value, type, ctor, binop, and export names; run canonicalization and assert it produces `DuplicateDecl`, `DuplicateType`, `DuplicateCtor`, `DuplicateBinop`, or `ExportDuplicate` errors as appropriate. Also generate nested scopes with shadowing to ensure `Shadowing` errors are emitted and correctly localized.
inputs: Source IR modules
oracle: Specific error constructors occur for each duplicate scenario; no module with duplicates canonicalizes successfully.
--
--
name: Imports resolve to valid interfaces
phase: canonicalization
invariants: CANON_004
ir: Source module → Canonicalization errors
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
### Type checking phase

--
name: Constraints cover all reachable declarations
phase: type checking
invariants: TYPE_001
ir: Canonical module → Constraint tree
logic: Traverse canonical declarations, effects, expressions, and patterns; mark reachable nodes. After constraint generation (erased and typed), traverse the constraint tree and mark nodes back. Assert every reachable node has corresponding constraints.
inputs: Canonical modules (large plus synthetic edge cases)
oracle: No reachable AST node is missing from constraints; dead/unreachable parts may be exempt by design and documented.
--
--
name: Unification failures become type errors
phase: type checking
invariants: TYPE_002
ir: Constraints → Solver result
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
logic: After `Solve.runWithIds`, compute the set of all expression/pattern IDs ≥ 0 that were recorded via NodeIds during constraint generation. Assert:
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
### Post-solve phase

--
name: Group B expressions get structural types
phase: post-solve
invariants: POST_001
ir: PostSolve NodeTypes
logic: Identify Group B expressions (lists, tuples, records, units, lambdas) whose pre-PostSolve solver types include unconstrained synthetic variables. After PostSolve:
  * Assert those entries are replaced with concrete `Can.Type` structures.
  * Reconstruct the type structurally from subexpression types and compare to PostSolve’s result.
inputs: TypedCanonical + pre-/post-PostSolve NodeTypes snapshots
oracle: No Group B expression retains an unconstrained synthetic var; recomputed structural type matches PostSolve’s.
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
  * For any placeholder kind that remain by design (kernel-related), assert they’re limited to kernel expressions.
inputs: PostSolve NodeTypes maps from many modules
oracle: NodeTypes is fully concrete for non-kernel expressions; any remaining synthetic variables are flagged as a violation.
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
---
### Typed optimization phase

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
  * Assert that the expression’s own attached `Can.Type` equals that TLambda type.
inputs: TypedOptimized modules with varied arities and partial applications
oracle: Function types are internally consistent; arity and parameter/result types always match the TLambda-encoded type.
--
---
### Monomorphization phase

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
oracle: 1–1 mapping between specializations and nodes; no missing or orphan specs.
--
--
name: Record and tuple layouts capture shape completely
phase: monomorphization
invariants: MONO_006
ir: RecordLayout, TupleLayout
logic: For every record/tuple type:
  * Inspect the associated layout’s `fieldCount`, `indices`, and `unboxedBitmap`.
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
  * Use the record value’s MonoType to find its `RecordLayout`.
  * Verify the field index and `isUnboxed` flag used in the IR matches the layout’s metadata.
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
  * Check every `MonoVarLocal` resolves to a binder in scope.
  * Check every `MonoVarGlobal` and `SpecId` refer to existing MonoNodes.
  * Detect unreachable `SpecId`s and ensure they’re either optimized away or flagged.
inputs: Monomorphized graphs including randomized stress graphs
oracle: No dangling references, no undefined globals, no unreachable specs in the registry.
--
--
name: Function arity matches parameters and closure info
phase: monomorphization
invariants: MONO_012
ir: MonoNodes with function types
logic: For each function/closure node:
  * Compare the function MonoType’s arity with the parameter list length and closure bindings.
  * Verify each call site’s argument count matches the function’s MonoType (allowing partial application where supported).
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
---
### MLIR codegen phase

--
name: Boxing only between primitives and eco.value
phase: MLIR codegen
invariants: CGEN_001
ir: Generated MLIR for boxing/unboxing
logic: Inspect MLIR for boxing/unboxing operations:
  * Assert they only convert between primitive MLIR types (i64, f64, etc.) and `!eco.value`.
  * Any conversion between mismatched primitives (e.g., i64 ↔ f64) is reported as a monomorphization bug for test purposes.
inputs: MLIR from a variety of programs, especially numeric ones
oracle: All boxing/unboxing edges are primitive ↔ eco.value; no primitive ↔ different-primitive patches.
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
name: Closure application uses eco.value and eco.papExtend
phase: MLIR codegen
invariants: CGEN_003
ir: MLIR closure application ops
logic: Check `generateClosureApplication` output:
  * All captured and applied arguments are boxed to `!eco.value`.
  * `eco.papExtend` is emitted with `_operand_types` listing `!eco.value` for all operands.
inputs: Monomorphized programs using closures
oracle: No non-eco.value operand in closure applications; remaining arity matches MonoType.
--
--
name: Destruct paths follow destructor MonoType
phase: MLIR codegen
invariants: CGEN_004
ir: MLIR destruct and eco.project usage
logic: For each destruct operation:
  * Confirm `generateDestruct` and `generateMonoPath` use the destructor’s MonoType to determine the path target MLIR type.
  * Assert they do not use the body result type in that computation.
inputs: Programs with complex destructuring
oracle: Destruct results have their natural type; no unintended unboxing or type mismatch.
--
--
name: eco.project matches container and field types
phase: MLIR codegen
invariants: CGEN_005
ir: eco.project ops
logic: For each `eco.project`:
  * Assert the operand type is `!eco.value`.
  * Assert the result type equals the field’s MLIR type derived from MonoType.
  * Verify `unboxed` attribute is set exactly when the result type is not `!eco.value`.
inputs: MLIR with record/tuple/custom field projections
oracle: eco.project attributes and types are consistent; no incorrect unboxing.
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
  * No primitive kind changes (i64 ↔ f64) are introduced.
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
--
--
name: Boolean constants use typed i1 attributes
phase: MLIR codegen
invariants: CGEN_009
ir: MLIR boolean constants
logic: Scan MLIR for boolean-typed SSA values:
  * Assert constants are emitted with attributes like `value = 0 : i1` or `1 : i1`.
  * Verify MLIR verifier accepts these and rejects any mismatched constant types.
inputs: MLIR with many boolean operations and constants
oracle: All boolean constants are well-typed i1 values; no untyped or mismatched constants.
--
--
name: eco.case result_types and returns agree
phase: MLIR codegen
invariants: CGEN_010
ir: eco.case ops
logic: For each `eco.case`:
  * Inspect its `result_types` attribute.
  * Verify every `eco.return` in its alternatives uses exactly that result type list (including order and MLIR types).
inputs: MLIR for pattern matches and cases
oracle: All branches of a case are type-consistent and agree with `result_types`.
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
ir: MonoType → MLIR type mapping
logic: For each MonoType:
  * Check that `MInt → i64`, `MFloat → f64`, `MBool → i1`, `MChar → i32`.
  * Assert all other MonoTypes map to `!eco.value`.
inputs: Synthetic MonoTypes and integrated MLIR outputs
oracle: Mapping table is complete and consistent; no primitive maps to eco.value or wrong MLIR primitive.
--
--
name: CEcoValue MVars always lower to eco.value
phase: MLIR codegen
invariants: CGEN_013
ir: MonoType containing MVar(CEcoValue) → MLIR types
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
---
### Runtime heap phase

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
oracle: Heap graph never has old→young edges, matching Elm immutability assumptions.
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
name: isInHeap’s bounds check is heap_base + heap_reserved
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
  * GC’s `getObjectSize` and tracing for that tag must successfully interpret the memory.
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
### Cross-phase invariants

--
name: Layout consistency across MonoGraph, MLIR, and runtime
phase: cross-phase (monomorphization → MLIR → runtime)
invariants: XPHASE_001
ir: RecordLayout, TupleLayout, CtorLayout, eco.construct attrs, C++ structs
logic: For records/tuples/custom types:
  * Compare `RecordLayout` / `TupleLayout` / `CtorLayout` to eco.construct’s `tag`, `size`, and `unboxed_bitmap`.
  * Check generated MLIR objects match the C++ `Custom` and `Record` struct layouts at runtime via allocation/inspection.
inputs: MonoGraph, generated MLIR, running heap
oracle: Exact agreement on field counts, ordering, sizes, and unboxing between all three layers.
--
--
name: eco.value pointers obey runtime heap invariants
phase: cross-phase (codegen → runtime)
invariants: XPHASE_002
ir: MLIR `!eco.value`, HPointer-based heap
logic: For all boxed values from MLIR:
  * Ensure they are valid HPointer-based heap objects (8-byte aligned, header first, valid tag).
  * Confirm MLIR never produces boxed values that violate heap invariants (misaligned or missing header).
inputs: End-to-end programs with heavy boxing/unboxing and GC
oracle: Every eco.value corresponds to a well-formed heap object; heap and IR representations remain consistent.
--
