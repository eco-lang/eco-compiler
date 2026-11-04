module TestLogic.Type.NodeTypeVarNamesDistinct exposing
    ( Collision
    , expectNamesDistinct
    , nameCollisions
    )

{-| A check that, within one top-level definition, one type variable name in
the solver's node types stands for one solver variable.

Monomorphization identifies type variables by name within a definition
(`Compiler.PreMono.AssignMVarIds.ensureBinder`). If two different variables
shared a name there, a let-bound helper could be specialized at the type of an
unrelated variable. The names come from two places.
`Compiler.Type.Solve.runWithIds` runs `Type.toAnnotation` on every top-level
definition, which names the variables of that definition's annotation, and
those variables keep their names in the node types.
`Compiler.Type.Type.toCanTypeBatch` then names every other node variable in
one shared naming scope, and is handed the annotations' names so that it gives
none of them to another variable.

`expectNamesDistinct` type checks a module with
`TestLogic.TestPipeline.runToTypeCheck`, resolves the solver variable of every
node whose type is a bare type variable to its union-find root
(`Compiler.Type.SolverRoots.normalizeNodeVars`), and fails if, within one
top-level definition, a name is the type of nodes with different roots. The
nodes of a definition are its argument patterns and every expression and
pattern of its body, those of let-bound definitions included. A name shared
between two top-level definitions is allowed, since each definition is checked
on its own. `nameCollisions` returns the collisions themselves, for a test that
needs to tell them apart.

Among what is not checked: node types that are not a bare type variable (a
variable nested inside a function or tuple type is not checked), and names
across definitions.

-}

import Array
import Compiler.Core.Annotation as A
import Compiler.IR.Canonical as Can
import Compiler.IR.Source as Src
import Compiler.Type.SolverRoots as SolverRoots
import Data.Map as DMap
import Dict
import Expect
import TestLogic.TestPipeline as Pipeline


{-| One name that is the bare type of nodes with different solver roots inside
one top-level definition: the definition, the name, and a line describing the
roots and their node ids.
-}
type alias Collision =
    { definition : String
    , name : String
    , description : String
    }


{-| Fails when, inside one top-level definition, one name is the bare type of
nodes whose solver variables have different roots, listing the definition,
the name and the node ids of each root.
-}
expectNamesDistinct : Src.Module -> Expect.Expectation
expectNamesDistinct srcModule =
    case nameCollisions srcModule of
        Err msg ->
            Expect.fail msg

        Ok [] ->
            Expect.pass

        Ok collisions ->
            Expect.fail (String.join "\n" (List.map .description collisions))


{-| Type checks `srcModule` and returns every `Collision` in it, or the
pipeline's message when type checking fails.
-}
nameCollisions : Src.Module -> Result String (List Collision)
nameCollisions srcModule =
    case Pipeline.runToTypeCheck srcModule of
        Err msg ->
            Err msg

        Ok result ->
            let
                roots =
                    SolverRoots.normalizeNodeVars result.solverState result.nodeVars

                collisionsIn ( defName, ids ) =
                    List.foldl
                        (\nodeId acc ->
                            case ( Array.get nodeId result.nodeTypes |> Maybe.andThen identity, Array.get nodeId roots |> Maybe.andThen identity ) of
                                ( Just (Can.TVar name), Just root ) ->
                                    Dict.update name
                                        (\m ->
                                            Just
                                                (Dict.update (Debug.toString root)
                                                    (\rootIds -> Just (nodeId :: Maybe.withDefault [] rootIds))
                                                    (Maybe.withDefault Dict.empty m)
                                                )
                                        )
                                        acc

                                _ ->
                                    acc
                        )
                        Dict.empty
                        ids
                        |> Dict.toList
                        |> List.filter (\( _, rs ) -> Dict.size rs > 1)
                        |> List.map
                            (\( name, rs ) ->
                                { definition = defName
                                , name = name
                                , description =
                                    defName
                                        ++ ": '"
                                        ++ name
                                        ++ "' names "
                                        ++ String.fromInt (Dict.size rs)
                                        ++ " different variables: "
                                        ++ String.join "; "
                                            (List.map (\( r, rootIds ) -> r ++ " at nodes " ++ String.join "," (List.map String.fromInt (List.sort rootIds))) (Dict.toList rs))
                                }
                            )
            in
            Ok (List.concatMap collisionsIn (topLevelNodeIds result.canonical))


{-| Returns, for each top-level definition of the module, its name and the
node ids of its expressions and patterns, argument patterns included.
-}
topLevelNodeIds : Can.Module -> List ( String, List Int )
topLevelNodeIds (Can.Module modData) =
    let
        defIds def =
            case def of
                Can.Def (A.At _ name) args body ->
                    ( name, List.concatMap patternIds args ++ exprIds body )

                Can.TypedDef (A.At _ name) _ args body _ ->
                    ( name, List.concatMap (Tuple.first >> patternIds) args ++ exprIds body )

        go decls =
            case decls of
                Can.Declare def rest ->
                    defIds def :: go rest

                Can.DeclareRec def defs rest ->
                    List.map defIds (def :: defs) ++ go rest

                Can.SaveTheEnvironment ->
                    []
    in
    go modData.decls


{-| Returns the node id of an expression and of every expression and pattern
inside it, including those of let-bound definitions.
-}
exprIds : Can.Expr -> List Int
exprIds (A.At _ info) =
    let
        innerDefIds def =
            case def of
                Can.Def _ args body ->
                    List.concatMap patternIds args ++ exprIds body

                Can.TypedDef _ _ args body _ ->
                    List.concatMap (Tuple.first >> patternIds) args ++ exprIds body
    in
    info.id
        :: (case info.node of
                Can.List es ->
                    List.concatMap exprIds es

                Can.Negate e ->
                    exprIds e

                Can.Binop _ _ _ _ l r ->
                    exprIds l ++ exprIds r

                Can.Lambda ps body ->
                    List.concatMap patternIds ps ++ exprIds body

                Can.Call f args ->
                    List.concatMap exprIds (f :: args)

                Can.If branches final ->
                    List.concatMap (\( c, t ) -> exprIds c ++ exprIds t) branches ++ exprIds final

                Can.Let def body ->
                    innerDefIds def ++ exprIds body

                Can.LetRec defs body ->
                    List.concatMap innerDefIds defs ++ exprIds body

                Can.LetDestruct p e body ->
                    patternIds p ++ exprIds e ++ exprIds body

                Can.Case e branches ->
                    exprIds e ++ List.concatMap (\(Can.CaseBranch p b) -> patternIds p ++ exprIds b) branches

                Can.Access e _ ->
                    exprIds e

                Can.Update e fields ->
                    exprIds e ++ DMap.foldl (\_ (Can.FieldUpdate _ fe) acc -> exprIds fe ++ acc) [] fields

                Can.Record fields ->
                    DMap.foldl (\_ fe acc -> exprIds fe ++ acc) [] fields

                Can.Tuple a b cs ->
                    List.concatMap exprIds (a :: b :: cs)

                _ ->
                    []
           )


{-| Returns the node id of a pattern and of every pattern inside it.
-}
patternIds : Can.Pattern -> List Int
patternIds (A.At _ info) =
    info.id
        :: (case info.node of
                Can.PAlias p _ ->
                    patternIds p

                Can.PTuple a b cs ->
                    List.concatMap patternIds (a :: b :: cs)

                Can.PList ps ->
                    List.concatMap patternIds ps

                Can.PCons h t ->
                    patternIds h ++ patternIds t

                Can.PCtor { args } ->
                    List.concatMap (\(Can.PatternCtorArg _ _ p) -> patternIds p) args

                _ ->
                    []
           )
