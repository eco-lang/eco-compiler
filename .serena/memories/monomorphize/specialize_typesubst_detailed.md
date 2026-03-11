# Monomorphization and Specialization Code - Detailed Reference

## KEY FILES
- `compiler/src/Compiler/Monomorphize/Specialize.elm` - Main specialization logic
- `compiler/src/Compiler/Monomorphize/TypeSubst.elm` - Type unification and substitution
- `compiler/src/Compiler/Monomorphize/Monomorphize.elm` - Entry point and erasure logic
- `compiler/src/Compiler/AST/Monomorphized.elm` - MonoType definitions and erasure helpers

---

## CORE DATA STRUCTURES

### MonoType (in Monomorphized.elm)
```elm
type MonoType
    = MInt
    | MFloat
    | MBool
    | MChar
    | MString
    | MUnit
    | MList MonoType
    | MTuple (List MonoType)
    | MRecord (Dict Name MonoType)
    | MCustom IO.Canonical Name (List MonoType)
    | MFunction (List MonoType) MonoType
    | MVar Name Constraint
    | MErased

type Constraint
    = CEcoValue  -- Truly polymorphic type variable
    | CNumber    -- Number constraint (Int or Float)
```

### ProcessedArg (in Specialize.elm)
```elm
type ProcessedArg
    = ResolvedArg Mono.MonoExpr
    | PendingAccessor A.Region Name Can.Type
    | PendingKernel A.Region String String Can.Type
    | LocalFunArg Name Can.Type
```

---

## SPECIALIZEEXPR - MAIN EXPRESSION SPECIALIZATION

Function signature:
```elm
specializeExpr : TOpt.Expr -> Substitution -> MonoState -> (Mono.MonoExpr, MonoState)
```

### Key Cases:

#### TOpt.Record (lines 1397-1433)
- Extract monoType from subst: `Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)`
- Get field types from monoType: `case monoType of Mono.MRecord fieldMap -> fieldMap`
- For each field:
  - Refine subst with unification: `TypeSubst.unifyExtend (TOpt.typeOf fieldExpr) fieldMonoType subst`
  - Specialize field expression with refined subst
  - Collect as `(fieldName, monoExpr)`
- Result: `Mono.MonoRecordCreate monoFields monoType`

#### TOpt.TrackedRecord (lines 1435-1473)
- Same as Record but uses `Data.Map.foldl A.compareLocated` instead of `Dict.foldl`
- Unboxes field names via `A.toValue locName`

#### TOpt.Update (lines 1341-1395)
- Get canonical record type: `TOpt.typeOf record`
- Define getFieldCanType helper to lookup field types from canonical record
- For each update:
  - Get field's canonical type from record, lookup mono field type
  - Refine subst via unification of updateExpr canonical type with mono field type
  - Specialize updateExpr with refined subst
- Result: `Mono.MonoRecordUpdate monoRecord monoUpdates monoType`

#### TOpt.List (lines 824-847)
- Get monoType from subst
- Specialize all elements: `specializeExprs exprs subst state`
- If `Mono.containsCEcoMVar monoType0`, infer type from first element
- Result: `Mono.MonoList region monoExprs monoType`

#### TOpt.Lambda/TrackedFunction (lines 815-817)
- Delegate to `specializeLambda`

#### TOpt.Let (lines 1053-1208)
**Function Defs (TLambda):**
- Push entry onto `localMulti` stack: `{ defName = defName, instances = Data.Map.empty }`
- Specialize body with stack entry visible
- If instances discovered during body specialization:
  - For each instance: merge subst, specialize def, rename with freshName
  - Build nested MonoLet chain
  - Register all instances in varEnv
- If no instances (fallback):
  - Specialize def once with original name

**Non-Function Defs:**
- Specialize def
- Get defMonoType, possibly inferring from monoDefExprType
- Enrich subst via `TypeSubst.unifyExtend defCanType defMonoType subst`
- Specialize body with enriched subst and updated varEnv

#### TOpt.Call (lines 826-1041)
**Two-Phase Processing:**
1. `processCallArgs` - defers Accessor and NumberBoxed kernel specialization
2. Unify function type with arg types: `TypeSubst.unifyFuncCall funcCanType argTypes canType subst`
3. `resolveProcessedArgs` - resolves deferred args with unified param types

**For VarGlobal callees:**
- Compute callSubst from unifyFuncCall
- Extract param types from unified function type
- Resolve processed args with param types
- Result type: prefer caller's subst to avoid name collisions

**For LocalFunArg callees:**
- Check if local is multi-target
- If yes, get/create instance with refined subst and funcMonoType
- If no, use original name

---

## SPECIALIZELAMBDA - LAMBDA SPECIALIZATION

Function signature:
```elm
specializeLambda lambdaExpr canType subst state -> (Mono.MonoClosure, MonoState)
```

Lines 178-264. **Critical steps:**

1. **Specialize whole function type:**
   - `monoType0 = Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)`
   - Do NOT flatten here; preserve curried structure

2. **Refine substitution with monomorphic type:**
   - `refinedSubst = TypeSubst.unifyExtend canType monoType0 subst`
   - This propagates constraints from enclosing context (e.g., compose identity identity 1)

3. **Extract params and body:**
   - Pattern match on TOpt.Function or TOpt.TrackedFunction
   - Handle tracked names via `A.toValue locName`

4. **Specialize parameters under refinedSubst:**
   - `List.map (Tuple.mapSecond (Mono.forceCNumberToInt (TypeSubst.applySubst refinedSubst canParamType)))`

5. **Create lambdaId and varEnv:**
   - Create fresh `AnonymousLambda` ID
   - Push frame, insert params into varEnv
   - `newVarEnv = List.foldl (...State.insertVar...) (State.pushFrame state.varEnv) monoParams`

6. **Specialize body under refinedSubst:**
   - `(monoBody, stateAfter0) = specializeExpr bodyExpr refinedSubst stateWithLambda`
   - Pop frame after specialization

7. **Compute closure captures:**
   - `captures = Closure.computeClosureCaptures monoParams monoBody`
   - Returns list of (name, expr, type) tuples

8. **Return with ORIGINAL (not flattened) type:**
   - `monoTypeFixed = monoType0` (preserve staging)
   - GlobalOpt will flatten via GOPT_001
   - Result: `Mono.MonoClosure closureInfo monoBody monoTypeFixed`

---

## SPECIALIZENODE & CYCLES

### specializeFunc (lines 522-563)
Specializes a single function in a cycle.

- Use requestedMonoType as specId key (must match call sites)
- Other functions in cycle use monoTypeFromDef
- Register with `Registry.getOrCreateSpecId`
- Delegate to `specializeFuncDefInCycle`

### specializeFuncDefInCycle (lines 571-621)
For **Def nodes:**
- Specialize expr under subst
- `actualType = Mono.typeOf monoExpr`

For **TailDef nodes:**
- Specialize all args
- Push frame, insert args into varEnv
- Create augmentedSubst by unifying each (canParamType, monoParamType) pair
- Specialize body under augmentedSubst
- Pop frame
- **Critical:** Use augmentedSubst (not subst) for final function type
  - This ensures param constraints (CNumber -> MInt/MFloat) are reflected

---

## TYPESUBST - UNIFICATION & SUBSTITUTION

### unifyFuncCall (lines 45-62)
**Two-phase unification for function calls:**
```elm
unifyFuncCall funcCanType argMonoTypes resultCanType baseSubst -> Substitution
```

1. Unify args: `subst1 = unifyArgsOnly funcCanType argMonoTypes baseSubst`
2. Resolve arg types to avoid re-introducing MVars: `resolvedArgTypes = List.map (resolveMonoVars subst1) argMonoTypes`
3. Build desired function type: `desiredFuncMono = Mono.MFunction resolvedArgTypes (applySubst subst1 resultCanType)`
4. Final unification: `unifyHelp funcCanType desiredFuncMono subst1`

This ensures call-site constraints propagate into function's internal type variables.

### unifyExtend (line 76-77)
Alias for `unifyHelp`:
```elm
unifyExtend canType monoType baseSubst = unifyHelp canType monoType baseSubst
```

Used to enrich substitutions when concrete types are discovered (e.g., let-def actual types).

### unifyHelp (lines 83-194)
**Unification rules:**
- TVar: direct binding
- Primitive types (Int, Float, Bool, etc.): verify match
- TLambda + MFunction: unify args and result, recursing on remaining args
- TType + MCustom: unify argument types
- TRecord + MRecord: 
  - Unify matching fields
  - For extension var, bind remainder as MRecord
- TTuple + MTuple: unify element types
- TAlias: recursively unify inner types
- Non-matching: return unchanged

### applySubst (lines 388-520)
**Substitution application:**
- TVar: lookup in subst, apply constraint default (CNumber -> MInt, CEcoValue -> MVar)
- TLambda: preserve curried structure, apply to from/to recursively
- TType: recursively apply to args, handle elm/core builtins
- TRecord: merge base fields (from extension var) with explicit fields
  - `baseFields = case maybeExtension of Just extName -> Dict.get extName subst as MRecord`
  - `extensionFields = Dict.map (applySubst subst) fields`
  - `monoFields = Dict.union extensionFields baseFields`
- TTuple: apply to all elements
- TAlias: handle Filled vs Holey, apply to inner type

### resolveMonoVars (lines 241-267)
**Resolve MVars through substitution:**
- For MVar, lookup and resolve transitively
- For MFunction, resolve args and result
- For MList, MTuple, MRecord, MCustom: recursively resolve
- Leaves other types unchanged

### collectCanTypeVars (lines 273-305)
**Collect all TVar names from canonical type:**
- Recursive descent through all type constructors
- Returns list of variable names (may have duplicates)

### buildRenameMap (lines 312-326)
**Create fresh variable names to avoid collisions:**
- For each funcVarName that conflicts with callerVarName
- Generate freshName: `name ++ "__callee" ++ String.fromInt counter`
- Skip if already in renameMap

### renameCanTypeVars (lines 332-371)
**Apply rename map to canonical type:**
- Replace TVar names via map lookup
- Recursively apply to all constructors
- Preserves type structure

### unifyArgsOnly (lines 200-214)
**Helper for unifyFuncCall:**
- Peels TLambda from funcCanType and unifies with argTypes
- Stops when args exhausted or structure mismatches

### extractParamTypes (lines 223-232)
**Extract flat param list from curried function type:**
- For curried MFunction [argType] resultType
- Recursively extract args from result
- E.g., `(a -> x) -> (a, b) -> (x, b)` becomes `[MFunction [a] x, MTuple [a,b]]`

---

## TYPESUBST - CONSTRAINT MAPPING

### constraintFromName (in TypeSubst.elm)
Maps type variable names to constraints based on naming convention:
- Variables containing "number" → CNumber
- All others → CEcoValue

### canTypeToMonoType (in Monomorphize.elm)
One-shot conversion from canonical to mono type without substitution:
- Used for entry point type initialization
- Handles CNumber -> MInt default for unresolved number vars

---

## PROCESSING CALL ARGUMENTS

### processCallArgs (lines 1572-1669)
**Two-phase deferred processing:**
```elm
processCallArgs args subst state -> (List ProcessedArg, List Mono.MonoType, MonoState)
```

Uses List.foldr (processes right-to-left, accumulates in reverse).

**Deferred cases:**
1. **Accessor**: Deferred because we need fully-resolved record type from parameter
   - `PendingAccessor region fieldName canType`
   - Type for unification only (may have incomplete row)

2. **VarKernel (NumberBoxed)**: Deferred for post-unification specialization
   - `PendingKernel region home name canType`
   - Non-number-boxed kernels specialized immediately

3. **VarLocal/TrackedVarLocal (multi-target)**: Deferred
   - `LocalFunArg name canType`
   - Single-target locals specialize immediately

4. **All others**: Specialize immediately

### resolveProcessedArgs (lines 1820-1840)
**Resolves deferred args with unified param types:**
```elm
resolveProcessedArgs : List ProcessedArg -> List Mono.MonoType -> Substitution -> MonoState
                    -> (List Mono.MonoExpr, MonoState)
```

For each processed arg:
1. Get corresponding param type (zip with list)
2. Call `resolveProcessedArg` with that param type
3. Accumulate resolved exprs

### resolveProcessedArg (lines 1684-1809)
**Resolves individual deferred args:**

**ResolvedArg**: Pass through

**PendingAccessor**:
- Get field type from parameter's record layout
- Create accessor virtual global with full record type
- Register in worklist for specialization
- Return: `Mono.MonoVarGlobal region specId accessorMonoType`

**PendingKernel**:
- Re-derive kernel ABI type with call-site substitution
- Now has fully-resolved types for numeric kernel selection
- Return: `Mono.MonoVarKernel region home name kernelMonoType`

**LocalFunArg**:
- If param is MFunction, refine subst via unification
- If local is multi-target, get/create instance with refined subst
- Otherwise use original name with mono type from subst
- Return: `Mono.MonoVarLocal name funcMonoType`

---

## ERASURE - DEAD SPECS & PHANTOM VARS

### monomorphizeFromEntry (lines 73-220 in Monomorphize.elm)
**Main entry point with key-type-aware erasure:**

1. Run specialization to fixpoint via `processWorklist`
2. Determine value-used set: `BitSet` of specs referenced via MonoVarGlobal
3. **Key-type-aware patching:**
   ```
   For each spec:
   - If NOT value-used: erase ALL MVars (dead code)
   - Else if key type contains CEcoValue: erase only CEcoValue MVars (phantom)
   - Else: leave unchanged (fully constrained)
   ```
4. Update registry reverseMapping and rebuild mapping (maintain MONO_017)

### patchNodeTypesToErased (lines 578-594)
**Erase ALL MVars to MErased for dead-value specs:**
- Applies to: MonoDefine, MonoTailFunc
- Skips: MonoCycle (preserve for MONO_021 visibility), ports, externs, managers, ctors/enums

Uses: `Mono.eraseTypeVarsToErased` (in Monomorphized.elm)

### patchNodeTypesCEcoToErased (lines 606-629)
**Erase only CEcoValue MVars for polymorphic-key value-used specs:**
- Applies to: MonoDefine, MonoTailFunc, MonoCycle
- Skips: ports, externs, managers, ctors/enums

Uses: `Mono.eraseCEcoVarsToErased` (in Monomorphized.elm)

### Erasure Functions (in Monomorphized.elm)

**eraseTypeVarsToErased:**
```elm
eraseTypeVarsToErased monoType = Tuple.second (eraseTypeVarsToErasedHelp monoType)
```

**eraseTypeVarsToErasedHelp (lines 329-393):**
- MVar (any) → MErased
- MList, MFunction, MTuple, MRecord, MCustom: recursively apply
- Others: unchanged
- Returns: (changed: Bool, newType: MonoType)

**eraseCEcoVarsToErased:**
```elm
eraseCEcoVarsToErased monoType = Tuple.second (eraseCEcoVarsToErasedHelp monoType)
```

**eraseCEcoVarsToErasedHelp (lines 478-545):**
- MVar _ CEcoValue → MErased
- MVar _ CNumber → unchanged (CNumber always resolves to concrete)
- MList, MFunction, MTuple, MRecord, MCustom: recursively apply
- Others: unchanged

### containsCEcoMVar (lines 431-455 in Monomorphized.elm)
**Test if type contains any CEcoValue MVar:**
```elm
containsCEcoMVar : MonoType -> Bool
```
Used to gate erasure decisions and infer concrete types from expressions.

---

## INVARIANTS - MONO_021 & MONO_024

### MONO_021: No CEcoValue in User Functions
**After monomorphization**, no user-defined function (MonoDefine, MonoTailFunc, MonoClosure) may contain MVar with CEcoValue in:
- Node MonoType (if MFunction)
- Parameter types
- Closure parameter types

**Exemptions:**
- Kernel nodes (MonoExtern, MonoManagerLeaf, Debug kernels)
- MErased (allowed in dead specs or as phantom vars)

**Test Logic:** (NoCEcoValueInUserFunctions.elm)
- Checks every spec's node
- Collects CEcoValue vars recursively
- Reports context + violated positions

### MONO_024: Fully Monomorphic Specs Have No CEcoValue
**For specializations with fully monomorphic key types** (no MVar, no MErased):
- ALL MonoTypes reachable from the node must contain NO CEcoValue
- Checks expression tree at all positions (not just function types)

**Rationale:**
- Fully monomorphic key means ALL call sites constrain all type vars
- Any surviving CEcoValue = failed substitution propagation

**Test Logic:** (FullyMonomorphicNoCEcoValue.elm)
- Iterate registry reverse mapping
- Skip non-fully-monomorphic and pruned entries
- Check expression tree comprehensively
- Reports all type positions with CEcoValue

---

## KEY HELPER FUNCTIONS

### Mono.typeOf(expr) → MonoType
Returns the type of a mono expression

### Mono.forceCNumberToInt(monoType) → MonoType
Converts CNumber MVars to MInt (default when CNumber unresolved)

### Mono.resultTypeOf(monoType) → MonoType
Extracts result type from nested MFunction

### Mono.containsAnyMVar(monoType) → Bool
Tests for any MVar (either constraint)

### Mono.nodeType(node) → MonoType
Returns the type annotation of a node

---

## CRITICAL INVARIANTS

1. **TOPT_005**: Lambda expr canType is TLambda (curried structure from Canonical)
2. **GOPT_001**: Closure params match stage arity; GlobalOpt flattens non-matching
3. **MONO_017**: SpecId reverse mapping matches actual node types
4. **MONO_021**: No CEcoValue MVar in user function types after mono
5. **MONO_024**: Fully monomorphic specs have no CEcoValue anywhere
6. **Substitution refinement**: Unify explicit constraints from:
   - Call-site arguments (unifyFuncCall)
   - Let-def actual types (unifyExtend)
   - Field/update context (field-level refinement in Record/Update cases)

---

## CALL FLOW SUMMARY

```
specializeExpr
├─ processCallArgs
│  └─ Returns deferred Accessors, NumberBoxed kernels, local multi-targets
├─ unifyFuncCall (for global functions)
│  └─ unifyArgsOnly + resolveMonoVars + final unifyHelp
├─ extractParamTypes (flatten curried type)
└─ resolveProcessedArgs
   └─ resolveProcessedArg (specializes Accessors via virtual globals, kernels, locals)
```
