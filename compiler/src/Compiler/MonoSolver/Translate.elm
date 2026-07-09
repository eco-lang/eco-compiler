module Compiler.MonoSolver.Translate exposing (translate, demandUnify, specializeCtorViaScheme, enumNode, specializeCycle, specializePort, canKindDebug, monoKindDebug)

{-| Translate a TypedOptimized expression into a monomorphized expression — the
M1 (monomorphic-spine) arms, ported from `Specialize.specializeExpr`.

Node types come from `Zonk.canTypeToMono` (the pure `applySubstPure`-with-empty-
subst classification, correct for monomorphic globals). Kernel-call ABIs use the
store (`Store.instantiate`-style fresh load + unify param slots with the concrete
arg types + zonk) to reproduce `deriveKernelAbiType` exactly. Everything the M1
spine does not yet cover returns `Engine.fail (Unsupported …)` — never a fallback
to the original engine.

@docs translate

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.DecisionTree.TypedPath as TypedPath
import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeIds as TypeIds
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Id as Id
import Compiler.Data.Index as Index
import Compiler.Data.Name as Name exposing (Name)
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.Monomorphize.Analysis as Analysis
import Compiler.Monomorphize.Closure as Closure
import Compiler.Monomorphize.KernelAbi as KernelAbi
import Compiler.Monomorphize.ResolveAccessorValues as ResolveAccessorValues
import Compiler.Monomorphize.State as State
import Compiler.MonoSolver.Engine as Engine exposing (Failure(..), Step)
import Compiler.MonoSolver.Store as Store
import Compiler.MonoSolver.Zonk as Zonk
import Compiler.Reporting.Annotation as A
import Compiler.Type.UnionFind as UF
import Data.Map as DMap
import Data.Set as EverySet
import Set
import Dict
import System.TypeCheck.IO as IO
import Utils.Crash


{-| A node's monomorphized type: load its canonical type into the item store
(through the shared memo, so any demand unified at the top of the item is
visible) and zonk it back. For a monomorphic item with no demand this equals the
pure `Zonk.canTypeToMono`; for a polymorphic item the memo carries the
concretization — this is Architecture C's propagation-by-identity.
-}
classify : Can.Type TypeIds.MVarId -> Step Mono.MonoType
classify canType =
    Engine.andThen Store.zonkToMono (Store.loadType canType)


{-| Assert a demanded MonoType against a definition's annotation in the store,
concretizing the annotation's scheme variables (shared with the body via the
item memo). A no-op when the demand equals the annotation (monomorphic case).
-}
demandUnify : Can.Type TypeIds.MVarId -> Mono.MonoType -> Step ()
demandUnify annCanType demand =
    Engine.andThen
        (\annVar -> Engine.andThen (unifyStepCtx ("demandUnify " ++ canKind annCanType ++ " vs " ++ monoKind demand) annVar) (Store.monoTypeToVar demand))
        (Store.loadType annCanType)


{-| Best-effort in-store unification of two canonical types (child vs parent
context): loads both through the item memo and unifies, so a child's fresh
use-var picks up the context's already-concretized demand before the child is
translated. Never fails — the typechecker already proved these compatible; any
residual weirdness just leaves vars unbound.
-}
connectTypes : Can.Type TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Step ()
connectTypes childCan parentCan =
    Engine.andThen
        (\parentVar ->
            Engine.andThen
                (\childVar -> unifyStepBestEffort childVar parentVar)
                (Store.loadType childCan)
        )
        (Store.loadType parentCan)


{-| The element type of a canonical `List a` (through filled aliases).
-}
listElemCanType : Can.Type TypeIds.MVarId -> Maybe (Can.Type TypeIds.MVarId)
listElemCanType t =
    case t of
        Can.TType _ "List" [ elem ] ->
            Just elem

        Can.TAlias _ _ _ (Can.Filled inner) ->
            listElemCanType inner

        _ ->
            Nothing


{-| The slot types of a canonical tuple (through filled aliases).
-}
tupleSlotCanTypes : Can.Type TypeIds.MVarId -> Maybe (List (Can.Type TypeIds.MVarId))
tupleSlotCanTypes t =
    case t of
        Can.TTuple a b rest ->
            Just (a :: b :: rest)

        Can.TAlias _ _ _ (Can.Filled inner) ->
            tupleSlotCanTypes inner

        _ ->
            Nothing


{-| Connect each record-literal field expr's type to the record type's field
slot (through filled aliases); fields without a slot are skipped.
-}
connectRecordFields : List ( Name, TOpt.Expr TypeIds.MVarId ) -> Can.Type TypeIds.MVarId -> Step ()
connectRecordFields fieldExprs recordCanType =
    case recordFieldCanTypes recordCanType of
        Just fieldCans ->
            Engine.traverse
                (\( name, fieldExpr ) ->
                    case Dict.get name fieldCans of
                        Just fieldCan ->
                            connectTypes (TOpt.typeOf fieldExpr) fieldCan

                        Nothing ->
                            Engine.succeed ()
                )
                fieldExprs
                |> Engine.map (\_ -> ())

        Nothing ->
            Engine.succeed ()


recordFieldCanTypes : Can.Type TypeIds.MVarId -> Maybe (Dict.Dict Name (Can.Type TypeIds.MVarId))
recordFieldCanTypes t =
    case t of
        Can.TRecord fields _ ->
            Just (Dict.map (\_ (Can.FieldType _ ft) -> ft) fields)

        Can.TAlias _ _ _ (Can.Filled inner) ->
            recordFieldCanTypes inner

        _ ->
            Nothing


translate : TOpt.Expr TypeIds.MVarId -> Step Mono.MonoExpr
translate expr =
    case expr of
        TOpt.Bool _ v _ ->
            Engine.succeed (Mono.MonoLiteral (Mono.LBool v) Mono.MBool)

        TOpt.Chr _ v _ ->
            Engine.succeed (Mono.MonoLiteral (Mono.LChar v) Mono.MChar)

        TOpt.Str _ v _ ->
            Engine.succeed (Mono.MonoLiteral (Mono.LStr v) Mono.MString)

        TOpt.Int _ v meta ->
            Engine.map
                (\monoType ->
                    case monoType of
                        Mono.MFloat ->
                            Mono.MonoLiteral (Mono.LFloat (toFloat v)) monoType

                        _ ->
                            Mono.MonoLiteral (Mono.LInt v) monoType
                )
                (classify meta.tipe)

        TOpt.Float _ v meta ->
            Engine.map (\monoType -> Mono.MonoLiteral (Mono.LFloat v) monoType) (classify meta.tipe)

        TOpt.VarLocal name meta ->
            Engine.andThen
                (\isLM ->
                    if isLM then
                        -- local-multi FUNCTION target: record this use's applied type
                        -- and point at its per-type binding (f / f$1 / …).
                        Engine.andThen
                            (\resolvedType ->
                                Engine.map
                                    (\( freshName, instType ) -> Mono.MonoVarLocal freshName instType)
                                    (Engine.recordLocalInstance name resolvedType)
                            )
                            (classify meta.tipe)

                    else
                        Engine.andThen
                            (\isNM ->
                                if isNM then
                                    -- number-multi target: record this use's instance and
                                    -- point at its per-type binding (n / n$v1 / …).
                                    Engine.andThen
                                        (\resolvedType ->
                                            Engine.map
                                                (\( freshName, instType ) -> Mono.MonoVarLocal freshName instType)
                                                (Engine.recordNumberInstance name resolvedType)
                                        )
                                        (classify meta.tipe)

                                else
                                    -- Prefer the varEnv-bound type (from an enclosing let/
                                    -- lambda/destructor, may be more concrete than the meta).
                                    Engine.andThen
                                        (\maybeBound ->
                                            case maybeBound of
                                                Just boundType ->
                                                    Engine.succeed (Mono.MonoVarLocal name boundType)

                                                Nothing ->
                                                    Engine.map (\monoType -> Mono.MonoVarLocal name monoType) (classify meta.tipe)
                                        )
                                        (Engine.lookupVar name)
                            )
                            (Engine.isNumberMultiTarget name)
                )
                (Engine.isLocalMultiTarget name)

        TOpt.TrackedVarLocal _ name meta ->
            translate (TOpt.VarLocal name meta)

        TOpt.VarGlobal region global meta ->
            translateVarRef region global meta.tipe

        TOpt.VarEnum region global _ meta ->
            translateVarRef region global meta.tipe

        TOpt.VarBox region global meta ->
            translateVarRef region global meta.tipe

        TOpt.VarCycle region canonical name meta ->
            translateVarRef region (TOpt.Global canonical name) meta.tipe

        TOpt.VarKernel region kernelPrefix home name meta ->
            Engine.map
                (\funcMonoType -> Mono.MonoVarKernel region kernelPrefix home name funcMonoType)
                (deriveKernelAbiTypeRef ( home, name ) meta.tipe)

        TOpt.VarDebug region name _ _ meta ->
            Engine.map
                (\funcMonoType -> Mono.MonoVarKernel region "Elm" "Debug" name funcMonoType)
                (deriveKernelAbiTypeRef ( "Debug", name ) meta.tipe)

        TOpt.List region exprs meta ->
            -- Connect every element's type var to the list's element slot (or,
            -- lacking one, to the first element) before translating: an element
            -- use of a let-generalized number picks up the shared demand.
            Engine.andThen
                (\_ ->
                    Engine.andThen
                        (\monoType0 ->
                            Engine.map
                                (\monoExprs ->
                                    let
                                        monoType =
                                            if Mono.containsAnyMVar monoType0 then
                                                case monoExprs of
                                                    first :: _ ->
                                                        Mono.MList (Mono.typeOf first)

                                                    [] ->
                                                        monoType0

                                            else
                                                monoType0
                                    in
                                    Mono.MonoList region monoExprs monoType
                                )
                                (Engine.traverse translate exprs)
                        )
                        (classify meta.tipe)
                )
                (case listElemCanType meta.tipe of
                    Just elemCan ->
                        Engine.traverse (\e -> connectTypes (TOpt.typeOf e) elemCan) exprs
                            |> Engine.map (\_ -> ())

                    Nothing ->
                        case exprs of
                            first :: restExprs ->
                                Engine.traverse (\e -> connectTypes (TOpt.typeOf e) (TOpt.typeOf first)) restExprs
                                    |> Engine.map (\_ -> ())

                            [] ->
                                Engine.succeed ()
                )

        TOpt.Call region func args meta ->
            translateCall region func args meta.tipe

        TOpt.If branches final meta ->
            -- Per branch: translate the CONDITION first (a shared number var used
            -- there stays at its eager type), then connect the branch value's type
            -- var to the If's own var (so a use of a let-generalized number under a
            -- Float context picks up the demand), then translate the branch value.
            -- Interleaved to mirror the original engine's per-use demand recording.
            Engine.andThen
                (\monoType0 ->
                    Engine.andThen
                        (\monoBranches ->
                            Engine.map
                                (\monoFinal ->
                                    let
                                        monoType =
                                            if Mono.containsAnyMVar monoType0 then
                                                Mono.typeOf monoFinal

                                            else
                                                monoType0
                                    in
                                    Mono.MonoIf monoBranches monoFinal monoType
                                )
                                (Engine.andThen (\_ -> translate final)
                                    (connectTypes (TOpt.typeOf final) meta.tipe)
                                )
                        )
                        (Engine.traverse (translateIfBranch meta.tipe) branches)
                )
                (classify meta.tipe)

        TOpt.TailCall name args meta ->
            Engine.andThen
                (\monoType ->
                    Engine.map
                        (\monoArgs -> Mono.MonoTailCall name monoArgs monoType)
                        (Engine.traverse (\( argName, argExpr ) -> Engine.map (\me -> ( argName, me )) (translate argExpr)) args)
                )
                (classify meta.tipe)

        TOpt.Unit _ ->
            Engine.succeed Mono.MonoUnit

        TOpt.Tuple region a b rest meta ->
            -- Connect each slot's type var to the tuple type's slot before
            -- translating (demand flow into tuple literals).
            Engine.andThen
                (\_ ->
                    Engine.andThen
                        (\monoA ->
                            Engine.andThen
                                (\monoB ->
                                    Engine.map
                                        (\monoRest ->
                                            let
                                                allExprs =
                                                    monoA :: monoB :: monoRest
                                            in
                                            Mono.MonoTupleCreate region allExprs (Mono.MTuple (List.map Mono.typeOf allExprs))
                                        )
                                        (Engine.traverse translate rest)
                                )
                                (translate b)
                        )
                        (translate a)
                )
                (case tupleSlotCanTypes meta.tipe of
                    Just slotCans ->
                        Engine.traverse (\( e, slotCan ) -> connectTypes (TOpt.typeOf e) slotCan)
                            (List.map2 Tuple.pair (a :: b :: rest) slotCans)
                            |> Engine.map (\_ -> ())

                    Nothing ->
                        Engine.succeed ()
                )

        TOpt.Record fields meta ->
            -- Connect each field expr's type var to the record type's field slot
            -- before translating (demand flow into record literals).
            Engine.andThen
                (\_ ->
                    Engine.map
                        (\monoFieldsRev ->
                            Mono.MonoRecordCreate monoFieldsRev (recordTypeFromFields monoFieldsRev)
                        )
                        (Engine.foldlS
                            (\( name, fieldExpr ) acc -> Engine.map (\me -> ( name, me ) :: acc) (translate fieldExpr))
                            []
                            (Dict.toList fields)
                        )
                )
                (connectRecordFields (Dict.toList fields) meta.tipe)

        TOpt.TrackedRecord _ fields meta ->
            Engine.andThen
                (\_ ->
                    Engine.map
                        (\monoFieldsRev ->
                            Mono.MonoRecordCreate monoFieldsRev (recordTypeFromFields monoFieldsRev)
                        )
                        (Engine.foldlS
                            (\( locName, fieldExpr ) acc ->
                                Engine.map (\me -> ( A.toValue locName, me ) :: acc) (translate fieldExpr)
                            )
                            []
                            (DMap.toList A.compareLocated fields)
                        )
                )
                (connectRecordFields
                    (List.map (\( locName, e ) -> ( A.toValue locName, e )) (DMap.toList A.compareLocated fields))
                    meta.tipe
                )

        TOpt.Access record _ fieldName meta ->
            translateAccess record fieldName meta

        TOpt.Update _ record updates meta ->
            translateUpdate record updates meta.tipe

        TOpt.Let def body meta ->
            translateLet def body meta.tipe

        TOpt.Case label root decider jumps meta ->
            Engine.andThen
                (\monoTypeFromCan ->
                    Engine.andThen
                        (\monoDecider ->
                            Engine.map
                                (\monoJumps ->
                                    Mono.MonoCase label
                                        root
                                        monoDecider
                                        monoJumps
                                        (if Mono.containsAnyMVar monoTypeFromCan then
                                            inferCaseType monoJumps monoDecider monoTypeFromCan

                                         else
                                            monoTypeFromCan
                                        )
                                )
                                (specializeJumps meta.tipe jumps)
                        )
                        (specializeDecider meta.tipe root decider)
                )
                (classify meta.tipe)

        TOpt.Destruct destructor body meta ->
            let
                (TOpt.Destructor dname path dmeta) =
                    destructor
            in
            -- Divert (MONO_028): a scalar-number destructor slot projected from a
            -- number-multi root is specialized body-FIRST, so its uses drive one
            -- root instance per demanded numeric type (+ dead-destructor elim).
            Engine.andThen
                (\maybeRootType ->
                    case maybeRootType of
                        Just eagerRootType ->
                            Engine.andThen
                                (\gte ->
                                    Engine.andThen
                                        (\eagerLeaf ->
                                            if isScalarNumber eagerLeaf && refineRootInstance gte eagerRootType path eagerLeaf /= Nothing then
                                                specializeNumberDestruct dname path dmeta (pathRootName path) eagerRootType body meta

                                            else
                                                generalDestruct destructor body meta
                                        )
                                        (classify dmeta.tipe)
                                )
                                (Engine.getS .globalTypeEnv)

                        Nothing ->
                            generalDestruct destructor body meta
                )
                (Engine.numberMultiRootType (pathRootName path))

        TOpt.Accessor region fieldName meta ->
            Engine.andThen
                (\monoType ->
                    if ResolveAccessorValues.accessorTypeNeedsDefer monoType then
                        Engine.succeed (Mono.MonoAccessorValue region fieldName monoType)

                    else
                        Engine.map
                            (\specId -> Mono.MonoVarGlobal region specId monoType)
                            (Engine.enqueueSpec (Mono.Accessor fieldName) monoType)
                )
                (classify meta.tipe)

        TOpt.Function params body meta ->
            specializeLambda params body meta.tipe

        TOpt.TrackedFunction trackedParams body meta ->
            specializeLambda (List.map (\( locName, pt ) -> ( A.toValue locName, pt )) trackedParams) body meta.tipe

        -- Deferred to later milestones:
        _ ->
            Engine.fail (Unsupported (nodeKind expr))


translateBranch : ( TOpt.Expr TypeIds.MVarId, TOpt.Expr TypeIds.MVarId ) -> Step ( Mono.MonoExpr, Mono.MonoExpr )
translateBranch ( cond, bodyExpr ) =
    Engine.map2 (\c b -> ( c, b )) (translate cond) (translate bodyExpr)


{-| Translate one If branch: condition first, then connect the branch value's
type to the If's type, then the branch value (see the `TOpt.If` arm).
-}
translateIfBranch : Can.Type TypeIds.MVarId -> ( TOpt.Expr TypeIds.MVarId, TOpt.Expr TypeIds.MVarId ) -> Step ( Mono.MonoExpr, Mono.MonoExpr )
translateIfBranch ifCanType ( cond, bodyExpr ) =
    Engine.andThen
        (\monoCond ->
            Engine.andThen
                (\_ -> Engine.map (\monoBody -> ( monoCond, monoBody )) (translate bodyExpr))
                (connectTypes (TOpt.typeOf bodyExpr) ifCanType)
        )
        (translate cond)



-- ====== RECURSIVE CYCLES (single-recursion / SCC-of-1) ======


{-| Specialize the DEMANDED member of a recursive cycle (self- or mutual-
recursive). We produce only the node for `name`; its `VarCycle` references to
itself and to siblings enqueue those members as their own specs (the drain skips
the in-progress self-spec), so an SCC of any size materializes one node per
member across separate work items — no single node holds the whole group.
-}
specializeCycle : Name -> List ( Name, TOpt.Expr TypeIds.MVarId ) -> List (TOpt.Def TypeIds.MVarId) -> Mono.MonoType -> Step Mono.MonoNode
specializeCycle name valueDefs funcDefs demand =
    case listFind (\d -> cycleDefName d == name) funcDefs of
        Just def ->
            specializeCycleFuncDef def demand

        Nothing ->
            case listFind (\( n, _ ) -> n == name) valueDefs of
                Just ( _, vexpr ) ->
                    specializeCycleValue vexpr demand

                Nothing ->
                    -- Name didn't match a member (SCC-of-1 whose enqueued name was
                    -- the group's, not the member's): fall back to the lone def.
                    case ( valueDefs, funcDefs ) of
                        ( [], [ singleDef ] ) ->
                            specializeCycleFuncDef singleDef demand

                        ( [ ( _, vexpr ) ], [] ) ->
                            specializeCycleValue vexpr demand

                        _ ->
                            Engine.fail (EngineBug ("cycle member not found: " ++ name))


cycleDefName : TOpt.Def TypeIds.MVarId -> Name
cycleDefName def =
    case def of
        TOpt.Def _ n _ _ ->
            n

        TOpt.TailDef _ n _ _ _ _ ->
            n


listFind : (a -> Bool) -> List a -> Maybe a
listFind pred xs =
    List.head (List.filter pred xs)


specializeCycleValue : TOpt.Expr TypeIds.MVarId -> Mono.MonoType -> Step Mono.MonoNode
specializeCycleValue vexpr demand =
    Engine.andThen
        (\_ -> Engine.map (\monoExpr -> Mono.MonoDefine monoExpr (Mono.typeOf monoExpr)) (translate vexpr))
        (demandUnify (TOpt.typeOf vexpr) demand)



-- ====== PORTS ======


{-| Specialize a port node into a `MonoPortIncoming`/`MonoPortOutgoing` wrapper
closure over `Elm.Platform.leaf name value`. Incoming ports enqueue their decoder
(recorded as the port's `decoderSpecId`); outgoing ports inline their encoder.
Mirrors `Specialize.specializePortNode`.
-}
specializePort : Bool -> TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Mono.MonoType -> Step Mono.MonoNode
specializePort incoming expr canType requestedMonoType =
    Engine.andThen
        (\_ ->
            Engine.andThen
                (\classifiedCan ->
                    Engine.andThen
                        (\( portGlobal, portName ) ->
                            -- Usually the demand is a concrete `p -> r`; if it reached
                            -- us erased (a bare MVar), recover the shape from the port's
                            -- own (now-unified) canonical type.
                            let
                                effectiveType =
                                    case requestedMonoType of
                                        Mono.MFunction _ _ ->
                                            requestedMonoType

                                        _ ->
                                            classifiedCan
                            in
                            case effectiveType of
                                Mono.MFunction [ paramType ] resultType ->
                                    Engine.andThen
                                        (\lambdaId ->
                                            let
                                                region =
                                                    A.zero

                                                paramName =
                                                    "_eco_port_arg"

                                                paramVar =
                                                    Mono.MonoVarLocal paramName paramType

                                                nameLit =
                                                    Mono.MonoLiteral (Mono.LStr portName) Mono.MString

                                                leafKernel valueType =
                                                    Mono.MonoVarKernel region "Elm" "Platform" "leaf" (Mono.MFunction [ Mono.MString, valueType ] resultType)

                                                closureInfo =
                                                    { lambdaId = lambdaId
                                                    , captures = []
                                                    , params = [ ( paramName, paramType ) ]
                                                    , closureKind = Nothing
                                                    , captureAbi = Nothing
                                                    }
                                            in
                                            if incoming then
                                                let
                                                    body =
                                                        Mono.MonoCall region (leafKernel paramType) [ nameLit, paramVar ] resultType Mono.defaultCallInfo

                                                    wrapper =
                                                        Mono.MonoClosure closureInfo body effectiveType
                                                in
                                                Engine.andThen
                                                    (\decoderMonoType ->
                                                        Engine.andThen
                                                            (\decoderSpecId ->
                                                                Engine.map
                                                                    (\_ -> Mono.MonoPortIncoming wrapper effectiveType)
                                                                    (recordPort { name = portName, key = Mono.toComparableGlobal portGlobal, incoming = True, decoderSpecId = Just decoderSpecId })
                                                            )
                                                            (Engine.enqueueSpec portGlobal decoderMonoType)
                                                    )
                                                    (classify (TOpt.typeOf expr))

                                            else
                                                Engine.andThen
                                                    (\_ ->
                                                        Engine.andThen
                                                            (\encoderMono ->
                                                        let
                                                            encodedType =
                                                                case Mono.typeOf encoderMono of
                                                                    Mono.MFunction _ r ->
                                                                        r

                                                                    t ->
                                                                        t

                                                            encodedExpr =
                                                                Mono.MonoCall region encoderMono [ paramVar ] encodedType Mono.defaultCallInfo

                                                            body =
                                                                Mono.MonoCall region (leafKernel encodedType) [ nameLit, encodedExpr ] resultType Mono.defaultCallInfo

                                                            wrapper =
                                                                Mono.MonoClosure closureInfo body effectiveType
                                                        in
                                                                Engine.map
                                                                    (\_ -> Mono.MonoPortOutgoing wrapper effectiveType)
                                                                    (recordPort { name = portName, key = Mono.toComparableGlobal portGlobal, incoming = False, decoderSpecId = Nothing })
                                                            )
                                                            (translate expr)
                                                    )
                                                    (connectEncoderType expr canType)
                                        )
                                        allocLambdaId

                                _ ->
                                    Engine.fail (EngineBug ("port '" ++ portName ++ "' must have a single-parameter function type; got " ++ monoKind effectiveType))
                        )
                        portGlobalContext
                )
                (classify canType)
        )
        (demandUnify canType requestedMonoType)


{-| Connect an outgoing port's ENCODER reference to `payload -> fresh` so its
(otherwise free-floating) type var takes the function shape at the payload type
— an erased encoder VG compiles to a 0-operand llvm.call.
-}
connectEncoderType : TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Step ()
connectEncoderType expr portCanType =
    case portCanType of
        Can.TLambda payloadCan _ ->
            Engine.andThen
                (\encVar ->
                    Engine.andThen
                        (\payloadVar ->
                            Engine.andThen
                                (\resVar ->
                                    Engine.andThen
                                        (\funVar -> unifyStepBestEffort encVar funVar)
                                        (Engine.freshVar (IO.Structure (IO.Fun1 payloadVar resVar)))
                                )
                                (Engine.freshVar (IO.FlexVar Nothing))
                        )
                        (Store.loadType payloadCan)
                )
                (Store.loadType (TOpt.typeOf expr))

        _ ->
            Engine.succeed ()


portGlobalContext : Step ( Mono.Global, String )
portGlobalContext s =
    case s.currentGlobal of
        Just ((Mono.Global _ nm) as g) ->
            Ok ( ( g, Name.toElmString nm ), s )

        _ ->
            Err (EngineBug "specializePort: currentGlobal must be a Global")


{-| Replace every `MVar _ CEcoValue` in a kernel ABI with a fresh id (one per
distinct source id, sharing preserved), returning the next unused id.
-}
remapEcoVarsFresh : TypeIds.MVarId -> Mono.MonoType -> ( Mono.MonoType, TypeIds.MVarId )
remapEcoVarsFresh nextId0 abiType =
    let
        go t ( mapping, nextId ) =
            case t of
                Mono.MVar mid Mono.CEcoValue ->
                    case Dict.get (Engine.mvarIdKey mid) mapping of
                        Just fresh ->
                            ( Mono.MVar fresh Mono.CEcoValue, ( mapping, nextId ) )

                        Nothing ->
                            ( Mono.MVar nextId Mono.CEcoValue
                            , ( Dict.insert (Engine.mvarIdKey mid) nextId mapping, Id.succ nextId )
                            )

                Mono.MVar _ _ ->
                    ( t, ( mapping, nextId ) )

                Mono.MFunction args r ->
                    let
                        ( args1, acc1 ) =
                            List.foldr (\a ( accL, accS ) -> let ( a1, accS1 ) = go a accS in ( a1 :: accL, accS1 )) ( [], ( mapping, nextId ) ) args

                        ( r1, acc2 ) =
                            go r acc1
                    in
                    ( Mono.MFunction args1 r1, acc2 )

                Mono.MList e ->
                    let
                        ( e1, acc1 ) =
                            go e ( mapping, nextId )
                    in
                    ( Mono.MList e1, acc1 )

                Mono.MTuple es ->
                    let
                        ( es1, acc1 ) =
                            List.foldr (\a ( accL, accS ) -> let ( a1, accS1 ) = go a accS in ( a1 :: accL, accS1 )) ( [], ( mapping, nextId ) ) es
                    in
                    ( Mono.MTuple es1, acc1 )

                Mono.MCustom h n args ->
                    let
                        ( args1, acc1 ) =
                            List.foldr (\a ( accL, accS ) -> let ( a1, accS1 ) = go a accS in ( a1 :: accL, accS1 )) ( [], ( mapping, nextId ) ) args
                    in
                    ( Mono.MCustom h n args1, acc1 )

                Mono.MRecord fields ->
                    let
                        ( fields1, acc1 ) =
                            Dict.foldr (\k v ( accD, accS ) -> let ( v1, accS1 ) = go v accS in ( Dict.insert k v1 accD, accS1 )) ( Dict.empty, ( mapping, nextId ) ) fields
                    in
                    ( Mono.MRecord fields1, acc1 )

                _ ->
                    ( t, ( mapping, nextId ) )

        ( result, ( _, finalNext ) ) =
            go abiType ( Dict.empty, nextId0 )
    in
    ( result, finalNext )


canKindIds : Can.Type TypeIds.MVarId -> String
canKindIds canType =
    case canType of
        Can.TVar mvarId ->
            "v" ++ String.fromInt (Engine.mvarIdKey mvarId)

        Can.TLambda a b ->
            "(" ++ canKindIds a ++ "->" ++ canKindIds b ++ ")"

        Can.TType _ name args ->
            name
                ++ (if List.isEmpty args then
                        ""

                    else
                        "<" ++ String.join "," (List.map canKindIds args) ++ ">"
                   )

        Can.TRecord _ _ ->
            "rec"

        Can.TUnit ->
            "unit"

        Can.TTuple a b rest ->
            "T(" ++ String.join "," (List.map canKindIds (a :: b :: rest)) ++ ")"

        Can.TAlias _ name _ _ ->
            "alias:" ++ name


canKindDebug : Can.Type TypeIds.MVarId -> String
canKindDebug =
    canKind


monoKindDebug : Mono.MonoType -> String
monoKindDebug =
    monoKind


monoKind : Mono.MonoType -> String
monoKind mt =
    case mt of
        Mono.MFunction ps r ->
            "(" ++ String.join "," (List.map monoKind ps) ++ "->" ++ monoKind r ++ ")"

        Mono.MCustom _ n args ->
            n ++ (if List.isEmpty args then "" else "<" ++ String.join "," (List.map monoKind args) ++ ">")

        Mono.MVar _ Mono.CNumber ->
            "num"

        Mono.MVar _ Mono.CEcoValue ->
            "eco"

        Mono.MInt ->
            "I"

        Mono.MFloat ->
            "F"

        Mono.MList e ->
            "[" ++ monoKind e ++ "]"

        Mono.MTuple es ->
            "T(" ++ String.join "," (List.map monoKind es) ++ ")"

        Mono.MRecord fields ->
            "R{" ++ String.join "," (List.map (\( k, v ) -> k ++ ":" ++ monoKind v) (Dict.toList fields)) ++ "}"

        Mono.MString ->
            "S"

        Mono.MBool ->
            "B"

        _ ->
            "other"


recordPort : Mono.PortRegistration -> Step ()
recordPort reg =
    Engine.modifyS
        (\s ->
            if List.any (\p -> p.key == reg.key) s.ports then
                s

            else
                { s | ports = reg :: s.ports }
        )


specializeCycleFuncDef : TOpt.Def TypeIds.MVarId -> Mono.MonoType -> Step Mono.MonoNode
specializeCycleFuncDef def demand =
    case def of
        TOpt.Def _ _ body defType ->
            Engine.andThen
                (\_ -> Engine.map (\monoExpr -> Mono.MonoDefine monoExpr (Mono.typeOf monoExpr)) (translate body))
                (demandUnify defType demand)

        TOpt.TailDef _ _ typedArgs body defType _ ->
            Engine.andThen
                (\_ ->
                    Engine.andThen
                        (\monoParams ->
                            Engine.andThen
                                (\funcType ->
                                    Engine.map
                                        (\monoBody -> Mono.MonoTailFunc monoParams monoBody funcType)
                                        (Engine.scoped (Engine.andThen (\_ -> translate body) (insertVars monoParams)))
                                )
                                (classify defType)
                        )
                        (Engine.traverse (\( locName, argType ) -> Engine.map (\mt -> ( A.toValue locName, mt )) (classify argType)) typedArgs)
                )
                (demandUnify defType demand)



-- ====== CONSTRUCTOR / ENUM NODES ======


{-| Specialize a constructor node into `MonoCtor`. Unify the ctor's scheme type
with the demanded type, zonk to the substituted function type, and peel `arity`
field types off it; the result type is peeled off the demand. Mirrors
`Specialize.specializeCtorViaScheme` (Box uses tag 0, arity 1).
-}
specializeCtorViaScheme : Name -> Int -> Int -> Can.Type TypeIds.MVarId -> Mono.MonoType -> Step Mono.MonoNode
specializeCtorViaScheme name tag arity canType demand =
    Engine.andThen
        (\annVar ->
            Engine.andThen
                (\demandVar ->
                    Engine.andThen
                        (\_ ->
                            Engine.map
                                (\ctorMonoType ->
                                    Mono.MonoCtor
                                        { name = name, tag = tag, fieldTypes = extractFieldTypes arity ctorMonoType }
                                        (extractCtorResultType arity demand)
                                )
                                (Store.zonkToMono annVar)
                        )
                        (Store.unifyStep annVar demandVar)
                )
                (Store.monoTypeToVar demand)
        )
        (Store.loadType canType)


{-| Specialize an enum (nullary ctor) node into `MonoEnum tag <type>`.
-}
enumNode : Int -> Can.Type TypeIds.MVarId -> Mono.MonoType -> Step Mono.MonoNode
enumNode tag canType demand =
    Engine.andThen
        (\annVar ->
            Engine.andThen
                (\demandVar ->
                    Engine.andThen
                        (\_ -> Engine.map (\monoType -> Mono.MonoEnum tag monoType) (Store.zonkToMono annVar))
                        (Store.unifyStep annVar demandVar)
                )
                (Store.monoTypeToVar demand)
        )
        (Store.loadType canType)


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


extractCtorResultType : Int -> Mono.MonoType -> Mono.MonoType
extractCtorResultType n monoType =
    if n <= 0 then
        monoType

    else
        case monoType of
            Mono.MFunction _ result ->
                extractCtorResultType (n - 1) result

            _ ->
                monoType



-- ====== CLOSURES ======


{-| Specialize a lambda into `MonoClosure`. Mirrors `Specialize.specializeLambda`:
classify the (curried, un-flattened) function type, specialize each param type,
allocate `AnonymousLambda currentModule counter++`, translate the body, and
compute captures via the shared `Closure.computeClosureCaptures`. `closureKind`
and `captureAbi` are placeholder `Nothing` at mono time (filled by GlobalOpt).
-}
specializeLambda : List ( Name, Can.Type TypeIds.MVarId ) -> TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
specializeLambda params body canType =
    Engine.andThen
        (\monoType0 ->
            Engine.andThen
                (\classifiedParams ->
                    let
                        -- Prefer param types PEELED from the (possibly re-translated,
                        -- hence concretized) function type: `classify` is compositional
                        -- so this equals per-param classify in the normal case, but stays
                        -- concrete when only the function type's vars were unified (a
                        -- re-translated local-multi lambda whose param vars are distinct).
                        peeled =
                            extractFieldTypes (List.length params) monoType0

                        monoParams =
                            if List.length peeled == List.length params then
                                List.map2 (\( nm, _ ) pt -> ( nm, pt )) classifiedParams peeled

                            else
                                classifiedParams
                    in
                    Engine.andThen
                        (\lambdaId ->
                            Engine.map
                                (\monoBody ->
                                    Mono.MonoClosure
                                        { lambdaId = lambdaId
                                        , captures = Closure.computeClosureCaptures monoParams monoBody
                                        , params = monoParams
                                        , closureKind = Nothing
                                        , captureAbi = Nothing
                                        }
                                        monoBody
                                        monoType0
                                )
                                (Engine.scoped (Engine.andThen (\_ -> translate body) (insertVars monoParams)))
                        )
                        allocLambdaId
                )
                (Engine.traverse (\( name, paramCanType ) -> Engine.map (\mt -> ( name, mt )) (classify paramCanType)) params)
        )
        (classify canType)


allocLambdaId : Step Mono.LambdaId
allocLambdaId =
    \s -> Ok ( Mono.AnonymousLambda s.currentModule s.lambdaCounter, { s | lambdaCounter = s.lambdaCounter + 1 } )



-- ====== VAR REFERENCES ======


{-| A standalone reference to a global value/ctor/box → `MonoVarGlobal SpecId`.
Mirrors the VarGlobal/VarEnum/VarBox arms (enqueue with the node's own type).
-}
translateVarRef : A.Region -> TOpt.Global -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateVarRef region global canType =
    Engine.andThen
        (\monoType ->
            Engine.map
                (\specId -> Mono.MonoVarGlobal region specId monoType)
                (Engine.enqueueSpec (toptToMonoGlobal global) monoType)
        )
        (classify canType)


monoTypeMentionsEco : Mono.MonoType -> Bool
monoTypeMentionsEco mt =
    case mt of
        Mono.MVar _ Mono.CEcoValue ->
            True

        Mono.MFunction args r ->
            List.any monoTypeMentionsEco args || monoTypeMentionsEco r

        Mono.MList t ->
            monoTypeMentionsEco t

        Mono.MTuple ts ->
            List.any monoTypeMentionsEco ts

        Mono.MCustom _ _ args ->
            List.any monoTypeMentionsEco args

        Mono.MRecord fields ->
            Dict.foldl (\_ t acc -> acc || monoTypeMentionsEco t) False fields

        _ ->
            False



-- ====== CALLS ======


translateCall : A.Region -> TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateCall region func args callCanType =
    case func of
        TOpt.VarGlobal funcRegion global funcMeta ->
            Engine.andThen
                (\maybeAnn ->
                    let
                        funcCanType =
                            case maybeAnn of
                                Just (Can.Forall _ annType) ->
                                    annType

                                Nothing ->
                                    funcMeta.tipe
                    in
                    translateGlobalCall region funcRegion global funcCanType args callCanType
                )
                (lookupAnnotation global)

        TOpt.VarKernel funcRegion kernelPrefix home name funcMeta ->
            translateKernelCall region funcRegion kernelPrefix home name ( home, name ) funcMeta.tipe args callCanType

        TOpt.VarDebug funcRegion name _ _ funcMeta ->
            translateKernelCall region funcRegion "Elm" "Debug" name ( "Debug", name ) funcMeta.tipe args callCanType

        TOpt.VarLocal name funcMeta ->
            localCalleeCall region func name funcMeta args callCanType

        TOpt.TrackedVarLocal _ name funcMeta ->
            localCalleeCall region func name funcMeta args callCanType

        _ ->
            translateIndirectCall region func args callCanType


{-| A call whose callee is a direct local reference (tracked or not). If the
local is a multi-instance FUNCTION, concretize its type from the call args
(solver-native, like the global path) and record its instance at that concrete
type — so `applyTwo (\x y->x) 1 2` specializes the callee's params to Int
rather than leaving them CEcoValue.
-}
localCalleeCall : A.Region -> TOpt.Expr TypeIds.MVarId -> Name -> TOpt.Meta TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
localCalleeCall region func name funcMeta args callCanType =
    Engine.andThen
        (\isLM ->
            if isLM then
                translateLocalMultiCall region name funcMeta.tipe args callCanType

            else
                translateIndirectCall region func args callCanType
        )
        (Engine.isLocalMultiTarget name)


{-| Specialize a call to a local-multi function: instantiate its type, unify its
params/result against the arg types (concretizing shared vars), translate the
args, then record the callee's instance at the zonked concrete type (`f`/`f$1`).
Mirrors `translateGlobalCall` but records a local instance instead of enqueueing
a global spec.
-}
translateLocalMultiCall : A.Region -> Name -> Can.Type TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateLocalMultiCall region name funcCanType args callCanType =
    let
        _ =
            args

        argCanTypes =
            List.map TOpt.typeOf args

        argCount =
            List.length argCanTypes
    in
    Engine.andThen
        (\funcVar ->
            Engine.andThen
                (\argStash ->
                    Engine.andThen
                        (\_ ->
                            Engine.andThen
                                (\monoArgs ->
                                    Engine.andThen
                                        (\funcMonoType ->
                                            Engine.andThen
                                                (\resultMonoType ->
                                                    Engine.map
                                                        (\( freshName, instType ) ->
                                                            Mono.MonoCall region
                                                                (Mono.MonoVarLocal freshName instType)
                                                                monoArgs
                                                                resultMonoType
                                                                Mono.defaultCallInfo
                                                        )
                                                        (Engine.recordLocalInstance name funcMonoType)
                                                )
                                                (callResultType argCount funcMonoType callCanType)
                                        )
                                        (Store.zonkToMono funcVar)
                                )
                                (translateArgsWith argStash args)
                        )
                        (unifyResultWithExpected funcVar argCount callCanType)
                )
                (unifyParamsCollect funcVar args)
        )
        (instantiate funcCanType)


{-| A call whose callee is not a direct global/kernel/debug (a local holding a
function, an `Access`, a nested `Call`): translate the args, translate the callee
as an ordinary expression, and take the result type from the call node. Mirrors
the generic fallback in `Specialize` (recursively specialize the callee expr).
-}
translateIndirectCall : A.Region -> TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateIndirectCall region func args callCanType =
    Engine.andThen
        (\_ ->
            translateIndirectCallBody region func args callCanType
        )
        -- Connect the callee's type var to `arg1 -> … -> result` first: a call to
        -- a destructor-derived local function (`getter rec`) is the only place its
        -- type meets concrete arguments, and the connection flows back through the
        -- destructor root into the case/tuple the function came from.
        (appShapeConnect func args callCanType)


appShapeConnect : TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step ()
appShapeConnect func args callCanType =
    Engine.andThen
        (\funcUseVar ->
            Engine.andThen
                (\appVar ->
                    Engine.andThen
                        (\_ ->
                            -- Bridge into the destructor's own type ids (and through
                            -- them, the root case/tuple type) for derived functions.
                            case accessedLocalName func of
                                Just localName ->
                                    Engine.andThen
                                        (\maybeDCan ->
                                            case maybeDCan of
                                                Just dCan ->
                                                    Engine.andThen
                                                        (\dVar -> unifyStepBestEffort dVar appVar)
                                                        (Store.loadType dCan)

                                                Nothing ->
                                                    Engine.succeed ()
                                        )
                                        (Engine.getS (\s -> Dict.get localName s.derivedDestructors))

                                Nothing ->
                                    Engine.succeed ()
                        )
                        (unifyStepBestEffort funcUseVar appVar)
                )
                (buildAppVar args callCanType)
        )
        (Store.loadType (TOpt.typeOf func))


buildAppVar : List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step IO.Variable
buildAppVar args callCanType =
    case args of
        [] ->
            Store.loadType callCanType

        arg :: rest ->
            Engine.andThen
                (\argVar ->
                    Engine.andThen
                        (\restVar -> Engine.freshVar (IO.Structure (IO.Fun1 argVar restVar)))
                        (buildAppVar rest callCanType)
                )
                (Store.loadType (TOpt.typeOf arg))


translateIndirectCallBody : A.Region -> TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateIndirectCallBody region func args callCanType =
    Engine.andThen
        (\monoArgs ->
            Engine.andThen
                (\monoFunc ->
                    Engine.map
                        (\resultMonoType -> Mono.MonoCall region monoFunc monoArgs resultMonoType Mono.defaultCallInfo)
                        (classify callCanType)
                )
                (translate func)
        )
        (Engine.traverse translate args)


{-| Specialize a call to a top-level global (monomorphic or polymorphic). The
callee's demanded type is derived by instantiating its scheme with fresh vars,
unifying the parameter slots with the concrete argument types and the result
with the expected call type, then zonking — the store equivalent of the original
engine's `applySubstPure` (monomorphic) / `unifyCallSiteDirectWithExpected`
(polymorphic).
-}
translateGlobalCall : A.Region -> A.Region -> TOpt.Global -> Can.Type TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateGlobalCall region funcRegion global funcCanType args callCanType =
    let
        argCanTypes =
            List.map TOpt.typeOf args

        argCount =
            List.length argCanTypes
    in
    -- Instantiate the callee and unify its params/result against the arg types
    -- FIRST, concretizing shared vars in the item memo, THEN translate the args
    -- so their VarLocal uses see the demanded type (solver-native demand flow;
    -- needed for number-multi and for a faithful funcMonoType).
    Engine.andThen
        (\funcVar ->
            Engine.andThen
                (\argStash ->
                    Engine.andThen
                        (\_ ->
                            Engine.andThen
                                (\monoArgs ->
                                    Engine.andThen
                                        (\funcMonoType ->
                                            Engine.andThen
                                                (\resultMonoType ->
                                                    Engine.map
                                                        (\specId ->
                                                            Mono.MonoCall region
                                                                (Mono.MonoVarGlobal funcRegion specId funcMonoType)
                                                                monoArgs
                                                                resultMonoType
                                                                Mono.defaultCallInfo
                                                        )
                                                        (Engine.enqueueSpec (toptToMonoGlobal global) funcMonoType)
                                                )
                                                (callResultType argCount funcMonoType callCanType)
                                        )
                                        (Store.zonkToMono funcVar)
                                )
                                (translateArgsWith argStash args)
                        )
                        (unifyResultWithExpected funcVar argCount callCanType)
                )
                (unifyParamsCollect funcVar args)
        )
        (instantiate funcCanType)


translateKernelCall : A.Region -> A.Region -> Name -> Name -> Name -> ( String, String ) -> Can.Type TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateKernelCall region funcRegion kernelPrefix home name kernelId funcCanType args callCanType =
    let
        argCanTypes =
            List.map TOpt.typeOf args
    in
    -- Derive the kernel ABI FIRST: this unifies the kernel's param slots with the
    -- argument types, concretizing shared vars in the item memo (e.g. `1.4 * n`
    -- forces `n`'s number var to Float) BEFORE the args are translated — so an
    -- arg's VarLocal use sees the demanded type (needed for number-multi).
    Engine.andThen
        (\funcMonoType ->
            Engine.andThen
                (\monoArgs ->
                    Engine.map
                        (\resultMonoType ->
                            Mono.MonoCall region
                                (Mono.MonoVarKernel funcRegion kernelPrefix home name funcMonoType)
                                monoArgs
                                resultMonoType
                                Mono.defaultCallInfo
                        )
                        (callResultType (List.length argCanTypes) funcMonoType callCanType)
                )
                (Engine.traverse translate args)
        )
        (deriveKernelAbiTypeCall kernelId funcCanType args)


{-| The MonoCall result type: peel the applied-arg count off the callee's type;
if that still has a var, fall back to the call node's type. Mirrors
`abiResultType`/`peelCallResult` in the original engine.
-}
callResultType : Int -> Mono.MonoType -> Can.Type TypeIds.MVarId -> Step Mono.MonoType
callResultType argCount funcMonoType callCanType =
    let
        abiResultType =
            peelResult argCount funcMonoType
    in
    if Mono.containsAnyMVar abiResultType then
        classify callCanType

    else
        Engine.succeed abiResultType


peelResult : Int -> Mono.MonoType -> Mono.MonoType
peelResult n monoType =
    if n <= 0 then
        monoType

    else
        case monoType of
            Mono.MFunction _ result ->
                peelResult (n - 1) result

            _ ->
                monoType



-- ====== KERNEL ABI ======


{-| Kernel ABI for a CALL: instantiate the kernel type fresh, unify its param
slots with the concrete argument types, zonk, then apply the ABI-mode policy.
-}
deriveKernelAbiTypeCall : ( String, String ) -> Can.Type TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Step Mono.MonoType
deriveKernelAbiTypeCall kernelId canFuncType args =
    deriveKernelAbiTypeWith kernelId canFuncType <|
        Engine.andThen
            (\funcVar -> Engine.map (\_ -> funcVar) (unifyParamsWithArgExprs funcVar args))
            (instantiate canFuncType)


{-| Like `unifyParamsWithArgs` but ignores unification failures: for the kernel
ABI, `monoAfterSubst` only feeds the mode logic (which handles residual vars), so
a higher-order arg whose curried structure doesn't line up with the kernel's
declared param must not abort — it simply leaves the ABI non-concrete (which the
PreserveVars-else path then boxes as CEcoValue).
-}
unifyParamsBestEffort : IO.Variable -> List (Can.Type TypeIds.MVarId) -> Step ()
unifyParamsBestEffort funcVar argCanTypes =
    case argCanTypes of
        [] ->
            Engine.succeed ()

        argCanType :: rest ->
            Engine.andThen
                (\desc ->
                    case desc.content of
                        IO.Structure (IO.Fun1 pParam pRest) ->
                            Engine.andThen
                                (\argVar ->
                                    Engine.andThen
                                        (\_ -> unifyParamsBestEffort pRest rest)
                                        (unifyStepBestEffort pParam argVar)
                                )
                                (Store.loadType argCanType)

                        _ ->
                            Engine.succeed ()
                )
                (Engine.liftIO (UF.get funcVar))


{-| Like `unifyParamsBestEffort` but from the argument EXPRS: each param slot is
unified with the arg's canonical type AND, when the arg is a local with a varEnv
binding, with that bound MonoType too. The env binding carries the CONCRETE type
(a lambda param or destructor-bound local peeled from a concretized instance),
where the use's canonical type may still be a narrow/row-polymorphic
generalization — without this, a body-internal call like `Tuple.second tup`
inside a re-translated local function keys its callee at the NARROW record type
and mis-lays-out fields (RecordNarrow).
-}
unifyParamsWithArgExprs : IO.Variable -> List (TOpt.Expr TypeIds.MVarId) -> Step ()
unifyParamsWithArgExprs funcVar args =
    Engine.map (\_ -> ()) (unifyParamsCollect funcVar args)


{-| Like `unifyParamsWithArgExprs` but returns, per arg, the FRESH store var
minted for a LOCAL-MULTI FUNCTION arg. Such an arg's canonical type is
instantiated FRESH (per-call-site) rather than loaded through the shared memo:
an annotation with crossed var ids (LocalOpt-rebuilt) would otherwise poison the
function's own type via id sharing (TupleSlotBoxingClosure). The caller zonks
the stash to record the instance the call actually demanded.
-}
unifyParamsCollect : IO.Variable -> List (TOpt.Expr TypeIds.MVarId) -> Step (List (Maybe IO.Variable))
unifyParamsCollect funcVar args =
    case args of
        [] ->
            Engine.succeed []

        arg :: rest ->
            Engine.andThen
                (\desc ->
                    case desc.content of
                        IO.Structure (IO.Fun1 pParam pRest) ->
                            Engine.andThen
                                (\maybeLM ->
                                    case maybeLM of
                                        Just _ ->
                                            Engine.andThen
                                                (\freshVar0 ->
                                                    Engine.andThen
                                                        (\_ ->
                                                            Engine.map (\restStash -> Just freshVar0 :: restStash)
                                                                (unifyParamsCollect pRest rest)
                                                        )
                                                        (unifyStepBestEffort pParam freshVar0)
                                                )
                                                (instantiate (TOpt.typeOf arg))

                                        Nothing ->
                                            Engine.andThen
                                                (\argVar ->
                                                    Engine.andThen
                                                        (\_ ->
                                                            Engine.map (\restStash -> Nothing :: restStash)
                                                                (unifyParamsCollect pRest rest)
                                                        )
                                                        (unifyStepBestEffort pParam argVar)
                                                )
                                                (argUnifyVar arg)
                                )
                                (localMultiArgName arg)

                        _ ->
                            Engine.succeed (List.map (\_ -> Nothing) args)
                )
                (Engine.liftIO (UF.get funcVar))


{-| Translate call args, using the per-call-site stash for local-multi function
args: zonk the fresh instantiation the params were unified against, record the
instance at THAT type, and emit its per-instance local ref.
-}
translateArgsWith : List (Maybe IO.Variable) -> List (TOpt.Expr TypeIds.MVarId) -> Step (List Mono.MonoExpr)
translateArgsWith stash args =
    let
        padded =
            stash ++ List.repeat (List.length args - List.length stash) Nothing
    in
    Engine.traverse
        (\( maybeVar, arg ) ->
            case ( maybeVar, accessedLocalName arg ) of
                ( Just v, Just localName ) ->
                    Engine.andThen
                        (\instType0 ->
                            Engine.map
                                (\( freshName, instType ) -> Mono.MonoVarLocal freshName instType)
                                (Engine.recordLocalInstance localName instType0)
                        )
                        (Store.zonkToMono v)

                _ ->
                    translate arg
        )
        (List.map2 Tuple.pair padded args)


{-| `Just name` when the arg is a direct reference to a local-multi FUNCTION.
-}
localMultiArgName : TOpt.Expr TypeIds.MVarId -> Step (Maybe Name)
localMultiArgName arg =
    case accessedLocalName arg of
        Just localName ->
            Engine.map
                (\isLM ->
                    if isLM then
                        Just localName

                    else
                        Nothing
                )
                (Engine.isLocalMultiTarget localName)

        Nothing ->
            Engine.succeed Nothing


{-| The store var to unify a call argument against: the arg's canonical type
loaded through the memo, ENRICHED at local leaves with the varEnv binding (the
concrete type of a lambda param / destructor-bound / let-bound local — the use's
canonical type may still be a narrow row-polymorphic generalization). Tuple
literals recurse so a `( 0, outer )` arg carries `outer`'s full record type.
-}
argUnifyVar : TOpt.Expr TypeIds.MVarId -> Step IO.Variable
argUnifyVar arg =
    Engine.andThen
        (\canVar ->
            Engine.andThen
                (\_ -> Engine.succeed canVar)
                (enrichFromEnv arg canVar)
        )
        (Store.loadType (TOpt.typeOf arg))


{-| Best-effort unify `canVar` with environment-derived structure for `arg`.
-}
enrichFromEnv : TOpt.Expr TypeIds.MVarId -> IO.Variable -> Step ()
enrichFromEnv arg canVar =
    case accessedLocalName arg of
        Just localName ->
            -- Never enrich from a local-multi target: its varEnv entry is only
            -- the DECLARED classify (possibly a closed-narrow row type), and
            -- forcing it here would block the full type flowing from the other
            -- call args. Its typing is owned by the instance-recording path.
            Engine.andThen
                (\isLM ->
                    if isLM then
                        Engine.succeed ()

                    else
                        Engine.andThen
                            (\maybeBound ->
                                case maybeBound of
                                    Just boundType ->
                                        Engine.andThen (unifyStepBestEffort canVar) (Store.monoTypeToVar boundType)

                                    Nothing ->
                                        Engine.succeed ()
                            )
                            (Engine.lookupVar localName)
                )
                (Engine.isLocalMultiTarget localName)

        Nothing ->
            case arg of
                TOpt.Tuple _ a b rest _ ->
                    Engine.andThen
                        (\desc ->
                            case desc.content of
                                IO.Structure (IO.Tuple1 pa pb pRest) ->
                                    Engine.andThen
                                        (\_ ->
                                            Engine.andThen
                                                (\_ ->
                                                    Engine.traverse (\( e, pt ) -> enrichFromEnv e pt) (List.map2 Tuple.pair rest pRest)
                                                        |> Engine.map (\_ -> ())
                                                )
                                                (enrichFromEnv b pb)
                                        )
                                        (enrichFromEnv a pa)

                                _ ->
                                    Engine.succeed ()
                        )
                        (Engine.liftIO (UF.get canVar))

                _ ->
                    Engine.succeed ()


{-| Kernel ABI for a STANDALONE reference (`eq = Utils.equal`): load the type
through the ITEM memo so the item's demand concretization (unified against the
enclosing definition's annotation) is visible — a fresh instantiation would
isolate the vars and lose it.
-}
deriveKernelAbiTypeRef : ( String, String ) -> Can.Type TypeIds.MVarId -> Step Mono.MonoType
deriveKernelAbiTypeRef kernelId canFuncType =
    deriveKernelAbiTypeWith kernelId canFuncType (Store.loadType canFuncType)


deriveKernelAbiTypeWith : ( String, String ) -> Can.Type TypeIds.MVarId -> Step IO.Variable -> Step Mono.MonoType
deriveKernelAbiTypeWith kernelId canFuncType funcVarStep =
    Engine.andThen
        (\funcVar ->
            Engine.andThen
                (\monoAfterSubst ->
                    Engine.andThen
                        (\mvarEnv ->
                            case KernelAbi.deriveKernelAbiMode kernelId canFuncType mvarEnv of
                                KernelAbi.UseSubstitution ->
                                    Engine.succeed monoAfterSubst

                                KernelAbi.PreserveVars ->
                                    if
                                        EverySet.member KernelAbi.comparePair kernelId KernelAbi.suffixSelectingKernels
                                            && not (Mono.containsAnyMVar monoAfterSubst)
                                    then
                                        Engine.succeed monoAfterSubst

                                    else
                                        -- The preserved-vars ABI keeps the canType's var ids,
                                        -- which THIS item's demand unification may have Join-R
                                        -- number-tainted (e.g. `Decode.null 0` keys the spec at
                                        -- CNumber and demandUnify taints the annotation vars) —
                                        -- Prune would then close the honest eco ABI to MInt and
                                        -- pass an unboxed i64 to a kernel expecting a boxed
                                        -- value. The erased vars are layout placeholders, so
                                        -- REMAP them to fresh, taint-proof engine ids (one per
                                        -- distinct source id, preserving sharing) and advance
                                        -- the id counter past everything minted.
                                        (\st ->
                                            let
                                                ( abiType, env1 ) =
                                                    KernelAbi.canTypeToMonoType_preserveVars mvarEnv canFuncType

                                                -- Suffix-selecting kernels and Debug WANT the
                                                -- taint (they close to Int like the original
                                                -- refreshConstraints); only genuinely-generic
                                                -- kernels get taint-proof fresh ids.
                                                remapWanted =
                                                    not (EverySet.member KernelAbi.comparePair kernelId KernelAbi.suffixSelectingKernels)
                                                        && Tuple.first kernelId /= "Debug"

                                                ( finalAbi, nextId2 ) =
                                                    if remapWanted then
                                                        remapEcoVarsFresh env1.nextId abiType

                                                    else
                                                        ( abiType, env1.nextId )
                                            in
                                            Ok ( finalAbi, { st | nextMVarId = nextId2 } )
                                        )
                        )
                        currentMVarEnv
                )
                (Store.zonkToMono funcVar)
        )
        funcVarStep


{-| Load a type with a fresh, isolated memo so its vars do not share Points with
the surrounding item (a fresh scheme instantiation). The minted Points persist
in the store; the item memo is restored afterward.
-}
instantiate : Can.Type TypeIds.MVarId -> Step IO.Variable
instantiate canType =
    \s0 ->
        case Store.loadType canType { s0 | memo = Dict.empty } of
            Err e ->
                Err e

            Ok ( v, s1 ) ->
                Ok ( v, { s1 | memo = s0.memo } )


{-| Unify each parameter slot of a (possibly polymorphic) function Point with
its argument's canonical type (loaded through the item memo, preserving the
source structure). Stops when args run out or the callee is over-applied.
-}
unifyParamsWithArgs : IO.Variable -> List (Can.Type TypeIds.MVarId) -> Step ()
unifyParamsWithArgs funcVar argCanTypes =
    case argCanTypes of
        [] ->
            Engine.succeed ()

        argCanType :: rest ->
            Engine.andThen
                (\desc ->
                    case desc.content of
                        IO.Structure (IO.Fun1 pParam pRest) ->
                            Engine.andThen
                                (\argVar ->
                                    Engine.andThen
                                        (\_ -> unifyParamsWithArgs pRest rest)
                                        (unifyStepCtx ("param vs arg " ++ canKind argCanType) pParam argVar)
                                )
                                (Store.loadType argCanType)

                        _ ->
                            -- Over-applied or not a function at this depth: stop.
                            Engine.succeed ()
                )
                (Engine.liftIO (UF.get funcVar))


unifyStepCtx : String -> IO.Variable -> IO.Variable -> Step ()
unifyStepCtx ctx v1 v2 s =
    case Store.unifyStep v1 v2 s of
        Ok ok ->
            Ok ok

        Err (UnifyMismatch m) ->
            Err (UnifyMismatch (ctx ++ " | " ++ m))

        Err other ->
            Err other


{-| Unify but never abort: on failure keep the store as-is. For polymorphic-call
result/param unification where a higher-order arg's curried shape needn't line up
(the residual then boxes to CEcoValue, matching the erased ABI).
-}
unifyStepBestEffort : IO.Variable -> IO.Variable -> Step ()
unifyStepBestEffort v1 v2 s =
    case Store.unifyStep v1 v2 s of
        Ok ( _, s1 ) ->
            Ok ( (), s1 )

        Err _ ->
            Ok ( (), s )


canKind : Can.Type TypeIds.MVarId -> String
canKind canType =
    case canType of
        Can.TVar _ ->
            "var"

        Can.TLambda a b ->
            "(" ++ canKind a ++ "->" ++ canKind b ++ ")"

        Can.TType _ name args ->
            name
                ++ (if List.isEmpty args then
                        ""

                    else
                        "<" ++ String.join "," (List.map canKind args) ++ ">"
                   )

        Can.TRecord _ _ ->
            "record"

        Can.TUnit ->
            "unit"

        Can.TTuple _ _ _ ->
            "tuple"

        Can.TAlias _ name _ _ ->
            "alias:" ++ name


{-| Unify the callee's result (after peeling `argCount` parameters) with the
expected call type — the "WithExpected" part of the original poly call path,
needed for return-polymorphic callees.
-}
unifyResultWithExpected : IO.Variable -> Int -> Can.Type TypeIds.MVarId -> Step ()
unifyResultWithExpected funcVar argCount callCanType =
    Engine.andThen
        (\maybeResultVar ->
            case maybeResultVar of
                Just resultVar ->
                    Engine.andThen (unifyStepBestEffort resultVar) (Store.loadType callCanType)

                Nothing ->
                    Engine.succeed ()
        )
        (resultVarAfter funcVar argCount)


resultVarAfter : IO.Variable -> Int -> Step (Maybe IO.Variable)
resultVarAfter funcVar n =
    if n <= 0 then
        Engine.succeed (Just funcVar)

    else
        Engine.andThen
            (\desc ->
                case desc.content of
                    IO.Structure (IO.Fun1 _ pRest) ->
                        resultVarAfter pRest (n - 1)

                    _ ->
                        Engine.succeed Nothing
            )
            (Engine.liftIO (UF.get funcVar))


{-| Build an `MVarEnv` for the KernelAbi helpers (which read super info; they
never mutate it here). Uses the engine's current allocator + super table.
-}
currentMVarEnv : Step State.MVarEnv
currentMVarEnv =
    -- STATIC supers only: the kernel-ABI preserveVars computation must not see
    -- cross-item Join-R taint (a call like `Decode.null 0` elsewhere would stamp
    -- the kernel's `a` as CNumber → Prune closes it to MInt → unboxed i64 passed
    -- to a kernel expecting a boxed value). Same principle as Store.loadVar.
    Engine.getS (\s -> State.initMVarEnv s.nextMVarId s.superStatic)



-- ====== RECORDS ======


recordTypeFromFields : List ( Name, Mono.MonoExpr ) -> Mono.MonoType
recordTypeFromFields fields =
    Mono.MRecord (List.foldl (\( name, me ) acc -> Dict.insert name (Mono.typeOf me) acc) Dict.empty fields)


{-| Prefer the record's own field type when it is more concrete than the
access node's classified type (mirrors the original `isMoreConcrete` guard,
approximated: use the field type only when the classified type still has a var).
-}
refineAccessType : Mono.MonoType -> Mono.MonoType -> Name -> Mono.MonoType
refineAccessType classified recordType fieldName =
    case recordType of
        Mono.MRecord fields ->
            case Dict.get fieldName fields of
                Just fieldType ->
                    if Mono.containsAnyMVar classified then
                        fieldType

                    else if recordKeySubset classified fieldType then
                        -- The classified type is a NARROWED (row-poly, closed at
                        -- zonk) view of the record's actual field: the record side
                        -- is authoritative for layout (field indices).
                        fieldType

                    else
                        classified

                Nothing ->
                    classified

        _ ->
            classified


{-| Do the two types have the SAME shape, differing only at numeric leaves
(MInt vs MFloat)? The signature of shared-number-var memo pollution.
-}
numericLeafOnlyDiff : Mono.MonoType -> Mono.MonoType -> Bool
numericLeafOnlyDiff a b =
    if a == b then
        False

    else
        sameShapeModuloNumeric a b


sameShapeModuloNumeric : Mono.MonoType -> Mono.MonoType -> Bool
sameShapeModuloNumeric a b =
    case ( a, b ) of
        ( Mono.MInt, Mono.MFloat ) ->
            True

        ( Mono.MFloat, Mono.MInt ) ->
            True

        ( Mono.MVar _ Mono.CNumber, Mono.MInt ) ->
            True

        ( Mono.MVar _ Mono.CNumber, Mono.MFloat ) ->
            True

        ( Mono.MInt, Mono.MVar _ Mono.CNumber ) ->
            True

        ( Mono.MFloat, Mono.MVar _ Mono.CNumber ) ->
            True

        ( Mono.MFunction args1 r1, Mono.MFunction args2 r2 ) ->
            List.length args1 == List.length args2 && List.all identity (List.map2 sameShapeModuloNumeric args1 args2) && sameShapeModuloNumeric r1 r2

        ( Mono.MList e1, Mono.MList e2 ) ->
            sameShapeModuloNumeric e1 e2

        ( Mono.MTuple es1, Mono.MTuple es2 ) ->
            List.length es1 == List.length es2 && List.all identity (List.map2 sameShapeModuloNumeric es1 es2)

        ( Mono.MCustom h1 n1 args1, Mono.MCustom h2 n2 args2 ) ->
            h1 == h2 && n1 == n2 && List.length args1 == List.length args2 && List.all identity (List.map2 sameShapeModuloNumeric args1 args2)

        ( Mono.MRecord f1, Mono.MRecord f2 ) ->
            Dict.keys f1 == Dict.keys f2 && List.all identity (List.map2 sameShapeModuloNumeric (Dict.values f1) (Dict.values f2))

        _ ->
            a == b


{-| Is `narrow` a record whose keys are a STRICT subset of record `full`'s keys?
(The signature of row-polymorphic narrowing.)
-}
recordKeySubset : Mono.MonoType -> Mono.MonoType -> Bool
recordKeySubset narrow full =
    case ( narrow, full ) of
        ( Mono.MRecord nf, Mono.MRecord ff ) ->
            Dict.size nf < Dict.size ff && List.all (\k -> Dict.member k ff) (Dict.keys nf)

        _ ->
            False


translateUpdate : TOpt.Expr TypeIds.MVarId -> DMap.Dict String (A.Located Name) (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateUpdate record updates canType =
    Engine.andThen
        (\monoType ->
            Engine.andThen
                (\monoRecord ->
                    Engine.map
                        (\monoUpdatesRev ->
                            let
                                recordMonoType =
                                    Mono.typeOf monoRecord

                                resultMonoType =
                                    unionRecordTypes monoType recordMonoType
                            in
                            Mono.MonoRecordUpdate monoRecord monoUpdatesRev resultMonoType
                        )
                        (Engine.foldlS
                            (\( locName, updateExpr ) acc ->
                                Engine.map (\me -> ( A.toValue locName, me ) :: acc) (translate updateExpr)
                            )
                            []
                            (DMap.toList A.compareLocated updates)
                        )
                )
                (translate record)
        )
        (classify canType)


{-| `MRecord (Dict.union resultFields recordFields)` from the two record types,
matching the original Update result-type computation.
-}
unionRecordTypes : Mono.MonoType -> Mono.MonoType -> Mono.MonoType
unionRecordTypes classified recordType =
    case ( classified, recordType ) of
        ( Mono.MRecord resultFields, Mono.MRecord recordFields ) ->
            Mono.MRecord (Dict.union resultFields recordFields)

        ( Mono.MRecord _, _ ) ->
            classified

        _ ->
            classified



-- ====== LET ======


translateLet : TOpt.Def TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateLet def body letCanType =
    case def of
        TOpt.Def _ name defBody defCanType ->
            if isFunctionType defCanType || (typeContainsCanLambda defCanType && not (List.isEmpty (KernelAbi.freeVarIds defCanType []))) then
                -- Function-typed lets AND lambda-CONTAINING lets with unresolved
                -- vars (a list/record of closures — the original engine's
                -- value-multi gate `typeContainsLambda && hasVar`) route through
                -- body-first discovery + per-instance re-translation, so a use at
                -- a concrete type re-specializes the closures inside.
                translateLocalMultiLet name defBody body letCanType

            else
                Engine.andThen
                    (\eligible ->
                        if eligible then
                            translateNumberMultiLet name defBody body letCanType

                        else
                            -- Plain non-function, non-number value let.
                            Engine.andThen
                                (\monoDefBody ->
                                    Engine.andThen
                                        (\defMonoType0 ->
                                            let
                                                bodyType =
                                                    Mono.typeOf monoDefBody

                                                defType =
                                                    if
                                                        Mono.containsAnyMVar defMonoType0
                                                            -- A closed-narrow (row-poly) classified type defers
                                                            -- to the body's actual/full record type (layout).
                                                            || recordKeySubset defMonoType0 bodyType
                                                            -- Same shape differing ONLY in numeric leaves:
                                                            -- the classify carries Float pollution from a
                                                            -- sibling use of a shared number var; the body IS
                                                            -- the value (LetNumberIndirectDual).
                                                            || (not (monoTypeMentionsEco bodyType) && numericLeafOnlyDiff defMonoType0 bodyType)
                                                    then
                                                        bodyType

                                                    else
                                                        defMonoType0
                                            in
                                            Engine.scoped
                                                (Engine.andThen (\_ -> finishLet (Mono.MonoDef name monoDefBody) body letCanType)
                                                    (Engine.insertVar name defType)
                                                )
                                        )
                                        (classify defCanType)
                                )
                                (translate defBody)
                    )
                    (isNumberMultiEligible defCanType)

        TOpt.TailDef _ name typedArgs tailBody defCanType _ ->
            -- Local tail-recursive function: BODY-FIRST discovery (uses record the
            -- applied type via the local-multi stack), then — for the single-instance
            -- case — demand-unify the def's type with the recorded instance IN the
            -- item store and translate the def ONCE under the bare name (the
            -- TailCall self-reference needs no renaming). Multi-instance falls back
            -- to the declared type (rare; would need renamed self-calls).
            Engine.andThen
                (\_ ->
                    Engine.andThen
                        (\declType ->
                            Engine.andThen
                                (\monoBody ->
                                    Engine.andThen
                                        (\maybeEntry ->
                                            let
                                                singleInstance =
                                                    case maybeEntry of
                                                        Just entry ->
                                                            case Dict.values entry.instances of
                                                                [ inst ] ->
                                                                    Just inst.monoType

                                                                _ ->
                                                                    Nothing

                                                        Nothing ->
                                                            Nothing
                                            in
                                            Engine.andThen
                                                (\_ ->
                                                    Engine.andThen
                                                        (\monoParams ->
                                                            Engine.andThen
                                                                (\defType ->
                                                                    Engine.andThen
                                                                        (\monoTailBody ->
                                                                            Engine.map
                                                                                (\letType0 ->
                                                                                    let
                                                                                        letType =
                                                                                            if
                                                                                                Mono.containsAnyMVar letType0
                                                                                                    || (not (monoTypeMentionsEco (Mono.typeOf monoBody)) && numericLeafOnlyDiff letType0 (Mono.typeOf monoBody))
                                                                                            then
                                                                                                Mono.typeOf monoBody

                                                                                            else
                                                                                                letType0
                                                                                    in
                                                                                    Mono.MonoLet (Mono.MonoTailDef name monoParams monoTailBody) monoBody letType
                                                                                )
                                                                                (classify letCanType)
                                                                        )
                                                                        (Engine.scoped
                                                                            (Engine.andThen (\_ -> Engine.andThen (\_ -> translate tailBody) (insertVars monoParams))
                                                                                (Engine.insertVar name defType)
                                                                            )
                                                                        )
                                                                )
                                                                (classify defCanType)
                                                        )
                                                        (Engine.traverse (\( locName, argType ) -> Engine.map (\mt -> ( A.toValue locName, mt )) (classify argType)) typedArgs)
                                                )
                                                (case singleInstance of
                                                    Just instType ->
                                                        -- Bind the def's vars to the single recorded
                                                        -- demand (best-effort, shared store).
                                                        Engine.andThen
                                                            (\annVar -> Engine.andThen (unifyStepBestEffort annVar) (Store.monoTypeToVar instType))
                                                            (Store.loadType defCanType)

                                                    Nothing ->
                                                        Engine.succeed ()
                                                )
                                        )
                                        Engine.popLocalMulti
                                )
                                (Engine.scoped
                                    (Engine.andThen (\_ -> translate body) (Engine.insertVar name declType))
                                )
                        )
                        (classify defCanType)
                )
                (Engine.pushLocalMulti name)


finishLet : Mono.MonoDef -> TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
finishLet monoDef body letCanType =
    Engine.andThen
        (\monoBody ->
            Engine.map
                (\letType0 ->
                    let
                        letType =
                            if
                                Mono.containsAnyMVar letType0
                                    || (not (monoTypeMentionsEco (Mono.typeOf monoBody)) && numericLeafOnlyDiff letType0 (Mono.typeOf monoBody))
                            then
                                Mono.typeOf monoBody

                            else
                                letType0
                    in
                    Mono.MonoLet monoDef monoBody letType
                )
                (classify letCanType)
        )
        (translate body)


insertVars : List ( Name, Mono.MonoType ) -> Step ()
insertVars pairs =
    Engine.foldlS (\( name, t ) _ -> Engine.insertVar name t) () pairs



-- ====== NUMBER-MULTI (a let-bound `number` used at Int AND Float) ======


{-| A `let n = <number>` whose type carries an unresolved `number` var and a
numeric-fixable shape gets multi-specialized: one binding per distinct
monomorphic type it is used at (the first/Int keeps the bare name, later ones
get `n$v<idx>`). Discovery is body-first (each use records its instance), then
the eager Int def is emitted outermost, the extra copies nested inside.
-}
translateNumberMultiLet : Name -> TOpt.Expr TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateNumberMultiLet name defBody body letCanType =
    Engine.andThen
        (\eagerBody ->
            Engine.andThen
                (\_ -> Engine.recordNumberInstance name (Mono.typeOf eagerBody))
                (Engine.pushNumberMulti name)
                |> thenAlso
                    (Engine.andThen
                        (\monoBody ->
                            Engine.andThen
                                (\maybeEntry ->
                                    Engine.andThen
                                        (\floatDefs ->
                                            Engine.map
                                                (\letType0 ->
                                                    let
                                                        letType =
                                                            if
                                                                Mono.containsAnyMVar letType0
                                                                    || (not (monoTypeMentionsEco (Mono.typeOf monoBody)) && numericLeafOnlyDiff letType0 (Mono.typeOf monoBody))
                                                            then
                                                                Mono.typeOf monoBody

                                                            else
                                                                letType0

                                                        bodyWithFloats =
                                                            List.foldl (\d acc -> Mono.MonoLet d acc (Mono.typeOf acc)) monoBody (List.reverse floatDefs)
                                                    in
                                                    Mono.MonoLet (Mono.MonoDef name eagerBody) bodyWithFloats letType
                                                )
                                                (classify letCanType)
                                        )
                                        (buildFloatDefs name defBody maybeEntry)
                                )
                                Engine.popNumberMulti
                        )
                        -- Bind the eager name in varEnv (scoped to the body) so
                        -- destructor roots (`let (a,b) = (1,2)` ⇒ root `_v0`) and
                        -- any non-VarLocal consumer resolve it. VarLocal uses still
                        -- take the recordNumberInstance path (isTarget wins first).
                        (Engine.scoped
                            (Engine.andThen (\_ -> translate body)
                                (Engine.insertVar name (Mono.typeOf eagerBody))
                            )
                        )
                    )
        )
        (translate defBody)


{-| Sequence two steps discarding the first's result.
-}
thenAlso : Step b -> Step a -> Step b
thenAlso next first =
    Engine.andThen (\_ -> next) first


{-| Build the per-type extra copies (`n$v1`, …), each by re-translating the RHS
under a demand of the instance type (so e.g. `10 + 20` becomes the Float add).
Excludes the eager/first instance (which keeps the bare name).
-}
buildFloatDefs : Name -> TOpt.Expr TypeIds.MVarId -> Maybe Engine.NumberMultiEntry -> Step (List Mono.MonoDef)
buildFloatDefs name defBody maybeEntry =
    case maybeEntry of
        Just entry ->
            Engine.traverse
                (\inst -> Engine.map (\e -> Mono.MonoDef inst.freshName e) (retranslateAt defBody inst.monoType))
                (Dict.values entry.instances |> List.filter (\inst -> inst.freshName /= name))

        Nothing ->
            Engine.succeed []


{-| Re-translate an expression under a demanded type, in a fresh solver store
(so the demand's concretization doesn't contaminate the surrounding item);
`varEnv` and global state (registry/worklist) are kept so it can reference outer
locals and enqueue its callees.
-}
retranslateAt : TOpt.Expr TypeIds.MVarId -> Mono.MonoType -> Step Mono.MonoExpr
retranslateAt defBody instType s0 =
    let
        sFresh =
            { s0 | store = Engine.freshStore, memo = Dict.empty, revMemo = Dict.empty }

        step =
            Engine.andThen (\_ -> translate defBody) (demandUnify (TOpt.typeOf defBody) instType)
    in
    case step sFresh of
        Err e ->
            Err e

        Ok ( monoExpr, s1 ) ->
            Ok ( monoExpr, { s1 | store = s0.store, memo = s0.memo, revMemo = s0.revMemo } )


isNumberMultiEligible : Can.Type TypeIds.MVarId -> Step Bool
isNumberMultiEligible defCanType =
    Engine.andThen
        (\hasNum ->
            if hasNum then
                Engine.map isNumericFixableShape (classify defCanType)

            else
                Engine.succeed False
        )
        (hasNumberVar defCanType)


hasNumberVar : Can.Type TypeIds.MVarId -> Step Bool
hasNumberVar defCanType =
    Engine.map
        (\superTable ->
            List.any (\id -> Dict.get (Id.toComparable id) superTable == Just IO.Number) (KernelAbi.freeVarIds defCanType [])
        )
        (Engine.getS .superTable)


isNumericFixableShape : Mono.MonoType -> Bool
isNumericFixableShape monoType =
    case monoType of
        Mono.MInt ->
            True

        Mono.MFloat ->
            True

        Mono.MVar _ Mono.CNumber ->
            True

        Mono.MTuple elems ->
            not (List.isEmpty elems) && List.all isNumericFixableShape elems

        Mono.MRecord fields ->
            not (Dict.isEmpty fields) && List.all isNumericFixableShape (Dict.values fields)

        Mono.MList elem ->
            isNumericFixableShape elem

        Mono.MCustom _ _ args ->
            -- A custom type with at least one numeric-fixable arg and no arg the
            -- recording couldn't re-type (mirrors the original engine's rule).
            List.any isNumericFixableShape args
                && List.all (\a -> isNumericFixableShape a || not (monoTypeMentionsNumeric a)) args

        _ ->
            False


monoTypeMentionsNumeric : Mono.MonoType -> Bool
monoTypeMentionsNumeric mt =
    case mt of
        Mono.MInt ->
            True

        Mono.MFloat ->
            True

        Mono.MVar _ Mono.CNumber ->
            True

        Mono.MList t ->
            monoTypeMentionsNumeric t

        Mono.MTuple ts ->
            List.any monoTypeMentionsNumeric ts

        Mono.MRecord fields ->
            Dict.foldl (\_ t acc -> acc || monoTypeMentionsNumeric t) False fields

        Mono.MCustom _ _ args ->
            List.any monoTypeMentionsNumeric args

        Mono.MFunction args r ->
            List.any monoTypeMentionsNumeric args || monoTypeMentionsNumeric r

        _ ->
            False



-- ====== RECORD ACCESS ======


{-| Translate a record access. When the record is a direct use of a number-multi
target and the access result is demanded at a CONCRETE scalar number, this is the
access-analogue of the destructor divert: overlay ONLY the accessed field onto the
root's eager type, record that root instance (`r$vN`), and point the access at it
— each access site refines its own slot independently (sibling uses share solved
type vars, so flowing the demand through the store would cross-pollute them).
Otherwise: generic path, connecting the access result's var to the record-use
type's field slot (demand flow for single-owner shapes).
-}
translateAccess : TOpt.Expr TypeIds.MVarId -> Name -> TOpt.Meta TypeIds.MVarId -> Step Mono.MonoExpr
translateAccess record fieldName meta =
    case accessedLocalName record of
        Just rname ->
            Engine.andThen
                (\maybeRoot ->
                    case maybeRoot of
                        Just eagerRootType ->
                            Engine.andThen
                                (\demand ->
                                    if demand == Mono.MFloat || demand == Mono.MInt then
                                        Engine.andThen
                                            (\gte ->
                                                case refineRootInstance gte eagerRootType (TOpt.Field fieldName (TOpt.Root rname)) demand of
                                                    Just refinedRootType ->
                                                        Engine.map
                                                            (\( freshName, instType ) ->
                                                                Mono.MonoRecordAccess (Mono.MonoVarLocal freshName instType) fieldName demand
                                                            )
                                                            (Engine.recordNumberInstance rname refinedRootType)

                                                    Nothing ->
                                                        genericAccess record fieldName meta
                                            )
                                            (Engine.getS .globalTypeEnv)

                                    else
                                        genericAccess record fieldName meta
                                )
                                (classify meta.tipe)

                        Nothing ->
                            genericAccess record fieldName meta
                )
                (Engine.numberMultiRootType rname)

        Nothing ->
            genericAccess record fieldName meta


{-| The local name a record-access scrutinee refers to (if it is a direct local
reference, tracked or not).
-}
accessedLocalName : TOpt.Expr TypeIds.MVarId -> Maybe Name
accessedLocalName record =
    case record of
        TOpt.VarLocal rname _ ->
            Just rname

        TOpt.TrackedVarLocal _ rname _ ->
            Just rname

        _ ->
            Nothing


genericAccess : TOpt.Expr TypeIds.MVarId -> Name -> TOpt.Meta TypeIds.MVarId -> Step Mono.MonoExpr
genericAccess record fieldName meta =
    Engine.andThen
        (\_ ->
            Engine.andThen
                (\monoType ->
                    Engine.map
                        (\monoRecord ->
                            let
                                refined =
                                    refineAccessType monoType (Mono.typeOf monoRecord) fieldName
                            in
                            Mono.MonoRecordAccess monoRecord fieldName refined
                        )
                        (translate record)
                )
                (classify meta.tipe)
        )
        (case recordFieldCanTypes (TOpt.typeOf record) |> Maybe.andThen (Dict.get fieldName) of
            Just fieldCan ->
                connectTypes meta.tipe fieldCan

            Nothing ->
                Engine.succeed ()
        )



-- ====== DESTRUCTOR-DERIVED MULTI-INSTANCE (MONO_028) ======


{-| Original eager destructor handling (bind then translate body, always emit).
-}
generalDestruct : TOpt.Destructor TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> TOpt.Meta TypeIds.MVarId -> Step Mono.MonoExpr
generalDestruct ((TOpt.Destructor dname0 _ dmeta0) as destructor) body meta =
    Engine.andThen
        (\_ ->
            generalDestructBody destructor body meta
        )
        -- Remember the derived name -> destructor canType, AND connect the
        -- destructor's (freshly-rebuilt) type ids to the ROOT's canonical slot
        -- type: a later CALL of a derived FUNCTION (`getter rec`) then flows its
        -- concreteness back into the root case/tuple's own vars.
        (Engine.andThen
            (\_ ->
                let
                    (TOpt.Destructor _ dpath0 _) =
                        destructor
                in
                Engine.andThen
                    (\maybeRootCan ->
                        case maybeRootCan |> Maybe.andThen (\rootCan -> canSlotForPath rootCan dpath0) of
                            Just slotCan ->
                                connectTypes dmeta0.tipe slotCan

                            Nothing ->
                                Engine.succeed ()
                    )
                    (Engine.getS (\s -> Dict.get (pathRootName dpath0) s.localCanTypes))
            )
            (Engine.modifyS (\s -> { s | derivedDestructors = Dict.insert dname0 dmeta0.tipe s.derivedDestructors }))
        )


generalDestructBody : TOpt.Destructor TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> TOpt.Meta TypeIds.MVarId -> Step Mono.MonoExpr
generalDestructBody destructor body meta =
    Engine.andThen
        (\monoType0 ->
            Engine.andThen
                (\monoDestructor ->
                    let
                        (Mono.MonoDestructor destructorName _ destructorType) =
                            monoDestructor
                    in
                    Engine.scoped
                        (Engine.andThen
                            (\_ ->
                                Engine.map
                                    (\monoBody ->
                                        Mono.MonoDestruct monoDestructor
                                            monoBody
                                            (if Mono.containsAnyMVar monoType0 then
                                                Mono.typeOf monoBody

                                             else
                                                monoType0
                                            )
                                    )
                                    (translate body)
                            )
                            (Engine.insertVar destructorName destructorType)
                        )
                )
                (specializeDestructor destructor)
        )
        (classify meta.tipe)


{-| Body-first specialization of a `Destruct` whose root is a number-multi target.
Seed `dname` as a number-multi target, specialize the body FIRST so its uses
record one instance per demanded numeric type, then for each instance materialise
a slot-refined root instance (`recordNumberInstance rootName` — the root's own
`translateNumberMultiLet` emits it) and emit a renamed destructor. The eager Int
destructor is emitted only if the bare `dname` is actually referenced.
-}
specializeNumberDestruct : Name -> TOpt.Path -> TOpt.Meta TypeIds.MVarId -> Name -> Mono.MonoType -> TOpt.Expr TypeIds.MVarId -> TOpt.Meta TypeIds.MVarId -> Step Mono.MonoExpr
specializeNumberDestruct dname path dmeta rootName eagerRootType body meta =
    Engine.andThen
        (\eagerLeaf ->
            Engine.andThen (\_ -> Engine.recordNumberInstance dname eagerLeaf) (Engine.pushNumberMulti dname)
                |> thenAlso
                    (Engine.andThen
                        (\monoBody ->
                            Engine.andThen
                                (\maybeEntry ->
                                    let
                                        dnameUsed =
                                            exprReferencesLocal dname monoBody

                                        instances =
                                            case maybeEntry of
                                                Just e ->
                                                    List.filter (\i -> i.freshName /= dname || dnameUsed) (Dict.values e.instances)

                                                Nothing ->
                                                    []
                                    in
                                    Engine.map
                                        (\maybeDestructors ->
                                            let
                                                destructors =
                                                    List.filterMap identity maybeDestructors
                                            in
                                            List.foldl (\md acc -> Mono.MonoDestruct md acc (Mono.typeOf acc)) monoBody (List.reverse destructors)
                                        )
                                        (Engine.traverse (buildRefinedDestructor rootName eagerRootType path dmeta) instances)
                                )
                                Engine.popNumberMulti
                        )
                        (Engine.scoped (Engine.andThen (\_ -> translate body) (Engine.insertVar dname eagerLeaf)))
                    )
        )
        (classify dmeta.tipe)


{-| For one recorded instance of the destructor name, materialise the root value
instance with only this slot refined (overlay the leaf onto the eager root type),
register it on the root's multi-entry, and build the renamed destructor pointing
at that fresh root instance. Returns Nothing if the slot can't be refined.
-}
buildRefinedDestructor : Name -> Mono.MonoType -> TOpt.Path -> TOpt.Meta TypeIds.MVarId -> Engine.NumberInstance -> Step (Maybe Mono.MonoDestructor)
buildRefinedDestructor rootName eagerRootType path dmeta inst s0 =
    buildRefinedDestructorWith s0.globalTypeEnv rootName eagerRootType path dmeta inst s0


buildRefinedDestructorWith : TypeEnv.GlobalTypeEnv -> Name -> Mono.MonoType -> TOpt.Path -> TOpt.Meta TypeIds.MVarId -> Engine.NumberInstance -> Step (Maybe Mono.MonoDestructor)
buildRefinedDestructorWith gte rootName eagerRootType path _ inst =
    case refineRootInstance gte eagerRootType path inst.monoType of
        Just refinedRootType ->
            Engine.andThen
                (\( freshRootName, _ ) ->
                    Engine.andThen
                        (\_ ->
                            Engine.andThen
                                (\monoPath ->
                                    let
                                        dtype =
                                            Mono.getMonoPathType monoPath
                                    in
                                    Engine.map (\_ -> Just (Mono.MonoDestructor inst.freshName monoPath dtype))
                                        (Engine.insertVar inst.freshName dtype)
                                )
                                (specializePath (rewriteRootInPath rootName freshRootName path))
                        )
                        (Engine.insertVar freshRootName refinedRootType)
                )
                (Engine.recordNumberInstance rootName refinedRootType)

        Nothing ->
            Engine.succeed Nothing


{-| Overlay `leaf` onto the eager root container at the slot selected by `path`
(tuple index / record field / custom-type payload / unbox wrapper), leaving
other slots as they were. Nothing for list/array paths (those stay on the
general destructor path).
-}
refineRootInstance : TypeEnv.GlobalTypeEnv -> Mono.MonoType -> TOpt.Path -> Mono.MonoType -> Maybe Mono.MonoType
refineRootInstance gte container path leaf =
    case path of
        TOpt.Root _ ->
            Just leaf

        TOpt.Index idx hint subPath ->
            navigateType gte container subPath
                |> Maybe.andThen
                    (\subC ->
                        case hint of
                            TOpt.HintCustom ctorName ->
                                replaceCustomSlot gte ctorName (Index.toMachine idx) subC leaf

                            TOpt.HintList ->
                                Nothing

                            _ ->
                                replaceIndexSlot subC (Index.toMachine idx) leaf
                    )
                |> Maybe.andThen (\newSub -> refineRootInstance gte container subPath newSub)

        TOpt.Field fieldName subPath ->
            navigateType gte container subPath
                |> Maybe.andThen (\subC -> replaceRecordSlot subC fieldName leaf)
                |> Maybe.andThen (\newSub -> refineRootInstance gte container subPath newSub)

        TOpt.Unbox subPath ->
            navigateType gte container subPath
                |> Maybe.andThen (\subC -> replaceUnboxSlot gte subC leaf)
                |> Maybe.andThen (\newSub -> refineRootInstance gte container subPath newSub)

        _ ->
            Nothing


{-| Set the union type-arg selected by ctor `ctorName`'s field `idx` to `leaf`
(only when that field's declared type is a bare union type-param).
-}
replaceCustomSlot : TypeEnv.GlobalTypeEnv -> Name -> Int -> Mono.MonoType -> Mono.MonoType -> Maybe Mono.MonoType
replaceCustomSlot gte ctorName idx container leaf =
    case container of
        Mono.MCustom home typeName typeArgs ->
            case Analysis.lookupUnion gte home typeName of
                Just (Can.Union unionData) ->
                    findCtorArg ctorName idx unionData.alts
                        |> Maybe.andThen
                            (\fieldCanType ->
                                case fieldCanType of
                                    Can.TVar paramName ->
                                        paramPosition paramName unionData.vars
                                            |> Maybe.map
                                                (\pos ->
                                                    Mono.MCustom home typeName (List.indexedMap (\i t -> if i == pos then leaf else t) typeArgs)
                                                )

                                    _ ->
                                        Nothing
                            )

                Nothing ->
                    Nothing

        _ ->
            Nothing


{-| Set the single type-arg of an @unbox wrapper's payload to `leaf` (only when
the single ctor's single field is a bare union type-param).
-}
replaceUnboxSlot : TypeEnv.GlobalTypeEnv -> Mono.MonoType -> Mono.MonoType -> Maybe Mono.MonoType
replaceUnboxSlot gte container leaf =
    case container of
        Mono.MCustom home typeName typeArgs ->
            case Analysis.lookupUnion gte home typeName of
                Just (Can.Union unionData) ->
                    case unionData.alts of
                        [ Can.Ctor c ] ->
                            case c.args of
                                [ Can.TVar paramName ] ->
                                    paramPosition paramName unionData.vars
                                        |> Maybe.map
                                            (\pos ->
                                                Mono.MCustom home typeName (List.indexedMap (\i t -> if i == pos then leaf else t) typeArgs)
                                            )

                                _ ->
                                    Nothing

                        _ ->
                            Nothing

                Nothing ->
                    Nothing

        _ ->
            Nothing


paramPosition : Name -> List Name -> Maybe Int
paramPosition name vars =
    List.indexedMap Tuple.pair vars
        |> List.filter (\( _, v ) -> v == name)
        |> List.head
        |> Maybe.map Tuple.first


navigateType : TypeEnv.GlobalTypeEnv -> Mono.MonoType -> TOpt.Path -> Maybe Mono.MonoType
navigateType gte container path =
    case path of
        TOpt.Root _ ->
            Just container

        TOpt.Index idx hint subPath ->
            navigateType gte container subPath
                |> Maybe.andThen
                    (\c ->
                        case hint of
                            TOpt.HintCustom ctorName ->
                                customSlot gte ctorName (Index.toMachine idx) c

                            TOpt.HintList ->
                                Nothing

                            _ ->
                                tupleSlot c (Index.toMachine idx)
                    )

        TOpt.Field fieldName subPath ->
            navigateType gte container subPath |> Maybe.andThen (recordSlot fieldName)

        TOpt.Unbox subPath ->
            navigateType gte container subPath |> Maybe.andThen (unboxSlot gte)

        _ ->
            Nothing


{-| Read the type of ctor `ctorName`'s field `idx` from a custom container
(only when the field's declared type is a bare union type-param).
-}
customSlot : TypeEnv.GlobalTypeEnv -> Name -> Int -> Mono.MonoType -> Maybe Mono.MonoType
customSlot gte ctorName idx container =
    case container of
        Mono.MCustom home typeName typeArgs ->
            case Analysis.lookupUnion gte home typeName of
                Just (Can.Union unionData) ->
                    findCtorArg ctorName idx unionData.alts
                        |> Maybe.andThen
                            (\fieldCanType ->
                                case fieldCanType of
                                    Can.TVar paramName ->
                                        paramPosition paramName unionData.vars
                                            |> Maybe.andThen (\pos -> List.head (List.drop pos typeArgs))

                                    _ ->
                                        Nothing
                            )

                Nothing ->
                    Nothing

        _ ->
            Nothing


unboxSlot : TypeEnv.GlobalTypeEnv -> Mono.MonoType -> Maybe Mono.MonoType
unboxSlot gte container =
    case container of
        Mono.MCustom home typeName typeArgs ->
            case Analysis.lookupUnion gte home typeName of
                Just (Can.Union unionData) ->
                    case unionData.alts of
                        [ Can.Ctor c ] ->
                            case c.args of
                                [ Can.TVar paramName ] ->
                                    paramPosition paramName unionData.vars
                                        |> Maybe.andThen (\pos -> List.head (List.drop pos typeArgs))

                                _ ->
                                    Nothing

                        _ ->
                            Nothing

                Nothing ->
                    Nothing

        _ ->
            Nothing


tupleSlot : Mono.MonoType -> Int -> Maybe Mono.MonoType
tupleSlot t i =
    case t of
        Mono.MTuple elems ->
            List.head (List.drop i elems)

        _ ->
            Nothing


recordSlot : String -> Mono.MonoType -> Maybe Mono.MonoType
recordSlot f t =
    case t of
        Mono.MRecord fields ->
            Dict.get f fields

        _ ->
            Nothing


replaceIndexSlot : Mono.MonoType -> Int -> Mono.MonoType -> Maybe Mono.MonoType
replaceIndexSlot t i leaf =
    case t of
        Mono.MTuple elems ->
            if i >= 0 && i < List.length elems then
                Just (Mono.MTuple (List.indexedMap (\j x -> if j == i then leaf else x) elems))

            else
                Nothing

        _ ->
            Nothing


replaceRecordSlot : Mono.MonoType -> String -> Mono.MonoType -> Maybe Mono.MonoType
replaceRecordSlot t f leaf =
    case t of
        Mono.MRecord fields ->
            Just (Mono.MRecord (Dict.insert f leaf fields))

        _ ->
            Nothing


{-| Navigate a destructor path over the CANONICAL type (tuple/record slots).
-}
canSlotForPath : Can.Type TypeIds.MVarId -> TOpt.Path -> Maybe (Can.Type TypeIds.MVarId)
canSlotForPath rootCan path =
    case path of
        TOpt.Root _ ->
            Just rootCan

        TOpt.Index idx _ sub ->
            canSlotForPath rootCan sub
                |> Maybe.andThen tupleSlotCanTypes
                |> Maybe.andThen (\slots -> List.head (List.drop (Index.toMachine idx) slots))

        TOpt.Field f sub ->
            canSlotForPath rootCan sub
                |> Maybe.andThen recordFieldCanTypes
                |> Maybe.andThen (Dict.get f)

        _ ->
            Nothing


pathRootName : TOpt.Path -> Name
pathRootName path =
    case path of
        TOpt.Root name ->
            name

        TOpt.Index _ _ sub ->
            pathRootName sub

        TOpt.ArrayIndex _ sub ->
            pathRootName sub

        TOpt.Field _ sub ->
            pathRootName sub

        TOpt.Unbox sub ->
            pathRootName sub


rewriteRootInPath : Name -> Name -> TOpt.Path -> TOpt.Path
rewriteRootInPath oldName newName path =
    case path of
        TOpt.Root name ->
            TOpt.Root
                (if name == oldName then
                    newName

                 else
                    name
                )

        TOpt.Index i h sub ->
            TOpt.Index i h (rewriteRootInPath oldName newName sub)

        TOpt.ArrayIndex i sub ->
            TOpt.ArrayIndex i (rewriteRootInPath oldName newName sub)

        TOpt.Field f sub ->
            TOpt.Field f (rewriteRootInPath oldName newName sub)

        TOpt.Unbox sub ->
            TOpt.Unbox (rewriteRootInPath oldName newName sub)


isScalarNumber : Mono.MonoType -> Bool
isScalarNumber t =
    case t of
        Mono.MInt ->
            True

        Mono.MFloat ->
            True

        Mono.MVar _ Mono.CNumber ->
            True

        _ ->
            False


exprReferencesLocal : Name -> Mono.MonoExpr -> Bool
exprReferencesLocal name expr =
    List.member name (Closure.findFreeLocals Set.empty expr)



-- ====== LOCAL-MULTI (a let-bound function used at multiple types) ======


{-| Does the canonical type CONTAIN a lambda anywhere (through aliases)?
-}
typeContainsCanLambda : Can.Type TypeIds.MVarId -> Bool
typeContainsCanLambda t =
    case t of
        Can.TLambda _ _ ->
            True

        Can.TType _ _ args ->
            List.any typeContainsCanLambda args

        Can.TRecord fields _ ->
            Dict.foldl (\_ (Can.FieldType _ ft) acc -> acc || typeContainsCanLambda ft) False fields

        Can.TTuple a b rest ->
            List.any typeContainsCanLambda (a :: b :: rest)

        Can.TAlias _ _ args (Can.Filled inner) ->
            typeContainsCanLambda inner || List.any (\( _, at ) -> typeContainsCanLambda at) args

        Can.TAlias _ _ args (Can.Holey inner) ->
            typeContainsCanLambda inner || List.any (\( _, at ) -> typeContainsCanLambda at) args

        _ ->
            False


{-| Is this a function type (possibly through aliases)? Every let-bound function
routes through local-multi (a single use collapses to the bare name; N distinct
applied types produce `f`, `f$1`, …).
-}
isFunctionType : Can.Type TypeIds.MVarId -> Bool
isFunctionType t =
    case t of
        Can.TLambda _ _ ->
            True

        Can.TAlias _ _ _ (Can.Filled inner) ->
            isFunctionType inner

        Can.TAlias _ _ _ (Can.Holey inner) ->
            isFunctionType inner

        _ ->
            False


{-| Specialize a let-bound function per distinct type it is applied at. Discovery
is body-first (each use records its applied type), then each recorded instance is
produced by re-translating the RHS under that type (in a fresh store), renamed to
its per-instance name. An unused function emits its bare def once.
-}
translateLocalMultiLet : Name -> TOpt.Expr TypeIds.MVarId -> TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateLocalMultiLet name defBody body letCanType =
    Engine.modifyS (\s -> { s | localCanTypes = Dict.insert name (TOpt.typeOf defBody) s.localCanTypes })
        |> Engine.andThen (\_ -> Engine.pushLocalMulti name)
        |> Engine.andThen
            (\_ ->
                Engine.andThen
                    (\declType ->
                        -- Bind the name (scoped) so non-VarLocal consumers — e.g. a
                        -- destructor root over a tuple-of-functions binding — resolve.
                        Engine.scoped
                            (Engine.andThen (\_ -> translate body) (Engine.insertVar name declType))
                    )
                    (classify (TOpt.typeOf defBody))
            )
        |> Engine.andThen
            (\monoBody ->
                Engine.andThen
                    (\maybeEntry ->
                        Engine.andThen
                            (\instanceDefs ->
                                Engine.map
                                    (\letType0 ->
                                        let
                                            letType =
                                                if
                                                    Mono.containsAnyMVar letType0
                                                        || (not (monoTypeMentionsEco (Mono.typeOf monoBody)) && numericLeafOnlyDiff letType0 (Mono.typeOf monoBody))
                                                then
                                                    Mono.typeOf monoBody

                                                else
                                                    letType0
                                        in
                                        List.foldl (\d acc -> Mono.MonoLet d acc (Mono.typeOf acc)) monoBody (List.reverse instanceDefs)
                                            |> retypeLet letType
                                    )
                                    (classify letCanType)
                            )
                            (buildLocalDefs name defBody maybeEntry)
                    )
                    Engine.popLocalMulti
            )


{-| Overwrite the outermost `MonoLet`'s carried type with the let's own type
(the fold seeds from the body's type; the whole expression's type is the let
type). No-op for a bare body.
-}
retypeLet : Mono.MonoType -> Mono.MonoExpr -> Mono.MonoExpr
retypeLet letType expr =
    case expr of
        Mono.MonoLet d inner _ ->
            Mono.MonoLet d inner letType

        _ ->
            expr


buildLocalDefs : Name -> TOpt.Expr TypeIds.MVarId -> Maybe Engine.NumberMultiEntry -> Step (List Mono.MonoDef)
buildLocalDefs name defBody maybeEntry =
    case maybeEntry of
        Just entry ->
            if Dict.isEmpty entry.instances then
                -- Unused function: emit its bare def once, at its declared type.
                Engine.map (\e -> [ Mono.MonoDef name e ]) (translate defBody)

            else
                Engine.traverse
                    (\inst -> Engine.map (\e -> Mono.MonoDef inst.freshName e) (retranslateAt defBody inst.monoType))
                    (Dict.values entry.instances)

        Nothing ->
            Engine.succeed []




-- ====== CASE / DECISION TREE ======


specializeDecider : Can.Type TypeIds.MVarId -> Name -> TOpt.Decider (TOpt.Choice TypeIds.MVarId) -> Step (Mono.Decider Mono.MonoChoice)
specializeDecider caseCanType root decider =
    case decider of
        TOpt.Leaf choice ->
            Engine.map Mono.Leaf (specializeChoice caseCanType choice)

        TOpt.Chain testChain success failure ->
            Engine.andThen
                (\monoTestChain ->
                    Engine.andThen
                        (\monoSuccess ->
                            Engine.map (\monoFailure -> Mono.Chain monoTestChain monoSuccess monoFailure)
                                (Engine.scoped (specializeDecider caseCanType root failure))
                        )
                        (Engine.scoped (specializeDecider caseCanType root success))
                )
                (Engine.traverse (\( path, test ) -> Engine.map (\mp -> ( mp, test )) (specializeDtPath root path)) testChain)

        TOpt.FanOut path edges fallback ->
            Engine.andThen
                (\monoPath ->
                    Engine.andThen
                        (\monoEdges ->
                            Engine.map (\monoFallback -> Mono.FanOut monoPath monoEdges monoFallback)
                                (Engine.scoped (specializeDecider caseCanType root fallback))
                        )
                        (Engine.traverse (\( test, dec ) -> Engine.map (\md -> ( test, md )) (Engine.scoped (specializeDecider caseCanType root dec))) edges)
                )
                (specializeDtPath root path)


specializeChoice : Can.Type TypeIds.MVarId -> TOpt.Choice TypeIds.MVarId -> Step Mono.MonoChoice
specializeChoice caseCanType choice =
    case choice of
        TOpt.Inline expr ->
            -- Connect the result's type to the case's own type first (demand flow
            -- into branch results, as in the If arm).
            Engine.andThen
                (\_ -> Engine.map Mono.Inline (translate expr))
                (connectTypes (TOpt.typeOf expr) caseCanType)

        TOpt.Jump index ->
            Engine.succeed (Mono.Jump index)


specializeJumps : Can.Type TypeIds.MVarId -> List ( Int, TOpt.Expr TypeIds.MVarId ) -> Step (List ( Int, Mono.MonoExpr ))
specializeJumps caseCanType jumps =
    Engine.traverse
        (\( idx, expr ) ->
            Engine.map (\me -> ( idx, me ))
                (Engine.scoped (Engine.andThen (\_ -> translate expr) (connectTypes (TOpt.typeOf expr) caseCanType)))
        )
        jumps


inferCaseType : List ( Int, Mono.MonoExpr ) -> Mono.Decider Mono.MonoChoice -> Mono.MonoType -> Mono.MonoType
inferCaseType jumps decider fallback =
    case jumps of
        ( _, e ) :: _ ->
            Mono.typeOf e

        [] ->
            inferFromDecider decider fallback


inferFromDecider : Mono.Decider Mono.MonoChoice -> Mono.MonoType -> Mono.MonoType
inferFromDecider decider fallback =
    case decider of
        Mono.Leaf (Mono.Inline e) ->
            Mono.typeOf e

        Mono.Leaf (Mono.Jump _) ->
            fallback

        Mono.Chain _ yes _ ->
            inferFromDecider yes fallback

        Mono.FanOut _ edges def ->
            case edges of
                ( _, d ) :: _ ->
                    inferFromDecider d fallback

                [] ->
                    inferFromDecider def fallback


specializeDtPath : Name -> TypedPath.Path -> Step Mono.MonoDtPath
specializeDtPath root path =
    case path of
        TypedPath.Empty ->
            Engine.andThen
                (\maybeT ->
                    case maybeT of
                        Just t ->
                            Engine.succeed (Mono.DtRoot root t)

                        Nothing ->
                            Engine.fail (EngineBug ("case root not in varEnv: " ++ root))
                )
                (Engine.lookupVar root)

        TypedPath.Index index hint subPath ->
            Engine.andThen
                (\monoSubPath ->
                    let
                        i =
                            Index.toMachine index
                    in
                    Engine.map (\resultType -> Mono.DtIndex i (dtHintToKind hint) resultType monoSubPath)
                        (projIndexType (dtHintToProj hint) i (Mono.dtPathType monoSubPath))
                )
                (specializeDtPath root subPath)

        TypedPath.Unbox subPath ->
            Engine.andThen
                (\monoSubPath ->
                    Engine.map (\resultType -> Mono.DtUnbox resultType monoSubPath)
                        (computeUnboxResultType (Mono.dtPathType monoSubPath))
                )
                (specializeDtPath root subPath)



-- ====== DESTRUCTURE ======


specializeDestructor : TOpt.Destructor TypeIds.MVarId -> Step Mono.MonoDestructor
specializeDestructor (TOpt.Destructor name path meta) =
    Engine.andThen
        (\monoPath -> Engine.map (\monoType -> Mono.MonoDestructor name monoPath monoType) (classify meta.tipe))
        (specializePath path)


specializePath : TOpt.Path -> Step Mono.MonoPath
specializePath path =
    case path of
        TOpt.Root name ->
            Engine.andThen
                (\maybeT ->
                    case maybeT of
                        Just t ->
                            Engine.succeed (Mono.MonoRoot name t)

                        Nothing ->
                            Engine.fail (EngineBug ("destruct root not in varEnv: " ++ name))
                )
                (Engine.lookupVar name)

        TOpt.Index index hint subPath ->
            Engine.andThen
                (\monoSubPath ->
                    let
                        i =
                            Index.toMachine index
                    in
                    Engine.map (\resultType -> Mono.MonoIndex i (hintToKind hint) resultType monoSubPath)
                        (projIndexType (hintToProj hint) i (Mono.getMonoPathType monoSubPath))
                )
                (specializePath subPath)

        TOpt.ArrayIndex idx subPath ->
            Engine.andThen
                (\monoSubPath ->
                    Engine.map (\resultType -> Mono.MonoIndex idx (Mono.CustomContainer "") resultType monoSubPath)
                        (computeArrayElementType (Mono.getMonoPathType monoSubPath))
                )
                (specializePath subPath)

        TOpt.Field fieldName subPath ->
            Engine.andThen
                (\monoSubPath ->
                    case Mono.getMonoPathType monoSubPath of
                        Mono.MRecord fields ->
                            case Dict.get fieldName fields of
                                Just t ->
                                    Engine.succeed (Mono.MonoField fieldName t monoSubPath)

                                Nothing ->
                                    Engine.fail (EngineBug ("field not in record: " ++ fieldName))

                        _ ->
                            Engine.fail (EngineBug "field projection: container not MRecord")
                )
                (specializePath subPath)

        TOpt.Unbox subPath ->
            Engine.andThen
                (\monoSubPath ->
                    Engine.map (\resultType -> Mono.MonoUnbox resultType monoSubPath)
                        (computeUnboxResultType (Mono.getMonoPathType monoSubPath))
                )
                (specializePath subPath)



-- ====== PROJECTION-TYPE COMPUTATION ======


type ProjKind
    = PList
    | PTuple
    | PCustom Name


projIndexType : ProjKind -> Int -> Mono.MonoType -> Step Mono.MonoType
projIndexType kind index container =
    case kind of
        PList ->
            case container of
                Mono.MList elem ->
                    -- index 0 = head → element; otherwise = tail → the list itself
                    if index == 0 then
                        Engine.succeed elem

                    else
                        Engine.succeed container

                _ ->
                    Engine.fail (EngineBug "list projection: container not MList")

        PTuple ->
            case container of
                Mono.MTuple elems ->
                    case List.head (List.drop index elems) of
                        Just t ->
                            Engine.succeed t

                        Nothing ->
                            Engine.fail (EngineBug "tuple projection: index out of range")

                _ ->
                    Engine.fail (EngineBug "tuple projection: container not MTuple")

        PCustom ctorName ->
            computeCustomFieldType ctorName index container


computeArrayElementType : Mono.MonoType -> Step Mono.MonoType
computeArrayElementType container =
    case container of
        Mono.MCustom _ "Array" [ elem ] ->
            Engine.succeed elem

        _ ->
            Engine.fail (EngineBug "array projection: container not Array")


computeCustomFieldType : Name -> Int -> Mono.MonoType -> Step Mono.MonoType
computeCustomFieldType ctorName index container =
    case container of
        Mono.MCustom home typeName typeArgs ->
            Engine.andThen
                (\gte ->
                    case Analysis.lookupUnion gte home typeName of
                        Just (Can.Union unionData) ->
                            case findCtorArg ctorName index unionData.alts of
                                Just canArgType ->
                                    instantiateUnionType unionData.vars typeArgs canArgType

                                Nothing ->
                                    Engine.fail (EngineBug ("ctor field not found: " ++ ctorName ++ "@" ++ String.fromInt index))

                        Nothing ->
                            Engine.fail (EngineBug ("union not found: " ++ typeName))
                )
                (Engine.getS .globalTypeEnv)

        _ ->
            Engine.fail (EngineBug "custom field projection: container not MCustom")


computeUnboxResultType : Mono.MonoType -> Step Mono.MonoType
computeUnboxResultType container =
    case container of
        Mono.MCustom home typeName typeArgs ->
            Engine.andThen
                (\gte ->
                    case Analysis.lookupUnion gte home typeName of
                        Just (Can.Union unionData) ->
                            case unionData.alts of
                                [ Can.Ctor c ] ->
                                    case c.args of
                                        [ canArgType ] ->
                                            instantiateUnionType unionData.vars typeArgs canArgType

                                        _ ->
                                            Engine.fail (EngineBug "unbox: constructor is not single-arg")

                                _ ->
                                    Engine.fail (EngineBug "unbox: type is not single-constructor")

                        Nothing ->
                            Engine.fail (EngineBug ("unbox: union not found: " ++ typeName))
                )
                (Engine.getS .globalTypeEnv)

        _ ->
            Engine.fail (EngineBug "unbox: container not MCustom")


findCtorArg : Name -> Int -> List Can.Ctor -> Maybe (Can.Type Name)
findCtorArg ctorName index alts =
    case List.filter (\(Can.Ctor c) -> c.name == ctorName) alts of
        (Can.Ctor c) :: _ ->
            List.head (List.drop index c.args)

        [] ->
            Nothing


{-| Instantiate a union constructor's declared field type: map the union's
type-param names to the container's concrete type args, convert to MVarIds, and
classify. Mirrors the original engine's field-type computation without importing
its `applySubstPure`.
-}
instantiateUnionType : List Name -> List Mono.MonoType -> Can.Type Name -> Step Mono.MonoType
instantiateUnionType vars typeArgs canArgType =
    Engine.andThen
        (\ids ->
            let
                nameToId =
                    Dict.fromList (List.map2 Tuple.pair vars ids)

                subst =
                    Dict.fromList (List.map2 (\id t -> ( Id.toComparable id, t )) ids typeArgs)

                convertedArg =
                    Analysis.convertCanTypeNameToMVarId nameToId canArgType
            in
            Engine.map (\superTable -> Zonk.canTypeToMonoWith superTable subst convertedArg) (Engine.getS .superTable)
        )
        (allocFreshIds (List.length vars))


allocFreshIds : Int -> Step (List TypeIds.MVarId)
allocFreshIds n =
    Engine.traverse (\_ -> allocFreshId) (List.repeat n ())


allocFreshId : Step TypeIds.MVarId
allocFreshId =
    \s -> Ok ( s.nextMVarId, { s | nextMVarId = Id.succ s.nextMVarId } )


hintToKind : TOpt.ContainerHint -> Mono.ContainerKind
hintToKind hint =
    case hint of
        TOpt.HintList ->
            Mono.ListContainer

        TOpt.HintTuple2 ->
            Mono.Tuple2Container

        TOpt.HintTuple3 ->
            Mono.Tuple3Container

        TOpt.HintCustom name ->
            Mono.CustomContainer name


hintToProj : TOpt.ContainerHint -> ProjKind
hintToProj hint =
    case hint of
        TOpt.HintList ->
            PList

        TOpt.HintTuple2 ->
            PTuple

        TOpt.HintTuple3 ->
            PTuple

        TOpt.HintCustom name ->
            PCustom name


dtHintToKind : TypedPath.ContainerHint -> Mono.ContainerKind
dtHintToKind hint =
    case hint of
        TypedPath.HintList ->
            Mono.ListContainer

        TypedPath.HintTuple2 ->
            Mono.Tuple2Container

        TypedPath.HintTuple3 ->
            Mono.Tuple3Container

        TypedPath.HintCustom name ->
            Mono.CustomContainer name

        TypedPath.HintUnknown ->
            Mono.CustomContainer ""


dtHintToProj : TypedPath.ContainerHint -> ProjKind
dtHintToProj hint =
    case hint of
        TypedPath.HintList ->
            PList

        TypedPath.HintTuple2 ->
            PTuple

        TypedPath.HintTuple3 ->
            PTuple

        TypedPath.HintCustom name ->
            PCustom name

        TypedPath.HintUnknown ->
            PCustom ""



-- ====== HELPERS ======


lookupAnnotation : TOpt.Global -> Step (Maybe (Can.Annotation TypeIds.MVarId))
lookupAnnotation global =
    Engine.getS (\s -> DMap.get TOpt.toComparableGlobal global s.annotations)


toptToMonoGlobal : TOpt.Global -> Mono.Global
toptToMonoGlobal (TOpt.Global home name) =
    Mono.Global home name


nodeKind : TOpt.Expr TypeIds.MVarId -> String
nodeKind expr =
    case expr of
        TOpt.Function _ _ _ ->
            "closure/lambda (M4)"

        TOpt.TrackedFunction _ _ _ ->
            "closure/lambda (M4)"

        TOpt.Case _ _ _ _ _ ->
            "case/decision-tree (M3)"

        TOpt.Accessor _ _ _ ->
            "accessor (M3)"

        TOpt.Destruct _ _ _ ->
            "destructure (M3)"

        TOpt.VarDebug _ _ _ _ _ ->
            "Debug reference (M6)"

        TOpt.VarCycle _ _ _ _ ->
            "cycle reference (M6)"

        TOpt.Shader _ _ _ _ ->
            "shader (M6)"

        _ ->
            "expression"
