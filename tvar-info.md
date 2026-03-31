# Type Variable Information Across the Elm Compiler

All file paths are relative to `/work/compiler/src/Compiler/`.

---

## 1. Dicts Keyed by String/Name Containing Type Variable Information

| # | File | Line | Dict Type | Description | Phase |
|---|------|------|-----------|-------------|-------|
| 1 | `Type/Instantiate.elm` | 50 | `Dict Name Type` (alias `FreeVars`) | Maps tvar names to instantiated internal Types | TypeInference |
| 2 | `Type/Type.elm` | 102 | `Dict Name (A.Located Type)` | Type variable bindings in CLet constraint scope | TypeInference |
| 3 | `Type/Type.elm` | 805 | `Dict Name ()` (alias `NameStateData.taken`) | Tracks which tvar names are already used | TypeInference |
| 4 | `Type/Type.elm` | 818 | `Dict Name Variable` | Maps taken tvar names to solver Variables (in `makeNameState`) | TypeInference |
| 5 | `Type/Constrain/Typed/Expression.elm` | 293–307 | `Dict Name Type` | Renamed type variables (`rtv`) in typed argument constraints | TypeInference |
| 6 | `Type/Constrain/Typed/Pattern.elm` | 43 | `Dict Name Type` | Tvar-to-type map inside `PFromSrcType` pattern DSL | TypeInference |
| 7 | `Type/Constrain/Typed/Pattern.elm` | 468, 628 | `Dict Name Type` (`freeVarDict`) | Free type variables in typed pattern matching | TypeInference |
| 8 | `Type/Constrain/Erased/Expression.elm` | 985, 1015, 1115 | `Dict Name Type` | Renamed type variables (`rtv`) in erased constraint gen | TypeInference |
| 9 | `Type/Constrain/Erased/Pattern.elm` | 45, 108, 289, 466 | `Dict Name Type` (`freeVarDict`) | Free type variables in erased pattern matching | TypeInference |
| 10 | `Type/Constrain/Common.elm` | 78, 100 | `Dict Name (A.Located Type)` (alias `Header`) | Record/variable names to located types | TypeInference |
| 11 | `Type/Constrain/Common.elm` | 266 | `Dict Name Type` (alias `RigidTypeVar`) | Rigid type variables from annotations | TypeInference |
| 12 | `Type/Constrain/Common.elm` | 340 | `Dict Name Shader.Type` | Shader field type variables | TypeInference |
| 13 | `Type/Error.elm` | 72 | `Dict Name Type` | Record field-to-type map in error type representation | TypeInference |
| 14 | `Type/Error.elm` | 722, 726, 746 | `Dict Name (D.Doc, D.Doc)` | Record field diffs for type error reporting | TypeInference |
| 15 | `Type/PostSolve.elm` | 52 | `Dict Name (Can.Annotation Name)` | Inferred type annotations after solving | PostSolve |
| 16 | `Type/SolverSnapshot.elm` | 52 | `Dict Name TypeVar` (`annotationVars`) | Tvar names to solver Variables for annotations | PostSolve |
| 17 | `Type/SolverSnapshot.elm` | 107 | `Dict String Mono.MonoType` (`subst`) | Tvar names to monomorphic types after local unification | PostSolve |
| 18 | `Monomorphize/State.elm` | 72 | `Dict Name Mono.Constraint` (`constraints`) | Tvar names to constraints (Number, EcoValue) in SchemeInfo | Monomorphize |
| 19 | `Monomorphize/State.elm` | 80 | `Dict Name Name` (`preRenameMap`) | Original tvar names to definition-scoped renamed names | Monomorphize |
| 20 | `Monomorphize/State.elm` | 101 | `Dict Name MVarId` (`nameToId`) | Tvar names to deterministic MVarIds | Monomorphize |
| 21 | `Monomorphize/State.elm` | 102 | `Dict Int Name` (`idToName`) | Reverse: MVarId to tvar name | Monomorphize |
| 22 | `Monomorphize/State.elm` | 210 | `Dict Name Mono.MonoType` (alias `Substitution`) | Tvar names to monomorphic type substitutions | Monomorphize |
| 23 | `Monomorphize/State.elm` | 219 | `List (Dict Name Mono.MonoType)` (`VarEnv`) | Scoped layers of variable-to-MonoType mappings | Monomorphize |
| 24 | `Monomorphize/TypeSubst.elm` | 936 | `Dict Name Mono.MonoType` | Tvar-to-MonoType used in reverse renaming | Monomorphize |
| 25 | `Monomorphize/TypeSubst.elm` | 1205 | `Dict Name Mono.MonoType` | Tvar-to-MonoType in normalization/occurs check | Monomorphize |
| 26 | `Monomorphize/Closure.elm` | 165, 171, 473 | `Dict String Mono.MonoType` | Variable/field names to MonoTypes in closure analysis | Monomorphize |
| 27 | `LocalOpt/Typed/Names.elm` | 103 | `Dict Name (Can.Type Name)` (`locals`) | Local variable names to canonical types | LocalOpt |
| 28 | `Generate/MLIR/Types.elm` | 423 | `Dict Name Mono.MonoType` | Field names to MonoTypes for record layout computation | Codegen |

---

## 2. Sets Keyed by String/Name Signalling Type Variable Information

| # | File | Line | Set Type | Description | Phase |
|---|------|------|----------|-------------|-------|
| 1 | `AST/Canonical.elm` | 274 | `Dict Name ()` (alias `FreeVars`) | Universally quantified tvar names in `Forall` annotations | Canonicalize |
| 2 | `Type/Constrain/Typed/NodeIds.elm` | 58 | `EverySet Int Int` (`syntheticExprIds`) | Expression node IDs that have synthetic placeholder tvars | TypeInference |
| 3 | `GlobalOpt/MonoGlobalOptimize.elm` | 79 | `Set Name` (`varPolymorphicReturn`) | Variables bound to partial applications with polymorphic returns | GlobalOpt |
| 4 | `GlobalOpt/Staging/Types.elm` | 183 | `Set String` (`dynamicSlots`) | Slot keys requiring generic apply (unsettled tvar equivalence class) | GlobalOpt |
| 5 | `GlobalOpt/MonoGlobalOptimize.elm` | 77 | `Set String` (`dynamicSlots`) | Dynamic slots in the call environment | GlobalOpt |

---

## 3. Places Where Type Variables Are Alpha-Renamed

| # | File | Line | Function | Description | Phase |
|---|------|------|----------|-------------|-------|
| 1 | `Monomorphize/TypeSubst.elm` | 909–929 | `buildPreRenameMap` | Renames canonical tvars to definition-scoped names (`a__def_Module_0`) | Monomorphize |
| 2 | `Monomorphize/TypeSubst.elm` | 960–1002 | `renameCanTypeVarsInternal` | Recursively renames tvars in canonical types using a rename map | Monomorphize |
| 3 | `Monomorphize/TypeSubst.elm` | 936–954 | `applyReverseRenaming` | Copies bindings from renamed keys back to original keys | Monomorphize |
| 4 | `Monomorphize/TypeSubst.elm` | 862–891 | `buildSchemeInfo` | Pre-computes renamed type variants for function specialization | Monomorphize |
| 5 | `Monomorphize/TypeSubst.elm` | 647–768 | `applySubst` | Applies type substitutions to canonical types (resolves `Can.TVar` to `MonoType`) | Monomorphize |
| 6 | `Monomorphize/Specialize.elm` | 66–80 | `buildRenameMap` | Per-call rename maps with `__callee{epoch}_{counter}` suffixes on conflict | Monomorphize |
| 7 | `Monomorphize/Specialize.elm` | 84–125 | `renameCanTypeVars` | Applies per-call rename maps to canonical types | Monomorphize |
| 8 | `Monomorphize/State.elm` | 132–150 | `allocMVar` | Deterministic MVarId allocation for tvar names (hash-based identity) | Monomorphize |
| 9 | `Type/Instantiate.elm` | 74–128 | `fromSrcType` | Converts source type annotations to internal types, tracking free tvars | TypeInference |
| 10 | `Type/Solve.elm` | 1063–1073 | `makeCopyHelp` | Creates fresh copies of generalized tvars for polymorphic instantiation | TypeSolving |
| 11 | `Type/Unify.elm` | 204–213 | `fresh` | Creates fresh tvars at min rank during unification (merged structures) | TypeSolving |
| 12 | `LocalOpt/Typed/NormalizeLambdaBoundaries.elm` | 111–119 | `freshName` | Generates fresh parameter names with `_hl_` suffix for lambda normalization | LocalOpt |
| 13 | `LocalOpt/Typed/NormalizeLambdaBoundaries.elm` | 150–251 | `renameExpr` | Applies alpha-renaming to expression variables using a rename environment | LocalOpt |
| 14 | `GlobalOpt/MonoInlineSimplify.elm` | 532–536 | `freshVar` | Generates `mono_inline_` prefixed names for inlined expressions | GlobalOpt |
| 15 | `GlobalOpt/MonoInlineSimplify.elm` | 1218–1315 | `substitute` | Substitutes original parameter names with fresh names to avoid capture | GlobalOpt |

---

## 4. Types Modelling Elm's Typeclasses (number, appendable, comparable, compappend)

| # | File | Line | Type | Definition | Phase |
|---|------|------|------|------------|-------|
| 1 | `System/TypeCheck/IO.elm` | 438–442 | `SuperType` | `Number \| Comparable \| Appendable \| CompAppend` — core constraint enum | TypeInference |
| 2 | `System/TypeCheck/IO.elm` | 420–427 | `Content` | `FlexSuper SuperType (Maybe String) \| RigidSuper SuperType String \| ...` — tvar descriptor content | TypeInference |
| 3 | `System/TypeCheck/IO.elm` | 382–406 | `Descriptor` | Wraps `Content` with rank/mark/copy metadata | TypeInference |
| 4 | `Type/Error.elm` | 80–84 | `Super` | `Number \| Comparable \| Appendable \| CompAppend` — error-domain mirror of `SuperType` | Error Reporting |
| 5 | `Type/Error.elm` | 63–75 | `Type` (error) | Includes `FlexSuper Super Name \| RigidSuper Super Name` variants | Error Reporting |
| 6 | `Type/Error.elm` | 219–232 | `Problem` | Includes `BadFlexSuper Direction Super Type \| BadRigidSuper Super Name Type` | Error Reporting |
| 7 | `AST/Monomorphized.elm` | 240–242 | `Constraint` | `CEcoValue \| CNumber` — backend constraint markers for monomorphized tvars | Monomorphize |
| 8 | `Data/Name.elm` | 159–182 | Name predicates | `isNumberType`, `isComparableType`, `isAppendableType`, `isCompappendType` | Cross-cutting |
| 9 | `Data/Name.elm` | 195–212 | Name prefix constants | `prefixNumber`, `prefixComparable`, `prefixAppendable`, `prefixCompappend` | Cross-cutting |
| 10 | `Type/Type.elm` | 349–356 | `mkFlexNumber` | Factory for fresh Number-constrained flex variables | TypeInference |
| 11 | `Type/Type.elm` | 365–367 | `unnamedFlexSuper` | Creates unnamed `FlexSuper` content for a given `SuperType` | TypeInference |
| 12 | `Type/Type.elm` | 398–413 | `toSuper` | Maps tvar name prefixes to `Maybe SuperType` | TypeInference |
| 13 | `Type/Type.elm` | 381–383 | `nameToFlex` | Creates named flex var, auto-promoting to `FlexSuper` if name matches a constraint | TypeInference |
| 14 | `Type/Type.elm` | 393–395 | `nameToRigid` | Creates named rigid var, auto-promoting to `RigidSuper` if name matches a constraint | TypeInference |

---

## 5. Places Where Synthetic Type Variables Are Created

| # | File | Line | Function/Construct | Description | Phase |
|---|------|------|-------------------|-------------|-------|
| 1 | `Type/Type.elm` | 318 | `mkFlexVar` | Fresh unnamed flex tvar for inference | TypeInference |
| 2 | `Type/Type.elm` | 349 | `mkFlexNumber` | Fresh unnamed number-constrained flex tvar | TypeInference |
| 3 | `Type/Type.elm` | 381 | `nameToFlex` | Named flex var (auto-FlexSuper for constrained names) | TypeInference |
| 4 | `Type/Type.elm` | 393 | `nameToRigid` | Named rigid var (auto-RigidSuper for constrained names) | TypeInference |
| 5 | `Type/Type.elm` | 827 | `getFreshVarName` | Generates names ("a", "b", …) for unnamed flex vars in error display | TypeInference |
| 6 | `Type/Type.elm` | 866 | `getFreshSuperName` | Generates names ("number0", "comparable0", …) for supertype vars | TypeInference |
| 7 | `Type/UnionFind.elm` | 46 | `fresh` | Low-level union-find point creation (backing all variable creation) | Core |
| 8 | `Type/Constrain/Typed/Program.elm` | 74–75 | `MkFlexVarS` / `MkFlexNumberS` | Constraint DSL instructions for fresh var allocation | Constraint Gen |
| 9 | `Type/Constrain/Typed/Program.elm` | 164, 171 | `opMkFlexVarS` / `opMkFlexNumberS` | Lifts fresh var creation into constraint program monad | Constraint Gen |
| 10 | `Type/Constrain/Typed/Expression.elm` | 434 | `constrainGenericWithIdsProg` | Fresh var for generic expressions | Constraint Gen |
| 11 | `Type/Constrain/Typed/Expression.elm` | 467 | `constrainIntWithIdsProg` | Fresh number var for integer literals | Constraint Gen |
| 12 | `Type/Constrain/Typed/Expression.elm` | 482 | `constrainNegateWithIdsProg` | Fresh number var for negation | Constraint Gen |
| 13 | `Type/Constrain/Typed/Expression.elm` | 507, 510 | `constrainAccessWithIdsProg` | Fresh vars for record extension + field type | Constraint Gen |
| 14 | `Type/Constrain/Typed/Expression.elm` | 559 | `constrainAccessorGroupAWithIdsProg` | Fresh var for field accessor | Constraint Gen |
| 15 | `Type/Constrain/Typed/Expression.elm` | 596, 632, 666, 701, 736, 775, 815 | List/Tuple/Record/Lambda/Let/LetRec/LetDestruct | Fresh var for each expression form | Constraint Gen |
| 16 | `Type/Constrain/Typed/Expression.elm` | 877 | Int literal constraint | Fresh number var via `opMkFlexNumberS` | Constraint Gen |
| 17 | `Type/Constrain/Typed/Pattern.elm` | 139, 179, 235 | `PMkFlexVar` + pattern helpers | Fresh flex vars for pattern types | Constraint Gen |
| 18 | `Type/Constrain/Typed/Pattern.elm` | 151 | `PTraverseList` | Fresh flex vars for each name in pattern (calls `nameToFlex`) | Constraint Gen |
| 19 | `Type/Constrain/Typed/Module.elm` | 137, 154 | Port incoming/outgoing | Fresh rigid vars from free tvars via `nameToRigid` | Constraint Gen |
| 20 | `Type/Constrain/Typed/Module.elm` | 177, 199 | `letCmdWithVars` / `letSubWithVars` | Fresh flex var for effect message types | Constraint Gen |
| 21 | `Type/Constrain/Erased/Expression.elm` | 981, 1111 | Polymorphic function calls | Fresh rigid vars for free tvars in function types | Constraint Gen |
| 22 | `Type/Constrain/Erased/Pattern.elm` | 142, 155 | `PMkFlexVar` / `PTraverseList` | Fresh vars in erased pattern constraint gen | Constraint Gen |
| 23 | `Type/Constrain/Erased/Module.elm` | 124, 140, 162, 184 | Ports + Cmd/Sub | Fresh rigid/flex vars for erased module constraints | Constraint Gen |
| 24 | `Type/Solve.elm` | 868 | `register` | Creates and pools fresh vars during constraint solving | TypeSolving |
| 25 | `Type/Solve.elm` | 900–923 | `srcTypeToVariable` | Converts canonical source types to fresh unification vars | TypeSolving |
| 26 | `Type/Solve.elm` | 934–1013 | `srcTypeToVar` | Recursively creates structure vars (App, Fun, Record, etc.) | TypeSolving |
| 27 | `Type/Solve.elm` | 1063 | `makeCopyHelp` | Fresh copies of generalized tvars for polymorphic instantiation | TypeSolving |
| 28 | `Type/Unify.elm` | 204 | `fresh` | Fresh var at min rank during unification | TypeSolving |
| 29 | `Type/Unify.elm` | 578 | Record unification | Fresh Comparable var for record extension | TypeSolving |
| 30 | `Type/Unify.elm` | 867, 870, 873 | Record flattening | Fresh flex/record vars for record substructures | TypeSolving |
| 31 | `Type/SolverSnapshot.elm` | 512 | `freshFlexVar` | Fresh flex var in solver state with proper rank | PostSolve |
| 32 | `Type/SolverSnapshot.elm` | 481 | `freshStructureVar` | Fresh var with concrete structure descriptor from MonoType | PostSolve |
| 33 | `Type/SolverSnapshot.elm` | 544–615 | `monoTypeToVar` / `monoFunctionToVar` | Converts MonoTypes back to fresh solver vars | PostSolve |
