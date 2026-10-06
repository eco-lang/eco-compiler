module TestLogic.Type.NodeTypeVarNamesDistinctTest exposing (suite)

{-| Within one top-level definition, one type variable name in the solver's
node types must stand for one solver variable.

`Compiler.Type.Type.toCanTypeBatch` names the variables of every node type with
one shared name state. `Compiler.Type.Solve.runWithIds` has already run
`Type.toAnnotation` on every top-level definition, which names each variable
of that definition's annotation; those variables keep their names in the node
types, and `toCanTypeBatch` is handed the annotations' names so that no other
variable is given one of them. It cannot find them itself: `toAnnotation`'s
`getVarNames` walk leaves `getVarNamesMark` on those variables, and its own
`getVarNames` walk skips marked variables.

Before that was done, in `f x = let h y = y in ( h x, h 1 )`, `x`'s variable
was named `a` by `f`'s annotation and the batch also named `h`'s own,
generalized variable `a`: two different variables, one name, inside one
definition. Monomorphization identifies type variables by name within a
definition (`Compiler.Monomorphize.AssignMVarIds.ensureBinder`), so it took
one for the other.

The first two tests resolve the solver variable of every node whose type is a
bare type variable to its union-find root
(`Compiler.Type.SolverRoots.normalizeNodeVars`) and require, for each
top-level definition, each name used in that definition's expressions and
patterns to belong to a single root. Two definitions may each use a name for
a variable of their own scheme, as their annotations do.

The other two check the effect on monomorphization as `TestLogic.TestPipeline`
runs it:

  - Substitution engine (`TestPipeline.runToMonoStage5`): in
    `wrapInt x = let h y = y * 2147483648 * 2147483648 in ( x * 1, h 4 )`
    applied to a `Float`, `h` must be specialized at `Int`, its use, not at
    `Float`. With the collision it was specialized at `Float -> Float`, and
    its MLIR multiplied the `Int` 4 with the `Float` multiplication.
  - Solver engine (`TestPipeline.runToGlobalOpt`, the default engine): in
    `capture x = let h y = ( x, y ) in ( h 1, h 2.5 )` applied to a `String`,
    no specialization may be typed with an `( Int, Int )` tuple. With the
    collision the `Int` specialization of `h` was declared
    `Int -> ( Int, Int )` while its body builds a `( String, Int )`.

-}

import Array
import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder as SB
import Compiler.Reporting.Annotation as A
import Compiler.Type.SolverRoots as SolverRoots
import Data.Map as DMap
import Dict
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "Node type variable names are unique per solver variable (toCanTypeBatch)"
        [ Test.test "let-polymorphic helper's variable is not named like the enclosing argument's" <|
            \_ ->
                SB.makeModuleWithDefs "NameCollision"
                    [ ( "f"
                      , [ SB.pVar "x" ]
                      , SB.letExpr [ SB.define "h" [ SB.pVar "y" ] (SB.varExpr "y") ]
                            (SB.tupleExpr
                                (SB.callExpr (SB.varExpr "h") [ SB.varExpr "x" ])
                                (SB.callExpr (SB.varExpr "h") [ SB.intExpr 1 ])
                            )
                      )
                    ]
                    |> expectNamesDistinct
        , Test.test "let helper's variable is not named like the definition's own, next to another polymorphic definition" <|
            \_ ->
                SB.makeModuleWithDefs "NameCollisionAcross"
                    [ ( "first", [ SB.pVar "p", SB.pVar "q" ], SB.varExpr "p" )
                    , ( "g"
                      , [ SB.pVar "z" ]
                      , SB.letExpr [ SB.define "k" [ SB.pVar "w" ] (SB.varExpr "w") ]
                            (SB.tupleExpr (SB.callExpr (SB.varExpr "k") [ SB.varExpr "z" ]) (SB.callExpr (SB.varExpr "k") [ SB.strExpr "s" ]))
                      )
                    ]
                    |> expectNamesDistinct
        , Test.test "substitution engine specializes a let helper at its own use's type, not the enclosing argument's" <|
            \_ ->
                case Pipeline.runToMonoStage5 wrapIntModule of
                    Err msg ->
                        Expect.fail msg

                    Ok result ->
                        let
                            graph =
                                Debug.toString result.monoGraph
                        in
                        Expect.all
                            [ \() ->
                                String.contains "params = [(\"y\",MInt)]" graph
                                    |> Expect.equal True
                                    |> Expect.onFail "h is used at Int (h 4) but no specialization of h takes an Int"
                            , \() ->
                                String.contains "params = [(\"y\",MFloat)]" graph
                                    |> Expect.equal False
                                    |> Expect.onFail "h was specialized at Float, the type of the enclosing argument x that shares h's variable name"
                            ]
                            ()
        , Test.test "solver engine gives a let helper closure the type its body has" <|
            \_ ->
                case Pipeline.runToGlobalOpt captureModule of
                    Err msg ->
                        Expect.fail msg

                    Ok result ->
                        -- The program has no ( Int, Int ) tuple anywhere.
                        String.contains "[MInt,MInt]" (Debug.toString result.monoGraph)
                            |> Expect.equal False
                            |> Expect.onFail "a specialization of h is typed Int -> ( Int, Int ); its body builds ( String, Int )"
        ]


{-| `wrapInt x = let h y = y * 2147483648 * 2147483648 in ( x * 1, h 4 )` and
`testValue = wrapInt 2.5`.
-}
wrapIntModule : Src.Module
wrapIntModule =
    SB.makeModuleWithDefs "WrapInt"
        [ ( "wrapInt"
          , [ SB.pVar "x" ]
          , SB.letExpr
                [ SB.define "h"
                    [ SB.pVar "y" ]
                    (SB.binopsExpr [ ( SB.varExpr "y", "*" ), ( SB.intExpr 2147483648, "*" ) ] (SB.intExpr 2147483648))
                ]
                (SB.tupleExpr
                    (SB.binopsExpr [ ( SB.varExpr "x", "*" ) ] (SB.intExpr 1))
                    (SB.callExpr (SB.varExpr "h") [ SB.intExpr 4 ])
                )
          )
        , ( "testValue", [], SB.callExpr (SB.varExpr "wrapInt") [ SB.floatExpr 2.5 ] )
        ]


{-| `capture x = let h y = ( x, y ) in ( h 1, h 2.5 )` and
`testValue = capture "s"`.
-}
captureModule : Src.Module
captureModule =
    SB.makeModuleWithDefs "Capture"
        [ ( "capture"
          , [ SB.pVar "x" ]
          , SB.letExpr [ SB.define "h" [ SB.pVar "y" ] (SB.tupleExpr (SB.varExpr "x") (SB.varExpr "y")) ]
                (SB.tupleExpr
                    (SB.callExpr (SB.varExpr "h") [ SB.intExpr 1 ])
                    (SB.callExpr (SB.varExpr "h") [ SB.floatExpr 2.5 ])
                )
          )
        , ( "testValue", [], SB.callExpr (SB.varExpr "capture") [ SB.strExpr "s" ] )
        ]


{-| Fails when, inside one top-level definition, one name is the bare type of
nodes whose solver variables have different roots, listing the definition,
the name and the node ids of each root.
-}
expectNamesDistinct : Src.Module -> Expect.Expectation
expectNamesDistinct srcModule =
    case Pipeline.runToTypeCheck srcModule of
        Err msg ->
            Expect.fail msg

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
                                defName
                                    ++ ": '"
                                    ++ name
                                    ++ "' names "
                                    ++ String.fromInt (Dict.size rs)
                                    ++ " different variables: "
                                    ++ String.join "; "
                                        (List.map (\( r, rootIds ) -> r ++ " at nodes " ++ String.join "," (List.map String.fromInt (List.sort rootIds))) (Dict.toList rs))
                            )

                collisions =
                    List.concatMap collisionsIn (topLevelNodeIds result.canonical)
            in
            if List.isEmpty collisions then
                Expect.pass

            else
                Expect.fail (String.join "\n" collisions)


{-| The node ids of the expressions and patterns of each top-level definition,
its argument patterns included.
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


{-| The ids of an expression and of every expression and pattern inside it.
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


{-| The ids of a pattern and of every pattern inside it.
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
