module Compiler.Type.Constrain.Typed.Module exposing (constrainWithIds, constrainWithIdsDetailed, constrainErased)

{-| The type checker needs one constraint for a whole module, and this module
builds it, optionally recording which solver variable stands for each
expression and pattern.

A _constraint_ is the tree of type facts that `Compiler.Type.Solve` makes true;
its constructors are described in `Compiler.Type.Type`. The _node-id record_ is
the side table, kept in the type checker's state, that maps expression and
pattern ids to solver variables so that types can be read back after solving;
`Compiler.Type.Constrain.Typed.NodeIds` describes it. Each of the three entry
points runs the same generator, inside `IO.withNodeIds`, and they differ only in
whether that record is kept and how much of it is returned.

The shape of the tree follows from one fact: a top-level declaration can use
the declarations before it, and the solver reports as the module's annotations
the names in scope at the `CSaveTheEnvironment` leaf. So the declarations are
nested in source order, the first outermost, and the leaf sits inside all of
them. Ports wrap the declarations from outside, each bound in a `CLet` with its
annotation's type variables as rigid variables. In an effect module the checks
on `init`, `onEffects`, `onSelfMsg`, `cmdMap` and `subMap` sit inside the
declarations, around the leaf, so that they can refer to them, and `command`
and `subscription` are bound outside the declarations.


# Constraint Generation with ID Tracking

@docs constrainWithIds, constrainWithIdsDetailed, constrainErased

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.TypeVars as Vars
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


{-| Returns the constraint for `canonical`, the map from expression and pattern
ids to their solver variables, and the scheme binder variables recorded for
annotated definitions.
-}
constrainWithIds : Can.Module -> IO ( Constraint, NodeIds.NodeVarMap, NodeIds.SchemeBinderVars )
constrainWithIds canonical =
    constrainWithIdsDetailed canonical
        |> IO.map (\( con, state ) -> ( con, state.mapping, state.schemeBinderVars ))


{-| Returns the constraint for a module together with the whole node-id record,
recording on.

Beyond what `constrainWithIds` returns, the record carries `syntheticExprIds`:
the expressions given a placeholder variable rather than one their constraint
produced, which lets a caller tell a placeholder from a real polymorphic
variable. `Compiler.Type.Constrain.Typed.Expression` says which expressions
get one.

-}
constrainWithIdsDetailed : Can.Module -> IO ( Constraint, NodeIds.NodeIdState )
constrainWithIdsDetailed =
    constrainWithIdsDetailedFrom NodeIds.emptyNodeIdState


{-| Returns the constraint for a module with recording off, for checking types
without reading them back.

The tree is not identical to the one `constrainWithIds` builds: the placeholder
variables of `syntheticExprIds` are not made, but checking is equivalent.

-}
constrainErased : Can.Module -> IO Constraint
constrainErased canonical =
    constrainWithIdsDetailedFrom NodeIds.erasedNodeIdState canonical
        |> IO.map Tuple.first


{-| Runs the generator on `canonical` starting from the node-id record
`initState`, and returns the constraint with the record as it ends.
-}
constrainWithIdsDetailedFrom : NodeIds.NodeIdState -> Can.Module -> IO ( Constraint, NodeIds.NodeIdState )
constrainWithIdsDetailedFrom initState canonical =
    IO.withNodeIds initState (constrainModule canonical)


{-| Builds the constraint for a module: its declarations, wrapped by its ports
or by its effect manager's checks and bindings, as the module docstring
describes.
-}
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


{-| One top-level declaration of the canonical declaration list: a single
definition, or a group of mutually recursive definitions.
-}
type DeclItem
    = Single Can.Def
    | Rec Can.Def (List Can.Def)


{-| Returns the declarations of `decls` as a list in source order, after those
already in `acc` in reverse.
-}
flattenDecls : Can.Decls -> List DeclItem -> List DeclItem
flattenDecls decls acc =
    case decls of
        Can.Declare def rest ->
            flattenDecls rest (Single def :: acc)

        Can.DeclareRec def defs rest ->
            flattenDecls rest (Rec def defs :: acc)

        Can.SaveTheEnvironment ->
            List.reverse acc


{-| Returns `finalConstraint` nested inside the constraints of every declaration
in `decls`, the first declaration outermost.
-}
constrainDeclsWithVars : Can.Decls -> Constraint -> IO Constraint
constrainDeclsWithVars decls finalConstraint s0 =
    constrainDeclsGo (List.reverse (flattenDecls decls [])) finalConstraint s0


{-| Wraps `bodyCon` in the constraint of each of `items` in turn, so the last
item becomes the outermost.

It is tail-recursive, so the module's number of declarations does not deepen
the stack.

-}
constrainDeclsGo : List DeclItem -> Constraint -> IO.State -> ( IO.State, Constraint )
constrainDeclsGo items bodyCon s0 =
    case items of
        [] ->
            ( s0, bodyCon )

        (Single def) :: rest ->
            let
                ( s1, con ) =
                    Expr.constrainDefWithIds Dict.empty def bodyCon s0
            in
            constrainDeclsGo rest con s1

        (Rec def defs) :: rest ->
            let
                ( s1, con ) =
                    Expr.constrainRecursiveDefsWithIds Dict.empty (def :: defs) bodyCon s0
            in
            constrainDeclsGo rest con s1



-- ====== Port Constraints with ID Tracking ======


{-| Wraps the constraint `makeConstraint` produces in a `CLet` binding the port
`name` to its annotated type, with the annotation's type variables made rigid.
Incoming and outgoing ports are treated alike.
-}
letPortWithVars : Name -> Can.Port -> IO Constraint -> IO Constraint
letPortWithVars name port_ makeConstraint =
    case port_ of
        Can.Incoming { freeVars, func } ->
            IO.traverseMapWithKey identity (\k _ -> nameToRigid k) (DMap.fromList identity (Dict.toList freeVars))
                |> IO.andThen
                    (\vars ->
                        Instantiate.fromSrcType (Dict.fromList (List.map (\( k, v ) -> ( k, VarN v )) (DMap.toList vars))) func
                            |> IO.andThen
                                (\tipe ->
                                    let
                                        header : Dict.Dict Name (A.Located Type)
                                        header =
                                            Dict.singleton name (A.At A.zero tipe)
                                    in
                                    makeConstraint
                                        |> IO.map (\con -> CLet (DMap.values vars) [] header CTrue con)
                                )
                    )

        Can.Outgoing { freeVars, func } ->
            IO.traverseMapWithKey identity (\k _ -> nameToRigid k) (DMap.fromList identity (Dict.toList freeVars))
                |> IO.andThen
                    (\vars ->
                        Instantiate.fromSrcType (Dict.fromList (List.map (\( k, v ) -> ( k, VarN v )) (DMap.toList vars))) func
                            |> IO.andThen
                                (\tipe ->
                                    let
                                        header : Dict.Dict Name (A.Located Type)
                                        header =
                                            Dict.singleton name (A.At A.zero tipe)
                                    in
                                    makeConstraint
                                        |> IO.map (\con -> CLet (DMap.values vars) [] header CTrue con)
                                )
                    )



-- ====== Effect Manager Helpers with ID Tracking ======


{-| Wraps `constraint` in a `CLet` binding `command` to a function from the
module's command type `tipe` to `Cmd`, polymorphic in the message type.
-}
letCmdWithVars : ModuleName.Canonical -> Name -> Constraint -> IO Constraint
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


{-| Wraps `constraint` in a `CLet` binding `subscription` to a function from
the module's subscription type `tipe` to `Sub`, polymorphic in the message
type.
-}
letSubWithVars : ModuleName.Canonical -> Name -> Constraint -> IO Constraint
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


{-| Returns the checks an effect manager's definitions must pass, ending in a
`CSaveTheEnvironment` leaf.

`init`, `onEffects` and `onSelfMsg` (at regions `r0`, `r1` and `r2`) must have
the shapes `Platform` requires of them, with one state type shared by all three
and one self-message type shared by `onEffects` and `onSelfMsg`. Inside those
checks, `checkMapWithIds` adds the checks on `cmdMap` and `subMap`.

-}
constrainEffectsWithIds : ModuleName.Canonical -> A.Region -> A.Region -> A.Region -> Can.Manager -> IO Constraint
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


{-| Wraps `effectCons` and the `cmdMap` or `subMap` checks that `manager` needs
(both for a manager of commands and subscriptions) in a `CLet` introducing
`vars` as flexible variables.
-}
checkMapWithIds : Can.Manager -> ModuleName.Canonical -> List Vars.Variable -> Constraint -> IO Constraint
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


{-| Wraps `constraint` in a check that the local value `name` has the type of a
map over the effect type `tipe`, polymorphic in both of its type variables.
-}
checkMapHelperWithIds : Name -> ModuleName.Canonical -> Name -> Constraint -> IO Constraint
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


{-| Returns the type of a list of the effect type `name` of module `home`,
applied to `msg`.
-}
effectList : ModuleName.Canonical -> Name -> Type -> Type
effectList home name msg =
    AppN ModuleName.list Name.list [ AppN home name [ msg ] ]


{-| Returns the type of a `Platform.Task` that cannot fail and succeeds with
`answer`.
-}
task : Type -> Type
task answer =
    AppN ModuleName.platform Name.task [ Type.never, answer ]


{-| Returns the type `Platform.Router msg self`.
-}
router : Type -> Type -> Type
router msg self =
    AppN ModuleName.platform Name.router [ msg, self ]


{-| Returns the type `(a -> b) -> tipe a -> tipe b` for the type `tipe` of
module `home`.
-}
toMapType : ModuleName.Canonical -> Name -> Type -> Type -> Type
toMapType home tipe a b =
    Type.funType (Type.funType a b) (Type.funType (AppN home tipe [ a ]) (AppN home tipe [ b ]))
