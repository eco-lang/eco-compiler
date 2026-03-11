module Compiler.Type.Constrain.Typed.Module exposing (constrainWithIds, constrainWithIdsDetailed)

{-| Generates type constraints for Elm modules during type checking (Typed pathway).

This is the entry point for constraint generation with ID tracking. It traverses
the module's declarations, effects (ports, managers), and builds a constraint tree
while tracking node IDs to solver variables for later type retrieval.


# Constraint Generation with ID Tracking

@docs constrainWithIds, constrainWithIdsDetailed

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Type as E
import Compiler.Type.Constrain.Typed.Expression as Expr
import Compiler.Type.Constrain.Typed.NodeIds as NodeIds
import Compiler.Type.Constrain.Typed.Program as Prog exposing (ProgS)
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
constrainWithIds : Can.Module -> IO ( Constraint, NodeIds.NodeVarMap )
constrainWithIds canonical =
    constrainWithIdsDetailed canonical
        |> IO.map (\( con, state ) -> ( con, state.mapping ))


{-| Generate type constraints with full node ID state including synthetic expr tracking.

This is the detailed version of `constrainWithIds` that returns the full `NodeIdState`,
including `syntheticExprIds` which tracks which expression IDs had synthetic placeholder
variables allocated (Group B expressions). This metadata is useful for testing invariants
like POST\_001 and POST\_003.

-}
constrainWithIdsDetailed : Can.Module -> IO ( Constraint, NodeIds.NodeIdState )
constrainWithIdsDetailed (Can.Module canData) =
    case canData.effects of
        Can.NoEffects ->
            constrainDeclsWithVars canData.decls CSaveTheEnvironment Expr.emptyExprIdState

        Can.Ports ports ->
            Dict.foldr letPortWithVars (constrainDeclsWithVars canData.decls CSaveTheEnvironment Expr.emptyExprIdState) ports

        Can.Manager r0 r1 r2 manager ->
            case manager of
                Can.Cmd cmdName ->
                    constrainEffectsWithIds canData.name r0 r1 r2 manager Expr.emptyExprIdState
                        |> IO.andThen (\( con, state ) -> constrainDeclsWithVars canData.decls con state)
                        |> IO.andThen (\( con, state ) -> letCmdWithVars canData.name cmdName con state)

                Can.Sub subName ->
                    constrainEffectsWithIds canData.name r0 r1 r2 manager Expr.emptyExprIdState
                        |> IO.andThen (\( con, state ) -> constrainDeclsWithVars canData.decls con state)
                        |> IO.andThen (\( con, state ) -> letSubWithVars canData.name subName con state)

                Can.Fx cmdName subName ->
                    constrainEffectsWithIds canData.name r0 r1 r2 manager Expr.emptyExprIdState
                        |> IO.andThen (\( con, state ) -> constrainDeclsWithVars canData.decls con state)
                        |> IO.andThen (\( con, state ) -> letSubWithVars canData.name subName con state)
                        |> IO.andThen (\( con, state ) -> letCmdWithVars canData.name cmdName con state)



-- ====== Declaration Constraints with ID Tracking ======


constrainDeclsWithVars : Can.Decls -> Constraint -> Expr.ExprIdState -> IO ( Constraint, Expr.ExprIdState )
constrainDeclsWithVars decls finalConstraint state =
    constrainDeclsWithVarsHelp decls finalConstraint state


constrainDeclsWithVarsHelp : Can.Decls -> Constraint -> Expr.ExprIdState -> IO ( Constraint, Expr.ExprIdState )
constrainDeclsWithVarsHelp decls finalConstraint state =
    case decls of
        Can.Declare def otherDecls ->
            constrainDeclsWithVarsHelp otherDecls finalConstraint state
                |> IO.andThen
                    (\( bodyCon, newState ) ->
                        Expr.constrainDefWithIds DMap.empty def bodyCon newState
                    )

        Can.DeclareRec def defs otherDecls ->
            constrainDeclsWithVarsHelp otherDecls finalConstraint state
                |> IO.andThen
                    (\( bodyCon, newState ) ->
                        Expr.constrainRecursiveDefsWithIds DMap.empty (def :: defs) bodyCon newState
                    )

        Can.SaveTheEnvironment ->
            IO.pure ( finalConstraint, state )



-- ====== Port Constraints with ID Tracking ======


letPortWithVars : Name -> Can.Port -> IO ( Constraint, Expr.ExprIdState ) -> IO ( Constraint, Expr.ExprIdState )
letPortWithVars name port_ makeConstraint =
    case port_ of
        Can.Incoming { freeVars, func } ->
            IO.traverseMapWithKey identity compare (\k _ -> nameToRigid k) (DMap.fromList identity (Dict.toList freeVars))
                |> IO.andThen
                    (\vars ->
                        Instantiate.fromSrcType (DMap.map (\_ v -> VarN v) vars) func
                            |> IO.andThen
                                (\tipe ->
                                    let
                                        header : DMap.Dict String Name (A.Located Type)
                                        header =
                                            DMap.singleton identity name (A.At A.zero tipe)
                                    in
                                    makeConstraint
                                        |> IO.map (\( con, state ) -> ( CLet (DMap.values compare vars) [] header CTrue con, state ))
                                )
                    )

        Can.Outgoing { freeVars, func } ->
            IO.traverseMapWithKey identity compare (\k _ -> nameToRigid k) (DMap.fromList identity (Dict.toList freeVars))
                |> IO.andThen
                    (\vars ->
                        Instantiate.fromSrcType (DMap.map (\_ v -> VarN v) vars) func
                            |> IO.andThen
                                (\tipe ->
                                    let
                                        header : DMap.Dict String Name (A.Located Type)
                                        header =
                                            DMap.singleton identity name (A.At A.zero tipe)
                                    in
                                    makeConstraint
                                        |> IO.map (\( con, state ) -> ( CLet (DMap.values compare vars) [] header CTrue con, state ))
                                )
                    )



-- ====== Effect Manager Helpers with ID Tracking ======


letCmdWithVars : IO.Canonical -> Name -> Constraint -> Expr.ExprIdState -> IO ( Constraint, Expr.ExprIdState )
letCmdWithVars home tipe constraint state =
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

                    header : DMap.Dict String Name (A.Located Type)
                    header =
                        DMap.singleton identity "command" (A.At A.zero cmdType)
                in
                ( CLet [ msgVar ] [] header CTrue constraint, state )
            )


letSubWithVars : IO.Canonical -> Name -> Constraint -> Expr.ExprIdState -> IO ( Constraint, Expr.ExprIdState )
letSubWithVars home tipe constraint state =
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

                    header : DMap.Dict String Name (A.Located Type)
                    header =
                        DMap.singleton identity "subscription" (A.At A.zero subType)
                in
                ( CLet [ msgVar ] [] header CTrue constraint, state )
            )


constrainEffectsWithIds : IO.Canonical -> A.Region -> A.Region -> A.Region -> Can.Manager -> Expr.ExprIdState -> IO ( Constraint, Expr.ExprIdState )
constrainEffectsWithIds home r0 r1 r2 manager state =
    Prog.runS state (constrainEffectsWithIdsProg home r0 r1 r2 manager)


constrainEffectsWithIdsProg : IO.Canonical -> A.Region -> A.Region -> A.Region -> Can.Manager -> ProgS Expr.ExprIdState Constraint
constrainEffectsWithIdsProg home r0 r1 r2 manager =
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\s0 ->
                Prog.opMkFlexVarS
                    |> Prog.andThenS
                        (\s1 ->
                            Prog.opMkFlexVarS
                                |> Prog.andThenS
                                    (\s2 ->
                                        Prog.opMkFlexVarS
                                            |> Prog.andThenS
                                                (\m1 ->
                                                    Prog.opMkFlexVarS
                                                        |> Prog.andThenS
                                                            (\m2 ->
                                                                Prog.opMkFlexVarS
                                                                    |> Prog.andThenS
                                                                        (\sm1 ->
                                                                            Prog.opMkFlexVarS
                                                                                |> Prog.andThenS
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
                                                                                        checkMapWithIdsProg manager home [ s0, s1, s2, m1, m2, sm1, sm2 ] effectCons
                                                                                    )
                                                                        )
                                                            )
                                                )
                                    )
                        )
            )


checkMapWithIdsProg : Can.Manager -> IO.Canonical -> List IO.Variable -> Constraint -> ProgS Expr.ExprIdState Constraint
checkMapWithIdsProg manager home vars effectCons =
    case manager of
        Can.Cmd cmd ->
            checkMapHelperWithIdsProg "cmdMap" home cmd CSaveTheEnvironment
                |> Prog.mapS (CLet [] vars DMap.empty effectCons)

        Can.Sub sub ->
            checkMapHelperWithIdsProg "subMap" home sub CSaveTheEnvironment
                |> Prog.mapS (CLet [] vars DMap.empty effectCons)

        Can.Fx cmd sub ->
            checkMapHelperWithIdsProg "subMap" home sub CSaveTheEnvironment
                |> Prog.andThenS (checkMapHelperWithIdsProg "cmdMap" home cmd)
                |> Prog.mapS (CLet [] vars DMap.empty effectCons)


checkMapHelperWithIdsProg : Name -> IO.Canonical -> Name -> Constraint -> ProgS Expr.ExprIdState Constraint
checkMapHelperWithIdsProg name home tipe constraint =
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\a ->
                Prog.opMkFlexVarS
                    |> Prog.mapS
                        (\b ->
                            let
                                mapType : Type
                                mapType =
                                    toMapType home tipe (VarN a) (VarN b)

                                mapCon : Constraint
                                mapCon =
                                    CLocal A.zero name (E.NoExpectation mapType)
                            in
                            CLet [ a, b ] [] DMap.empty mapCon constraint
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
