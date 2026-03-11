# Monomorphization Code - Complete Snippets & Analysis

## FILE LOCATIONS
- Specialize.elm: `/work/compiler/src/Compiler/Monomorphize/Specialize.elm`
- TypeSubst.elm: `/work/compiler/src/Compiler/Monomorphize/TypeSubst.elm`
- Monomorphize.elm: `/work/compiler/src/Compiler/Monomorphize/Monomorphize.elm`
- Monomorphized.elm: `/work/compiler/src/Compiler/AST/Monomorphized.elm`

---

## TOpt.LIST SPECIALIZATION (lines 824-847)

```elm
TOpt.List region exprs canType ->
    let
        monoType0 =
            Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)

        ( monoExprs, stateAfter ) =
            specializeExprs exprs subst state

        -- If the canonical element type has unresolved TVars, infer from first element.
        monoType =
            if Mono.containsCEcoMVar monoType0 then
                case monoExprs of
                    first :: _ ->
                        Mono.MList (Mono.typeOf first)

                    [] ->
                        monoType0

            else
                monoType0
    in
    ( Mono.MonoList region monoExprs monoType, stateAfter )
```

**Key Pattern:**
1. Apply subst to canonical type to get initial mono type
2. Specialize all element expressions
3. If initial type has CEcoValue, **infer concrete type from first element's actual type**
4. This handles polymorphic lists where element constraint was never bound

---

## TOpt.RECORD SPECIALIZATION (lines 1397-1433)

```elm
TOpt.Record fields canType ->
    let
        monoType =
            Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)

        -- Extract mono field types from the record MonoType for substitution refinement.
        monoFieldTypes =
            case monoType of
                Mono.MRecord fieldMap ->
                    fieldMap

                _ ->
                    Dict.empty

        ( monoFields, stateAfter ) =
            Dict.foldl
                (\fieldName fieldExpr ( acc, st ) ->
                    let
                        -- Refine substitution per field: unify field's canonical type with
                        -- the expected mono type, so lambdas inside records get concrete types.
                        refinedSubst =
                            case Dict.get fieldName monoFieldTypes of
                                Just fieldMonoType ->
                                    TypeSubst.unifyExtend (TOpt.typeOf fieldExpr) fieldMonoType subst

                                Nothing ->
                                    subst

                        ( monoExpr, newSt ) =
                            specializeExpr fieldExpr refinedSubst st
                    in
                    ( ( fieldName, monoExpr ) :: acc, newSt )
                )
                ( [], state )
                fields
    in
    ( Mono.MonoRecordCreate monoFields monoType, stateAfter )
```

**Key Pattern:**
1. Get record mono type (includes field types from layout)
2. For each field, **unify field's canonical type with expected field mono type**
   - This propagates field constraints to lambdas inside fields
   - E.g., `{ fn = \x -> ... }` where `fn : Int -> Int` refines lambda's param type
3. Specialize each field with its own refined substitution
4. Preserve field order in monomorphic record layout

**CRITICAL:** Field names are used directly by codegen for layout lookup — order doesn't matter, names must be exact.

---

## TOpt.UPDATE SPECIALIZATION (lines 1341-1395)

```elm
TOpt.Update _ record updates canType ->
    let
        monoType =
            Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)

        ( monoRecord, state1 ) =
            specializeExpr record subst state

        -- Get canonical record type for field type lookup.
        -- This lets us propagate field type constraints into update lambdas.
        recordCanType =
            TOpt.typeOf record

        getFieldCanType fieldName =
            case recordCanType of
                Can.TRecord fields _ ->
                    case Dict.get fieldName fields of
                        Just (Can.FieldType _ fieldT) ->
                            Just fieldT

                        Nothing ->
                            Nothing

                _ ->
                    Nothing

        ( monoUpdates, state2 ) =
            Data.Map.foldl A.compareLocated
                (\locName updateExpr ( acc, st ) ->
                    let
                        fieldName =
                            A.toValue locName

                        refinedSubst =
                            case getFieldCanType fieldName of
                                Just fieldCanType ->
                                    let
                                        fieldMonoType =
                                            Mono.forceCNumberToInt
                                                (TypeSubst.applySubst subst fieldCanType)
                                    in
                                    TypeSubst.unifyExtend (TOpt.typeOf updateExpr) fieldMonoType subst

                                Nothing ->
                                    subst

                        ( monoExpr, newSt ) =
                            specializeExpr updateExpr refinedSubst st
                    in
                    ( ( fieldName, monoExpr ) :: acc, newSt )
                )
                ( [], state1 )
                updates
    in
    ( Mono.MonoRecordUpdate monoRecord monoUpdates monoType, state2 )
```

**Key Pattern:**
1. Specialize the record expression first (in base subst)
2. Get the **canonical** record type from the record expression (not the update result type)
3. For each field being updated:
   - Look up field's type in canonical record
   - Unify update expression's canonical type with that field type
   - This ensures `r { x = \y -> y + 1 }` gets numeric constraint on the lambda
4. Specialize each update expression with field-refined substitution

**Note:** Canonical record type may differ from update result type (result includes updates).

---

## TOpt.LAMBDA SPECIALIZATION (FULL - lines 178-264)

```elm
specializeLambda lambdaExpr canType subst state =
    let
        -- 1. Specialize the whole function type once (no flattening).
        -- Invariant: `canType` is the TLambda encoding of this function (TOPT_005).
        -- Monomorphize preserves the curried structure from TypeSubst.applySubst.
        -- The closure will have N params (from TOpt syntax) but type with stage arity < N.
        -- Example: \\x y -> body has params=2, type=MFunction [a] (MFunction [b] c) (stage arity 1).
        -- GlobalOpt (GOPT_001) will flatten: MFunction [a, b] c.
        monoType0 : Mono.MonoType
        monoType0 =
            Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)

        -- 1b. Feed the concrete function type back into the substitution.
        -- This propagates constraints from the enclosing specialization context
        -- (e.g. compose identity identity 1) into the lambda's internal type variables.
        -- unifyExtend only adds bindings already implied by monoType0, so this is safe.
        refinedSubst : Substitution
        refinedSubst =
            TypeSubst.unifyExtend canType monoType0 subst

        -- 2. Extract params and body directly (no peelFunctionChain).
        ( params, bodyExpr ) =
            case lambdaExpr of
                TOpt.Function ps body _ ->
                    ( ps, body )

                TOpt.TrackedFunction trackedPs body _ ->
                    ( List.map (\( locName, ty ) -> ( A.toValue locName, ty )) trackedPs, body )

                _ ->
                    Utils.Crash.crash
                        "specializeLambda: called with non-lambda expression"

        -- Guard: paramCount == 0 is a bug
        -- 3. Specialize each parameter's declared Can.Type under refinedSubst.
        monoParams : List ( Name, Mono.MonoType )
        monoParams =
            List.map
                (\( name, paramCanType ) ->
                    ( name, Mono.forceCNumberToInt (TypeSubst.applySubst refinedSubst paramCanType) )
                )
                params

        lambdaId =
            Mono.AnonymousLambda state.currentModule state.lambdaCounter

        newVarEnv =
            List.foldl
                (\( name, monoParamType ) ve ->
                    State.insertVar name monoParamType ve
                )
                (State.pushFrame state.varEnv)
                monoParams

        stateWithLambda =
            { state
                | lambdaCounter = state.lambdaCounter + 1
                , varEnv = newVarEnv
            }

        -- 4. Specialize the body under refinedSubst.
        ( monoBody, stateAfter0 ) =
            specializeExpr bodyExpr refinedSubst stateWithLambda

        stateAfter =
            { stateAfter0 | varEnv = State.popFrame stateAfter0.varEnv }

        -- 5. Compute captures.
        captures =
            Closure.computeClosureCaptures monoParams monoBody

        closureInfo =
            { lambdaId = lambdaId
            , captures = captures
            , params = monoParams
            , closureKind = Nothing
            , captureAbi = Nothing
            }

        -- 6. Use the monomorphic function type from TypeSubst.applySubst unchanged.
        -- Under staging-agnostic Monomorphize, we must NOT change the type's staging.
        -- GlobalOpt (GOPT_001) will canonicalize by flattening to match param count.
        monoTypeFixed : Mono.MonoType
        monoTypeFixed =
            monoType0
    in
    ( Mono.MonoClosure closureInfo monoBody monoTypeFixed, stateAfter )
```

**Critical Points:**
1. **Two-pass substitution:**
   - Apply subst to get monoType0 (initial specialization)
   - Unify monoType0 back into subst as refinedSubst (contextual constraints)
2. **Preserve curried structure:**
   - Do NOT flatten even if N params but type shows stage arity < N
   - GlobalOpt will flatten when canonicalizing (GOPT_001)
3. **Frame management:**
   - Push frame with params
   - Specialize body in local scope
   - Pop frame (captures already computed, so scoped vars not leaked)
4. **Closure captures computed from monoBody:**
   - Uses Closure.computeClosureCaptures (walks body, finds free non-params)
   - Returns (name, expr, type) tuples for captured variables

---

## UNIFY FUNC CALL (lines 45-62)

```elm
unifyFuncCall funcCanType argMonoTypes resultCanType baseSubst =
    let
        subst1 =
            unifyArgsOnly funcCanType argMonoTypes baseSubst

        desiredResultMono =
            applySubst subst1 resultCanType

        -- Resolve MVars in arg types through subst1 to avoid re-introducing
        -- unresolved MVars that would overwrite correct bindings during the
        -- final unification step.
        resolvedArgTypes =
            List.map (resolveMonoVars subst1) argMonoTypes

        desiredFuncMono =
            Mono.MFunction resolvedArgTypes desiredResultMono
    in
    unifyHelp funcCanType desiredFuncMono subst1
```

**Why two-phase?**
1. `unifyArgsOnly`: Peel TLambdas from funcCanType, unify with arg MonoTypes one-by-one
   - Gets initial substitution from call site
2. `resolveMonoVars`: Resolve any MVars in actual arg types through subst1
   - Prevents unresolved MVars from overwriting correct bindings in step 3
3. `unifyHelp`: Unify entire function type with desired type
   - Final unification catches any nested constraints

**Example:** `f x y` where `f : a -> a -> a` and `x : Int`, `y : String`
- Step 1: unifyArgsOnly infers a = Int from first arg
- Step 2: resolveMonoVars turns `String` into MString (concrete)
- Step 3: unifyHelp catches a mismatch: (Int -> Int -> Int) vs (Int -> String -> ?) 

---

## APPLY SUBST (lines 388-520)

```elm
applySubst subst canType =
    case canType of
        Can.TVar name ->
            case Data.Map.get identity name subst of
                Just monoType ->
                    monoType

                Nothing ->
                    let
                        constraint =
                            constraintFromName name
                    in
                    case constraint of
                        Mono.CNumber ->
                            Mono.MInt  -- Default for unresolved number

                        Mono.CEcoValue ->
                            Mono.MVar name constraint  -- Truly polymorphic

        Can.TLambda from to ->
            -- IMPORTANT: Preserve curried structure
            let
                argMono =
                    applySubst subst from

                resultMono =
                    applySubst subst to
            in
            Mono.MFunction [ argMono ] resultMono

        Can.TRecord fields maybeExtension ->
            let
                -- Get base fields from extension variable if present
                baseFields =
                    case maybeExtension of
                        Just extName ->
                            case Data.Map.get identity extName subst of
                                Just (Mono.MRecord baseFieldsDict) ->
                                    baseFieldsDict

                                _ ->
                                    Dict.empty

                        Nothing ->
                            Dict.empty

                -- Convert explicit fields to mono types
                extensionFields =
                    Dict.map (\_ (Can.FieldType _ t) -> applySubst subst t) fields

                -- Merge: extension fields override base fields
                monoFields =
                    Dict.union extensionFields baseFields
            in
            Mono.MRecord monoFields
        
        -- ... other cases (TTuple, TType, TUnit, TAlias)
```

**Record merging logic:**
1. If extension var present, look up its monomorphic value in subst
2. If bound to MRecord, use that as base fields
3. Apply subst to explicit fields from canonical record
4. Merge with `Dict.union` (explicit overrides base)

**Why important:** Preserves field constraints from prior unifications while adding newly-resolved fields.

---

## PROCESS CALL ARGS (lines 1572-1669)

```elm
processCallArgs args subst state =
    List.foldr
        (\arg ( accArgs, accTypes, st ) ->
            case arg of
                TOpt.Accessor region fieldName canType ->
                    let
                        monoType =
                            Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)
                    in
                    ( PendingAccessor region fieldName canType :: accArgs
                    , monoType :: accTypes
                    , st
                    )

                TOpt.VarKernel region home name canType ->
                    case KernelAbi.deriveKernelAbiMode ( home, name ) canType of
                        KernelAbi.NumberBoxed ->
                            let
                                monoType =
                                    Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)
                            in
                            ( PendingKernel region home name canType :: accArgs
                            , monoType :: accTypes
                            , st
                            )

                        _ ->
                            let
                                ( monoExpr, st1 ) =
                                    specializeExpr arg subst st
                            in
                            ( ResolvedArg monoExpr :: accArgs
                            , Mono.typeOf monoExpr :: accTypes
                            , st1
                            )

                _ ->
                    let
                        ( monoExpr, st1 ) =
                            specializeExpr arg subst st
                    in
                    ( ResolvedArg monoExpr :: accArgs
                    , Mono.typeOf monoExpr :: accTypes
                    , st1
                    )
        )
        ( [], [], state )
        args
```

**Deferred Processing Strategy:**
1. **Accessors**: Need fully-resolved record type from function parameter
   - Can't determine field offset until we know the record layout
2. **NumberBoxed kernels**: Need post-unification type info
   - `Basics.add` can be `Int -> Int -> Int` or boxed `a -> a -> a` depending on call site
3. **LocalFunArg**: Need to check if multi-target and get instance

**Why List.foldr?**
- Processes arguments right-to-left, accumulates in reverse order
- Maintains argument order in final result via List.reverse in resolveProcessedArgs

---

## RESOLVE PROCESSED ARG - ACCESSOR CASE (lines 1684-1745)

```elm
case processedArg of
    -- ...
    PendingAccessor region fieldName _ ->
        case maybeParamType of
            Just (Mono.MFunction [ Mono.MRecord fields ] _) ->
                -- The parameter type is a function from record to something.
                -- Derive accessor's MonoType from the full record layout.
                let
                    fieldType =
                        case Dict.get fieldName fields of
                            Just ft ->
                                ft

                            Nothing ->
                                Utils.Crash.crash (...)

                    recordType =
                        Mono.MRecord fields

                    accessorMonoType =
                        Mono.MFunction [ recordType ] fieldType

                    accessorGlobal =
                        Mono.Accessor fieldName

                    ( specId, newRegistry ) =
                        Registry.getOrCreateSpecId accessorGlobal accessorMonoType Nothing state.registry

                    newState =
                        { state
                            | registry = newRegistry
                            , worklist = SpecializeGlobal accessorGlobal accessorMonoType Nothing :: state.worklist
                        }
                in
                ( Mono.MonoVarGlobal region specId accessorMonoType, newState )

            Just (Mono.MRecord fields) ->
                -- The parameter type is directly a record (accessor applied to record).
                -- This case handles when the accessor IS the function being called.
                let
                    fieldType =
                        case Dict.get fieldName fields of
                            Just ft ->
                                ft

                            Nothing ->
                                Utils.Crash.crash (...)

                    recordType =
                        Mono.MRecord fields

                    accessorMonoType =
                        Mono.MFunction [ recordType ] fieldType

                    accessorGlobal =
                        Mono.Accessor fieldName

                    ( specId, newRegistry ) =
                        Registry.getOrCreateSpecId accessorGlobal accessorMonoType Nothing state.registry

                    newState =
                        { state
                            | registry = newRegistry
                            , worklist = SpecializeGlobal accessorGlobal accessorMonoType Nothing :: state.worklist
                        }
                in
                ( Mono.MonoVarGlobal region specId accessorMonoType, newState )

            _ ->
                Utils.Crash.crash "Specialize.resolveProcessedArg: Accessor argument did not receive a record parameter type..."
```

**Two cases for accessors:**
1. **Accessor as argument to function expecting `Record -> Type`**
   - Extract record type from outer MFunction
   - Build accessor as virtual global with full type
   
2. **Accessor IS the function (applied to record directly)**
   - Record type is the parameter type itself
   - Still creates virtual global for proper specialization

**Why virtual global?**
- Accessors need layout-aware code generation
- Specializing them as globals ensures proper offset computation
- Registration in worklist defers generation until record layout is known

---

## MONO_021 & MONO_024 TEST LOGIC

### MONO_021 Violations (from NoCEcoValueInUserFunctions.elm)
```elm
checkNode : Int -> Mono.MonoNode -> List Violation
checkNode specId node =
    case node of
        Mono.MonoDefine expr monoType ->
            checkNodeType ctx "MonoDefine" monoType
                ++ checkExpr ctx expr

        Mono.MonoTailFunc params expr monoType ->
            checkNodeType ctx "MonoTailFunc" monoType
                ++ checkParamTypes ctx "MonoTailFunc" params
                ++ checkExpr ctx expr

        -- Kernel nodes: CEcoValue is allowed (MONO_021 exemption)
        Mono.MonoExtern _ -> []
        Mono.MonoManagerLeaf _ _ -> []
```

**Checks:**
1. Node type (if MFunction, must not contain CEcoValue MVar)
2. Parameter types (for MonoTailFunc)
3. All expressions in body (recursive descent)
4. Closure info parameter types

### MONO_024 Violations (from FullyMonomorphicNoCEcoValue.elm)
```elm
checkNodeAllTypes : Int -> Mono.MonoType -> Mono.MonoNode -> List Violation
checkNodeAllTypes specId keyType node =
    case node of
        Mono.MonoDefine expr monoType ->
            checkType ctx "node type" monoType
                ++ checkExprAllTypes ctx expr

        Mono.MonoTailFunc params expr monoType ->
            checkType ctx "node type" monoType
                ++ checkParamTypes ctx params
                ++ checkExprAllTypes ctx expr
```

**Scope gating:**
```elm
isFullyMonomorphic : Mono.MonoType -> Bool
isFullyMonomorphic monoType =
    not (Mono.containsAnyMVar monoType) && not (containsMErased monoType)
```

Only checks specs whose key type is fully monomorphic (no MVars or MErased).

**Difference from MONO_021:**
- MONO_024 checks ALL MonoType positions in expression tree
- MONO_021 only checks function positions
- MONO_024 only applies to fully-monomorphic specs
- MONO_021 applies to all reachable user functions

---

## CRITICAL PATTERNS

### Pattern 1: Substitution Refinement
**When discovered concrete type:**
```elm
refinedSubst = TypeSubst.unifyExtend canonicalType monoType subst
```
Used in:
- Field specialization in Record/Update
- Parameter specialization in TailFunc
- Lambda type propagation in specializeLambda

### Pattern 2: CEcoValue Inference
**When type has unresolved polymorphism:**
```elm
if Mono.containsCEcoMVar monoType0 then
    inferFromExpression
else
    useCanonicalType
```
Used in:
- List element type inference
- Let-def type inference
- If-branch type inference
- TailCall result type inference

### Pattern 3: Virtual Global Specialization
**For layout-aware constructs:**
```elm
( specId, newRegistry ) = Registry.getOrCreateSpecId global monoType Nothing state.registry
newState = { state | worklist = SpecializeGlobal global monoType Nothing :: state.worklist }
```
Used for:
- Accessors (need record layout)
- Global variables (permit deferred monomorphization)
- Constructors and enums (layout-dependent)

### Pattern 4: State Accumulation
**Threading state through specialization:**
```elm
( monoExpr1, state1 ) = specializeExpr expr1 subst state
( monoExpr2, state2 ) = specializeExpr expr2 subst state1
( monoExpr3, state3 ) = specializeExpr expr3 subst state2
```
Accumulates:
- Worklist items (global specs to process)
- Registry (SpecId allocations)
- Lambda counter (for anonymous lambda IDs)
- VarEnv (local variable types)

---

## MEMORY INEFFICIENCIES REFERENCE

From monomorphize/memory_inefficiencies memory:

1. **Worklist prepending (O(n²)):** Each prepend with `::` traverses list
   - Fix: Use append/DList or reverse final result

2. **Repeated substitution:** applySubst called multiple times without memoization
   - Fix: Cache results

3. **Dict.values + List.foldl:** Creates unnecessary intermediate list
   - Fix: Use Dict.foldl directly

4. **State record updates:** Millions of allocations for worklist prepending
   - Fix: Batch updates

5. **VarTypes accumulation/clearing:** Wasted scoping across function boundaries
   - Fix: Stack-based approach

---

## SUGGESTED TEST CASES

For understanding code flow:

1. **Simple record with lambdas:**
   - `{ f = \x -> x + 1, y = 5 }` with `{ f : Int -> Int, y : Int }`
   - Traces field refinement in Record case

2. **Accessor in call:**
   - `map .x [{ x = 1 }, { x = 2 }]`
   - Traces PendingAccessor -> virtual global specialization

3. **NumberBoxed kernel:**
   - `List.foldl (+) 0 [1,2,3]`
   - Traces PendingKernel deferred specialization

4. **Local multi-target:**
   - `let f = \x -> x + 1 in (f 1, f "a")`
   - Traces LocalFunArg instance creation

5. **Polymorphic list inference:**
   - `[id]` where `id : a -> a`
   - Traces CEcoValue inference from first element

