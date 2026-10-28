module Compiler.LocalOpt.Typed.NormalizeLambdaBoundariesDebugNameTest exposing (suite)

{-| Regression test for a bug in
`Compiler.LocalOpt.Typed.NormalizeLambdaBoundaries.renameExpr` (S2 list,
NormalizeLambdaBoundaries.elm lines 199 and 223).

Fixed 2026-10-28 (plans/review-bug-triage-fixes.md, item 3.4); the text
below describes the old behaviour.

`renameExpr` applies the rename environment to the name inside a `VarDebug`
node, which is the name of a `Debug` function (`log`, `todo`, ...), not a local
variable. When a case boundary is merged and a branch's lambda parameter has
the same name as a `Debug` function used in that branch, as in

    f : Bool -> String -> String
    f b =
        case b of
            True ->
                \log -> Debug.log "x" log

            False ->
                \log -> log

the branch is renamed with `log -> log_hl_0` and the `VarDebug "log"` becomes
`VarDebug "log_hl_0"`, a `Debug` function that does not exist.

The graph is built by hand because the mock interfaces the test pipeline
canonicalizes against have no `Debug` module. The check: after
`normalizeLocalGraph`, every `VarDebug` in the graph is still named `log`
(and the case boundary was merged, so the rename really happened).

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.DecisionTree.Test as DT
import Compiler.AST.DecisionTree.TypedPath as DTPath
import Compiler.AST.TypedOptimized as TOpt
import Compiler.Data.Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.LocalOpt.Typed.NormalizeLambdaBoundaries as NLB
import Compiler.Reporting.Annotation as A
import Data.Map
import Data.Set
import Dict
import Expect
import Test exposing (Test)


suite : Test
suite =
    Test.test "Regression: merging a case boundary does not rename a Debug function" <|
        \_ ->
            let
                (TOpt.LocalGraph data) =
                    NLB.normalizeLocalGraph graph

                found =
                    Data.Map.foldl
                        (\_ node acc ->
                            case node of
                                TOpt.Define expr _ _ ->
                                    ( paramCount expr, debugNames expr ) :: acc

                                _ ->
                                    acc
                        )
                        []
                        data.nodes
            in
            -- Two parameters: the boundary was merged. One VarDebug, still `log`.
            Expect.equal [ ( 2, [ "log" ] ) ] found


testHome : ModuleName.Canonical
testHome =
    ModuleName.Canonical ( "eco", "example" ) "Test"


tString : Can.Type Name
tString =
    Can.TType ModuleName.string "String" []


tBool : Can.Type Name
tBool =
    Can.TType ModuleName.basics "Bool" []


meta : Can.Type Name -> TOpt.Meta Name
meta t =
    { tipe = t, tvar = Nothing }


strToStr : Can.Type Name
strToStr =
    Can.tLambda tString tString


branchLog : TOpt.Expr Name
branchLog =
    TOpt.Function Nothing
        [ ( "log", tString ) ]
        (TOpt.Call A.zero
            (TOpt.VarDebug A.zero "log" testHome Nothing (meta (Can.tLambda tString strToStr)))
            [ TOpt.Str A.zero "x" (meta tString), TOpt.VarLocal "log" (meta tString) ]
            (meta tString)
        )
        (meta strToStr)


branchId : TOpt.Expr Name
branchId =
    TOpt.Function Nothing [ ( "log", tString ) ] (TOpt.VarLocal "log" (meta tString)) (meta strToStr)


caseExpr : TOpt.Expr Name
caseExpr =
    TOpt.Case "b"
        "b"
        (TOpt.Chain [ ( DTPath.Empty, DT.IsBool True ) ] (TOpt.Leaf (TOpt.Jump 0)) (TOpt.Leaf (TOpt.Jump 1)))
        [ ( 0, branchLog ), ( 1, branchId ) ]
        (meta strToStr)


fType : Can.Type Name
fType =
    Can.tLambda tBool strToStr


graph : TOpt.LocalGraph Name
graph =
    TOpt.LocalGraph
        { main = Nothing
        , nodes =
            Data.Map.singleton TOpt.toComparableGlobal
                (TOpt.Global testHome "f")
                (TOpt.Define (TOpt.Function Nothing [ ( "b", tBool ) ] caseExpr (meta fType)) Data.Set.empty (meta fType))
        , fields = Dict.empty
        , annotations = Dict.empty
        , schemeRoots = Dict.empty
        , varSupers = Dict.empty
        }


paramCount : TOpt.Expr Name -> Int
paramCount expr =
    case expr of
        TOpt.Function _ params _ _ ->
            List.length params

        TOpt.TrackedFunction _ params _ _ ->
            List.length params

        _ ->
            0


debugNames : TOpt.Expr Name -> List Name
debugNames expr =
    case expr of
        TOpt.VarDebug _ name _ _ _ ->
            [ name ]

        TOpt.Function _ _ body _ ->
            debugNames body

        TOpt.TrackedFunction _ _ body _ ->
            debugNames body

        TOpt.Call _ func args _ ->
            debugNames func ++ List.concatMap debugNames args

        TOpt.Case _ _ decider jumps _ ->
            deciderDebugNames decider ++ List.concatMap (\( _, e ) -> debugNames e) jumps

        _ ->
            []


deciderDebugNames : TOpt.Decider (TOpt.Choice Name) -> List Name
deciderDebugNames d =
    case d of
        TOpt.Leaf (TOpt.Inline e) ->
            debugNames e

        TOpt.Leaf (TOpt.Jump _) ->
            []

        TOpt.Chain _ s f ->
            deciderDebugNames s ++ deciderDebugNames f

        TOpt.FanOut _ options fallback ->
            List.concatMap (\( _, x ) -> deciderDebugNames x) options ++ deciderDebugNames fallback
