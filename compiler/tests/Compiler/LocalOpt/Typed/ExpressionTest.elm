module Compiler.LocalOpt.Typed.ExpressionTest exposing (suite)

{-| Regression test for a bug in
`Compiler.LocalOpt.Typed.Expression.optimizePotentialTailCallDef`
(recomment-bugs.txt, LocalOpt/Typed/Expression.elm lines 1290-1296).

Fixed 2026-10-28 (plans/review-bug-triage-fixes.md, item 3.3); the text
below describes the old behaviour.

The `Can.Def` arm passes the definition's whole function type on to
`optimizePotentialTailCall`, but the `Can.TypedDef` arm passes the
`TypedDef`'s stored type, which is the annotation's RESULT type (after the
argument types). `TOpt.TailDef` documents its type field as "the type of the
whole definition (not its result type)", so an annotated recursive `let`
definition

    go : Int -> Int -> Int
    go n acc = if n <= 0 then acc else go (n - 1) (acc + n)

comes out of typed optimization as a `TailDef` typed `Int` instead of
`Int -> Int -> Int`. The non-tail-recursive variant likewise gives a `Def`
whose `TrackedFunction` is typed `Int`, with two parameters.

The check counts the arrows of each stored type: it must equal the number of
parameters plus the arrows of the annotation's result.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder exposing (makeModule, unitExpr)
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name exposing (Name)
import Compiler.Parse.Module as M
import Data.Map
import Expect
import Test exposing (Test)
import TestLogic.TestPipeline as Pipeline


suite : Test
suite =
    Test.describe "Regression: annotated let rec keeps its whole function type"
        [ Test.test "tail-recursive annotated let def is a TailDef typed Int -> Int -> Int" <|
            \_ ->
                expectDefArrows "go" 2 tailSource
        , Test.test "non-tail recursive annotated let def is typed Int -> Int" <|
            \_ ->
                expectDefArrows "go" 1 nonTailSource
        ]


tailSource : String
tailSource =
    """module Test exposing (..)


testValue : Int
testValue =
    let
        go : Int -> Int -> Int
        go n acc =
            if n <= 0 then
                acc

            else
                go (n - 1) (acc + n)
    in
    go 10 0
"""


nonTailSource : String
nonTailSource =
    """module Test exposing (..)


testValue : Int
testValue =
    let
        go : Int -> Int
        go n =
            if n <= 0 then
                0

            else
                1 + go (n - 1)
    in
    go 10
"""


parse : String -> Result String Src.Module
parse source =
    case M.fromByteString M.Application source of
        Ok (Src.Module m) ->
            let
                    (Src.Module template) =
                        makeModule "unused" unitExpr
            in
            Ok (Src.Module { m | imports = template.imports })

        Err _ ->
            Err "fixture failed to parse"


expectDefArrows : Name -> Int -> String -> Expect.Expectation
expectDefArrows name expected source =
    case parse source |> Result.andThen Pipeline.runToTypedOpt of
        Err msg ->
            Expect.fail msg

        Ok result ->
            case findDefTypes name result.localGraph of
                [] ->
                    Expect.fail ("no let definition named " ++ name ++ " found")

                found ->
                    Expect.equal (List.map (\( kind, t ) -> ( kind, arrows t )) found)
                        (List.map (\( kind, _ ) -> ( kind, expected )) found)


arrows : Can.Type Name -> Int
arrows t =
    case t of
        Can.TLambda _ _ res ->
            1 + arrows res

        Can.TAlias _ _ _ (Can.Filled inner) ->
            arrows inner

        _ ->
            0


findDefTypes : Name -> TOpt.LocalGraph Name -> List ( String, Can.Type Name )
findDefTypes name (TOpt.LocalGraph data) =
    Data.Map.foldl
        (\_ node acc ->
            case node of
                TOpt.Define expr _ _ ->
                    inExpr name expr ++ acc

                TOpt.TrackedDefine _ expr _ _ ->
                    inExpr name expr ++ acc

                _ ->
                    acc
        )
        []
        data.nodes


inExpr : Name -> TOpt.Expr Name -> List ( String, Can.Type Name )
inExpr name expr =
    case expr of
        TOpt.Let def body _ ->
            inDef name def ++ inExpr name body

        TOpt.Destruct _ body _ ->
            inExpr name body

        _ ->
            []


inDef : Name -> TOpt.Def Name -> List ( String, Can.Type Name )
inDef name def =
    case def of
        TOpt.TailDef _ n _ _ t _ ->
            if n == name then
                [ ( "TailDef", t ) ]

            else
                []

        TOpt.Def _ n inner t ->
            if n == name then
                [ ( "Def", t ) ]
                    ++ (case inner of
                            TOpt.TrackedFunction _ _ _ meta ->
                                [ ( "Def/TrackedFunction", meta.tipe ) ]

                            _ ->
                                []
                       )

            else
                []
