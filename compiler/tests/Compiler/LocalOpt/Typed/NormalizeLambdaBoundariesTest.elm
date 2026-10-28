module Compiler.LocalOpt.Typed.NormalizeLambdaBoundariesTest exposing (suite)

{-| Regression test for a suspected variable-capture bug in
`Compiler.LocalOpt.Typed.NormalizeLambdaBoundaries` (recomment-bugs.txt,
NormalizeLambdaBoundaries.elm line 885).

EXPECTED TO FAIL until the bug is fixed.

The case-boundary rewrite names its fresh parameters after the first branch's
parameters with `_hl_` and a counter appended, and the counter restarts at 0
for every case boundary. `renameExpr` substitutes through the whole branch body
without stopping at binders. In

    f s t =
        case s of
            True ->
                \a -> a

            False ->
                \b -> apply (\y -> case t of
                                    True -> \a -> a + b
                                    False -> \a -> a) 1

the inner boundary is normalized first, giving `\y a_hl_0 -> ... a_hl_0 + b`.
The outer boundary then renames `b` to its own fresh `a_hl_0`, which the inner
lambda's parameter captures: `a + b` becomes `a_hl_0 + a_hl_0`.

The check: no call in the typed-optimized `f` has two arguments that are the
same local variable (the source has no such call).

-}

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
    Test.test "Regression: case-boundary merge does not capture a free variable of an inner boundary" <|
        \_ ->
            case parse source |> Result.andThen Pipeline.runToTypedOpt of
                Err msg ->
                    Expect.fail msg

                Ok result ->
                    Expect.equal [] (sameVarCalls result.localGraph)


source : String
source =
    """module Test exposing (..)


apply : (Int -> Int -> Int) -> Int -> Int
apply g n =
    g n 100


f : Bool -> Bool -> Int -> Int
f s t =
    case s of
        True ->
            \\a -> a

        False ->
            \\b ->
                apply
                    (\\y ->
                        case t of
                            True ->
                                \\a -> a + b

                            False ->
                                \\a -> a
                    )
                    1


testValue : Int
testValue =
    f False True 5
"""


parse : String -> Result String Src.Module
parse src =
    case M.fromByteString M.Application src of
        Ok (Src.Module m) ->
            let
                (Src.Module template) =
                    makeModule "unused" unitExpr
            in
            Ok (Src.Module { m | imports = template.imports })

        Err _ ->
            Err "fixture failed to parse"


{-| The names of the locals passed twice to one call, anywhere in the graph.
-}
sameVarCalls : TOpt.LocalGraph Name -> List Name
sameVarCalls (TOpt.LocalGraph data) =
    Data.Map.foldl
        (\_ node acc ->
            case node of
                TOpt.Define expr _ _ ->
                    walk expr ++ acc

                TOpt.TrackedDefine _ expr _ _ ->
                    walk expr ++ acc

                _ ->
                    acc
        )
        []
        data.nodes


localName : TOpt.Expr Name -> Maybe Name
localName e =
    case e of
        TOpt.VarLocal n _ ->
            Just n

        TOpt.TrackedVarLocal _ n _ ->
            Just n

        _ ->
            Nothing


walk : TOpt.Expr Name -> List Name
walk expr =
    case expr of
        TOpt.Function _ _ body _ ->
            walk body

        TOpt.TrackedFunction _ _ body _ ->
            walk body

        TOpt.Call _ func args _ ->
            let
                names =
                    List.filterMap localName args

                dup =
                    case names of
                        [ x, y ] ->
                            if x == y then
                                [ x ]

                            else
                                []

                        _ ->
                            []
            in
            dup ++ walk func ++ List.concatMap walk args

        TOpt.If branches final _ ->
            List.concatMap (\( c, b ) -> walk c ++ walk b) branches ++ walk final

        TOpt.Let def body _ ->
            (case def of
                TOpt.Def _ _ e _ ->
                    walk e

                TOpt.TailDef _ _ _ e _ _ ->
                    walk e
            )
                ++ walk body

        TOpt.Destruct _ body _ ->
            walk body

        TOpt.Case _ _ decider jumps _ ->
            walkDecider decider ++ List.concatMap (\( _, e ) -> walk e) jumps

        _ ->
            []


walkDecider : TOpt.Decider (TOpt.Choice Name) -> List Name
walkDecider d =
    case d of
        TOpt.Leaf (TOpt.Inline e) ->
            walk e

        TOpt.Leaf (TOpt.Jump _) ->
            []

        TOpt.Chain _ s f ->
            walkDecider s ++ walkDecider f

        TOpt.FanOut _ edges fallback ->
            List.concatMap (\( _, x ) -> walkDecider x) edges ++ walkDecider fallback
