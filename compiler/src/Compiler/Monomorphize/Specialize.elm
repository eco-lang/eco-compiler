module Compiler.Monomorphize.Specialize exposing (specializeNode)

{-| Expression and node specialization for monomorphization.

This module handles converting typed optimized expressions and nodes
into monomorphized form by applying type substitutions.


# Specialization

@docs specializeNode

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.BitSet as BitSet
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.AST.DecisionTree.TypedPath as TypedPath
import Compiler.LocalOpt.Typed.DecisionTree as DT
import Compiler.Monomorphize.Analysis as Analysis
import Compiler.Monomorphize.Closure as Closure
import Compiler.Monomorphize.KernelAbi as KernelAbi
import Compiler.Monomorphize.Registry as Registry
import Compiler.Monomorphize.State as State exposing (LocalMultiState, MonoState, SchemeInfo, SpecAccum, SpecContext, Substitution, ValueInstanceInfo, ValueMultiState, VarEnv, WorkItem(..))
import Compiler.Monomorphize.TypeSubst as TypeSubst
import Compiler.Reporting.Annotation as A
import Data.Map
import Data.Set as EverySet
import Dict exposing (Dict)
import System.TypeCheck.IO as IO
import Utils.Crash



-- ========== INTERNAL TYPES ==========


{-| A processed argument that might be pending specialization.

Accessors need special handling because they must be specialized AFTER
call-site type unification to receive the fully-resolved record type.

Number-boxed kernels (like Basics.add) need special handling because they
must be specialized AFTER call-site type unification to determine if they
can use the monomorphic numeric type (enabling intrinsics) or must fall
back to the boxed ABI.

-}
type ProcessedArg
    = ResolvedArg Mono.MonoExpr
    | PendingAccessor A.Region Name Can.Type
    | PendingKernel A.Region String String Can.Type
    | PendingGlobal TOpt.Expr Substitution Can.Type
    | LocalFunArg Name Can.Type


-- ========== CALL-SITE TYPE RENAMING ==========


buildRenameMap : Int -> List Name -> List Name -> Data.Map.Dict String Name Name -> Int -> Data.Map.Dict String Name Name
buildRenameMap epoch callerVarNames funcVarNames acc counter =
    case funcVarNames of
        [] ->
            acc

        name :: rest ->
            if List.member name callerVarNames && not (Data.Map.member identity name acc) then
                let
                    freshName =
                        name ++ "__callee" ++ String.fromInt epoch ++ "_" ++ String.fromInt counter
                in
                buildRenameMap epoch callerVarNames rest (Data.Map.insert identity name freshName acc) (counter + 1)

            else
                buildRenameMap epoch callerVarNames rest acc counter


renameCanTypeVars : Data.Map.Dict String Name Name -> Can.Type -> Can.Type
renameCanTypeVars renameMap canType =
    case canType of
        Can.TVar name ->
            case Data.Map.get identity name renameMap of
                Just newName ->
                    Can.TVar newName

                Nothing ->
                    canType

        Can.TLambda from to ->
            Can.TLambda (renameCanTypeVars renameMap from) (renameCanTypeVars renameMap to)

        Can.TType canonical name args ->
            Can.TType canonical name (List.map (renameCanTypeVars renameMap) args)

        Can.TRecord fields ext ->
            Can.TRecord
                (Dict.map (\_ (Can.FieldType idx t) -> Can.FieldType idx (renameCanTypeVars renameMap t)) fields)
                ext

        Can.TTuple a b rest ->
            Can.TTuple
                (renameCanTypeVars renameMap a)
                (renameCanTypeVars renameMap b)
                (List.map (renameCanTypeVars renameMap) rest)

        Can.TAlias canonical name aliasArgs aliasType ->
            Can.TAlias canonical
                name
                (List.map (\( n, t ) -> ( n, renameCanTypeVars renameMap t )) aliasArgs)
                (case aliasType of
                    Can.Filled inner ->
                        Can.Filled (renameCanTypeVars renameMap inner)

                    Can.Holey inner ->
                        Can.Holey (renameCanTypeVars renameMap inner)
                )

        Can.TUnit ->
            canType


{-| Get or build SchemeInfo for a callee, using the cache in MonoState.
For top-level globals, looks up and caches by global identity.
For local/anonymous callees, builds on demand without caching.
-}
getOrBuildSchemeInfo : Can.Type -> Maybe TOpt.Global -> MonoState -> ( SchemeInfo, MonoState )
getOrBuildSchemeInfo funcCanType maybeGlobal state =
    case maybeGlobal of
        Just global ->
            let
                accum =
                    state.accum
            in
            case Data.Map.get TOpt.toComparableGlobal global accum.schemeCache of
                Just info ->
                    ( info, state )

                Nothing ->
                    let
                        prefix =
                            String.join "_" (TOpt.toComparableGlobal global)

                        info =
                            TypeSubst.buildSchemeInfo prefix funcCanType

                        newCache =
                            Data.Map.insert TOpt.toComparableGlobal global info accum.schemeCache
                    in
                    ( info, { state | accum = { accum | schemeCache = newCache } } )

        Nothing ->
            -- Local/anonymous callee: build on demand, don't cache
            ( TypeSubst.buildSchemeInfo "__local" funcCanType, state )


{-| Unify call-site types with renaming to avoid type variable collisions.

Uses SchemeInfo's pre-renamed types when the callee's canonical var names
don't conflict with the caller's substitution keys (common case).
Falls back to per-call renaming when conflicts exist.

Returns the updated substitution, the renamed funcCanType (for kernel ABI
derivation), and the funcMonoType (computed in a single pass).
-}
unifyCallSiteWithRenaming :
    Can.Type
    -> List Mono.MonoType
    -> Can.Type
    -> Substitution
    -> Int
    -> SchemeInfo
    -> { callSubst : Substitution, callSubstAligned : Substitution, renamedFuncType : Can.Type, funcMonoType : Mono.MonoType }
unifyCallSiteWithRenaming funcCanType argMonoTypes resultCanType baseSubst epoch info =
    let
        callerVarNames =
            Dict.keys baseSubst

        -- Check if pre-renamed var names conflict with caller's substitution keys
        hasConflict =
            List.any (\name -> List.member name callerVarNames) info.renamedVarNames

        renameMapUsed =
            if hasConflict then
                buildRenameMap epoch callerVarNames info.varNames Data.Map.empty 0

            else
                info.preRenameMap

        ( renamedArgTypes, renamedResultType, renamedFuncType ) =
            if hasConflict then
                ( List.map (renameCanTypeVars renameMapUsed) info.argTypes
                , resultCanType
                , renameCanTypeVars renameMapUsed funcCanType
                )

            else
                ( info.renamedArgTypes
                , resultCanType
                , info.renamedFuncType
                )

        -- Single-pass: unify args, resolve, build funcMonoType all at once
        ( callSubst, funcMonoType ) =
            TypeSubst.unifyCallSiteDirect renamedArgTypes renamedResultType argMonoTypes baseSubst

        -- Apply reverse renaming: copy renamed-keyed bindings to original-keyed
        -- so downstream consumers using original Can.Type names find correct bindings
        callSubstAligned =
            TypeSubst.applyReverseRenaming callSubst renameMapUsed
    in
    { callSubst = callSubst
    , callSubstAligned = callSubstAligned
    , renamedFuncType = renamedFuncType
    , funcMonoType = funcMonoType
    }


{-| Rename type variables in the result Can.Type using the same mapping
as SchemeInfo's pre-rename. Since resultCanType shares type variables with
funcCanType, we can reuse the pre-rename's variable mapping.
-}
renameResultCanType : SchemeInfo -> Can.Type -> Can.Type
renameResultCanType info resultCanType =
    renameCanTypeVars info.preRenameMap resultCanType


{-| Enqueue a specialization onto the worklist, deduplicating via the scheduled BitSet.
-}
enqueueSpec :
    Mono.Global
    -> Mono.MonoType
    -> Maybe Mono.LambdaId
    -> MonoState
    -> ( Mono.SpecId, MonoState )
enqueueSpec global monoType maybeLambda state =
    let
        accum =
            state.accum

        ( specId, newRegistry ) =
            Registry.getOrCreateSpecId global monoType maybeLambda accum.registry
    in
    if BitSet.member specId accum.scheduled then
        ( specId, { state | accum = { accum | registry = newRegistry } } )

    else
        ( specId
        , { state
            | accum =
                { accum
                    | registry = newRegistry
                    , scheduled = BitSet.insertGrowing specId accum.scheduled
                    , worklist = SpecializeGlobal specId :: accum.worklist
                }
          }
        )


{-| Check if the given name matches any active localMulti context in the stack.
-}
isLocalMultiTarget : Name -> MonoState -> Bool
isLocalMultiTarget name state =
    List.any (\ls -> ls.defName == name) state.ctx.localMulti


{-| Allocate or reuse a local function instance for a let-bound function.

    Searches the localMulti stack for the entry matching `defName`, and
    either returns an existing instance or creates a new one.

-}
getOrCreateLocalInstance :
    Name
    -> Mono.MonoType
    -> Substitution
    -> MonoState
    -> ( Name, MonoState )
getOrCreateLocalInstance defName funcMonoType callSubst state =
    let
        key =
            Mono.toComparableMonoType funcMonoType

        ( updatedStack, freshName ) =
            updateLocalMultiStack defName key funcMonoType callSubst state.ctx.localMulti
    in
    ( freshName, { state | ctx = let ctx = state.ctx in { ctx | localMulti = updatedStack } } )


{-| Walk the localMulti stack, find the entry for defName, and update it.
-}
updateLocalMultiStack :
    Name
    -> String
    -> Mono.MonoType
    -> Substitution
    -> List LocalMultiState
    -> ( List LocalMultiState, Name )
updateLocalMultiStack defName key funcMonoType callSubst stack =
    case stack of
        [] ->
            Utils.Crash.crash
                ("Specialize.updateLocalMultiStack: defName not found in stack: " ++ defName)

        localState :: rest ->
            if localState.defName == defName then
                case Dict.get key localState.instances of
                    Just info ->
                        ( stack, info.freshName )

                    Nothing ->
                        let
                            freshIndex =
                                Dict.size localState.instances

                            freshName =
                                if freshIndex == 0 then
                                    defName

                                else
                                    defName ++ "$" ++ String.fromInt freshIndex

                            newInfo =
                                { freshName = freshName
                                , monoType = funcMonoType
                                , subst = callSubst
                                }

                            newInstances =
                                Dict.insert key newInfo localState.instances

                            newLocalState =
                                { localState | instances = newInstances }
                        in
                        ( newLocalState :: rest, freshName )

            else
                let
                    ( updatedRest, freshName ) =
                        updateLocalMultiStack defName key funcMonoType callSubst rest
                in
                ( localState :: updatedRest, freshName )



-- ========== VALUE-MULTI SPECIALIZATION ==========


{-| Check if a Can.Type contains any TLambda anywhere in its structure.
-}
typeContainsLambda : Can.Type -> Bool
typeContainsLambda canType =
    case canType of
        Can.TLambda _ _ ->
            True

        Can.TType _ _ args ->
            List.any typeContainsLambda args

        Can.TRecord fields _ ->
            Dict.foldl (\_ (Can.FieldType _ t) acc -> acc || typeContainsLambda t) False fields

        Can.TTuple a b rest ->
            typeContainsLambda a || typeContainsLambda b || List.any typeContainsLambda rest

        Can.TAlias _ _ _ (Can.Filled inner) ->
            typeContainsLambda inner

        Can.TAlias _ _ _ (Can.Holey inner) ->
            typeContainsLambda inner

        Can.TVar _ ->
            False

        Can.TUnit ->
            False


{-| Check if a Can.Type contains any type variable with CEcoValue constraint.
-}
hasCEcoTVar : Can.Type -> Bool
hasCEcoTVar canType =
    let
        vars =
            TypeSubst.collectCanTypeVars canType []
    in
    List.any (\name -> TypeSubst.constraintFromName name == Mono.CEcoValue) vars


{-| Should this non-function let binding use value-multi specialization?
True when the type contains lambdas AND unconstrained CEco type variables.
-}
shouldUseValueMulti : Can.Type -> Bool
shouldUseValueMulti defCanType =
    typeContainsLambda defCanType && hasCEcoTVar defCanType


{-| Check if the given name matches any active valueMulti context in the stack.
-}
isValueMultiTarget : Name -> MonoState -> Bool
isValueMultiTarget name state =
    List.any (\entry -> entry.defName == name) state.ctx.valueMulti


{-| Check if an expression is a VarLocal/TrackedVarLocal that is a value-multi target.
Returns the variable name and its canonical type if so.
-}
getValueMultiVar : TOpt.Expr -> MonoState -> Maybe ( Name, Can.Type )
getValueMultiVar expr state =
    case expr of
        TOpt.VarLocal name meta ->
            if isValueMultiTarget name state then
                Just ( name, meta.tipe )

            else
                Nothing

        TOpt.TrackedVarLocal _ name meta ->
            if isValueMultiTarget name state then
                Just ( name, meta.tipe )

            else
                Nothing

        _ ->
            Nothing


{-| Allocate or reuse a value instance for a let-bound value with lambdas.
-}
getOrCreateValueInstance :
    Name
    -> Mono.MonoType
    -> Substitution
    -> MonoState
    -> ( Name, MonoState )
getOrCreateValueInstance defName monoType currentSubst state =
    let
        key =
            Mono.toComparableMonoType monoType

        ( updatedStack, freshName_ ) =
            updateValueMultiStack defName key monoType currentSubst state.ctx.valueMulti
    in
    ( freshName_, { state | ctx = let ctx = state.ctx in { ctx | valueMulti = updatedStack } } )


{-| Walk the valueMulti stack, find the entry for defName, and update it.
-}
updateValueMultiStack :
    Name
    -> String
    -> Mono.MonoType
    -> Substitution
    -> List ValueMultiState
    -> ( List ValueMultiState, Name )
updateValueMultiStack defName key monoType currentSubst stack =
    case stack of
        [] ->
            Utils.Crash.crash
                ("Specialize.updateValueMultiStack: defName not found in stack: " ++ defName)

        entry :: rest ->
            if entry.defName == defName then
                case Dict.get key entry.instances of
                    Just info ->
                        ( stack, info.freshName )

                    Nothing ->
                        let
                            freshIndex =
                                Dict.size entry.instances

                            freshName_ =
                                if freshIndex == 0 then
                                    defName

                                else
                                    defName ++ "$v" ++ String.fromInt freshIndex

                            newInfo =
                                { freshName = freshName_
                                , monoType = monoType
                                , subst = currentSubst
                                }

                            newInstances =
                                Dict.insert key newInfo entry.instances

                            newEntry =
                                { entry | instances = newInstances }
                        in
                        ( newEntry :: rest, freshName_ )

            else
                let
                    ( updatedRest, freshName_ ) =
                        updateValueMultiStack defName key monoType currentSubst rest
                in
                ( entry :: updatedRest, freshName_ )


{-| Specialize a lambda expression (Function or TrackedFunction).

This is a staging-agnostic specialization that:

1.  Specializes exactly one lambda node at a time (no peelFunctionChain)
2.  Preserves the syntactic structure: `\x y -> body` vs `\x -> \y -> body`
3.  Does NOT enforce staging invariants (that's GlobalOpt's job as GOPT\_016)

After this pass:

  - `\x y -> body` (one TOpt.Function [x,y] body) → one MonoClosure with 2 params
  - `\x -> \y -> body` (nested TOpt.Function) → outer closure with 1 param,
    body contains inner closure

IMPORTANT: The closure may have more params than the type's stage arity.
This is INTENTIONAL. Example:

    \x y -> body
    produces: params=[(x,Int),(y,Int)], type=MFunction [Int] (MFunction [Int] Int)

The flat param list comes from TOpt.Function syntax.
The curried type comes from TypeSubst.applySubst preserving TLambda structure.

GlobalOpt (GOPT\_016) will canonicalize by flattening the type:
MFunction [Int] (MFunction [Int] Int) → MFunction [Int, Int] Int

Invariant relied upon: TOPT\_005 - the Can.Type on the TOpt node is the
authoritative TLambda encoding of this function's params and result.

-}
specializeLambda :
    TOpt.Expr
    -> Can.Type
    -> Substitution
    -> MonoState
    -> ( Mono.MonoExpr, MonoState )
specializeLambda lambdaExpr canType subst state =
    let
        -- 1. Specialize the whole function type once (no flattening).
        -- Invariant: `canType` is the TLambda encoding of this function (TOPT_005).
        -- Monomorphize preserves the curried structure from TypeSubst.applySubst.
        -- The closure will have N params (from TOpt syntax) but type with stage arity < N.
        -- Example: \x y -> body has params=2, type=MFunction [a] (MFunction [b] c) (stage arity 1).
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

        ctx =
            state.ctx

        lambdaId =
            Mono.AnonymousLambda ctx.currentModule ctx.lambdaCounter

        newVarEnv =
            List.foldl
                (\( name, monoParamType ) ve ->
                    State.insertVar name monoParamType ve
                )
                (State.pushFrame ctx.varEnv)
                monoParams

        stateWithLambda =
            { state
                | ctx =
                    { ctx
                        | lambdaCounter = ctx.lambdaCounter + 1
                        , varEnv = newVarEnv
                    }
            }

        -- 4. Specialize the body under refinedSubst.
        ( monoBody, stateAfter0 ) =
            specializeExpr bodyExpr refinedSubst stateWithLambda

        stateAfter =
            { stateAfter0 | ctx = let ctx0 = stateAfter0.ctx in { ctx0 | varEnv = State.popFrame ctx0.varEnv } }

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



-- ========== NODE SPECIALIZATION ==========


{-| Specialize a typed optimized node to a monomorphized node at the requested concrete type.
The ctorName parameter is used to populate CtorLayout.name for constructor nodes.
-}
specializeNode : Name.Name -> TOpt.Node -> Mono.MonoType -> MonoState -> ( Mono.MonoNode, MonoState )
specializeNode ctorName node requestedMonoType state =
    case node of
        TOpt.Define expr _ meta ->
            let
                canType =
                    meta.tipe

                subst0 =
                    TypeSubst.unify canType requestedMonoType

                -- Also unify the body expression's canonical type with requestedMonoType.
                -- The annotation canType may be fully resolved (no TVars) while internal
                -- expressions retain unresolved TVars. This enriches the substitution
                -- with bindings for those internal TVars.
                subst =
                    TypeSubst.unifyExtend (TOpt.typeOf expr) requestedMonoType subst0

                ( monoExpr, state1 ) =
                    specializeExpr expr subst state

                -- GlobalOpt will wrap bare expressions in closures via ensureCallableForNode
                actualType =
                    Mono.typeOf monoExpr
            in
            ( Mono.MonoDefine monoExpr actualType, state1 )

        TOpt.TrackedDefine _ expr _ meta ->
            let
                canType =
                    meta.tipe

                subst0 =
                    TypeSubst.unify canType requestedMonoType

                subst =
                    TypeSubst.unifyExtend (TOpt.typeOf expr) requestedMonoType subst0

                ( monoExpr, state1 ) =
                    specializeExpr expr subst state

                -- GlobalOpt will wrap bare expressions in closures via ensureCallableForNode
                actualType =
                    Mono.typeOf monoExpr
            in
            ( Mono.MonoDefine monoExpr actualType, state1 )

        TOpt.Ctor index arity canType ->
            let
                subst =
                    TypeSubst.unify canType requestedMonoType

                ctorMonoType =
                    Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)

                tag =
                    Index.toMachine index

                shape =
                    buildCtorShapeFromArity ctorName tag arity ctorMonoType

                ctorResultType =
                    extractCtorResultType arity requestedMonoType
            in
            ( Mono.MonoCtor shape ctorResultType, state )

        TOpt.Enum tag canType ->
            let
                monoType =
                    Mono.forceCNumberToInt (TypeSubst.applySubst (TypeSubst.unify canType requestedMonoType) canType)
            in
            ( Mono.MonoEnum (Index.toMachine tag) monoType, state )

        TOpt.Box canType ->
            -- @unbox types have a single constructor (tag=0) with one field (arity=1).
            -- Treat them as regular constructors so eco.construct.custom is emitted.
            let
                subst =
                    TypeSubst.unify canType requestedMonoType

                ctorMonoType =
                    Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)

                shape =
                    buildCtorShapeFromArity ctorName 0 1 ctorMonoType

                ctorResultType =
                    extractCtorResultType 1 requestedMonoType
            in
            ( Mono.MonoCtor shape ctorResultType, state )

        TOpt.Link linkedGlobal ->
            -- Link to another global - follow the link
            case Data.Map.get TOpt.toComparableGlobal linkedGlobal state.ctx.toptNodes of
                Nothing ->
                    ( Mono.MonoExtern requestedMonoType, state )

                Just linkedNode ->
                    let
                        linkedName =
                            case linkedGlobal of
                                TOpt.Global _ name ->
                                    name
                    in
                    specializeNode linkedName linkedNode requestedMonoType state

        TOpt.Kernel _ _ ->
            -- Inline kernel code - treat as extern
            ( Mono.MonoExtern requestedMonoType, state )

        TOpt.Manager _ ->
            -- Effect manager leaf: generate a function that calls Elm_Kernel_Platform_leaf
            let
                homeModuleName =
                    case state.ctx.currentGlobal of
                        Just (Mono.Global (IO.Canonical _ modName) _) ->
                            Name.toElmString modName

                        _ ->
                            "Unknown"
            in
            ( Mono.MonoManagerLeaf homeModuleName requestedMonoType, state )

        TOpt.Cycle names valueDefs funcDefs _ ->
            specializeCycle names valueDefs funcDefs requestedMonoType state

        TOpt.PortIncoming expr _ meta ->
            let
                canType =
                    meta.tipe

                subst =
                    TypeSubst.unify canType requestedMonoType

                ( monoExpr, state1 ) =
                    specializeExpr expr subst state
            in
            -- GlobalOpt will wrap bare expressions in closures via ensureCallableForNode
            ( Mono.MonoPortIncoming monoExpr requestedMonoType, state1 )

        TOpt.PortOutgoing expr _ meta ->
            let
                canType =
                    meta.tipe

                subst =
                    TypeSubst.unify canType requestedMonoType

                ( monoExpr, state1 ) =
                    specializeExpr expr subst state
            in
            -- GlobalOpt will wrap bare expressions in closures via ensureCallableForNode
            ( Mono.MonoPortOutgoing monoExpr requestedMonoType, state1 )


{-| Specialize a mutually recursive cycle, handling both value and function definitions.
-}
specializeCycle :
    List Name
    -> List ( Name, TOpt.Expr )
    -> List TOpt.Def
    -> Mono.MonoType
    -> MonoState
    -> ( Mono.MonoNode, MonoState )
specializeCycle _ valueDefs funcDefs requestedMonoType state =
    case ( List.isEmpty funcDefs, state.ctx.currentGlobal ) of
        ( True, _ ) ->
            specializeValueOnlyCycle valueDefs requestedMonoType state

        ( False, Nothing ) ->
            ( Mono.MonoExtern requestedMonoType, state )

        ( False, Just (Mono.Global requestedCanonical requestedName) ) ->
            specializeFunctionCycle
                requestedCanonical
                requestedName
                valueDefs
                funcDefs
                requestedMonoType
                state

        ( False, Just (Mono.Accessor _) ) ->
            -- Accessors are virtual globals and don't participate in cycles
            Utils.Crash.crash "Specialize.specializeCycle: Accessor should not appear in cycles"


{-| Specialize a cycle containing only value definitions.
-}
specializeValueOnlyCycle :
    List ( Name, TOpt.Expr )
    -> Mono.MonoType
    -> MonoState
    -> ( Mono.MonoNode, MonoState )
specializeValueOnlyCycle valueDefs requestedMonoType state =
    let
        subst =
            Dict.empty

        ( monoDefs, state1 ) =
            specializeValueDefs valueDefs subst state
    in
    ( Mono.MonoCycle monoDefs requestedMonoType, state1 )


{-| Specialize a cycle containing function definitions by creating separate nodes for each function.
-}
specializeFunctionCycle :
    IO.Canonical
    -> Name
    -> List ( Name, TOpt.Expr )
    -> List TOpt.Def
    -> Mono.MonoType
    -> MonoState
    -> ( Mono.MonoNode, MonoState )
specializeFunctionCycle requestedCanonical requestedName _ funcDefs requestedMonoType state =
    let
        maybeRequestedDef =
            List.filter (defHasName requestedName) funcDefs |> List.head

        sharedSubst : Substitution
        sharedSubst =
            case maybeRequestedDef of
                Just def ->
                    let
                        canType =
                            getDefCanonicalType def
                    in
                    TypeSubst.unify canType requestedMonoType

                Nothing ->
                    Dict.empty

        ( newNodes, stateAfter ) =
            List.foldl
                (specializeFunc requestedCanonical requestedName requestedMonoType sharedSubst)
                ( state.accum.nodes, state )
                funcDefs

        requestedGlobal =
            Mono.Global requestedCanonical requestedName

        ( requestedSpecId, _ ) =
            Registry.getOrCreateSpecId requestedGlobal requestedMonoType Nothing stateAfter.accum.registry
    in
    case Dict.get requestedSpecId newNodes of
        Just requestedNode ->
            ( requestedNode, { stateAfter | accum = let a = stateAfter.accum in { a | nodes = newNodes } } )

        Nothing ->
            ( Mono.MonoExtern requestedMonoType, { stateAfter | accum = let a = stateAfter.accum in { a | nodes = newNodes } } )


specializeFunc :
    IO.Canonical
    -> Name
    -> Mono.MonoType
    -> Substitution
    -> TOpt.Def
    -> ( Dict Int Mono.MonoNode, MonoState )
    -> ( Dict Int Mono.MonoNode, MonoState )
specializeFunc requestedCanonical requestedName requestedMonoType sharedSubst def ( accNodes, accState ) =
    let
        name =
            getDefName def

        globalFun =
            Mono.Global requestedCanonical name

        canType =
            getDefCanonicalType def

        monoTypeFromDef =
            Mono.forceCNumberToInt (TypeSubst.applySubst sharedSubst canType)

        -- For the requested function in this cycle, use the exact MonoType
        -- from the worklist (requestedMonoType) as the specialization key.
        -- This ensures the SpecId matches what call sites expect.
        monoTypeForSpecId =
            if name == requestedName then
                requestedMonoType

            else
                monoTypeFromDef

        accum =
            accState.accum

        ( specId, newRegistry ) =
            Registry.getOrCreateSpecId globalFun monoTypeForSpecId Nothing accum.registry

        accState1 =
            { accState | accum = { accum | registry = newRegistry } }
    in
    if Dict.member specId accNodes then
        ( accNodes, accState1 )

    else
        let
            ( monoNode, accState2 ) =
                specializeFuncDefInCycle sharedSubst def accState1

            nextNodes =
                Dict.insert specId monoNode accNodes
        in
        ( nextNodes, accState2 )


specializeFuncDefInCycle :
    Substitution
    -> TOpt.Def
    -> MonoState
    -> ( Mono.MonoNode, MonoState )
specializeFuncDefInCycle subst def state =
    case def of
        TOpt.Def _ _ expr _ ->
            let
                ( monoExpr, state1 ) =
                    specializeExpr expr subst state

                -- GlobalOpt will wrap bare expressions in closures via ensureCallableForNode
                actualType =
                    Mono.typeOf monoExpr
            in
            ( Mono.MonoDefine monoExpr actualType, state1 )

        TOpt.TailDef _ _ args body returnType _ ->
            let
                monoArgs =
                    List.map (specializeArg subst) args

                ctx =
                    state.ctx

                newVarEnv =
                    List.foldl
                        (\( name, monoParamType ) ve -> State.insertVar name monoParamType ve)
                        (State.pushFrame ctx.varEnv)
                        monoArgs

                stateWithParams =
                    { state | ctx = { ctx | varEnv = newVarEnv } }

                augmentedSubst =
                    List.foldl
                        (\( ( _, canParamType ), ( _, monoParamType ) ) s ->
                            TypeSubst.unifyExtend canParamType monoParamType s
                        )
                        subst
                        (List.map2 Tuple.pair args monoArgs)

                ( monoBody, state1pre ) =
                    specializeExpr body augmentedSubst stateWithParams

                state1 =
                    { state1pre | ctx = let ctx1 = state1pre.ctx in { ctx1 | varEnv = State.popFrame ctx1.varEnv } }

                -- Note: `returnType` is misleadingly named - it's actually the FULL function
                -- type of the definition (e.g., Int -> Int -> Int becomes MFunction [MInt] (MFunction [MInt] MInt)).
                -- Context.extractNodeSignature expects this full function type and extracts
                -- the actual return type from it.
                monoFuncType =
                    Mono.forceCNumberToInt (TypeSubst.applySubst augmentedSubst returnType)
            in
            ( Mono.MonoTailFunc monoArgs monoBody monoFuncType, state1 )



-- ========== VALUE DEFINITIONS ==========


{-| Specialize a list of value definitions in a cycle.
-}
specializeValueDefs :
    List ( Name, TOpt.Expr )
    -> Substitution
    -> MonoState
    -> ( List ( Name, Mono.MonoExpr ), MonoState )
specializeValueDefs values subst state =
    let
        ( revDefs, finalState ) =
            List.foldl
                (\( name, expr ) ( accDefs, accState ) ->
                    let
                        ( monoExpr, newState ) =
                            specializeExpr expr subst accState
                    in
                    ( ( name, monoExpr ) :: accDefs, newState )
                )
                ( [], state )
                values
    in
    ( List.reverse revDefs, finalState )



-- ========== EXPRESSION SPECIALIZATION ==========


{-| Specialize a typed optimized expression to a monomorphized expression by applying type substitutions.
-}
specializeExpr : TOpt.Expr -> Substitution -> MonoState -> ( Mono.MonoExpr, MonoState )
specializeExpr expr subst state =
    case expr of
        TOpt.Bool _ value _ ->
            ( Mono.MonoLiteral (Mono.LBool value) Mono.MBool, state )

        TOpt.Chr _ value _ ->
            ( Mono.MonoLiteral (Mono.LChar value) Mono.MChar, state )

        TOpt.Str _ value _ ->
            ( Mono.MonoLiteral (Mono.LStr value) Mono.MString, state )

        TOpt.Int _ value meta ->
            let
                canType =
                    meta.tipe

                monoType =
                    Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)
            in
            case monoType of
                Mono.MFloat ->
                    ( Mono.MonoLiteral (Mono.LFloat (toFloat value)) monoType, state )

                _ ->
                    ( Mono.MonoLiteral (Mono.LInt value) monoType, state )

        TOpt.Float _ value meta ->
            let
                canType =
                    meta.tipe

                monoType =
                    Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)
            in
            ( Mono.MonoLiteral (Mono.LFloat value) monoType, state )

        TOpt.VarLocal name meta ->
            let
                canType =
                    meta.tipe

                monoType =
                    Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)
            in
            if isLocalMultiTarget name state then
                let
                    ( freshName, state1 ) =
                        getOrCreateLocalInstance name monoType subst state
                in
                ( Mono.MonoVarLocal freshName monoType, state1 )

            else
                -- For value-multi targets, return the var as-is. Instance recording
                -- happens at use sites (Access, etc.) where concrete types are known.
                ( Mono.MonoVarLocal name monoType, state )

        TOpt.TrackedVarLocal _ name meta ->
            let
                canType =
                    meta.tipe

                monoType =
                    Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)
            in
            if isLocalMultiTarget name state then
                let
                    ( freshName, state1 ) =
                        getOrCreateLocalInstance name monoType subst state
                in
                ( Mono.MonoVarLocal freshName monoType, state1 )

            else
                -- For value-multi targets, return the var as-is. Instance recording
                -- happens at use sites (Access, etc.) where concrete types are known.
                ( Mono.MonoVarLocal name monoType, state )

        TOpt.VarGlobal region global meta ->
            let
                canType =
                    meta.tipe

                monoType0 =
                    Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)

                monoType =
                    case monoType0 of
                        Mono.MVar _ _ ->
                            case Data.Map.get TOpt.toComparableGlobal global state.ctx.toptNodes of
                                Just (TOpt.Define _ _ defMeta) ->
                                    Mono.forceCNumberToInt (TypeSubst.applySubst subst defMeta.tipe)

                                Just (TOpt.TrackedDefine _ _ _ defMeta) ->
                                    Mono.forceCNumberToInt (TypeSubst.applySubst subst defMeta.tipe)

                                Just (TOpt.Enum _ enumCanType) ->
                                    Mono.forceCNumberToInt (TypeSubst.applySubst subst enumCanType)

                                Just (TOpt.Ctor _ _ ctorCanType) ->
                                    Mono.forceCNumberToInt (TypeSubst.applySubst subst ctorCanType)

                                _ ->
                                    monoType0

                        _ ->
                            monoType0

                monoGlobal =
                    toptGlobalToMono global

                ( specId, newState ) =
                    enqueueSpec monoGlobal monoType Nothing state
            in
            ( Mono.MonoVarGlobal region specId monoType, newState )

        TOpt.VarEnum region global _ meta ->
            let
                canType =
                    meta.tipe

                monoType0 =
                    Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)

                monoType =
                    case monoType0 of
                        Mono.MVar _ _ ->
                            case Data.Map.get TOpt.toComparableGlobal global state.ctx.toptNodes of
                                Just (TOpt.Enum _ enumCanType) ->
                                    Mono.forceCNumberToInt (TypeSubst.applySubst subst enumCanType)

                                _ ->
                                    monoType0

                        _ ->
                            monoType0

                monoGlobal =
                    toptGlobalToMono global

                ( specId, newState ) =
                    enqueueSpec monoGlobal monoType Nothing state
            in
            ( Mono.MonoVarGlobal region specId monoType, newState )

        TOpt.VarBox region global meta ->
            let
                canType =
                    meta.tipe

                monoType =
                    Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)

                monoGlobal =
                    toptGlobalToMono global

                ( specId, newState ) =
                    enqueueSpec monoGlobal monoType Nothing state
            in
            ( Mono.MonoVarGlobal region specId monoType, newState )

        TOpt.VarCycle region canonical name meta ->
            let
                canType =
                    meta.tipe

                monoType =
                    Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)

                monoGlobal =
                    Mono.Global canonical name

                ( specId, newState ) =
                    enqueueSpec monoGlobal monoType Nothing state
            in
            ( Mono.MonoVarGlobal region specId monoType, newState )

        TOpt.VarDebug region name _ _ meta ->
            let
                canType =
                    meta.tipe

                funcMonoType =
                    deriveKernelAbiType ( "Debug", name ) canType subst
            in
            ( Mono.MonoVarKernel region "Debug" name funcMonoType, state )

        TOpt.VarKernel region home name meta ->
            let
                canType =
                    meta.tipe

                funcMonoType =
                    deriveKernelAbiType ( home, name ) canType subst
            in
            ( Mono.MonoVarKernel region home name funcMonoType, state )

        TOpt.List region exprs meta ->
            let
                canType =
                    meta.tipe

                monoType0 =
                    Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)

                ( monoExprs, stateAfter ) =
                    specializeExprs exprs subst state

                -- If the element type has unresolved TVars, infer from first element.
                monoType =
                    if Mono.containsAnyMVar monoType0 then
                        case monoExprs of
                            first :: _ ->
                                Mono.MList (Mono.typeOf first)

                            [] ->
                                -- Empty list: element type is unconstrained, leave as-is.
                                -- MVar _ CEcoValue compiles identically to eco.value.
                                monoType0

                    else
                        monoType0
            in
            ( Mono.MonoList region monoExprs monoType, stateAfter )

        TOpt.Function params body meta ->
            let
                canType =
                    meta.tipe
            in
            specializeLambda (TOpt.Function params body meta) canType subst state

        TOpt.TrackedFunction params body meta ->
            let
                canType =
                    meta.tipe
            in
            specializeLambda (TOpt.TrackedFunction params body meta) canType subst state

        TOpt.Call region func args meta ->
            -- Two-phase argument processing: defer accessor specialization until after
            -- call-site type unification, so accessors receive fully-resolved record types.
            let
                canType =
                    meta.tipe

                ( processedArgs, argTypes, state1 ) =
                    processCallArgs args subst state
            in
            case func of
                TOpt.VarGlobal funcRegion global funcMeta ->
                    let
                        funcCanType =
                            funcMeta.tipe

                        ( schemeInfo, state1a ) =
                            getOrBuildSchemeInfo funcCanType (Just global) state1

                        epoch =
                            state1a.ctx.renameEpoch

                        state1b =
                            { state1a | ctx = let c1a = state1a.ctx in { c1a | renameEpoch = epoch + 1 } }

                        unifyResult =
                            unifyCallSiteWithRenaming funcCanType argTypes canType subst epoch schemeInfo

                        callSubst =
                            unifyResult.callSubstAligned

                        funcMonoType =
                            Mono.forceCNumberToInt unifyResult.funcMonoType

                        paramTypes =
                            TypeSubst.extractParamTypes funcMonoType

                        ( monoArgs, state2 ) =
                            resolveProcessedArgs processedArgs paramTypes callSubst state1b

                        resultMonoType =
                            callResultMonoType subst callSubst canType

                        monoGlobal =
                            toptGlobalToMono global

                        ( specId, newState ) =
                            enqueueSpec monoGlobal funcMonoType Nothing state2

                        monoFunc =
                            Mono.MonoVarGlobal funcRegion specId funcMonoType
                    in
                    ( Mono.MonoCall region monoFunc monoArgs resultMonoType Mono.defaultCallInfo, newState )

                TOpt.VarKernel funcRegion home name funcMeta ->
                    let
                        funcCanType =
                            funcMeta.tipe

                        ( schemeInfo, state1a ) =
                            getOrBuildSchemeInfo funcCanType Nothing state1

                        epoch =
                            state1a.ctx.renameEpoch

                        state1b =
                            { state1a | ctx = let c1a = state1a.ctx in { c1a | renameEpoch = epoch + 1 } }

                        unifyResult =
                            unifyCallSiteWithRenaming funcCanType argTypes canType subst epoch schemeInfo

                        callSubst =
                            unifyResult.callSubstAligned

                        -- deriveKernelAbiType uses renamedFuncType (renamed namespace)
                        -- with callSubst (renamed-keyed) — both in renamed namespace
                        funcMonoType =
                            deriveKernelAbiType ( home, name ) unifyResult.renamedFuncType unifyResult.callSubst

                        paramTypes =
                            TypeSubst.extractParamTypes funcMonoType

                        ( monoArgs, state2 ) =
                            resolveProcessedArgs processedArgs paramTypes callSubst state1b

                        resultMonoType =
                            callResultMonoType subst callSubst canType

                        monoFunc =
                            Mono.MonoVarKernel funcRegion home name funcMonoType
                    in
                    ( Mono.MonoCall region monoFunc monoArgs resultMonoType Mono.defaultCallInfo, state2 )

                TOpt.VarDebug funcRegion name _ _ funcMeta ->
                    let
                        funcCanType =
                            funcMeta.tipe

                        ( schemeInfo, state1a ) =
                            getOrBuildSchemeInfo funcCanType Nothing state1

                        epoch =
                            state1a.ctx.renameEpoch

                        state1b =
                            { state1a | ctx = let c1a = state1a.ctx in { c1a | renameEpoch = epoch + 1 } }

                        unifyResult =
                            unifyCallSiteWithRenaming funcCanType argTypes canType subst epoch schemeInfo

                        callSubst =
                            unifyResult.callSubstAligned

                        -- deriveKernelAbiType uses renamedFuncType (renamed namespace)
                        -- with callSubst (renamed-keyed) — both in renamed namespace
                        funcMonoType =
                            deriveKernelAbiType ( "Debug", name ) unifyResult.renamedFuncType unifyResult.callSubst

                        paramTypes =
                            TypeSubst.extractParamTypes funcMonoType

                        ( monoArgs, state2 ) =
                            resolveProcessedArgs processedArgs paramTypes callSubst state1b

                        resultMonoType =
                            callResultMonoType subst callSubst canType

                        monoFunc =
                            Mono.MonoVarKernel funcRegion "Debug" name funcMonoType
                    in
                    ( Mono.MonoCall region monoFunc monoArgs resultMonoType Mono.defaultCallInfo, state2 )

                _ ->
                    -- Fallback: locally-bound or non-global function.
                    let
                        funcCanType =
                            TOpt.typeOf func

                        localMultiName =
                            case func of
                                TOpt.VarLocal name _ ->
                                    if isLocalMultiTarget name state1 then
                                        Just name

                                    else
                                        Nothing

                                TOpt.TrackedVarLocal _ name _ ->
                                    if isLocalMultiTarget name state1 then
                                        Just name

                                    else
                                        Nothing

                                _ ->
                                    Nothing
                    in
                    case localMultiName of
                        Just name ->
                            -- Local multi target: type variables are shared with enclosing
                            -- scope, so we must NOT rename them (no unifyFuncCall).
                            -- Use unifyArgsOnly to extend the caller's subst with arg bindings.
                            let
                                callSubst =
                                    TypeSubst.unifyArgsOnly funcCanType argTypes subst

                                funcMonoType =
                                    Mono.forceCNumberToInt (TypeSubst.applySubst callSubst funcCanType)

                                paramTypes =
                                    TypeSubst.extractParamTypes funcMonoType

                                ( monoArgs, state2 ) =
                                    resolveProcessedArgs processedArgs paramTypes callSubst state1

                                resultMonoType =
                                    callResultMonoType subst callSubst canType

                                ( freshName, state3 ) =
                                    getOrCreateLocalInstance name funcMonoType callSubst state2

                                monoFunc =
                                    Mono.MonoVarLocal freshName funcMonoType
                            in
                            ( Mono.MonoCall region monoFunc monoArgs resultMonoType Mono.defaultCallInfo
                            , state3
                            )

                        Nothing ->
                            -- Non-local function: use unifyFuncCall with rename to avoid
                            -- type variable name collisions between caller and callee.
                            let
                                ( schemeInfo, state1a ) =
                                    getOrBuildSchemeInfo funcCanType Nothing state1

                                epoch =
                                    state1a.ctx.renameEpoch

                                state1b =
                                    { state1a | ctx = let c1a = state1a.ctx in { c1a | renameEpoch = epoch + 1 } }

                                unifyResult =
                                    unifyCallSiteWithRenaming funcCanType argTypes canType subst epoch schemeInfo

                                callSubst =
                                    unifyResult.callSubstAligned

                                funcMonoType =
                                    Mono.forceCNumberToInt unifyResult.funcMonoType

                                paramTypes =
                                    TypeSubst.extractParamTypes funcMonoType

                                ( monoArgs, state2 ) =
                                    resolveProcessedArgs processedArgs paramTypes callSubst state1b

                                resultMonoType =
                                    callResultMonoType subst callSubst canType

                                ( monoFunc, state3 ) =
                                    specializeExpr func callSubst state2
                            in
                            ( Mono.MonoCall region monoFunc monoArgs resultMonoType Mono.defaultCallInfo
                            , state3
                            )

        TOpt.TailCall name args meta ->
            let
                canType =
                    meta.tipe

                monoType0 =
                    Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)

                ( monoArgs, stateAfter ) =
                    specializeNamedExprs args subst state

                -- If the canonical type had unresolved TVars (producing CEcoValue),
                -- look up the result type from the tail-called function's registered type.
                monoType =
                    if Mono.containsAnyMVar monoType0 then
                        case State.lookupVar name stateAfter.ctx.varEnv of
                            Just funcType ->
                                Mono.resultTypeOf funcType

                            Nothing ->
                                monoType0

                    else
                        monoType0
            in
            ( Mono.MonoTailCall name monoArgs monoType, stateAfter )

        TOpt.If branches final meta ->
            let
                canType =
                    meta.tipe

                monoType0 =
                    Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)

                ( monoBranches, state1 ) =
                    specializeBranches branches subst state

                ( monoFinal, state2 ) =
                    specializeExpr final subst state1

                -- If the canonical type had unresolved TVars (producing CEcoValue),
                -- infer the concrete type from the specialized final branch instead.
                monoType =
                    if Mono.containsAnyMVar monoType0 then
                        Mono.typeOf monoFinal

                    else
                        monoType0
            in
            ( Mono.MonoIf monoBranches monoFinal monoType, state2 )

        TOpt.Let def body meta ->
            let
                canType =
                    meta.tipe

                monoType0 =
                    Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)

                defName =
                    getDefName def

                defCanType =
                    getDefCanonicalType def
            in
            case defCanType of
                Can.TLambda _ _ ->
                    -- Function def: demand-driven local multi-specialization.
                    -- Push a fresh entry onto the localMulti stack for this defName.
                    let
                        newEntry =
                            { defName = defName
                            , instances = Dict.empty
                            }

                        stateForBody =
                            { state | ctx = let c = state.ctx in { c | localMulti = newEntry :: c.localMulti } }

                        -- Specialize the body under the outer substitution,
                        -- with the new localMulti stack entry for this defName.
                        ( monoBody, stateAfterBody ) =
                            specializeExpr body subst stateForBody
                    in
                    -- Pop our entry from the stack and extract discovered instances.
                    case stateAfterBody.ctx.localMulti of
                        topEntry :: restOfStack ->
                            if Dict.isEmpty topEntry.instances then
                                -- No calls to this def were recorded in the body:
                                -- fall back to single-instance behavior using the original name.
                                let
                                    -- Keep restOfStack so outer contexts are visible during specializeDef
                                    ( monoDef, state1 ) =
                                        specializeDef def subst { stateAfterBody | ctx = let cab = stateAfterBody.ctx in { cab | localMulti = restOfStack } }

                                    defMonoType0 =
                                        Mono.forceCNumberToInt (TypeSubst.applySubst subst defCanType)

                                    defMonoType =
                                        if Mono.containsAnyMVar defMonoType0 then
                                            monoDefExprType monoDef

                                        else
                                            defMonoType0

                                    -- Enrich substitution with bindings discovered from
                                    -- the concrete def type, so the body sees them.
                                    -- This mirrors the non-function let branch below.
                                    enrichedSubst =
                                        if Mono.containsAnyMVar defMonoType0 then
                                            TypeSubst.unifyExtend defCanType defMonoType subst

                                        else
                                            subst

                                    stateWithVar =
                                        { state1 | ctx = let c1 = state1.ctx in { c1 | varEnv = State.insertVar defName defMonoType c1.varEnv } }

                                    -- Re-specialize body with enriched substitution
                                    -- so downstream expressions see the concrete def type.
                                    ( monoBody2, state2 ) =
                                        if Mono.containsAnyMVar defMonoType0 then
                                            specializeExpr body enrichedSubst stateWithVar

                                        else
                                            ( monoBody, stateWithVar )
                                in
                                ( Mono.MonoLet monoDef
                                    monoBody2
                                    (if Mono.containsAnyMVar monoType0 then
                                        Mono.typeOf monoBody2

                                     else
                                        monoType0
                                    )
                                , state2
                                )

                            else
                                -- We have one or more concrete instances discovered from call sites.
                                let
                                    instancesList =
                                        Dict.values topEntry.instances

                                    -- Build MonoDefs for each instance, bridging call-site types
                                    -- to the def's own type variables via unifyExtend.
                                    -- info.subst uses renamed call-site variable names which
                                    -- don't match the def's canonical type variables; unifyExtend
                                    -- properly maps the def's variables to the call-site mono types.
                                    ( instanceDefs, stateWithDefs ) =
                                        List.foldl
                                            (\info ( defsAcc, stAcc ) ->
                                                let
                                                    mergedSubst =
                                                        TypeSubst.unifyExtend defCanType info.monoType subst

                                                    ( monoDef0, st1 ) =
                                                        specializeDef def mergedSubst stAcc

                                                    monoDef =
                                                        renameMonoDef info.freshName monoDef0
                                                in
                                                ( monoDef :: defsAcc, st1 )
                                            )
                                            ( [], { stateAfterBody | ctx = let cab2 = stateAfterBody.ctx in { cab2 | localMulti = restOfStack } } )
                                            instancesList

                                    -- Register varEnv for all instances
                                    stateWithVars =
                                        List.foldl
                                            (\info st ->
                                                { st
                                                    | ctx = let cst = st.ctx in
                                                        { cst | varEnv =
                                                            State.insertVar info.freshName info.monoType cst.varEnv
                                                        }
                                                }
                                            )
                                            stateWithDefs
                                            instancesList

                                    -- Build nested MonoLet chain
                                    finalExpr =
                                        List.foldl
                                            (\def_ accBody -> Mono.MonoLet def_ accBody (Mono.typeOf accBody))
                                            monoBody
                                            instanceDefs
                                in
                                ( finalExpr, stateWithVars )

                        [] ->
                            -- Should not happen: we pushed an entry above.
                            -- Fall back to single-instance behavior.
                            let
                                ( monoDef, state1 ) =
                                    specializeDef def subst stateAfterBody

                                defMonoType0 =
                                    Mono.forceCNumberToInt (TypeSubst.applySubst subst defCanType)

                                defMonoType =
                                    if Mono.containsAnyMVar defMonoType0 then
                                        monoDefExprType monoDef

                                    else
                                        defMonoType0

                                enrichedSubst =
                                    if Mono.containsAnyMVar defMonoType0 then
                                        TypeSubst.unifyExtend defCanType defMonoType subst

                                    else
                                        subst

                                stateWithVar =
                                    { state1 | ctx = let c1f = state1.ctx in { c1f | varEnv = State.insertVar defName defMonoType c1f.varEnv } }

                                ( monoBody2, state2 ) =
                                    if Mono.containsAnyMVar defMonoType0 then
                                        specializeExpr body enrichedSubst stateWithVar

                                    else
                                        ( monoBody, stateWithVar )
                            in
                            ( Mono.MonoLet monoDef
                                monoBody2
                                (if Mono.containsAnyMVar monoType0 then
                                    Mono.typeOf monoBody2

                                 else
                                    monoType0
                                )
                            , state2
                            )

                _ ->
                    if shouldUseValueMulti defCanType then
                        -- Value-multi path: defer specialization until uses are known.
                        let
                            newEntry =
                                { defName = defName
                                , defCanType = defCanType
                                , def = def
                                , instances = Dict.empty
                                }

                            -- Add defName to VarEnv with a preliminary type so that
                            -- Destruct nodes from LetDestruct can find their root variable.
                            -- (LetDestruct compiles to Let + Destruct chain where Destructs
                            -- reference Root defName.)
                            prelimDefMonoType =
                                Mono.forceCNumberToInt (TypeSubst.applySubst subst defCanType)

                            stateForBody =
                                { state | ctx = let cvm = state.ctx in
                                    { cvm
                                        | valueMulti = newEntry :: cvm.valueMulti
                                        , varEnv = State.insertVar defName prelimDefMonoType cvm.varEnv
                                    }
                                }

                            ( monoBody, stateAfterBody ) =
                                specializeExpr body subst stateForBody
                        in
                        case stateAfterBody.ctx.valueMulti of
                            topEntry :: restOfStack ->
                                if Dict.isEmpty topEntry.instances then
                                    -- Value never used: fall back to eager single-instance behavior.
                                    let
                                        ( monoDef, state1 ) =
                                            specializeDef def subst { stateAfterBody | ctx = let cvmf = stateAfterBody.ctx in { cvmf | valueMulti = restOfStack } }

                                        defMonoType0 =
                                            Mono.forceCNumberToInt (TypeSubst.applySubst subst defCanType)

                                        defMonoType =
                                            if Mono.containsAnyMVar defMonoType0 then
                                                monoDefExprType monoDef

                                            else
                                                defMonoType0

                                        enrichedSubst =
                                            if Mono.containsAnyMVar defMonoType0 then
                                                TypeSubst.unifyExtend defCanType defMonoType subst

                                            else
                                                subst

                                        stateWithVar =
                                            { state1 | ctx = let cvme = state1.ctx in { cvme | varEnv = State.insertVar defName defMonoType cvme.varEnv } }

                                        ( monoBody2, state2 ) =
                                            if Mono.containsAnyMVar defMonoType0 then
                                                specializeExpr body enrichedSubst stateWithVar

                                            else
                                                ( monoBody, stateWithVar )
                                    in
                                    ( Mono.MonoLet monoDef
                                        monoBody2
                                        (if Mono.containsAnyMVar monoType0 then
                                            Mono.typeOf monoBody2

                                         else
                                            monoType0
                                        )
                                    , state2
                                    )

                                else
                                    -- We have instances: specialize def once per requested type.
                                    let
                                        instancesList =
                                            Dict.values topEntry.instances

                                        ( instanceDefs, stateWithDefs ) =
                                            List.foldl
                                                (\info ( defsAcc, stAcc ) ->
                                                    let
                                                        mergedSubst =
                                                            TypeSubst.unifyExtend defCanType info.monoType subst

                                                        ( monoDef0, st1 ) =
                                                            specializeDef def mergedSubst stAcc

                                                        monoDef =
                                                            renameMonoDef info.freshName monoDef0
                                                    in
                                                    ( monoDef :: defsAcc, st1 )
                                                )
                                                ( [], { stateAfterBody | ctx = let cvmi = stateAfterBody.ctx in { cvmi | valueMulti = restOfStack } } )
                                                instancesList

                                        stateWithVars =
                                            List.foldl
                                                (\info st ->
                                                    { st
                                                        | ctx = let cvmv = st.ctx in
                                                            { cvmv | varEnv =
                                                                State.insertVar info.freshName info.monoType cvmv.varEnv
                                                            }
                                                    }
                                                )
                                                stateWithDefs
                                                instancesList

                                        finalExpr =
                                            List.foldl
                                                (\def_ accBody -> Mono.MonoLet def_ accBody (Mono.typeOf accBody))
                                                monoBody
                                                instanceDefs
                                    in
                                    ( finalExpr, stateWithVars )

                            [] ->
                                -- Stack underflow: should not happen.
                                Utils.Crash.crash "Specialize: valueMulti stack underflow in Let"

                    else
                        -- Non-function let: original eager behavior
                        let
                            ( monoDef, state1 ) =
                                specializeDef def subst state

                            defMonoType0 =
                                Mono.forceCNumberToInt (TypeSubst.applySubst subst defCanType)

                            -- If defCanType has unresolved TVars, infer from the specialized expr.
                            defMonoType =
                                if Mono.containsAnyMVar defMonoType0 then
                                    monoDefExprType monoDef

                                else
                                    defMonoType0

                            -- Also enrich the substitution with any bindings discovered
                            -- from the concrete def type, so the body sees them.
                            enrichedSubst =
                                if Mono.containsAnyMVar defMonoType0 then
                                    TypeSubst.unifyExtend defCanType defMonoType subst

                                else
                                    subst

                            stateWithVar =
                                { state1 | ctx = let c1n = state1.ctx in { c1n | varEnv = State.insertVar defName defMonoType c1n.varEnv } }

                            ( monoBody, state2 ) =
                                specializeExpr body enrichedSubst stateWithVar
                        in
                        ( Mono.MonoLet monoDef
                            monoBody
                            (if Mono.containsAnyMVar monoType0 then
                                Mono.typeOf monoBody

                             else
                                monoType0
                            )
                        , state2
                        )

        TOpt.Destruct destructor body meta ->
            let
                canType =
                    meta.tipe

                monoType0 =
                    Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)

                monoDestructor =
                    specializeDestructor destructor subst state.ctx.varEnv state.ctx.globalTypeEnv state.ctx.currentGlobal

                (Mono.MonoDestructor destructorName _ destructorType) =
                    monoDestructor

                stateWithVar =
                    { state | ctx = let cd = state.ctx in { cd | varEnv = State.insertVar destructorName destructorType cd.varEnv } }

                ( monoBody, stateAfter ) =
                    specializeExpr body subst stateWithVar

                monoType =
                    if Mono.containsAnyMVar monoType0 then
                        Mono.typeOf monoBody

                    else
                        monoType0
            in
            ( Mono.MonoDestruct monoDestructor monoBody monoType, stateAfter )

        TOpt.Case label root decider jumps meta ->
            -- ABI normalization for case expressions has been moved to MonoGlobalOptimize.
            -- Here we simply specialize the branches and use the type from the substitution.
            let
                canType =
                    meta.tipe

                monoTypeFromCan =
                    Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)

                savedVarEnv =
                    state.ctx.varEnv

                ( monoDecider0, state1 ) =
                    specializeDecider root decider subst state

                state1WithResetVarEnv =
                    { state1 | ctx = let cc = state1.ctx in { cc | varEnv = savedVarEnv } }

                ( monoJumps0, state2 ) =
                    specializeJumps jumps subst state1WithResetVarEnv
            in
            ( Mono.MonoCase label
                root
                monoDecider0
                monoJumps0
                (if Mono.containsAnyMVar monoTypeFromCan then
                    -- Infer from first jump or decider leaf
                    inferCaseType monoDecider0 monoJumps0 monoTypeFromCan

                 else
                    monoTypeFromCan
                )
            , state2
            )

        TOpt.Accessor region fieldName meta ->
            -- NOTE: This handles standalone accessor expressions (not passed as arguments).
            -- The MonoType derived here may have an incomplete record layout if the
            -- accessor's row variable is not yet bound in the substitution.
            --
            -- INVARIANT: Any accessor that is actually *invoked* at runtime must be
            -- specialized via the virtual-global mechanism (Mono.Accessor + worklist),
            -- which happens in resolveProcessedArg when the accessor is passed as an
            -- argument to a function call. The virtual-global path derives the accessor's
            -- MonoType from the fully-resolved parameter type, ensuring correct field indices.
            --
            -- A standalone accessor with incomplete type is only acceptable if it never
            -- participates in layout-dependent operations (e.g., dead code or debug output).
            let
                canType =
                    meta.tipe

                monoType =
                    Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)

                accessorGlobal =
                    Mono.Accessor fieldName

                ( specId, newState ) =
                    enqueueSpec accessorGlobal monoType Nothing state
            in
            ( Mono.MonoVarGlobal region specId monoType, newState )

        TOpt.Access record _ fieldName meta ->
            let
                canType =
                    meta.tipe

                monoType =
                    Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)
            in
            case getValueMultiVar record state of
                Just ( varName, recordCanType ) ->
                    -- Value-multi target: derive the concrete record type from the
                    -- access field type. The field's monoType is concrete (type inference
                    -- resolved it), but the record's canonical type has free type vars.
                    -- Unify to learn the concrete bindings.
                    let
                        partialRecordMono =
                            Mono.MRecord (Dict.singleton fieldName monoType)

                        enrichedSubst =
                            TypeSubst.unifyExtend recordCanType partialRecordMono subst

                        recordMonoType =
                            Mono.forceCNumberToInt (TypeSubst.applySubst enrichedSubst recordCanType)

                        ( freshName, state1 ) =
                            getOrCreateValueInstance varName recordMonoType enrichedSubst state
                    in
                    ( Mono.MonoRecordAccess (Mono.MonoVarLocal freshName recordMonoType) fieldName monoType, state1 )

                Nothing ->
                    let
                        ( monoRecord, stateAfter ) =
                            specializeExpr record subst state
                    in
                    ( Mono.MonoRecordAccess monoRecord fieldName monoType, stateAfter )

        TOpt.Update _ record updates meta ->
            let
                canType =
                    meta.tipe

                monoType =
                    Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)

                ( monoRecord, state1 ) =
                    specializeExpr record subst state

                -- Use the already-specialized record's MonoType for field type lookup.
                -- This is more concrete than re-applying subst to the canonical type,
                -- because monoRecord already encodes constraints from its own specialization.
                recordMonoType =
                    Mono.typeOf monoRecord

                getFieldMonoType fieldName =
                    case recordMonoType of
                        Mono.MRecord fieldMap ->
                            Dict.get fieldName fieldMap

                        _ ->
                            Nothing

                ( monoUpdates, state2 ) =
                    Data.Map.foldl A.compareLocated
                        (\locName updateExpr ( acc, st ) ->
                            let
                                fieldName =
                                    A.toValue locName

                                refinedSubst =
                                    case getFieldMonoType fieldName of
                                        Just fieldMonoType ->
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

        TOpt.Record fields meta ->
            let
                canType =
                    meta.tipe

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

        TOpt.TrackedRecord _ fields meta ->
            let
                canType =
                    meta.tipe

                monoType =
                    Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)

                -- Extract mono field types for substitution refinement.
                monoFieldTypes =
                    case monoType of
                        Mono.MRecord fieldMap ->
                            fieldMap

                        _ ->
                            Dict.empty

                ( monoFields, stateAfter ) =
                    Data.Map.foldl A.compareLocated
                        (\locName fieldExpr ( acc, st ) ->
                            let
                                fieldName =
                                    A.toValue locName

                                -- Refine substitution per field for lambdas in records.
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

        TOpt.Unit _ ->
            ( Mono.MonoUnit, state )

        TOpt.Tuple region a b rest meta ->
            let
                canType =
                    meta.tipe

                monoType =
                    Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)

                ( monoA, state1 ) =
                    specializeExpr a subst state

                ( monoB, state2 ) =
                    specializeExpr b subst state1

                ( monoRest, state3 ) =
                    specializeExprs rest subst state2

                allExprs =
                    monoA :: monoB :: monoRest
            in
            ( Mono.MonoTupleCreate region allExprs monoType, state3 )

        TOpt.Shader _ _ _ _ ->
            ( Mono.MonoUnit, state )


{-| Infer the result type of a case expression from its branches.
When the canonical type has unresolved TVars, we look at the first
concrete branch type instead.
-}
inferCaseType : Mono.Decider Mono.MonoChoice -> List ( Int, Mono.MonoExpr ) -> Mono.MonoType -> Mono.MonoType
inferCaseType decider jumps fallback =
    -- Try to extract type from first jump
    case jumps of
        ( _, expr ) :: _ ->
            Mono.typeOf expr

        [] ->
            -- No jumps, try decider leaf
            inferFromDecider decider fallback


inferFromDecider : Mono.Decider Mono.MonoChoice -> Mono.MonoType -> Mono.MonoType
inferFromDecider decider fallback =
    case decider of
        Mono.Leaf (Mono.Inline expr) ->
            Mono.typeOf expr

        Mono.Leaf (Mono.Jump _) ->
            fallback

        Mono.Chain _ yes _ ->
            inferFromDecider yes fallback

        Mono.FanOut _ branches def ->
            case branches of
                ( _, d ) :: _ ->
                    inferFromDecider d fallback

                [] ->
                    inferFromDecider def fallback



-- ========== EXPRESSION LIST HELPERS ==========


{-| Specialize a list of expressions.
Uses foldl + reverse instead of foldr for stack safety (foldl is tail-call optimized).
-}
specializeExprs : List TOpt.Expr -> Substitution -> MonoState -> ( List Mono.MonoExpr, MonoState )
specializeExprs exprs subst state =
    let
        ( revAcc, finalState ) =
            List.foldl
                (\e ( acc, st ) ->
                    let
                        ( me, st1 ) =
                            specializeExpr e subst st
                    in
                    ( me :: acc, st1 )
                )
                ( [], state )
                exprs
    in
    ( List.reverse revAcc, finalState )


{-| Process call arguments, deferring accessor specialization.

Returns:

  - processed args (some are PendingAccessor),
  - the monomorphic arg types for call-site unification,
  - updated MonoState.

-}
processCallArgs :
    List TOpt.Expr
    -> Substitution
    -> MonoState
    -> ( List ProcessedArg, List Mono.MonoType, MonoState )
processCallArgs args subst state =
    let
        ( revArgs, revTypes, finalState ) =
            List.foldl (processCallArg subst) ( [], [], state ) args
    in
    ( List.reverse revArgs, List.reverse revTypes, finalState )


processCallArg : Substitution -> TOpt.Expr -> ( List ProcessedArg, List Mono.MonoType, MonoState ) -> ( List ProcessedArg, List Mono.MonoType, MonoState )
processCallArg subst arg ( accArgs, accTypes, st ) =
    case arg of
        TOpt.Accessor region fieldName accessorMeta ->
            let
                accessorCanType =
                    accessorMeta.tipe

                monoType =
                    Mono.forceCNumberToInt (TypeSubst.applySubst subst accessorCanType)
            in
            ( PendingAccessor region fieldName accessorCanType :: accArgs
            , monoType :: accTypes
            , st
            )

        TOpt.VarKernel region home name kernelMeta ->
            let
                kernelCanType =
                    kernelMeta.tipe
            in
            case KernelAbi.deriveKernelAbiMode ( home, name ) kernelCanType of
                KernelAbi.NumberBoxed ->
                    let
                        monoType =
                            Mono.forceCNumberToInt (TypeSubst.applySubst subst kernelCanType)
                    in
                    ( PendingKernel region home name kernelCanType :: accArgs
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

        TOpt.VarLocal name localMeta ->
            let
                localCanType =
                    localMeta.tipe
            in
            if isLocalMultiTarget name st then
                let
                    monoType =
                        Mono.forceCNumberToInt (TypeSubst.applySubst subst localCanType)
                in
                ( LocalFunArg name localCanType :: accArgs
                , monoType :: accTypes
                , st
                )

            else
                let
                    ( monoExpr, st1 ) =
                        specializeExpr arg subst st
                in
                ( ResolvedArg monoExpr :: accArgs
                , Mono.typeOf monoExpr :: accTypes
                , st1
                )

        TOpt.TrackedVarLocal _ name trackedLocalMeta ->
            let
                trackedLocalCanType =
                    trackedLocalMeta.tipe
            in
            if isLocalMultiTarget name st then
                let
                    monoType =
                        Mono.forceCNumberToInt (TypeSubst.applySubst subst trackedLocalCanType)
                in
                ( LocalFunArg name trackedLocalCanType :: accArgs
                , monoType :: accTypes
                , st
                )

            else
                let
                    ( monoExpr, st1 ) =
                        specializeExpr arg subst st
                in
                ( ResolvedArg monoExpr :: accArgs
                , Mono.typeOf monoExpr :: accTypes
                , st1
                )

        _ ->
            case arg of
                TOpt.VarGlobal _ _ meta ->
                    let
                        canType =
                            meta.tipe

                        monoType =
                            Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)
                    in
                    if Mono.containsCEcoMVar monoType then
                        ( PendingGlobal arg subst canType :: accArgs
                        , monoType :: accTypes
                        , st
                        )

                    else
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


{-| Resolve a single processed argument.

For PendingAccessor, derives the accessor's MonoType from the expected
parameter type (which must be a record), NOT from the accessor's canonical type.

-}
resolveProcessedArg :
    ProcessedArg
    -> Maybe Mono.MonoType
    -> Substitution
    -> MonoState
    -> ( Mono.MonoExpr, MonoState )
resolveProcessedArg processedArg maybeParamType subst state =
    case processedArg of
        ResolvedArg monoExpr ->
            ( monoExpr, state )

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
                                    Utils.Crash.crash ("Specialize.resolveProcessedArg: Field " ++ fieldName ++ " not found in record. This is a compiler bug.")

                        recordType =
                            Mono.MRecord fields

                        accessorMonoType =
                            Mono.MFunction [ recordType ] fieldType

                        accessorGlobal =
                            Mono.Accessor fieldName

                        ( specId, newState ) =
                            enqueueSpec accessorGlobal accessorMonoType Nothing state
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
                                    Utils.Crash.crash ("Specialize.resolveProcessedArg: Field " ++ fieldName ++ " not found in record (direct). This is a compiler bug.")

                        recordType =
                            Mono.MRecord fields

                        accessorMonoType =
                            Mono.MFunction [ recordType ] fieldType

                        accessorGlobal =
                            Mono.Accessor fieldName

                        ( specId, newState ) =
                            enqueueSpec accessorGlobal accessorMonoType Nothing state
                    in
                    ( Mono.MonoVarGlobal region specId accessorMonoType, newState )

                _ ->
                    Utils.Crash.crash "Specialize.resolveProcessedArg: Accessor argument did not receive a record parameter type after monomorphization. This is a compiler bug."

        PendingGlobal savedExpr savedSubst canType ->
            -- Deferred VarGlobal: polymorphic global that needed call-site context.
            -- Refine the substitution with the callee's parameter type, then specialize.
            let
                refinedSubst =
                    case maybeParamType of
                        Just paramType ->
                            TypeSubst.unifyExtend canType paramType savedSubst

                        Nothing ->
                            savedSubst

                ( monoExpr, st1 ) =
                    specializeExpr savedExpr refinedSubst state
            in
            ( monoExpr, st1 )

        PendingKernel region home name canType ->
            -- Number-boxed kernel argument. Now that we have the call-site substitution,
            -- we can properly specialize it. If the type is fully monomorphic (e.g., Int -> Int -> Int),
            -- we'll get a specialized numeric type that enables intrinsics like eco.int.add.
            -- Otherwise, we fall back to the boxed ABI.
            let
                kernelMonoType =
                    deriveKernelAbiType ( home, name ) canType subst
            in
            ( Mono.MonoVarKernel region home name kernelMonoType, state )

        LocalFunArg name canType ->
            -- Let-bound function passed as argument. Use the callee's parameter type
            -- to refine the local's type and create a monomorphic instance.
            case maybeParamType of
                Just paramType ->
                    case paramType of
                        Mono.MFunction _ _ ->
                            let
                                refinedSubst =
                                    TypeSubst.unifyExtend canType paramType subst

                                funcMonoType =
                                    Mono.forceCNumberToInt
                                        (TypeSubst.applySubst refinedSubst canType)
                            in
                            if isLocalMultiTarget name state then
                                let
                                    ( freshName, state1 ) =
                                        getOrCreateLocalInstance
                                            name
                                            funcMonoType
                                            refinedSubst
                                            state
                                in
                                ( Mono.MonoVarLocal freshName funcMonoType, state1 )

                            else
                                ( Mono.MonoVarLocal name funcMonoType, state )

                        _ ->
                            let
                                monoType =
                                    Mono.forceCNumberToInt
                                        (TypeSubst.applySubst subst canType)
                            in
                            ( Mono.MonoVarLocal name monoType, state )

                Nothing ->
                    let
                        monoType =
                            Mono.forceCNumberToInt
                                (TypeSubst.applySubst subst canType)
                    in
                    ( Mono.MonoVarLocal name monoType, state )


{-| Resolve a list of processed arguments using the callee's parameter types.
-}
resolveProcessedArgs :
    List ProcessedArg
    -> List Mono.MonoType
    -> Substitution
    -> MonoState
    -> ( List Mono.MonoExpr, MonoState )
resolveProcessedArgs processedArgs paramTypes subst state =
    let
        step processedArg ( acc, st, remainingParams ) =
            let
                ( maybeParam, rest ) =
                    case remainingParams of
                        p :: ps ->
                            ( Just p, ps )

                        [] ->
                            ( Nothing, [] )

                ( monoExpr, st1 ) =
                    resolveProcessedArg processedArg maybeParam subst st
            in
            ( monoExpr :: acc, st1, rest )

        ( revArgs, finalState, _ ) =
            List.foldl step ( [], state, paramTypes ) processedArgs
    in
    ( List.reverse revArgs, finalState )


{-| Specialize a list of named expressions.
-}
specializeNamedExprs :
    List ( Name, TOpt.Expr )
    -> Substitution
    -> MonoState
    -> ( List ( Name, Mono.MonoExpr ), MonoState )
specializeNamedExprs namedExprs subst state =
    let
        ( revAcc, finalState ) =
            List.foldl
                (\( name, e ) ( acc, st ) ->
                    let
                        ( me, st1 ) =
                            specializeExpr e subst st
                    in
                    ( ( name, me ) :: acc, st1 )
                )
                ( [], state )
                namedExprs
    in
    ( List.reverse revAcc, finalState )


{-| Specialize if-expression branches (condition-body pairs).
-}
specializeBranches :
    List ( TOpt.Expr, TOpt.Expr )
    -> Substitution
    -> MonoState
    -> ( List ( Mono.MonoExpr, Mono.MonoExpr ), MonoState )
specializeBranches branches subst state =
    let
        savedVarEnv =
            state.ctx.varEnv

        ( revAcc, finalState ) =
            List.foldl
                (\( cond, body ) ( acc, st ) ->
                    let
                        ( mCond, st1 ) =
                            specializeExpr cond subst st

                        st1WithResetVarTypes =
                            { st1 | ctx = let c = st1.ctx in { c | varEnv = savedVarEnv } }

                        ( mBody, st2 ) =
                            specializeExpr body subst st1WithResetVarTypes
                    in
                    ( ( mCond, mBody ) :: acc, st2 )
                )
                ( [], state )
                branches
    in
    ( List.reverse revAcc, finalState )



-- ========== CONSTRUCTOR HELPERS ==========


{-| Extract the result type of a constructor after peeling off function arguments.
-}
extractCtorResultType : Int -> Mono.MonoType -> Mono.MonoType
extractCtorResultType n monoType =
    if n <= 0 then
        monoType

    else
        case monoType of
            Mono.MFunction args result ->
                extractCtorResultType (n - List.length args) result

            _ ->
                monoType



-- ========== CYCLE SPECIALIZATION HELPERS ==========


{-| Check if a definition has the given name.
-}
defHasName : Name -> TOpt.Def -> Bool
defHasName targetName def =
    case def of
        TOpt.Def _ name _ _ ->
            name == targetName

        TOpt.TailDef _ name _ _ _ _ ->
            name == targetName


{-| Get the name from a definition.
-}
getDefName : TOpt.Def -> Name
getDefName def =
    case def of
        TOpt.Def _ name _ _ ->
            name

        TOpt.TailDef _ name _ _ _ _ ->
            name


{-| Get the canonical type from a definition.
-}
getDefCanonicalType : TOpt.Def -> Can.Type
getDefCanonicalType def =
    case def of
        TOpt.Def _ _ _ canType ->
            canType

        TOpt.TailDef _ _ args _ returnType _ ->
            buildFuncType args returnType



-- ========== DEFINITION SPECIALIZATION HELPERS ==========


{-| Specialize a local definition.
-}
specializeDef : TOpt.Def -> Substitution -> MonoState -> ( Mono.MonoDef, MonoState )
specializeDef def subst state =
    case def of
        TOpt.Def _ name expr _ ->
            let
                ( monoExpr, stateAfter ) =
                    specializeExpr expr subst state
            in
            ( Mono.MonoDef name monoExpr, stateAfter )

        TOpt.TailDef _ name args expr _ _ ->
            let
                monoArgs =
                    List.map (specializeArg subst) args

                ctx =
                    state.ctx

                newVarEnv =
                    List.foldl
                        (\( pname, monoParamType ) ve ->
                            State.insertVar pname monoParamType ve
                        )
                        (State.pushFrame ctx.varEnv)
                        monoArgs

                stateWithParams =
                    { state | ctx = { ctx | varEnv = newVarEnv } }

                augmentedSubst =
                    List.foldl
                        (\( ( _, canParamType ), ( _, monoParamType ) ) s ->
                            TypeSubst.unifyExtend canParamType monoParamType s
                        )
                        subst
                        (List.map2 Tuple.pair args monoArgs)

                ( monoExpr, stateAfterPre ) =
                    specializeExpr expr augmentedSubst stateWithParams

                stateAfter =
                    { stateAfterPre | ctx = let c = stateAfterPre.ctx in { c | varEnv = State.popFrame c.varEnv } }
            in
            ( Mono.MonoTailDef name monoArgs monoExpr, stateAfter )


specializeDestructor : TOpt.Destructor -> Substitution -> VarEnv -> TypeEnv.GlobalTypeEnv -> Maybe Mono.Global -> Mono.MonoDestructor
specializeDestructor (TOpt.Destructor name path meta) subst varEnv globalTypeEnv currentGlobal =
    let
        monoPath =
            specializePath path varEnv globalTypeEnv currentGlobal name

        monoType =
            Mono.forceCNumberToInt (TypeSubst.applySubst subst meta.tipe)
    in
    Mono.MonoDestructor name monoPath monoType


{-| Specialize a path, computing the result type at each step.

The path is structured from leaf (root variable) outward, so we:

1.  Find the root and look up its type in VarTypes
2.  Walk back out through the path, computing types at each step

-}
specializePath : TOpt.Path -> VarEnv -> TypeEnv.GlobalTypeEnv -> Maybe Mono.Global -> Name -> Mono.MonoPath
specializePath path varEnv globalTypeEnv currentGlobal destructorName =
    case path of
        TOpt.Index index hint subPath ->
            let
                monoSubPath =
                    specializePath subPath varEnv globalTypeEnv currentGlobal destructorName

                containerType =
                    Mono.getMonoPathType monoSubPath

                resultType =
                    computeIndexProjectionType globalTypeEnv hint (Index.toMachine index) containerType
            in
            Mono.MonoIndex (Index.toMachine index) (hintToKind hint) resultType monoSubPath

        TOpt.ArrayIndex idx subPath ->
            let
                monoSubPath =
                    specializePath subPath varEnv globalTypeEnv currentGlobal destructorName

                containerType =
                    Mono.getMonoPathType monoSubPath

                -- ArrayIndex is used for array access, element type comes from the array's element type
                resultType =
                    computeArrayElementType containerType
            in
            Mono.MonoIndex idx (Mono.CustomContainer "") resultType monoSubPath

        TOpt.Field fieldName subPath ->
            let
                monoSubPath =
                    specializePath subPath varEnv globalTypeEnv currentGlobal destructorName

                recordType =
                    Mono.getMonoPathType monoSubPath

                resultType =
                    case recordType of
                        Mono.MRecord fields ->
                            case Dict.get fieldName fields of
                                Just fieldMonoType ->
                                    fieldMonoType

                                Nothing ->
                                    Utils.Crash.crash
                                        ("Specialize.specializePath: Field '"
                                            ++ fieldName
                                            ++ "' not found in record type. This is a compiler bug."
                                        )

                        _ ->
                            Utils.Crash.crash
                                ("Specialize.specializePath: Expected MRecord for field path but got: "
                                    ++ Mono.monoTypeToDebugString recordType
                                )
            in
            Mono.MonoField fieldName resultType monoSubPath

        TOpt.Unbox subPath ->
            let
                monoSubPath =
                    specializePath subPath varEnv globalTypeEnv currentGlobal destructorName

                containerType =
                    Mono.getMonoPathType monoSubPath

                -- Compute the result type by looking up the single field type of the container
                resultType =
                    computeUnboxResultType globalTypeEnv containerType
            in
            Mono.MonoUnbox resultType monoSubPath

        TOpt.Root name ->
            let
                rootType =
                    case State.lookupVar name varEnv of
                        Just ty ->
                            ty

                        Nothing ->
                            Utils.Crash.crash ("Specialize.specializePath: Root variable '" ++ name ++ "' not found in VarEnv. Destructor: '" ++ destructorName ++ "'. VarEnv keys: [" ++ String.join ", " (State.varEnvKeys varEnv) ++ "]. Global: " ++ debugGlobal currentGlobal)
            in
            Mono.MonoRoot name rootType


pathRoot : TOpt.Path -> Name
pathRoot p =
    case p of
        TOpt.Root n -> n
        TOpt.Index _ _ sub -> pathRoot sub
        TOpt.ArrayIndex _ sub -> pathRoot sub
        TOpt.Field _ sub -> pathRoot sub
        TOpt.Unbox sub -> pathRoot sub


debugPath : TOpt.Path -> String
debugPath p =
    case p of
        TOpt.Root n -> "Root(" ++ n ++ ")"
        TOpt.Index idx _ sub -> "Index(" ++ String.fromInt (Index.toMachine idx) ++ ", " ++ debugPath sub ++ ")"
        TOpt.ArrayIndex idx sub -> "ArrayIndex(" ++ String.fromInt idx ++ ", " ++ debugPath sub ++ ")"
        TOpt.Field f sub -> "Field(" ++ f ++ ", " ++ debugPath sub ++ ")"
        TOpt.Unbox sub -> "Unbox(" ++ debugPath sub ++ ")"


debugGlobal : Maybe Mono.Global -> String
debugGlobal mg =
    case mg of
        Nothing -> "Nothing"
        Just (Mono.Global (IO.Canonical _ modName) name) -> Name.toElmString modName ++ "." ++ name
        Just (Mono.Accessor name) -> "Accessor(" ++ name ++ ")"


{-| Compute the result type of projecting at an index from a container.
-}
computeIndexProjectionType : TypeEnv.GlobalTypeEnv -> TOpt.ContainerHint -> Int -> Mono.MonoType -> Mono.MonoType
computeIndexProjectionType globalTypeEnv hint index containerType =
    case hint of
        TOpt.HintList ->
            case containerType of
                Mono.MList elemType ->
                    if index == 0 then
                        -- Index 0 is head: returns the element type
                        elemType

                    else
                        -- Index 1 is tail: returns the list type itself
                        containerType

                _ ->
                    Utils.Crash.crash ("Specialize.computeIndexProjectionType: HintList at index " ++ String.fromInt index ++ " - Expected MList but got: " ++ Mono.monoTypeToDebugString containerType)

        TOpt.HintTuple2 ->
            computeTupleElementType index containerType

        TOpt.HintTuple3 ->
            computeTupleElementType index containerType

        TOpt.HintCustom ctorName ->
            computeCustomFieldType globalTypeEnv ctorName index containerType


{-| Compute element type from a tuple at the given index.
-}
computeTupleElementType : Int -> Mono.MonoType -> Mono.MonoType
computeTupleElementType index containerType =
    case containerType of
        Mono.MTuple elementTypes ->
            case List.drop index elementTypes of
                elemType :: _ ->
                    elemType

                [] ->
                    Utils.Crash.crash ("Specialize.computeTupleElementType: Tuple index " ++ String.fromInt index ++ " out of bounds for tuple with " ++ String.fromInt (List.length elementTypes) ++ " elements")

        _ ->
            Utils.Crash.crash ("Specialize.computeTupleElementType: Expected MTuple but got: " ++ Mono.monoTypeToDebugString containerType)


{-| Compute field type from a custom type constructor at the given index.

This looks up the union definition to find the constructor's argument types,
then applies the type variable substitution based on the monomorphized type arguments.

-}
computeCustomFieldType : TypeEnv.GlobalTypeEnv -> Name -> Int -> Mono.MonoType -> Mono.MonoType
computeCustomFieldType globalTypeEnv ctorName index containerType =
    case containerType of
        Mono.MCustom moduleName typeName typeArgs ->
            case Analysis.lookupUnion globalTypeEnv moduleName typeName of
                Nothing ->
                    Utils.Crash.crash ("Specialize.computeCustomFieldType: Union not found: " ++ typeName)

                Just (Can.Union unionData) ->
                    case findCtorByName ctorName unionData.alts of
                        Nothing ->
                            Utils.Crash.crash ("Specialize.computeCustomFieldType: Constructor '" ++ ctorName ++ "' not found in union " ++ typeName)

                        Just (Can.Ctor ctorData) ->
                            case List.drop index ctorData.args of
                                canArgType :: _ ->
                                    -- Build substitution from union's type vars to concrete type args
                                    let
                                        typeVarSubst =
                                            Dict.fromList (List.map2 Tuple.pair unionData.vars typeArgs)
                                    in
                                    Mono.forceCNumberToInt (TypeSubst.applySubst typeVarSubst canArgType)

                                [] ->
                                    Utils.Crash.crash ("Specialize.computeCustomFieldType: Constructor arg index " ++ String.fromInt index ++ " out of bounds for " ++ ctorName)

        _ ->
            Utils.Crash.crash ("Specialize.computeCustomFieldType: Expected MCustom for ctor '" ++ ctorName ++ "' index " ++ String.fromInt index ++ " but got: " ++ Mono.monoTypeToDebugString containerType)


{-| Find a constructor by name in a list of alternatives.
-}
findCtorByName : Name -> List Can.Ctor -> Maybe Can.Ctor
findCtorByName targetName alts =
    List.filter (\(Can.Ctor ctorData) -> ctorData.name == targetName) alts
        |> List.head


{-| Compute the result type of unwrapping a single-constructor type.

For Unbox paths, we need to find the single field type of the container.
The container must be a single-constructor type (Can.Unbox option).

-}
computeUnboxResultType : TypeEnv.GlobalTypeEnv -> Mono.MonoType -> Mono.MonoType
computeUnboxResultType globalTypeEnv containerType =
    case containerType of
        Mono.MCustom moduleName typeName typeArgs ->
            case Analysis.lookupUnion globalTypeEnv moduleName typeName of
                Nothing ->
                    Utils.Crash.crash ("Specialize.computeUnboxResultType: Union not found: " ++ typeName)

                Just (Can.Union unionData) ->
                    -- Unbox is used for single-constructor types with a single field
                    case unionData.alts of
                        [ Can.Ctor ctorData ] ->
                            case ctorData.args of
                                [ canArgType ] ->
                                    -- Build substitution from union's type vars to concrete type args
                                    let
                                        typeVarSubst =
                                            Dict.fromList (List.map2 Tuple.pair unionData.vars typeArgs)
                                    in
                                    Mono.forceCNumberToInt (TypeSubst.applySubst typeVarSubst canArgType)

                                _ ->
                                    Utils.Crash.crash ("Specialize.computeUnboxResultType: Expected single-arg constructor but got " ++ String.fromInt (List.length ctorData.args) ++ " args for " ++ typeName)

                        _ ->
                            Utils.Crash.crash ("Specialize.computeUnboxResultType: Expected single-constructor type but got " ++ String.fromInt (List.length unionData.alts) ++ " constructors for " ++ typeName)

        _ ->
            Utils.Crash.crash ("Specialize.computeUnboxResultType: Expected MCustom but got: " ++ Mono.monoTypeToDebugString containerType)


{-| Compute element type from an array access.
-}
computeArrayElementType : Mono.MonoType -> Mono.MonoType
computeArrayElementType containerType =
    case containerType of
        Mono.MCustom _ "Array" [ elemType ] ->
            elemType

        _ ->
            Utils.Crash.crash ("Specialize.computeArrayElementType: Expected Array type but got: " ++ Mono.monoTypeToDebugString containerType)


{-| Convert ContainerHint to ContainerKind for monomorphized paths.
-}
hintToKind : TOpt.ContainerHint -> Mono.ContainerKind
hintToKind hint =
    case hint of
        TOpt.HintList ->
            Mono.ListContainer

        TOpt.HintTuple2 ->
            Mono.Tuple2Container

        TOpt.HintTuple3 ->
            Mono.Tuple3Container

        TOpt.HintCustom ctorName ->
            Mono.CustomContainer ctorName


{-| Convert a TypedPath.ContainerHint to a ContainerKind for MonoDtPath.
-}
dtHintToKind : TypedPath.ContainerHint -> Mono.ContainerKind
dtHintToKind hint =
    case hint of
        TypedPath.HintList ->
            Mono.ListContainer

        TypedPath.HintTuple2 ->
            Mono.Tuple2Container

        TypedPath.HintTuple3 ->
            Mono.Tuple3Container

        TypedPath.HintCustom ctorName ->
            Mono.CustomContainer ctorName

        TypedPath.HintUnknown ->
            Mono.CustomContainer ""


{-| Convert TypedPath.ContainerHint to TOpt.ContainerHint for reuse of computeIndexProjectionType.
-}
dtHintToTOptHint : TypedPath.ContainerHint -> TOpt.ContainerHint
dtHintToTOptHint hint =
    case hint of
        TypedPath.HintList ->
            TOpt.HintList

        TypedPath.HintTuple2 ->
            TOpt.HintTuple2

        TypedPath.HintTuple3 ->
            TOpt.HintTuple3

        TypedPath.HintCustom ctorName ->
            TOpt.HintCustom ctorName

        TypedPath.HintUnknown ->
            TOpt.HintCustom ""


{-| Convert a DT.Path (TypedPath) to a MonoDtPath by resolving types from VarEnv.
-}
specializeDtPath : Name -> TypedPath.Path -> VarEnv -> TypeEnv.GlobalTypeEnv -> Mono.MonoDtPath
specializeDtPath rootName dtPath varEnv globalTypeEnv =
    let
        rootType =
            case State.lookupVar rootName varEnv of
                Just ty ->
                    ty

                Nothing ->
                    Utils.Crash.crash ("Specialize.specializeDtPath: Root '" ++ rootName ++ "' not in VarEnv")

        go : TypedPath.Path -> Mono.MonoDtPath
        go path =
            case path of
                TypedPath.Empty ->
                    Mono.DtRoot rootName rootType

                TypedPath.Index index hint subPath ->
                    let
                        monoSubPath =
                            go subPath

                        containerType =
                            Mono.dtPathType monoSubPath

                        resultType =
                            computeIndexProjectionType globalTypeEnv (dtHintToTOptHint hint) (Index.toMachine index) containerType
                    in
                    Mono.DtIndex (Index.toMachine index) (dtHintToKind hint) resultType monoSubPath

                TypedPath.Unbox subPath ->
                    let
                        monoSubPath =
                            go subPath

                        containerType =
                            Mono.dtPathType monoSubPath

                        resultType =
                            computeUnboxResultType globalTypeEnv containerType
                    in
                    Mono.DtUnbox resultType monoSubPath
    in
    go dtPath


{-| Specialize a pattern match decider tree.
-}
specializeDecider : Name -> TOpt.Decider TOpt.Choice -> Substitution -> MonoState -> ( Mono.Decider Mono.MonoChoice, MonoState )
specializeDecider rootName decider subst state =
    case decider of
        TOpt.Leaf choice ->
            let
                ( monoChoice, stateAfter ) =
                    specializeChoice choice subst state
            in
            ( Mono.Leaf monoChoice, stateAfter )

        TOpt.Chain testChain success failure ->
            let
                savedVarEnv =
                    state.ctx.varEnv

                monoTestChain =
                    List.map
                        (\( path, test ) ->
                            ( specializeDtPath rootName path state.ctx.varEnv state.ctx.globalTypeEnv, test )
                        )
                        testChain

                ( monoSuccess, state1 ) =
                    specializeDecider rootName success subst state

                state1WithResetVarEnv =
                    { state1 | ctx = let c = state1.ctx in { c | varEnv = savedVarEnv } }

                ( monoFailure, state2 ) =
                    specializeDecider rootName failure subst state1WithResetVarEnv
            in
            ( Mono.Chain monoTestChain monoSuccess monoFailure, state2 )

        TOpt.FanOut path edges fallback ->
            let
                savedVarEnv =
                    state.ctx.varEnv

                monoPath =
                    specializeDtPath rootName path state.ctx.varEnv state.ctx.globalTypeEnv

                ( monoEdges, state1 ) =
                    specializeEdges rootName edges subst state

                state1WithResetVarEnv =
                    { state1 | ctx = let c = state1.ctx in { c | varEnv = savedVarEnv } }

                ( monoFallback, state2 ) =
                    specializeDecider rootName fallback subst state1WithResetVarEnv
            in
            ( Mono.FanOut monoPath monoEdges monoFallback, state2 )


specializeChoice : TOpt.Choice -> Substitution -> MonoState -> ( Mono.MonoChoice, MonoState )
specializeChoice choice subst state =
    case choice of
        TOpt.Inline expr ->
            let
                ( monoExpr, stateAfter ) =
                    specializeExpr expr subst state
            in
            ( Mono.Inline monoExpr, stateAfter )

        TOpt.Jump index ->
            ( Mono.Jump index, state )


specializeEdges : Name -> List ( DT.Test, TOpt.Decider TOpt.Choice ) -> Substitution -> MonoState -> ( List ( DT.Test, Mono.Decider Mono.MonoChoice ), MonoState )
specializeEdges rootName edges subst state =
    let
        savedVarEnv =
            state.ctx.varEnv

        ( revAcc, finalState ) =
            List.foldl
                (\( test, decider ) ( acc, st ) ->
                    let
                        stWithResetVarEnv =
                            { st | ctx = let c = st.ctx in { c | varEnv = savedVarEnv } }

                        ( monoDecider, newSt ) =
                            specializeDecider rootName decider subst stWithResetVarEnv
                    in
                    ( ( test, monoDecider ) :: acc, newSt )
                )
                ( [], state )
                edges
    in
    ( List.reverse revAcc, finalState )


specializeJumps : List ( Int, TOpt.Expr ) -> Substitution -> MonoState -> ( List ( Int, Mono.MonoExpr ), MonoState )
specializeJumps jumps subst state =
    let
        savedVarEnv =
            state.ctx.varEnv

        ( revAcc, finalState ) =
            List.foldl
                (\( idx, expr ) ( acc, st ) ->
                    let
                        stWithResetVarEnv =
                            { st | ctx = let c = st.ctx in { c | varEnv = savedVarEnv } }

                        ( monoExpr, newSt ) =
                            specializeExpr expr subst stWithResetVarEnv
                    in
                    ( ( idx, monoExpr ) :: acc, newSt )
                )
                ( [], state )
                jumps
    in
    ( List.reverse revAcc, finalState )


{-| Extract the expression type from a MonoDef.
-}
monoDefExprType : Mono.MonoDef -> Mono.MonoType
monoDefExprType monoDef =
    case monoDef of
        Mono.MonoDef _ monoExpr ->
            Mono.typeOf monoExpr

        Mono.MonoTailDef _ monoArgs monoExpr ->
            -- For TailDef, construct the function type from args and body return type.
            List.foldr
                (\( _, argType ) acc -> Mono.MFunction [ argType ] acc)
                (Mono.typeOf monoExpr)
                monoArgs


{-| Compute the result MonoType for a Call expression.
Prefer the caller's substitution to avoid type variable name collisions
between the caller's scope and the callee's scope. When callee type variables
share names with caller type variables, callSubst can contaminate the result.
Fall back to callSubst only when the caller's subst leaves CEcoValue MVars.
-}
callResultMonoType : Substitution -> Substitution -> Can.Type -> Mono.MonoType
callResultMonoType callerSubst callSubst canType =
    let
        fromCaller =
            Mono.forceCNumberToInt (TypeSubst.applySubst callerSubst canType)
    in
    if Mono.containsAnyMVar fromCaller then
        Mono.forceCNumberToInt (TypeSubst.applySubst callSubst canType)

    else
        fromCaller


{-| Specialize a function argument by applying type substitution.
-}
specializeArg : Substitution -> ( A.Located Name, Can.Type ) -> ( Name, Mono.MonoType )
specializeArg subst ( locName, canType ) =
    let
        name =
            A.toValue locName

        monoType =
            Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)
    in
    ( name, monoType )


{-| Build a function type from a list of arguments and a return type.
-}
buildFuncType : List ( A.Located Name, Can.Type ) -> Can.Type -> Can.Type
buildFuncType args returnType =
    List.foldr
        (\( _, argType ) acc ->
            Can.TLambda argType acc
        )
        returnType
        args


{-| Build a constructor shape from name, tag, arity, and monomorphic type information.
-}
buildCtorShapeFromArity : Name.Name -> Int -> Int -> Mono.MonoType -> Mono.CtorShape
buildCtorShapeFromArity ctorName tag arity ctorMonoType =
    let
        fieldTypes =
            extractFieldTypes arity ctorMonoType
    in
    { name = ctorName
    , tag = tag
    , fieldTypes = fieldTypes
    }


{-| Extract a specific number of argument types from a function type.
-}
extractFieldTypes : Int -> Mono.MonoType -> List Mono.MonoType
extractFieldTypes n monoType =
    if n <= 0 then
        []

    else
        case monoType of
            Mono.MFunction args result ->
                args ++ extractFieldTypes (n - List.length args) result

            _ ->
                []


{-| Return True if a MonoType contains no remaining type variables.

Used to detect when a kernel use has been fully specialized at a call site
(e.g. Basics.add : number -> number -> number instantiated as
Int -> Int -> Int or Float -> Float -> Float).

-}
isFullyMonomorphicType : Mono.MonoType -> Bool
isFullyMonomorphicType monoType =
    case monoType of
        Mono.MVar _ _ ->
            False

        Mono.MList inner ->
            isFullyMonomorphicType inner

        Mono.MFunction args result ->
            List.all isFullyMonomorphicType args
                && isFullyMonomorphicType result

        Mono.MTuple elems ->
            List.all isFullyMonomorphicType elems

        Mono.MRecord fields ->
            Dict.foldl
                (\_ fieldType acc -> acc && isFullyMonomorphicType fieldType)
                True
                fields

        Mono.MCustom _ _ args ->
            List.all isFullyMonomorphicType args

        -- Primitive / unit types are trivially monomorphic
        Mono.MInt ->
            True

        Mono.MFloat ->
            True

        Mono.MBool ->
            True

        Mono.MChar ->
            True

        Mono.MString ->
            True

        Mono.MUnit ->
            True



-- ========== KERNEL ABI TYPE DERIVATION ==========


{-| Derive the MonoType for a kernel function's ABI.

This is _call-site aware_:

  - For monomorphic uses (no remaining MVar in the instantiated function type),
    we prefer the fully specialized MonoType obtained by applying the call-site
    substitution. This enables specializing number-polymorphic kernels like
    Basics.add to Int/Float and using intrinsics (eco.int.add / eco.float.add).

  - For genuinely polymorphic uses, we fall back to the KernelAbiMode-driven
    behavior:

        - UseSubstitution  -> applySubst
        - PreserveVars     -> all CEcoValue (boxed) vars
        - NumberBoxed      -> treat CNumber vars as CEcoValue (boxed)

-}
deriveKernelAbiType : ( String, String ) -> Can.Type -> Substitution -> Mono.MonoType
deriveKernelAbiType kernelId canFuncType callSubst =
    let
        -- Monomorphic function type at this use-site, after substitution.
        monoAfterSubstRaw : Mono.MonoType
        monoAfterSubstRaw =
            TypeSubst.applySubst callSubst canFuncType

        -- Backend policy: eagerly resolve any remaining CNumber vars to Int.
        -- This does NOT affect MFloat - only unresolved numeric vars.
        monoAfterSubst : Mono.MonoType
        monoAfterSubst =
            Mono.forceCNumberToInt monoAfterSubstRaw

        mode : KernelAbi.KernelAbiMode
        mode =
            KernelAbi.deriveKernelAbiMode kernelId canFuncType
    in
    case mode of
        KernelAbi.NumberBoxed ->
            -- Special case: number-polymorphic kernels like Basics.add/sub/mul/pow.
            --
            -- If this PARTICULAR use-site has been fully specialized (e.g. Int or
            -- Float everywhere), prefer the fully-monomorphic type. This lets
            -- MLIR see concrete MInt/MFloat arguments for intrinsics and avoids
            -- going through the boxed C ABI (@Elm_Kernel_Basics_add).
            if isFullyMonomorphicType monoAfterSubst then
                monoAfterSubst

            else
                -- Still genuinely number-polymorphic here: fall back to boxed ABI.
                KernelAbi.canTypeToMonoType_numberBoxed canFuncType

        KernelAbi.UseSubstitution ->
            -- Monomorphic kernel type from the outset (no type variables).
            monoAfterSubst

        KernelAbi.PreserveVars ->
            -- Container-specializable kernels get monomorphic, element-aware type
            -- for Elm-level wrapper specialization. The C++ kernel ABI is determined
            -- separately by kernelBackendAbiPolicy in MLIR codegen, which may
            -- override this type with all-boxed !eco.value arguments.
            if
                EverySet.member KernelAbi.comparePair kernelId KernelAbi.containerSpecializedKernels
                    && isFullyMonomorphicType monoAfterSubst
            then
                -- e.g. List.cons : Int -> List Int -> List Int at this site
                monoAfterSubst

            else
                -- default: all vars become CEcoValue (fully boxed ABI)
                KernelAbi.canTypeToMonoType_preserveVars canFuncType



-- ========== GLOBAL CONVERSIONS ==========


{-| Convert a typed optimized global reference to a monomorphized global reference.
-}
toptGlobalToMono : TOpt.Global -> Mono.Global
toptGlobalToMono (TOpt.Global canonical name) =
    Mono.Global canonical name



-- ========== LOCAL FUNCTION CLONE HELPERS ==========


{-| Rename a MonoDef to use a fresh name (for multi-specialization clones).
-}
renameMonoDef : Name -> Mono.MonoDef -> Mono.MonoDef
renameMonoDef newName def =
    case def of
        Mono.MonoDef _ expr ->
            Mono.MonoDef newName expr

        Mono.MonoTailDef oldName args expr ->
            Mono.MonoTailDef newName args (renameTailCalls oldName newName expr)


{-| Rename self tail-calls from oldName to newName in a MonoExpr.

Used when cloning MonoTailDef for local multi-specialization so that
each cloned definition's internal MonoTailCall refers to its own name.

-}
renameTailCalls : Name -> Name -> Mono.MonoExpr -> Mono.MonoExpr
renameTailCalls oldName newName expr =
    case expr of
        Mono.MonoTailCall name args resultType ->
            Mono.MonoTailCall
                (if name == oldName then
                    newName

                 else
                    name
                )
                (List.map (\( n, e ) -> ( n, renameTailCalls oldName newName e )) args)
                resultType

        Mono.MonoCall region func args resultType callInfo ->
            Mono.MonoCall region
                (renameTailCalls oldName newName func)
                (List.map (renameTailCalls oldName newName) args)
                resultType
                callInfo

        Mono.MonoIf branches final resultType ->
            Mono.MonoIf
                (List.map (\( c, t ) -> ( renameTailCalls oldName newName c, renameTailCalls oldName newName t )) branches)
                (renameTailCalls oldName newName final)
                resultType

        Mono.MonoLet def_ body resultType ->
            let
                newDef =
                    case def_ of
                        Mono.MonoDef n bound ->
                            Mono.MonoDef n (renameTailCalls oldName newName bound)

                        Mono.MonoTailDef n params bound ->
                            Mono.MonoTailDef
                                (if n == oldName then
                                    newName

                                 else
                                    n
                                )
                                params
                                (renameTailCalls oldName newName bound)
            in
            Mono.MonoLet newDef (renameTailCalls oldName newName body) resultType

        Mono.MonoClosure info body closureType ->
            Mono.MonoClosure info (renameTailCalls oldName newName body) closureType

        Mono.MonoList region items t ->
            Mono.MonoList region (List.map (renameTailCalls oldName newName) items) t

        Mono.MonoTupleCreate region items t ->
            Mono.MonoTupleCreate region (List.map (renameTailCalls oldName newName) items) t

        Mono.MonoRecordCreate fields t ->
            Mono.MonoRecordCreate
                (List.map (\( n, e ) -> ( n, renameTailCalls oldName newName e )) fields)
                t

        Mono.MonoRecordUpdate record updates t ->
            Mono.MonoRecordUpdate
                (renameTailCalls oldName newName record)
                (List.map (\( n, e ) -> ( n, renameTailCalls oldName newName e )) updates)
                t

        Mono.MonoRecordAccess record fieldName t ->
            Mono.MonoRecordAccess (renameTailCalls oldName newName record) fieldName t

        Mono.MonoDestruct destructor body t ->
            Mono.MonoDestruct destructor (renameTailCalls oldName newName body) t

        Mono.MonoCase scrutName scrutVar decider jumps t ->
            Mono.MonoCase scrutName
                scrutVar
                (renameTailCallsDecider oldName newName decider)
                (List.map (\( i, e ) -> ( i, renameTailCalls oldName newName e )) jumps)
                t

        -- Leaf nodes: unchanged
        Mono.MonoLiteral _ _ ->
            expr

        Mono.MonoVarLocal _ _ ->
            expr

        Mono.MonoVarGlobal _ _ _ ->
            expr

        Mono.MonoVarKernel _ _ _ _ ->
            expr

        Mono.MonoUnit ->
            expr


renameTailCallsDecider : Name -> Name -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice
renameTailCallsDecider oldName newName decider =
    case decider of
        Mono.Leaf choice ->
            Mono.Leaf (renameTailCallsChoice oldName newName choice)

        Mono.Chain tests success failure ->
            Mono.Chain tests
                (renameTailCallsDecider oldName newName success)
                (renameTailCallsDecider oldName newName failure)

        Mono.FanOut path edges fallback ->
            Mono.FanOut path
                (List.map (\( test, d ) -> ( test, renameTailCallsDecider oldName newName d )) edges)
                (renameTailCallsDecider oldName newName fallback)


renameTailCallsChoice : Name -> Name -> Mono.MonoChoice -> Mono.MonoChoice
renameTailCallsChoice oldName newName choice =
    case choice of
        Mono.Inline e ->
            Mono.Inline (renameTailCalls oldName newName e)

        Mono.Jump i ->
            Mono.Jump i
