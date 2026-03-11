module Compiler.Type.Constrain.Erased.Module exposing (constrain)

{-| Generates type constraints for Elm modules during type checking (Erased pathway).

This is the entry point for constraint generation. It traverses the module's
declarations, effects (ports, managers), and builds a constraint tree that
the constraint solver will use to infer or verify types.


# Constraint Generation

@docs constrain

-}

import Compiler.AST.Canonical as Can
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Reporting.Annotation as A
import Compiler.Reporting.Error.Type as E
import Compiler.Type.Constrain.Erased.Expression as Expr
import Compiler.Type.Constrain.Erased.Program as Prog exposing (Prog)
import Compiler.Type.Instantiate as Instantiate
import Compiler.Type.Type as Type exposing (Constraint(..), Type(..), mkFlexVar, nameToRigid)
import Data.Map as DMap
import Dict
import System.TypeCheck.IO as IO exposing (IO)



-- ====== Constraint Generation ======


{-| Generate type constraints for a canonical module.

Handles regular declarations, ports, and effect managers by traversing the
module's structure and producing a constraint tree that represents all type
relationships.

-}
constrain : Can.Module -> IO Constraint
constrain (Can.Module canData) =
    case canData.effects of
        Can.NoEffects ->
            constrainDecls canData.decls CSaveTheEnvironment

        Can.Ports ports ->
            Dict.foldr letPort (constrainDecls canData.decls CSaveTheEnvironment) ports

        Can.Manager r0 r1 r2 manager ->
            case manager of
                Can.Cmd cmdName ->
                    constrainEffects canData.name r0 r1 r2 manager
                        |> IO.andThen (constrainDecls canData.decls)
                        |> IO.andThen (letCmd canData.name cmdName)

                Can.Sub subName ->
                    constrainEffects canData.name r0 r1 r2 manager
                        |> IO.andThen (constrainDecls canData.decls)
                        |> IO.andThen (letSub canData.name subName)

                Can.Fx cmdName subName ->
                    constrainEffects canData.name r0 r1 r2 manager
                        |> IO.andThen (constrainDecls canData.decls)
                        |> IO.andThen (letSub canData.name subName)
                        |> IO.andThen (letCmd canData.name cmdName)



-- ====== Declaration Constraints ======
-- Generates constraints for all module declarations.


constrainDecls : Can.Decls -> Constraint -> IO Constraint
constrainDecls decls finalConstraint =
    constrainDeclsHelp decls finalConstraint identity


constrainDeclsHelp : Can.Decls -> Constraint -> (IO Constraint -> IO Constraint) -> IO Constraint
constrainDeclsHelp decls finalConstraint cont =
    case decls of
        Can.Declare def otherDecls ->
            constrainDeclsHelp otherDecls finalConstraint (IO.andThen (Expr.constrainDef DMap.empty def) >> cont)

        Can.DeclareRec def defs otherDecls ->
            constrainDeclsHelp otherDecls finalConstraint (IO.andThen (Expr.constrainRecursiveDefs DMap.empty (def :: defs)) >> cont)

        Can.SaveTheEnvironment ->
            cont (IO.pure finalConstraint)



-- ====== Port Constraints ======
-- Wraps a port's type in a CLet constraint, instantiating free type variables.


letPort : Name -> Can.Port -> IO Constraint -> IO Constraint
letPort name port_ makeConstraint =
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
                                    IO.map (CLet (DMap.values compare vars) [] header CTrue) makeConstraint
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
                                    IO.map (CLet (DMap.values compare vars) [] header CTrue) makeConstraint
                                )
                    )



-- ====== EFFECT MANAGER HELPERS ======


letCmd : IO.Canonical -> Name -> Constraint -> IO Constraint
letCmd home tipe constraint =
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
                CLet [ msgVar ] [] header CTrue constraint
            )


letSub : IO.Canonical -> Name -> Constraint -> IO Constraint
letSub home tipe constraint =
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
                CLet [ msgVar ] [] header CTrue constraint
            )


constrainEffects : IO.Canonical -> A.Region -> A.Region -> A.Region -> Can.Manager -> IO Constraint
constrainEffects home r0 r1 r2 manager =
    constrainEffectsProg home r0 r1 r2 manager |> Prog.run


{-| Stack-safe DSL version of constrainEffects.
Uses the Program DSL to avoid deeply nested mkFlexVar calls.
-}
constrainEffectsProg : IO.Canonical -> A.Region -> A.Region -> A.Region -> Can.Manager -> Prog Constraint
constrainEffectsProg home r0 r1 r2 manager =
    Prog.opMkFlexVar
        |> Prog.andThen
            (\s0 ->
                Prog.opMkFlexVar
                    |> Prog.andThen
                        (\s1 ->
                            Prog.opMkFlexVar
                                |> Prog.andThen
                                    (\s2 ->
                                        Prog.opMkFlexVar
                                            |> Prog.andThen
                                                (\m1 ->
                                                    Prog.opMkFlexVar
                                                        |> Prog.andThen
                                                            (\m2 ->
                                                                Prog.opMkFlexVar
                                                                    |> Prog.andThen
                                                                        (\sm1 ->
                                                                            Prog.opMkFlexVar
                                                                                |> Prog.andThen
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
                                                                                        checkMapProg manager home [ s0, s1, s2, m1, m2, sm1, sm2 ] effectCons
                                                                                    )
                                                                        )
                                                            )
                                                )
                                    )
                        )
            )


{-| Build the final constraint with the appropriate map checks.
-}
checkMapProg : Can.Manager -> IO.Canonical -> List IO.Variable -> Constraint -> Prog Constraint
checkMapProg manager home vars effectCons =
    case manager of
        Can.Cmd cmd ->
            checkMapProgHelper "cmdMap" home cmd CSaveTheEnvironment
                |> Prog.map (CLet [] vars DMap.empty effectCons)

        Can.Sub sub ->
            checkMapProgHelper "subMap" home sub CSaveTheEnvironment
                |> Prog.map (CLet [] vars DMap.empty effectCons)

        Can.Fx cmd sub ->
            checkMapProgHelper "subMap" home sub CSaveTheEnvironment
                |> Prog.andThen (checkMapProgHelper "cmdMap" home cmd)
                |> Prog.map (CLet [] vars DMap.empty effectCons)


{-| Stack-safe version of checkMap using the DSL.
-}
checkMapProgHelper : Name -> IO.Canonical -> Name -> Constraint -> Prog Constraint
checkMapProgHelper name home tipe constraint =
    Prog.opMkFlexVar
        |> Prog.andThen
            (\a ->
                Prog.opMkFlexVar
                    |> Prog.map
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
