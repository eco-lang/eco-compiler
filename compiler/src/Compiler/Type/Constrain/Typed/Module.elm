module Compiler.Type.Constrain.Typed.Module exposing (constrainWithIds, constrainWithIdsDetailed, constrainErased)

{-| Generates type constraints for Elm modules during type checking (Typed pathway).

This is the entry point for constraint generation with ID tracking. It traverses
the module's declarations, effects (ports, managers), and builds a constraint tree
while tracking node IDs to solver variables for later type retrieval. The node-id
state lives in `IO.State` and is seeded/collected here via `IO.withNodeIds`.


# Constraint Generation with ID Tracking

@docs constrainWithIds, constrainWithIdsDetailed, constrainErased

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Type as E
import Compiler.Type.Constrain.Typed.Expression as Expr
import Compiler.Type.Constrain.Typed.NodeIds as NodeIds
import Compiler.Type.Instantiate as Instantiate
import Compiler.Type.Type as Type exposing (Constraint(..), Type(..), mkFlexVar, nameToRigid)
import Data.Map as DMap
import Dict
import System.TypeCheck.IO as IO exposing (IO)



-- ====== Constraint Generation with ID Tracking ======


{-| Generate type constraints for a canonical module, tracking node IDs.

Handles regular declarations, ports, and effect managers by traversing the
module's structure and producing a constraint tree. Also builds a mapping
from expression/pattern IDs to solver variables for later type retrieval.

-}
constrainWithIds : Can.Module -> IO ( Constraint, NodeIds.NodeVarMap, NodeIds.SchemeBinderVars )
constrainWithIds canonical =
    constrainWithIdsDetailed canonical
        |> IO.map (\( con, state ) -> ( con, state.mapping, state.schemeBinderVars ))


{-| Generate type constraints with full node ID state including synthetic expr tracking.

This is the detailed version of `constrainWithIds` that returns the full `NodeIdState`,
including `syntheticExprIds` which tracks which expression IDs had synthetic placeholder
variables allocated (remaining Group B expressions: Str, Chr, Float, Unit, Shader). This metadata is useful for testing invariants
like POST\_001 and POST\_003.

-}
constrainWithIdsDetailed : Can.Module -> IO ( Constraint, NodeIds.NodeIdState )
constrainWithIdsDetailed =
    constrainWithIdsDetailedFrom NodeIds.emptyNodeIdState


{-| Erased (type-check-only) pathway.

Runs the shared generator with node recording disabled
(`NodeIds.erasedNodeIdState`), producing the same constraints as the standalone
erased generator did — without building the id→var side table or the Group B
synthetic placeholder vars — then discards the (empty) state.

-}
constrainErased : Can.Module -> IO Constraint
constrainErased canonical =
    constrainWithIdsDetailedFrom NodeIds.erasedNodeIdState canonical
        |> IO.map Tuple.first


constrainWithIdsDetailedFrom : NodeIds.NodeIdState -> Can.Module -> IO ( Constraint, NodeIds.NodeIdState )
constrainWithIdsDetailedFrom initState canonical =
    IO.withNodeIds initState (constrainModule canonical)


constrainModule : Can.Module -> IO Constraint
constrainModule (Can.Module canData) =
    case canData.effects of
        Can.NoEffects ->
            constrainDeclsWithVars canData.decls CSaveTheEnvironment

        Can.Ports ports ->
            Dict.foldr letPortWithVars (constrainDeclsWithVars canData.decls CSaveTheEnvironment) ports

        Can.Manager r0 r1 r2 manager ->
            case manager of
                Can.Cmd cmdName ->
                    constrainEffectsWithIds canData.name r0 r1 r2 manager
                        |> IO.andThen (\con -> constrainDeclsWithVars canData.decls con)
                        |> IO.andThen (\con -> letCmdWithVars canData.name cmdName con)

                Can.Sub subName ->
                    constrainEffectsWithIds canData.name r0 r1 r2 manager
                        |> IO.andThen (\con -> constrainDeclsWithVars canData.decls con)
                        |> IO.andThen (\con -> letSubWithVars canData.name subName con)

                Can.Fx cmdName subName ->
                    constrainEffectsWithIds canData.name r0 r1 r2 manager
                        |> IO.andThen (\con -> constrainDeclsWithVars canData.decls con)
                        |> IO.andThen (\con -> letSubWithVars canData.name subName con)
                        |> IO.andThen (\con -> letCmdWithVars canData.name cmdName con)



-- ====== Declaration Constraints with ID Tracking ======


type DeclItem
    = Single Can.Def
    | Rec Can.Def (List Can.Def)


flattenDecls : Can.Decls -> List DeclItem -> List DeclItem
flattenDecls decls acc =
    case decls of
        Can.Declare def rest ->
            flattenDecls rest (Single def :: acc)

        Can.DeclareRec def defs rest ->
            flattenDecls rest (Rec def defs :: acc)

        Can.SaveTheEnvironment ->
            List.reverse acc


{-| The module declaration spine: an explicit loop over the (unbounded)
declaration list, one declaration per iteration.
-}
constrainDeclsWithVars : Can.Decls -> Constraint -> IO Constraint
constrainDeclsWithVars decls finalConstraint =
    IO.loop constrainDeclsWithVarsStep
        ( List.reverse (flattenDecls decls []), finalConstraint )


constrainDeclsWithVarsStep :
    ( List DeclItem, Constraint )
    -> IO (IO.Step ( List DeclItem, Constraint ) Constraint)
constrainDeclsWithVarsStep ( items, bodyCon ) =
    case items of
        [] ->
            IO.pure (IO.Done bodyCon)

        (Single def) :: rest ->
            Expr.constrainDefWithIds Dict.empty def bodyCon
                |> IO.map (\con -> IO.Loop ( rest, con ))

        (Rec def defs) :: rest ->
            Expr.constrainRecursiveDefsWithIds Dict.empty (def :: defs) bodyCon
                |> IO.map (\con -> IO.Loop ( rest, con ))



-- ====== Port Constraints with ID Tracking ======


letPortWithVars : Name -> Can.Port -> IO Constraint -> IO Constraint
letPortWithVars name port_ makeConstraint =
    case port_ of
        Can.Incoming { freeVars, func } ->
            IO.traverseMapWithKey identity compare (\k _ -> nameToRigid k) (DMap.fromList identity (Dict.toList freeVars))
                |> IO.andThen
                    (\vars ->
                        Instantiate.fromSrcType (Dict.fromList (List.map (\( k, v ) -> ( k, VarN v )) (DMap.toList compare vars))) func
                            |> IO.andThen
                                (\tipe ->
                                    let
                                        header : Dict.Dict Name (A.Located Type)
                                        header =
                                            Dict.singleton name (A.At A.zero tipe)
                                    in
                                    makeConstraint
                                        |> IO.map (\con -> CLet (DMap.values compare vars) [] header CTrue con)
                                )
                    )

        Can.Outgoing { freeVars, func } ->
            IO.traverseMapWithKey identity compare (\k _ -> nameToRigid k) (DMap.fromList identity (Dict.toList freeVars))
                |> IO.andThen
                    (\vars ->
                        Instantiate.fromSrcType (Dict.fromList (List.map (\( k, v ) -> ( k, VarN v )) (DMap.toList compare vars))) func
                            |> IO.andThen
                                (\tipe ->
                                    let
                                        header : Dict.Dict Name (A.Located Type)
                                        header =
                                            Dict.singleton name (A.At A.zero tipe)
                                    in
                                    makeConstraint
                                        |> IO.map (\con -> CLet (DMap.values compare vars) [] header CTrue con)
                                )
                    )



-- ====== Effect Manager Helpers with ID Tracking ======


letCmdWithVars : IO.Canonical -> Name -> Constraint -> IO Constraint
letCmdWithVars home tipe constraint =
    mkFlexVar
        |> IO.map
            (\msgVar ->
                let
                    msg : Type
                    msg =
                        VarN msgVar

                    cmdType : Type
                    cmdType =
                        FunN (AppN home tipe [ msg ]) (AppN ModuleName.cmd Name.cmd [ msg ])

                    header : Dict.Dict Name (A.Located Type)
                    header =
                        Dict.singleton "command" (A.At A.zero cmdType)
                in
                CLet [ msgVar ] [] header CTrue constraint
            )


letSubWithVars : IO.Canonical -> Name -> Constraint -> IO Constraint
letSubWithVars home tipe constraint =
    mkFlexVar
        |> IO.map
            (\msgVar ->
                let
                    msg : Type
                    msg =
                        VarN msgVar

                    subType : Type
                    subType =
                        FunN (AppN home tipe [ msg ]) (AppN ModuleName.sub Name.sub [ msg ])

                    header : Dict.Dict Name (A.Located Type)
                    header =
                        Dict.singleton "subscription" (A.At A.zero subType)
                in
                CLet [ msgVar ] [] header CTrue constraint
            )


constrainEffectsWithIds : IO.Canonical -> A.Region -> A.Region -> A.Region -> Can.Manager -> IO Constraint
constrainEffectsWithIds home r0 r1 r2 manager =
    mkFlexVar
        |> IO.andThen
            (\s0 ->
                mkFlexVar
                    |> IO.andThen
                        (\s1 ->
                            mkFlexVar
                                |> IO.andThen
                                    (\s2 ->
                                        mkFlexVar
                                            |> IO.andThen
                                                (\m1 ->
                                                    mkFlexVar
                                                        |> IO.andThen
                                                            (\m2 ->
                                                                mkFlexVar
                                                                    |> IO.andThen
                                                                        (\sm1 ->
                                                                            mkFlexVar
                                                                                |> IO.andThen
                                                                                    (\sm2 ->
                                                                                        let
                                                                                            state0 : Type
                                                                                            state0 =
                                                                                                VarN s0

                                                                                            state1 : Type
                                                                                            state1 =
                                                                                                VarN s1

                                                                                            state2 : Type
                                                                                            state2 =
                                                                                                VarN s2

                                                                                            msg1 : Type
                                                                                            msg1 =
                                                                                                VarN m1

                                                                                            msg2 : Type
                                                                                            msg2 =
                                                                                                VarN m2

                                                                                            self1 : Type
                                                                                            self1 =
                                                                                                VarN sm1

                                                                                            self2 : Type
                                                                                            self2 =
                                                                                                VarN sm2

                                                                                            onSelfMsg : Type
                                                                                            onSelfMsg =
                                                                                                Type.funType (router msg2 self2) (Type.funType self2 (Type.funType state2 (task state2)))

                                                                                            routerArg : Type
                                                                                            routerArg =
                                                                                                router msg1 self1

                                                                                            stateToTask : Type
                                                                                            stateToTask =
                                                                                                Type.funType state1 (task state1)

                                                                                            onEffects : Type
                                                                                            onEffects =
                                                                                                case manager of
                                                                                                    Can.Cmd cmd ->
                                                                                                        Type.funType routerArg
                                                                                                            (Type.funType (effectList home cmd msg1) stateToTask)

                                                                                                    Can.Sub sub ->
                                                                                                        Type.funType routerArg
                                                                                                            (Type.funType (effectList home sub msg1) stateToTask)

                                                                                                    Can.Fx cmd sub ->
                                                                                                        Type.funType routerArg
                                                                                                            (Type.funType (effectList home cmd msg1)
                                                                                                                (Type.funType (effectList home sub msg1) stateToTask)
                                                                                                            )

                                                                                            effectCons : Constraint
                                                                                            effectCons =
                                                                                                CAnd
                                                                                                    [ CLocal r0 "init" (E.NoExpectation (task state0))
                                                                                                    , CLocal r1 "onEffects" (E.NoExpectation onEffects)
                                                                                                    , CLocal r2 "onSelfMsg" (E.NoExpectation onSelfMsg)
                                                                                                    , CEqual r1 E.Effects state0 (E.NoExpectation state1)
                                                                                                    , CEqual r2 E.Effects state0 (E.NoExpectation state2)
                                                                                                    , CEqual r2 E.Effects self1 (E.NoExpectation self2)
                                                                                                    ]
                                                                                        in
                                                                                        checkMapWithIds manager home [ s0, s1, s2, m1, m2, sm1, sm2 ] effectCons
                                                                                    )
                                                                        )
                                                            )
                                                )
                                    )
                        )
            )


checkMapWithIds : Can.Manager -> IO.Canonical -> List IO.Variable -> Constraint -> IO Constraint
checkMapWithIds manager home vars effectCons =
    case manager of
        Can.Cmd cmd ->
            checkMapHelperWithIds "cmdMap" home cmd CSaveTheEnvironment
                |> IO.map (CLet [] vars Dict.empty effectCons)

        Can.Sub sub ->
            checkMapHelperWithIds "subMap" home sub CSaveTheEnvironment
                |> IO.map (CLet [] vars Dict.empty effectCons)

        Can.Fx cmd sub ->
            checkMapHelperWithIds "subMap" home sub CSaveTheEnvironment
                |> IO.andThen (checkMapHelperWithIds "cmdMap" home cmd)
                |> IO.map (CLet [] vars Dict.empty effectCons)


checkMapHelperWithIds : Name -> IO.Canonical -> Name -> Constraint -> IO Constraint
checkMapHelperWithIds name home tipe constraint =
    mkFlexVar
        |> IO.andThen
            (\a ->
                mkFlexVar
                    |> IO.map
                        (\b ->
                            let
                                mapType : Type
                                mapType =
                                    toMapType home tipe (VarN a) (VarN b)

                                mapCon : Constraint
                                mapCon =
                                    CLocal A.zero name (E.NoExpectation mapType)
                            in
                            CLet [ a, b ] [] Dict.empty mapCon constraint
                        )
            )


effectList : IO.Canonical -> Name -> Type -> Type
effectList home name msg =
    AppN ModuleName.list Name.list [ AppN home name [ msg ] ]


task : Type -> Type
task answer =
    AppN ModuleName.platform Name.task [ Type.never, answer ]


router : Type -> Type -> Type
router msg self =
    AppN ModuleName.platform Name.router [ msg, self ]


toMapType : IO.Canonical -> Name -> Type -> Type -> Type
toMapType home tipe a b =
    Type.funType (Type.funType a b) (Type.funType (AppN home tipe [ a ]) (AppN home tipe [ b ]))
