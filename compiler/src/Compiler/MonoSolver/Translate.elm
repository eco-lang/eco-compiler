module Compiler.MonoSolver.Translate exposing (translate, demandUnify, demandUnifyRoot, specializeCtorViaScheme, enumNode, specializeCycle, specializePort, canKindDebug, monoKindDebug)

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

import Array
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
import Compiler.MonoSolver.LssInfer as LssInfer
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
classify canType s =
    -- Read-only classification: no store minting, no S copies. Byte-identical to
    -- the former `zonkToMono ∘ loadType` on fixed inputs (verified), see
    -- Store.classifyDirect. A1: explicit trailing-S (η-expanded) → direct calls.
    Store.classifyDirect canType s


{-| Assert a demanded MonoType against a definition's annotation in the store,
concretizing the annotation's scheme variables (shared with the body via the
item memo). A no-op when the demand equals the annotation (monomorphic case).
-}
demandUnify : Can.Type TypeIds.MVarId -> Mono.MonoType -> Step ()
demandUnify annCanType demand =
    Engine.map (\_ -> ()) (demandUnifyVar annCanType demand)


{-| `demandUnify` returning the loaded annotation var. Function-root defs
stash it (`S.lssRootAnn`) so the root lambda's `classifyLambdaHead` can
reuse THE seeded var: `Store.loadType` mints fresh arrow structure per load
(LSS_006 — only leaf MVarIds are memo-shared), so re-loading a GROUND
annotation shares nothing and the demand's lambda-set content would be
unreachable from the def's binder types.
-}
demandUnifyVar : Can.Type TypeIds.MVarId -> Mono.MonoType -> Step IO.Variable
demandUnifyVar annCanType demand =
    Engine.andThen
        (\annVar ->
            Engine.map (\_ -> annVar)
                (Engine.andThen (unifyStepCtx (\() -> "demandUnify " ++ canKind annCanType ++ " vs " ++ monoKind demand) annVar) (Store.monoTypeToVar demand))
        )
        (Store.loadType annCanType)


{-| `demandUnify` for a def root: when the def's expression is syntactically
a lambda and lss is on, stash the seeded annotation var for the root
`classifyLambdaHead` to consume (see `demandUnifyVar`). Non-function defs
and lss-off behave exactly like `demandUnify`.
-}
demandUnifyRoot : Can.Type TypeIds.MVarId -> Mono.MonoType -> TOpt.Expr TypeIds.MVarId -> Step ()
demandUnifyRoot annCanType demand expr s0 =
    case demandUnifyVar annCanType demand s0 of
        Err e ->
            Err e

        Ok ( annVar, s1 ) ->
            if s1.env.lss.enabled && exprIsLambda expr then
                Ok ( (), { s1 | lssRootAnn = Just ( annCanType, annVar ) } )

            else
                Ok ( (), s1 )


exprIsLambda : TOpt.Expr TypeIds.MVarId -> Bool
exprIsLambda expr =
    case expr of
        TOpt.Function _ _ _ _ ->
            True

        TOpt.TrackedFunction _ _ _ _ ->
            True

        _ ->
            False


{-| Best-effort in-store unification of two canonical types (child vs parent
context): loads both through the item memo and unifies, so a child's fresh
use-var picks up the context's already-concretized demand before the child is
translated. Never fails — the typechecker already proved these compatible; any
residual weirdness just leaves vars unbound.
-}
connectTypes : Can.Type TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Step ()
connectTypes childCan parentCan s0 =
    -- A1: direct state-passing (desugared andThen) → byte-identical.
    case Store.loadType parentCan s0 of
        Err e ->
            Err e

        Ok ( parentVar, s1 ) ->
            case Store.loadType childCan s1 of
                Err e ->
                    Err e

                Ok ( childVar, s2 ) ->
                    unifyStepBestEffort childVar parentVar s2


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
translate expr s0 =
    case expr of
        TOpt.Bool _ v _ ->
            Ok ( (Mono.MonoLiteral (Mono.LBool v) Mono.MBool), s0 )

        TOpt.Chr _ v _ ->
            Ok ( (Mono.MonoLiteral (Mono.LChar v) Mono.MChar), s0 )

        TOpt.Str _ v _ ->
            Ok ( (Mono.MonoLiteral (Mono.LStr v) Mono.MString), s0 )

        TOpt.Int _ v meta ->
            -- M6: direct state-passing (desugared map) → byte-identical.
                case classify meta.tipe s0 of
                    Err e ->
                        Err e

                    Ok ( monoType, s1 ) ->
                        Ok
                            ( case monoType of
                                Mono.MFloat ->
                                    Mono.MonoLiteral (Mono.LFloat (toFloat v)) monoType

                                _ ->
                                    Mono.MonoLiteral (Mono.LInt v) monoType
                            , s1
                            )

        TOpt.Float _ v meta ->
            -- M6: direct state-passing (desugared map) → byte-identical.
                case classify meta.tipe s0 of
                    Err e ->
                        Err e

                    Ok ( monoType, s1 ) ->
                        Ok ( Mono.MonoLiteral (Mono.LFloat v) monoType, s1 )

        TOpt.VarLocal name meta ->
            -- D9: read localMulti/numberMulti/varEnv in ONE getS (all pure), then
            -- branch — the former three sequential `getS` andThen-closures on this
            -- hot node collapse to one. Side effects (record*/classify) are
            -- unchanged and still occur only in the taken branch → byte-identical.
            -- M6: direct state-passing (desugared andThen/map). This node fires on
            -- every local-var reference, so eliminating its per-use bind closures is
            -- a broad cut; monad-law-preserving → byte-identical.
                case Engine.localVarInfo name s0 of
                    Err e ->
                        Err e

                    Ok ( ( isLM, isNM, maybeBound ), s1 ) ->
                        if isLM then
                            -- local-multi FUNCTION target: record this use's applied
                            -- type and point at its per-type binding (f / f$1 / …).
                            case classify meta.tipe s1 of
                                Err e ->
                                    Err e

                                Ok ( resolvedType, s2 ) ->
                                    case Engine.recordLocalInstance name resolvedType s2 of
                                        Err e ->
                                            Err e

                                        Ok ( ( freshName, instType ), s3 ) ->
                                            Ok ( Mono.MonoVarLocal freshName instType, s3 )

                        else if isNM then
                            -- number-multi target: record this use's instance and
                            -- point at its per-type binding (n / n$v1 / …).
                            case classify meta.tipe s1 of
                                Err e ->
                                    Err e

                                Ok ( resolvedType, s2 ) ->
                                    case Engine.recordNumberInstance name resolvedType s2 of
                                        Err e ->
                                            Err e

                                        Ok ( ( freshName, instType ), s3 ) ->
                                            Ok ( Mono.MonoVarLocal freshName instType, s3 )

                        else
                            -- Prefer the varEnv-bound type (from an enclosing let/
                            -- lambda/destructor, may be more concrete than the meta).
                            case maybeBound of
                                Just boundType ->
                                    Ok ( Mono.MonoVarLocal name boundType, s1 )

                                Nothing ->
                                    case classify meta.tipe s1 of
                                        Err e ->
                                            Err e

                                        Ok ( monoType, s2 ) ->
                                            Ok ( Mono.MonoVarLocal name monoType, s2 )

        TOpt.TrackedVarLocal _ name meta ->
            translate (TOpt.VarLocal name meta) s0

        TOpt.VarGlobal region global meta ->
            translateVarRef region global meta.tipe s0

        TOpt.VarEnum region global _ meta ->
            translateVarRef region global meta.tipe s0

        TOpt.VarBox region global meta ->
            translateVarRef region global meta.tipe s0

        TOpt.VarCycle region canonical name meta ->
            translateVarRef region (TOpt.Global canonical name) meta.tipe s0

        TOpt.VarKernel region kernelPrefix home name meta ->
            case deriveKernelAbiTypeRef ( home, name ) meta.tipe s0 of
                Err e ->
                    Err e

                Ok ( funcMonoType, s1 ) ->
                    Ok ( Mono.MonoVarKernel region kernelPrefix home name funcMonoType, s1 )

        TOpt.VarDebug region name _ _ meta ->
            case deriveKernelAbiTypeRef ( "Debug", name ) meta.tipe s0 of
                Err e ->
                    Err e

                Ok ( funcMonoType, s1 ) ->
                    Ok ( Mono.MonoVarKernel region "Elm" "Debug" name funcMonoType, s1 )

        TOpt.List region exprs meta ->
            -- Connect every element's type var to the list's element slot (or,
            -- lacking one, to the first element) before translating: an element
            -- use of a let-generalized number picks up the shared demand.
            -- M6: direct state-passing (desugared nested andThen/map) → byte-identical.
            let
                connectElems =
                    case listElemCanType meta.tipe of
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
            in
                case connectElems s0 of
                    Err e ->
                        Err e

                    Ok ( _, s1 ) ->
                        case classify meta.tipe s1 of
                            Err e ->
                                Err e

                            Ok ( monoType0, s2 ) ->
                                case Engine.traverse translate exprs s2 of
                                    Err e ->
                                        Err e

                                    Ok ( monoExprs, s3 ) ->
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
                                        Ok ( Mono.MonoList region monoExprs monoType, s3 )

        TOpt.Call region func args meta ->
            translateCall region func args meta.tipe s0

        TOpt.If branches final meta ->
            -- Per branch: translate the CONDITION first (a shared number var used
            -- there stays at its eager type), then connect the branch value's type
            -- var to the If's own var (so a use of a let-generalized number under a
            -- Float context picks up the demand), then translate the branch value.
            -- Interleaved to mirror the original engine's per-use demand recording.
            -- M6: direct state-passing (desugared nested andThen/map) → byte-identical.
                case classify meta.tipe s0 of
                    Err e ->
                        Err e

                    Ok ( monoType0, s1 ) ->
                        case Engine.traverse (translateIfBranch meta.tipe) branches s1 of
                            Err e ->
                                Err e

                            Ok ( monoBranches, s2 ) ->
                                case connectTypes (TOpt.typeOf final) meta.tipe s2 of
                                    Err e ->
                                        Err e

                                    Ok ( _, s3 ) ->
                                        case translate final s3 of
                                            Err e ->
                                                Err e

                                            Ok ( monoFinal, s4 ) ->
                                                let
                                                    monoType =
                                                        if Mono.containsAnyMVar monoType0 then
                                                            Mono.typeOf monoFinal

                                                        else
                                                            monoType0
                                                in
                                                Ok ( Mono.MonoIf monoBranches monoFinal monoType, s4 )

        TOpt.TailCall name args meta ->
            -- M6: direct state-passing (desugared andThen/map) → byte-identical.
                case classify meta.tipe s0 of
                    Err e ->
                        Err e

                    Ok ( monoType, s1 ) ->
                        case Engine.traverse (\( argName, argExpr ) -> Engine.map (\me -> ( argName, me )) (translate argExpr)) args s1 of
                            Err e ->
                                Err e

                            Ok ( monoArgs, s2 ) ->
                                Ok ( Mono.MonoTailCall name monoArgs monoType, s2 )

        TOpt.Unit _ ->
            Ok ( Mono.MonoUnit, s0 )

        TOpt.Tuple region a b rest meta ->
            -- Connect each slot's type var to the tuple type's slot before
            -- translating (demand flow into tuple literals).
            -- M6: direct state-passing (desugared nested andThen/map) → byte-identical.
            let
                connectSlots =
                    case tupleSlotCanTypes meta.tipe of
                        Just slotCans ->
                            Engine.traverse (\( e, slotCan ) -> connectTypes (TOpt.typeOf e) slotCan)
                                (List.map2 Tuple.pair (a :: b :: rest) slotCans)
                                |> Engine.map (\_ -> ())

                        Nothing ->
                            Engine.succeed ()
            in
                case connectSlots s0 of
                    Err e ->
                        Err e

                    Ok ( _, s1 ) ->
                        case translate a s1 of
                            Err e ->
                                Err e

                            Ok ( monoA, s2 ) ->
                                case translate b s2 of
                                    Err e ->
                                        Err e

                                    Ok ( monoB, s3 ) ->
                                        case Engine.traverse translate rest s3 of
                                            Err e ->
                                                Err e

                                            Ok ( monoRest, s4 ) ->
                                                let
                                                    allExprs =
                                                        monoA :: monoB :: monoRest
                                                in
                                                Ok ( Mono.MonoTupleCreate region allExprs (Mono.MTuple (List.map Mono.typeOf allExprs)), s4 )

        TOpt.Record fields meta ->
            -- Connect each field expr's type var to the record type's field slot
            -- before translating (demand flow into record literals).
            -- M6: direct state-passing (desugared andThen/map) → byte-identical.
                case connectRecordFields (Dict.toList fields) meta.tipe s0 of
                    Err e ->
                        Err e

                    Ok ( _, s1 ) ->
                        case
                            Engine.foldlS
                                (\( name, fieldExpr ) acc -> Engine.map (\me -> ( name, me ) :: acc) (translate fieldExpr))
                                []
                                (Dict.toList fields)
                                s1
                        of
                            Err e ->
                                Err e

                            Ok ( monoFieldsRev, s2 ) ->
                                Ok ( Mono.MonoRecordCreate monoFieldsRev (recordTypeFromFields monoFieldsRev), s2 )

        TOpt.TrackedRecord _ fields meta ->
            -- M6: direct state-passing (desugared andThen/map) → byte-identical.
                case
                    connectRecordFields
                        (List.map (\( locName, e ) -> ( A.toValue locName, e )) (DMap.toList A.compareLocated fields))
                        meta.tipe
                        s0
                of
                    Err e ->
                        Err e

                    Ok ( _, s1 ) ->
                        case
                            Engine.foldlS
                                (\( locName, fieldExpr ) acc ->
                                    Engine.map (\me -> ( A.toValue locName, me ) :: acc) (translate fieldExpr)
                                )
                                []
                                (DMap.toList A.compareLocated fields)
                                s1
                        of
                            Err e ->
                                Err e

                            Ok ( monoFieldsRev, s2 ) ->
                                Ok ( Mono.MonoRecordCreate monoFieldsRev (recordTypeFromFields monoFieldsRev), s2 )

        TOpt.Access record _ fieldName meta ->
            translateAccess record fieldName meta s0

        TOpt.Update _ record updates meta ->
            translateUpdate record updates meta.tipe s0

        TOpt.Let def body meta ->
            translateLet def body meta.tipe s0

        TOpt.Case label root decider jumps meta ->
            -- M6: direct state-passing (desugared nested andThen/map) → byte-identical.
                case classify meta.tipe s0 of
                    Err e ->
                        Err e

                    Ok ( monoTypeFromCan, s1 ) ->
                        case specializeDecider meta.tipe root decider s1 of
                            Err e ->
                                Err e

                            Ok ( monoDecider, s2 ) ->
                                case specializeJumps meta.tipe jumps s2 of
                                    Err e ->
                                        Err e

                                    Ok ( monoJumps, s3 ) ->
                                        Ok
                                            ( Mono.MonoCase label
                                                root
                                                monoDecider
                                                monoJumps
                                                (if Mono.containsAnyMVar monoTypeFromCan then
                                                    inferCaseType monoJumps monoDecider monoTypeFromCan

                                                 else
                                                    monoTypeFromCan
                                                )
                                            , s3
                                            )

        TOpt.Destruct destructor body meta ->
            let
                (TOpt.Destructor dname path dmeta) =
                    destructor
            in
            -- Divert (MONO_028): a scalar-number destructor slot projected from a
            -- number-multi root is specialized body-FIRST, so its uses drive one
            -- root instance per demanded numeric type (+ dead-destructor elim).
            -- A1: direct state-passing (desugared andThen; pure getS inlined) → byte-identical.
            case Engine.numberMultiRootType (pathRootName path) s0 of
                Err e ->
                    Err e

                Ok ( maybeRootType, s1 ) ->
                    case maybeRootType of
                        Just eagerRootType ->
                            case classify dmeta.tipe s1 of
                                Err e ->
                                    Err e

                                Ok ( eagerLeaf, s2 ) ->
                                    if isScalarNumber eagerLeaf && refineRootInstance s1.env.globalTypeEnv eagerRootType path eagerLeaf /= Nothing then
                                        specializeNumberDestruct dname path dmeta (pathRootName path) eagerRootType body meta s2

                                    else
                                        generalDestruct destructor body meta s2

                        Nothing ->
                            generalDestruct destructor body meta s1

        TOpt.Accessor region fieldName meta ->
            -- M6: direct state-passing (desugared andThen/map) → byte-identical.
                case classify meta.tipe s0 of
                    Err e ->
                        Err e

                    Ok ( monoType, s1 ) ->
                        if ResolveAccessorValues.accessorTypeNeedsDefer monoType then
                            Ok ( Mono.MonoAccessorValue region fieldName monoType, s1 )

                        else
                            case Engine.enqueueSpec (Mono.Accessor fieldName) monoType s1 of
                                Err e ->
                                    Err e

                                Ok ( specId, s2 ) ->
                                    Ok ( Mono.MonoVarGlobal region specId monoType, s2 )

        TOpt.Function srcLam params body meta ->
            specializeLambda srcLam params body meta.tipe s0

        TOpt.TrackedFunction srcLam trackedParams body meta ->
            specializeLambda srcLam (List.map (\( locName, pt ) -> ( A.toValue locName, pt )) trackedParams) body meta.tipe s0

        -- Deferred to later milestones:
        _ ->
            Err (Unsupported (nodeKind expr))


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
        (demandUnifyRoot (TOpt.typeOf vexpr) demand vexpr)



-- ====== PORTS ======


{-| Specialize a port node into a `MonoPortIncoming`/`MonoPortOutgoing` wrapper
closure over `Elm.Platform.leaf name value`. Incoming ports enqueue their decoder
(recorded as the port's `decoderSpecId`); outgoing ports inline their encoder.
Mirrors `Specialize.specializePortNode`.
-}
specializePort : Bool -> TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Mono.MonoType -> Step Mono.MonoNode
specializePort incoming expr canType requestedMonoType s0 =
    -- LSS_004: port payload/encoder arrows are kernel-facing — poison their
    -- set slots before the body walks/loads them (no-op when lss is off).
    case poisonPortArrowsIfOn canType s0 of
        Err e ->
            Err e

        Ok ( _, s1 ) ->
            specializePortBody incoming expr canType requestedMonoType s1


poisonPortArrowsIfOn : Can.Type TypeIds.MVarId -> Step ()
poisonPortArrowsIfOn canType s =
    if s.env.lss.enabled then
        case Store.loadType canType s of
            Err e ->
                Err e

            Ok ( v, s1 ) ->
                case Store.poisonArrowSets v s1 of
                    Err e ->
                        Err e

                    Ok ( _, s2 ) ->
                        Ok ( (), Engine.bumpWidenedByKernel s2 )

    else
        Ok ( (), s )


specializePortBody : Bool -> TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Mono.MonoType -> Step Mono.MonoNode
specializePortBody incoming expr canType requestedMonoType =
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
                                        Mono.MFunction _ _ _ ->
                                            requestedMonoType

                                        _ ->
                                            classifiedCan
                            in
                            case effectiveType of
                                Mono.MFunction _ [ paramType ] resultType ->
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
                                                    Mono.MonoVarKernel region "Elm" "Platform" "leaf" (Mono.MFunction Mono.LTop [ Mono.MString, valueType ] resultType)

                                                closureInfo =
                                                    { lambdaId = lambdaId
                                                    , srcLambda = Nothing
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
                                                                    Mono.MFunction _ _ r ->
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

                Mono.MFunction anno args r ->
                    let
                        ( args1, acc1 ) =
                            List.foldr (\a ( accL, accS ) -> let ( a1, accS1 ) = go a accS in ( a1 :: accL, accS1 )) ( [], ( mapping, nextId ) ) args

                        ( r1, acc2 ) =
                            go r acc1
                    in
                    ( Mono.MFunction anno args1 r1, acc2 )

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
        Mono.MFunction _ ps r ->
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
                (demandUnifyRoot defType demand body)

        TOpt.TailDef _ _ typedArgs body defType _ ->
            \sIn ->
                if sIn.env.lss.enabled then
                    -- lss on: the node/param types must come from a zonk of THE
                    -- demand-seeded annotation var — a storeless classify (or a
                    -- fresh re-load) cannot see the transported lambda sets
                    -- (LSS_006: set slots live on per-load arrow structure).
                    case demandUnifyVar defType demand sIn of
                        Err e ->
                            Err e

                        Ok ( annVar, s1 ) ->
                            case Store.zonkToMono annVar s1 of
                                Err e ->
                                    Err e

                                Ok ( funcType, s2 ) ->
                                    let
                                        peeled =
                                            extractFieldTypes (List.length typedArgs) funcType
                                    in
                                    case
                                        (if List.length peeled == List.length typedArgs then
                                            Ok ( List.map2 (\( locName, _ ) mt -> ( A.toValue locName, mt )) typedArgs peeled, s2 )

                                         else
                                            -- Shape fallback: annotation stages don't
                                            -- cover the params — classify as before.
                                            Engine.traverse (\( locName, argType ) -> Engine.map (\mt -> ( A.toValue locName, mt )) (classify argType)) typedArgs s2
                                        )
                                    of
                                        Err e ->
                                            Err e

                                        Ok ( monoParams, s3 ) ->
                                            case Engine.scoped (Engine.andThen (\_ -> translate body) (insertVars monoParams)) s3 of
                                                Err e ->
                                                    Err e

                                                Ok ( monoBody, s4 ) ->
                                                    Ok ( Mono.MonoTailFunc monoParams monoBody funcType, s4 )

                else
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
                        sIn



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
            Mono.MFunction _ args result ->
                args ++ extractFieldTypes (n - List.length args) result

            _ ->
                []


extractCtorResultType : Int -> Mono.MonoType -> Mono.MonoType
extractCtorResultType n monoType =
    if n <= 0 then
        monoType

    else
        case monoType of
            Mono.MFunction _ _ result ->
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
specializeLambda : Maybe TypeIds.SrcLambdaId -> List ( Name, Can.Type TypeIds.MVarId ) -> TOpt.Expr TypeIds.MVarId -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
specializeLambda srcLam params body canType =
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
                                        , srcLambda = srcLam
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
        (classifyLambdaHead srcLam canType)


{-| The lambda's head type. lss off: exactly the storeless `classify` (the
byte-identical path). lss on: LOAD the lambda's type (arrows slotted, through
the ITEM memo so demand concretization is visible), inject the lambda's own
member into the head arrow's slot, and zonk — the closure's MonoType then
carries `LSet [self, …demand-joined members]` on its head arrow (design §8.2).

Def-root lambdas consume the stashed `demandUnifyVar` annotation var
(matched by canonical type) instead of a fresh load: the fresh load of a
GROUND annotation shares no vars with the demand-seeded one (LSS_006), so
without the reuse the demand's transported lambda sets never reach the
def's binder/param types and every param-use call site zonks LTop. The
zonked structure is identical either way (leaf demand flow is memo-shared);
only annotations gain content — lss-off byte-identity untouched.
-}
classifyLambdaHead : Maybe TypeIds.SrcLambdaId -> Can.Type TypeIds.MVarId -> Step Mono.MonoType
classifyLambdaHead srcLam canType s0 =
    if s0.env.lss.enabled then
        let
            ( maybeRootVar, s0b ) =
                case s0.lssRootAnn of
                    Just ( annCanType, annVar ) ->
                        if annCanType == canType then
                            ( Just annVar, { s0 | lssRootAnn = Nothing } )

                        else
                            ( Nothing, s0 )

                    Nothing ->
                        ( Nothing, s0 )
        in
        case
            (case maybeRootVar of
                Just annVar ->
                    Ok ( annVar, s0b )

                Nothing ->
                    Store.loadType canType s0b
            )
        of
            Err e ->
                Err e

            Ok ( funcVar, s1 ) ->
                case LssInfer.injectLambdaMember srcLam funcVar s1 of
                    Err e ->
                        Err e

                    Ok ( _, s2 ) ->
                        Store.zonkToMono funcVar s2

    else
        classify canType s0


allocLambdaId : Step Mono.LambdaId
allocLambdaId =
    \s -> Ok ( Mono.AnonymousLambda s.env.currentModule s.lambdaCounter, { s | lambdaCounter = s.lambdaCounter + 1 } )



-- ====== VAR REFERENCES ======


{-| A standalone reference to a global value/ctor/box → `MonoVarGlobal SpecId`.
Mirrors the VarGlobal/VarEnum/VarBox arms (enqueue with the node's own type).
-}
translateVarRef : A.Region -> TOpt.Global -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateVarRef region global canType s0 =
    -- M6: direct state-passing (desugared andThen/map). Fires on every global
    -- reference; monad-law-preserving → byte-identical.
        case classify canType s0 of
            Err e ->
                Err e

            Ok ( monoType, s1 ) ->
                case Engine.enqueueSpec (toptToMonoGlobal global) monoType s1 of
                    Err e ->
                        Err e

                    Ok ( specId, s2 ) ->
                        Ok ( Mono.MonoVarGlobal region specId monoType, s2 )


monoTypeMentionsEco : Mono.MonoType -> Bool
monoTypeMentionsEco mt =
    case mt of
        Mono.MVar _ Mono.CEcoValue ->
            True

        Mono.MFunction _ args r ->
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
            -- M6: direct state-passing (desugared andThen) → byte-identical.
            \s0 ->
                case lookupAnnotation global s0 of
                    Err e ->
                        Err e

                    Ok ( maybeAnn, s1 ) ->
                        let
                            funcCanType =
                                case maybeAnn of
                                    Just (Can.Forall _ annType) ->
                                        annType

                                    Nothing ->
                                        funcMeta.tipe
                        in
                        translateGlobalCall region funcRegion global funcCanType args callCanType s1

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
localCalleeCall region func name funcMeta args callCanType s0 =
    -- M6: direct state-passing (desugared andThen) → byte-identical.
        case Engine.isLocalMultiTarget name s0 of
            Err e ->
                Err e

            Ok ( isLM, s1 ) ->
                if isLM then
                    translateLocalMultiCall region name funcMeta.tipe args callCanType s1

                else
                    translateIndirectCall region func args callCanType s1


{-| Specialize a call to a local-multi function: instantiate its type, unify its
params/result against the arg types (concretizing shared vars), translate the
args, then record the callee's instance at the zonked concrete type (`f`/`f$1`).
Mirrors `translateGlobalCall` but records a local instance instead of enqueueing
a global spec.
-}
translateLocalMultiCall : A.Region -> Name -> Can.Type TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateLocalMultiCall region name funcCanType args callCanType s0 =
    let
        argCount =
            List.length args
    in
    -- M6: direct state-passing (desugared 7-deep andThen/map nest, mirrors the
    -- D11 rewrite of translateGlobalCallSlow) → byte-identical.
        case instantiate funcCanType s0 of
            Err e ->
                Err e

            Ok ( funcVar, s1 ) ->
                case unifyParamsCollect funcVar args s1 of
                    Err e ->
                        Err e

                    Ok ( argStash, s2 ) ->
                        case unifyResultWithExpected funcVar argCount callCanType s2 of
                            Err e ->
                                Err e

                            Ok ( _, s3 ) ->
                                case translateArgsWith argStash args s3 of
                                    Err e ->
                                        Err e

                                    Ok ( monoArgs, s4 ) ->
                                        case Store.zonkToMono funcVar s4 of
                                            Err e ->
                                                Err e

                                            Ok ( funcMonoType, s5 ) ->
                                                case callResultType argCount funcMonoType callCanType s5 of
                                                    Err e ->
                                                        Err e

                                                    Ok ( resultMonoType, s6 ) ->
                                                        case Engine.recordLocalInstance name funcMonoType s6 of
                                                            Err e ->
                                                                Err e

                                                            Ok ( ( freshName, instType ), s7 ) ->
                                                                Ok
                                                                    ( Mono.MonoCall region
                                                                        (Mono.MonoVarLocal freshName instType)
                                                                        monoArgs
                                                                        resultMonoType
                                                                        Mono.defaultCallInfo
                                                                    , s7
                                                                    )


{-| A call whose callee is not a direct global/kernel/debug (a local holding a
function, an `Access`, a nested `Call`): translate the args, translate the callee
as an ordinary expression, and take the result type from the call node. Mirrors
the generic fallback in `Specialize` (recursively specialize the callee expr).
-}
translateIndirectCall : A.Region -> TOpt.Expr TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateIndirectCall region func args callCanType s0 =
    -- Connect the callee's type var to `arg1 -> … -> result` first: a call to
    -- a destructor-derived local function (`getter rec`) is the only place its
    -- type meets concrete arguments, and the connection flows back through the
    -- destructor root into the case/tuple the function came from.
    -- M6: direct state-passing (desugared andThen) → byte-identical.
        case appShapeConnect func args callCanType s0 of
            Err e ->
                Err e

            Ok ( _, s1 ) ->
                translateIndirectCallBody region func args callCanType s1


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
translateGlobalCall region funcRegion global funcCanType args callCanType s =
        -- Fast paths are guarded to no multi-instance recording in flight (that
        -- path has side effects they must not skip).
        if List.isEmpty s.numberMulti && List.isEmpty s.localMulti then
            -- LSS gate: the cached/storeless fast classifications stamp LTop,
            -- which is exact only when the callee's signature is trivial AND
            -- no argument type mentions an arrow (an arrow-free ground call
            -- cannot transport sets). lss off ⇒ trivially permitted.
            case lssFastOk global args s of
                Err e ->
                    Err e

                Ok ( fastOk, s0 ) ->
                    if not fastOk then
                        translateGlobalCallSlow region funcRegion global funcCanType args callCanType s0

                    else if groundCanType funcCanType then
                        -- M2a: a CLOSED (var-free) scheme instantiates to a fully-ground
                        -- structure — its classification is item-independent (cached) and
                        -- unifying params against args is a no-op on the scheme, so only
                        -- flow demand INTO non-ground args.
                        translateGlobalCallFast region funcRegion global funcCanType args callCanType s0

                    else if groundCanType callCanType && List.all (groundCanType << TOpt.typeOf) args then
                        -- M2b: an OPEN scheme called with all-ground args and result. The
                        -- instantiate+unify+zonk outcome is then a pure function of
                        -- (global, argMonos, resultMono) — memoize it. Ground args carry
                        -- no vars, so there is no demand to flow into them or back.
                        translateGlobalCallGroundMemo region funcRegion global funcCanType args callCanType s0

                    else
                        translateGlobalCallSlow region funcRegion global funcCanType args callCanType s0

        else
            translateGlobalCallSlow region funcRegion global funcCanType args callCanType s


{-| May this call take the cached fast paths under LSS? `sigTrivial` forces
the signature computation on first use — the memo makes that a one-time cost
per global.
-}
lssFastOk : TOpt.Global -> List (TOpt.Expr TypeIds.MVarId) -> Step Bool
lssFastOk global args s =
    if not s.env.lss.enabled then
        Ok ( True, s )

    else if List.any (canTypeHasArrow << TOpt.typeOf) args then
        Ok ( False, s )

    else
        case LssInfer.signatureFor global s of
            Err e ->
                Err e

            Ok ( sig, s1 ) ->
                Ok ( sig.trivial, s1 )


{-| Does a canonical type mention an arrow anywhere? (Syntactic; aliases
followed when filled.)
-}
canTypeHasArrow : Can.Type TypeIds.MVarId -> Bool
canTypeHasArrow t =
    case t of
        Can.TLambda _ _ ->
            True

        Can.TVar _ ->
            False

        Can.TType _ _ typeArgs ->
            List.any canTypeHasArrow typeArgs

        Can.TRecord fields _ ->
            Dict.foldl (\_ (Can.FieldType _ ft) acc -> acc || canTypeHasArrow ft) False fields

        Can.TUnit ->
            False

        Can.TTuple a b rest ->
            canTypeHasArrow a || canTypeHasArrow b || List.any canTypeHasArrow rest

        Can.TAlias _ _ aliasArgs (Can.Filled real) ->
            canTypeHasArrow real || List.any (\( _, at ) -> canTypeHasArrow at) aliasArgs

        Can.TAlias _ _ aliasArgs (Can.Holey real) ->
            canTypeHasArrow real || List.any (\( _, at ) -> canTypeHasArrow at) aliasArgs


{-| True when a canonical type has no free type variable (a closed scheme).
Conservative: never True for a type carrying a var, so the fast path is only
taken when instantiation would be a pure no-op. -}
groundCanType : Can.Type TypeIds.MVarId -> Bool
groundCanType canType =
    case canType of
        Can.TVar _ ->
            False

        Can.TLambda a b ->
            groundCanType a && groundCanType b

        Can.TType _ _ args ->
            List.all groundCanType args

        Can.TRecord fields maybeExt ->
            case maybeExt of
                Just _ ->
                    False

                Nothing ->
                    List.all (\( _, Can.FieldType _ t ) -> groundCanType t) (Dict.toList fields)

        Can.TUnit ->
            True

        Can.TTuple a b rest ->
            groundCanType a && groundCanType b && List.all groundCanType rest

        Can.TAlias _ _ _ (Can.Filled inner) ->
            groundCanType inner

        Can.TAlias _ _ aliasArgs (Can.Holey _) ->
            -- Holey body's only vars are the params, bound to args → ground iff
            -- every arg is ground.
            List.all (\( _, t ) -> groundCanType t) aliasArgs


{-| Peel `n` leading parameter MonoTypes off a single-arg-per-arrow function
MonoType — one per `MFunction` node, matching `peelResult`'s peeling. -}
mFunctionParams : Int -> Mono.MonoType -> List Mono.MonoType
mFunctionParams n mt =
    if n <= 0 then
        []

    else
        case mt of
            Mono.MFunction _ (p :: _) result ->
                p :: mFunctionParams (n - 1) result

            _ ->
                []


{-| Closed-scheme classification, from the global cache or computed purely
(`Zonk.canTypeToMono`, which equals the slow path's zonk of a fully-ground
instantiated scheme) and cached. -}
cachedSchemeMono : String -> Can.Type TypeIds.MVarId -> Step Mono.MonoType
cachedSchemeMono key funcCanType =
    Engine.andThen
        (\cached ->
            case cached of
                Just mt ->
                    Engine.succeed mt

                Nothing ->
                    Engine.andThen
                        (\superStatic ->
                            let
                                mt =
                                    Zonk.canTypeToMono superStatic funcCanType
                            in
                            Engine.map (\_ -> mt) (Engine.putSchemeMono key mt)
                        )
                        (Engine.getS (\s -> s.env.superStatic))
        )
        (Engine.lookupSchemeMono key)


{-| Flow the closed callee's ground parameter types into the args: a ground arg
already matches its ground param (a no-op unify), so skip it; a var-carrying arg
gets its vars concretized to the ground param via `demandUnify` (the store
equivalent of the slow path's per-arg param↔arg unification — enrichment is
redundant against a fully-ground param). -}
flowArgDemands : List ( Mono.MonoType, Can.Type TypeIds.MVarId ) -> Step ()
flowArgDemands pairs =
    Engine.foldlS
        (\( paramMono, argCanType ) () ->
            if groundCanType argCanType then
                Engine.succeed ()

            else
                demandUnify argCanType paramMono
        )
        ()
        pairs


translateGlobalCallFast : A.Region -> A.Region -> TOpt.Global -> Can.Type TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateGlobalCallFast region funcRegion global funcCanType args callCanType =
    let
        argCount =
            List.length args
    in
    Engine.andThen
        (\funcMonoType ->
            let
                paramMonos =
                    mFunctionParams argCount funcMonoType
            in
            if List.length paramMonos < argCount then
                -- Over-applied relative to the scheme's arrows: the slow path's
                -- Fun1 peeling handles this; fall back.
                translateGlobalCallSlow region funcRegion global funcCanType args callCanType

            else
                let
                    resultMonoType =
                        peelResult argCount funcMonoType
                in
                Engine.andThen
                    (\_ ->
                        Engine.andThen
                            (\_ ->
                                Engine.andThen
                                    (\monoArgs ->
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
                                    (Engine.traverse translate args)
                            )
                            (if groundCanType callCanType then
                                Engine.succeed ()

                             else
                                demandUnify callCanType resultMonoType
                            )
                    )
                    (flowArgDemands (List.map2 Tuple.pair paramMonos (List.map TOpt.typeOf args)))
        )
        (cachedSchemeMono (TOpt.toComparableGlobal global) funcCanType)


{-| M2b: memoized open-scheme call at all-ground args/result. The key is
`(global, ground arg MonoTypes, expected result MonoType)`; the cached value is
the slow path's `(funcMonoType, resultMonoType)`. Because ground args carry no
type variables, they touch neither the item memo nor demand flow, so on a hit
the whole instantiate+unify+zonk is skipped and only the args are translated and
the spec enqueued — byte-identical to the slow path. -}
translateGlobalCallGroundMemo : A.Region -> A.Region -> TOpt.Global -> Can.Type TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateGlobalCallGroundMemo region funcRegion global funcCanType args callCanType =
    Engine.andThen
        (\superStatic ->
            let
                key =
                    -- Annotation-neutral by construction (M4 == audit):
                    -- canTypeToMono stamps LTop on every arrow, and lssFastOk
                    -- gates this memo to trivial-signature callees with
                    -- arrow-free args, so no set can differ under one key and
                    -- the cached (funcMonoType, resultMonoType, specId) replay
                    -- is exact.
                    TOpt.toComparableGlobal global
                        ++ "|"
                        ++ String.join "," (List.map (Mono.toComparableMonoType << Zonk.canTypeToMono superStatic << TOpt.typeOf) args)
                        ++ "->"
                        ++ Mono.toComparableMonoType (Zonk.canTypeToMono superStatic callCanType)
            in
            Engine.andThen
                (\cached ->
                    case cached of
                        Just ( funcMonoType, resultMonoType, specId ) ->
                            -- D10 HIT: the spec was scheduled on the first miss
                            -- (scheduled is monotonic), so skip enqueue entirely —
                            -- no `getOrCreateSpecId` re-serialization — and emit
                            -- the cached specId directly. Args still translate.
                            Engine.map
                                (\monoArgs ->
                                    Mono.MonoCall region
                                        (Mono.MonoVarGlobal funcRegion specId funcMonoType)
                                        monoArgs
                                        resultMonoType
                                        Mono.defaultCallInfo
                                )
                                (Engine.traverse translate args)

                        Nothing ->
                            -- Compute exactly as the slow path does; enqueue to get
                            -- the specId; cache (funcMono, resultMono, specId).
                            Engine.andThen
                                (\funcVar ->
                                    Engine.andThen
                                        (\_ ->
                                            Engine.andThen
                                                (\_ ->
                                                    Engine.andThen
                                                        (\funcMonoType ->
                                                            Engine.andThen
                                                                (\resultMonoType ->
                                                                    Engine.andThen
                                                                        (\monoArgs ->
                                                                            Engine.andThen
                                                                                (\specId ->
                                                                                    Engine.map
                                                                                        (\_ ->
                                                                                            Mono.MonoCall region
                                                                                                (Mono.MonoVarGlobal funcRegion specId funcMonoType)
                                                                                                monoArgs
                                                                                                resultMonoType
                                                                                                Mono.defaultCallInfo
                                                                                        )
                                                                                        (Engine.putCallMemo key ( funcMonoType, resultMonoType, specId ))
                                                                                )
                                                                                (Engine.enqueueSpec (toptToMonoGlobal global) funcMonoType)
                                                                        )
                                                                        (Engine.traverse translate args)
                                                                )
                                                                (callResultType (List.length args) funcMonoType callCanType)
                                                        )
                                                        (Store.zonkToMono funcVar)
                                                )
                                                (unifyResultWithExpected funcVar (List.length args) callCanType)
                                        )
                                        (unifyParamsWithArgExprs funcVar args)
                                )
                                (instantiate funcCanType)
                )
                (Engine.lookupCallMemo key)
        )
        (Engine.getS (\s -> s.env.superStatic))


{-| Emit a global MonoCall: translate the args, enqueue the callee spec, build
the node — used by the M2b slow-fallback path. -}
emitCall : A.Region -> A.Region -> TOpt.Global -> Mono.MonoType -> Mono.MonoType -> List (TOpt.Expr TypeIds.MVarId) -> Step Mono.MonoExpr
emitCall region funcRegion global funcMonoType resultMonoType args s0 =
    -- D11: direct state-passing (desugared andThen/map). Avoids the two
    -- per-call monad closures; monad-law-preserving → byte-identical.
        case Engine.traverse translate args s0 of
            Err e ->
                Err e

            Ok ( monoArgs, s1 ) ->
                case Engine.enqueueSpec (toptToMonoGlobal global) funcMonoType s1 of
                    Err e ->
                        Err e

                    Ok ( specId, s2 ) ->
                        Ok
                            ( Mono.MonoCall region
                                (Mono.MonoVarGlobal funcRegion specId funcMonoType)
                                monoArgs
                                resultMonoType
                                Mono.defaultCallInfo
                            , s2
                            )


translateGlobalCallSlow : A.Region -> A.Region -> TOpt.Global -> Can.Type TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateGlobalCallSlow region funcRegion global funcCanType args callCanType s0 =
    let
        argCount =
            List.length args
    in
    -- Instantiate the callee and unify its params/result against the arg types
    -- FIRST, concretizing shared vars in the item memo, THEN translate the args
    -- so their VarLocal uses see the demanded type (solver-native demand flow;
    -- needed for number-multi and for a faithful funcMonoType).
    -- D11: direct state-passing (desugared 7-deep andThen/map nest). Eliminates
    -- the seven per-call monad closures; monad-law-preserving → byte-identical.
        case instantiateLss global funcCanType s0 of
            Err e ->
                Err e

            Ok ( funcVar, s1 ) ->
                case unifyParamsCollect funcVar args s1 of
                    Err e ->
                        Err e

                    Ok ( argStash, s2 ) ->
                        case unifyResultWithExpected funcVar argCount callCanType s2 of
                            Err e ->
                                Err e

                            Ok ( _, s3 ) ->
                                case translateArgsWith argStash args s3 of
                                    Err e ->
                                        Err e

                                    Ok ( monoArgs, s4 ) ->
                                        case Store.zonkToMono funcVar s4 of
                                            Err e ->
                                                Err e

                                            Ok ( funcMonoType, s5 ) ->
                                                case callResultType argCount funcMonoType callCanType s5 of
                                                    Err e ->
                                                        Err e

                                                    Ok ( resultMonoType, s6 ) ->
                                                        case Engine.enqueueSpec (toptToMonoGlobal global) funcMonoType s6 of
                                                            Err e ->
                                                                Err e

                                                            Ok ( specId, s7 ) ->
                                                                Ok
                                                                    ( Mono.MonoCall region
                                                                        (Mono.MonoVarGlobal funcRegion specId funcMonoType)
                                                                        monoArgs
                                                                        resultMonoType
                                                                        Mono.defaultCallInfo
                                                                    , s7
                                                                    )


translateKernelCall : A.Region -> A.Region -> Name -> Name -> Name -> ( String, String ) -> Can.Type TypeIds.MVarId -> List (TOpt.Expr TypeIds.MVarId) -> Can.Type TypeIds.MVarId -> Step Mono.MonoExpr
translateKernelCall region funcRegion kernelPrefix home name kernelId funcCanType args callCanType s0 =
    -- D5: no `argCanTypes` list — it was built only for its length.
    -- Derive the kernel ABI FIRST: this unifies the kernel's param slots with the
    -- argument types, concretizing shared vars in the item memo (e.g. `1.4 * n`
    -- forces `n`'s number var to Float) BEFORE the args are translated — so an
    -- arg's VarLocal use sees the demanded type (needed for number-multi).
    -- D11: direct state-passing (desugared andThen/map) → byte-identical.
        case deriveKernelAbiTypeCall kernelId funcCanType args s0 of
            Err e ->
                Err e

            Ok ( funcMonoType, s1 ) ->
                case Engine.traverse translate args s1 of
                    Err e ->
                        Err e

                    Ok ( monoArgs, s2 ) ->
                        case callResultType (List.length args) funcMonoType callCanType s2 of
                            Err e ->
                                Err e

                            Ok ( resultMonoType, s3 ) ->
                                Ok
                                    ( Mono.MonoCall region
                                        (Mono.MonoVarKernel funcRegion kernelPrefix home name funcMonoType)
                                        monoArgs
                                        resultMonoType
                                        Mono.defaultCallInfo
                                    , s3
                                    )


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
            Mono.MFunction _ _ result ->
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
                    case Store.arrowParts desc.content of
                        Just ( pParam, pRest ) ->
                            Engine.andThen
                                (\argVar ->
                                    Engine.andThen
                                        (\_ -> unifyParamsBestEffort pRest rest)
                                        (unifyStepBestEffort pParam argVar)
                                )
                                (Store.loadType argCanType)

                        Nothing ->
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
unifyParamsCollect funcVar args s0 =
    case args of
        [] ->
            Ok ( [], s0 )

        arg :: rest ->
            -- M6/A1: direct state-passing over an explicit trailing S; fires once
            -- per call argument. Monad-law-preserving → byte-identical.
                case Engine.liftIO (UF.get funcVar) s0 of
                    Err e ->
                        Err e

                    Ok ( desc, s1 ) ->
                        case Store.arrowParts desc.content of
                            Just ( pParam, pRest ) ->
                                case localMultiArgName arg s1 of
                                    Err e ->
                                        Err e

                                    Ok ( maybeLM, s2 ) ->
                                        case maybeLM of
                                            Just _ ->
                                                case instantiate (TOpt.typeOf arg) s2 of
                                                    Err e ->
                                                        Err e

                                                    Ok ( freshVar0, s3 ) ->
                                                        case unifyStepBestEffort pParam freshVar0 s3 of
                                                            Err e ->
                                                                Err e

                                                            Ok ( _, s4 ) ->
                                                                case unifyParamsCollect pRest rest s4 of
                                                                    Err e ->
                                                                        Err e

                                                                    Ok ( restStash, s5 ) ->
                                                                        Ok ( Just freshVar0 :: restStash, s5 )

                                            Nothing ->
                                                case argUnifyVar arg s2 of
                                                    Err e ->
                                                        Err e

                                                    Ok ( argVar, s3 ) ->
                                                        case unifyStepBestEffort pParam argVar s3 of
                                                            Err e ->
                                                                Err e

                                                            Ok ( _, s4 ) ->
                                                                case unifyParamsCollect pRest rest s4 of
                                                                    Err e ->
                                                                        Err e

                                                                    Ok ( restStash, s5 ) ->
                                                                        Ok ( Nothing :: restStash, s5 )

                            Nothing ->
                                Ok ( List.map (\_ -> Nothing) args, s1 )


{-| Translate call args, using the per-call-site stash for local-multi function
args: zonk the fresh instantiation the params were unified against, record the
instance at THAT type, and emit its per-instance local ref.
-}
translateArgsWith : List (Maybe IO.Variable) -> List (TOpt.Expr TypeIds.MVarId) -> Step (List Mono.MonoExpr)
translateArgsWith stash args =
    -- D4: `unifyParamsCollect` always returns exactly `List.length args` stash
    -- entries (every arm produces one per arg), so the former `stash ++
    -- List.repeat 0 Nothing` padding was a no-op that still copied `stash`.
    -- Pair directly.
    Engine.traverse
        (\( maybeVar, arg ) ->
            case ( maybeVar, accessedLocalName arg ) of
                ( Just v, Just localName ) ->
                    -- M6: direct state-passing (desugared andThen/map) → byte-identical.
                    \s0 ->
                        case Store.zonkToMono v s0 of
                            Err e ->
                                Err e

                            Ok ( instType0, s1 ) ->
                                case Engine.recordLocalInstance localName instType0 s1 of
                                    Err e ->
                                        Err e

                                    Ok ( ( freshName, instType ), s2 ) ->
                                        Ok ( Mono.MonoVarLocal freshName instType, s2 )

                _ ->
                    translate arg
        )
        (List.map2 Tuple.pair stash args)


{-| `Just name` when the arg is a direct reference to a local-multi FUNCTION.
-}
localMultiArgName : TOpt.Expr TypeIds.MVarId -> Step (Maybe Name)
localMultiArgName arg s0 =
    case accessedLocalName arg of
        Just localName ->
            -- M6/A1: direct state-passing over explicit trailing S → byte-identical.
            case Engine.isLocalMultiTarget localName s0 of
                Err e ->
                    Err e

                Ok ( isLM, s1 ) ->
                    Ok
                        ( if isLM then
                            Just localName

                          else
                            Nothing
                        , s1
                        )

        Nothing ->
            Ok ( Nothing, s0 )


{-| The store var to unify a call argument against: the arg's canonical type
loaded through the memo, ENRICHED at local leaves with the varEnv binding (the
concrete type of a lambda param / destructor-bound / let-bound local — the use's
canonical type may still be a narrow row-polymorphic generalization). Tuple
literals recurse so a `( 0, outer )` arg carries `outer`'s full record type.
-}
argUnifyVar : TOpt.Expr TypeIds.MVarId -> Step IO.Variable
argUnifyVar arg s0 =
    -- M6: direct state-passing (desugared andThen) → byte-identical.
        case Store.loadType (TOpt.typeOf arg) s0 of
            Err e ->
                Err e

            Ok ( canVar, s1 ) ->
                case enrichFromEnv arg canVar s1 of
                    Err e ->
                        Err e

                    Ok ( _, s2 ) ->
                        case injectArgLambdaMember arg canVar s2 of
                            Err e ->
                                Err e

                            Ok ( _, s3 ) ->
                                Ok ( canVar, s3 )


{-| M3 arg-side member transport: a lambda LITERAL passed directly as an
argument must contribute its member to the callee's param arrow slot.

`Store.loadType` mints fresh arrow structure per load (LSS_006 — only leaf
MVarIds are memo-shared), so the set slot `classifyLambdaHead` injects into
when the lambda is TRANSLATED is a different slot from `canVar`'s — the one
unified with the callee's param. Without this injection the member never
reaches the callee's demand, every downstream call-site annotation zonks to
LTop, and AbiCloning finds nothing to upgrade.

Locals referencing a closure transport through `enrichFromEnv` (the bound
MonoType carries the closure's annotation) when they are not local-multi
targets; local-multi args (fresh-instantiated stash vars) remain a known
precision gap in v1 — safe: no member, no stamp.

-}
injectArgLambdaMember : TOpt.Expr TypeIds.MVarId -> IO.Variable -> Step ()
injectArgLambdaMember arg canVar =
    case arg of
        TOpt.Function srcLam _ _ _ ->
            LssInfer.injectLambdaMember srcLam canVar

        TOpt.TrackedFunction srcLam _ _ _ ->
            LssInfer.injectLambdaMember srcLam canVar

        _ ->
            \s -> Ok ( (), s )


{-| Best-effort unify `canVar` with environment-derived structure for `arg`.
-}
enrichFromEnv : TOpt.Expr TypeIds.MVarId -> IO.Variable -> Step ()
enrichFromEnv arg canVar s0 =
    case accessedLocalName arg of
        Just localName ->
            -- Never enrich from a local-multi target: its varEnv entry is only
            -- the DECLARED classify (possibly a closed-narrow row type), and
            -- forcing it here would block the full type flowing from the other
            -- call args. Its typing is owned by the instance-recording path.
            -- M6/A1: direct state-passing over explicit trailing S → byte-identical.
                case Engine.isLocalMultiTarget localName s0 of
                    Err e ->
                        Err e

                    Ok ( isLM, s1 ) ->
                        if isLM then
                            Ok ( (), s1 )

                        else
                            case Engine.lookupVar localName s1 of
                                Err e ->
                                    Err e

                                Ok ( maybeBound, s2 ) ->
                                    case maybeBound of
                                        Just boundType ->
                                            case Store.monoTypeToVar boundType s2 of
                                                Err e ->
                                                    Err e

                                                Ok ( boundVar, s3 ) ->
                                                    unifyStepBestEffort canVar boundVar s3

                                        Nothing ->
                                            Ok ( (), s2 )

        Nothing ->
            case arg of
                TOpt.Tuple _ a b rest _ ->
                    -- M6/A1: direct state-passing over explicit trailing S → byte-identical.
                        case Engine.liftIO (UF.get canVar) s0 of
                            Err e ->
                                Err e

                            Ok ( desc, s1 ) ->
                                case desc.content of
                                    IO.Structure (IO.Tuple1 pa pb pRest) ->
                                        case enrichFromEnv a pa s1 of
                                            Err e ->
                                                Err e

                                            Ok ( _, s2 ) ->
                                                case enrichFromEnv b pb s2 of
                                                    Err e ->
                                                        Err e

                                                    Ok ( _, s3 ) ->
                                                        case Engine.traverse (\( e, pt ) -> enrichFromEnv e pt) (List.map2 Tuple.pair rest pRest) s3 of
                                                            Err e ->
                                                                Err e

                                                            Ok ( _, s4 ) ->
                                                                Ok ( (), s4 )

                                    _ ->
                                        Ok ( (), s1 )

                _ ->
                    Ok ( (), s0 )


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
        (Engine.andThen poisonKernelArrowsThen funcVarStep)


{-| LSS_004: arrows crossing the kernel ABI are dynamic. Poison the loaded
kernel scheme's set slots BEFORE it is zonked or unified with args, so both
the ABI readback and the item-memo Points shared with the arguments carry ⊤.
No-op when lss is off.
-}
poisonKernelArrowsThen : IO.Variable -> Step IO.Variable
poisonKernelArrowsThen funcVar s =
    if s.env.lss.enabled then
        case Store.poisonArrowSets funcVar s of
            Err e ->
                Err e

            Ok ( _, s1 ) ->
                Ok ( funcVar, Engine.bumpWidenedByKernel s1 )

    else
        Ok ( funcVar, s )


{-| Load a type with a fresh, isolated memo so its vars do not share Points with
the surrounding item (a fresh scheme instantiation). The minted Points persist
in the store; the item memo is restored afterward.
-}
instantiate : Can.Type TypeIds.MVarId -> Step IO.Variable
instantiate canType =
    -- D8: one S-write instead of three (see Store.loadTypeIsolated).
    Store.loadTypeIsolated canType


{-| `instantiate` with the callee's LSS signature facts applied to the fresh
instantiation's arrow slots (design §8.4). lss-off = exactly `instantiate`.
`funcCanType` is already annotation-sourced by `translateCall` (LSS_006's
other half — the signature side enumerates the same source).
-}
instantiateLss : TOpt.Global -> Can.Type TypeIds.MVarId -> Step IO.Variable
instantiateLss global funcCanType s =
    if s.env.lss.enabled then
        LssInfer.instantiateWithSignature global funcCanType s

    else
        instantiate funcCanType s


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
                    case Store.arrowParts desc.content of
                        Just ( pParam, pRest ) ->
                            Engine.andThen
                                (\argVar ->
                                    Engine.andThen
                                        (\_ -> unifyParamsWithArgs pRest rest)
                                        (unifyStepCtx (\() -> "param vs arg " ++ canKind argCanType) pParam argVar)
                                )
                                (Store.loadType argCanType)

                        Nothing ->
                            -- Over-applied or not a function at this depth: stop.
                            Engine.succeed ()
                )
                (Engine.liftIO (UF.get funcVar))


unifyStepCtx : (() -> String) -> IO.Variable -> IO.Variable -> Step ()
unifyStepCtx ctx v1 v2 s =
    -- D3: `ctx` is a THUNK — the diagnostic string (recursive `canKind`/`monoKind`
    -- type walks) is built ONLY on a mismatch (a compile-aborting failure), not on
    -- the ~100%-success hot path where it was formerly built and discarded.
    case Store.unifyStep v1 v2 s of
        Ok ok ->
            Ok ok

        Err (UnifyMismatch m) ->
            Err (UnifyMismatch (ctx () ++ " | " ++ m))

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
                case Store.arrowParts desc.content of
                    Just ( _, pRest ) ->
                        resultVarAfter pRest (n - 1)

                    Nothing ->
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
    Engine.getS (\s -> State.initMVarEnv s.nextMVarId s.env.superStatic)



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

        ( Mono.MFunction _ args1 r1, Mono.MFunction _ args2 r2 ) ->
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
translateUpdate record updates canType s0 =
    -- M6: direct state-passing (desugared andThen/map) → byte-identical.
        case classify canType s0 of
            Err e ->
                Err e

            Ok ( monoType, s1 ) ->
                case translate record s1 of
                    Err e ->
                        Err e

                    Ok ( monoRecord, s2 ) ->
                        case
                            Engine.foldlS
                                (\( locName, updateExpr ) acc ->
                                    Engine.map (\me -> ( A.toValue locName, me ) :: acc) (translate updateExpr)
                                )
                                []
                                (DMap.toList A.compareLocated updates)
                                s2
                        of
                            Err e ->
                                Err e

                            Ok ( monoUpdatesRev, s3 ) ->
                                let
                                    recordMonoType =
                                        Mono.typeOf monoRecord

                                    resultMonoType =
                                        unionRecordTypes monoType recordMonoType
                                in
                                Ok ( Mono.MonoRecordUpdate monoRecord monoUpdatesRev resultMonoType, s3 )


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
            if isFunctionType defCanType || (typeContainsCanLambda defCanType && KernelAbi.hasAnyFreeVar defCanType) then
                -- Function-typed lets AND lambda-CONTAINING lets with unresolved
                -- vars (a list/record of closures — the original engine's
                -- value-multi gate `typeContainsLambda && hasVar`) route through
                -- body-first discovery + per-instance re-translation, so a use at
                -- a concrete type re-specializes the closures inside.
                translateLocalMultiLet name defBody body letCanType

            else
                -- M6: direct state-passing (desugared andThen; plain-let path is the
                -- common case). The number-multi/local-multi sub-paths keep their own
                -- shapes. Monad-law-preserving → byte-identical.
                \s0 ->
                    case isNumberMultiEligible defCanType s0 of
                        Err e ->
                            Err e

                        Ok ( eligible, s1 ) ->
                            if eligible then
                                translateNumberMultiLet name defBody body letCanType s1

                            else
                                -- Plain non-function, non-number value let.
                                case translate defBody s1 of
                                    Err e ->
                                        Err e

                                    Ok ( monoDefBody, s2 ) ->
                                        case classify defCanType s2 of
                                            Err e ->
                                                Err e

                                            Ok ( defMonoType0, s3 ) ->
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
                                                    s3

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
            { s0 | store = Engine.freshStore, memo = Dict.empty, revMemo = Array.empty }

        step =
            Engine.andThen (\_ -> translate defBody) (demandUnifyRoot (TOpt.typeOf defBody) instType defBody)
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

        Mono.MFunction _ args r ->
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
                                            (Engine.getS (\s -> s.env.globalTypeEnv))

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
    buildRefinedDestructorWith s0.env.globalTypeEnv rootName eagerRootType path dmeta inst s0


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
                (Engine.getS (\s -> s.env.globalTypeEnv))

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
                (Engine.getS (\s -> s.env.globalTypeEnv))

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
    Engine.getS (\s -> DMap.get TOpt.toComparableGlobal global s.env.annotations)


toptToMonoGlobal : TOpt.Global -> Mono.Global
toptToMonoGlobal (TOpt.Global home name) =
    Mono.Global home name


nodeKind : TOpt.Expr TypeIds.MVarId -> String
nodeKind expr =
    case expr of
        TOpt.Function _ _ _ _ ->
            "closure/lambda (M4)"

        TOpt.TrackedFunction _ _ _ _ ->
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
